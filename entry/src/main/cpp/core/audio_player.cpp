#include "audio_player.h"
#include "diagnostic_log.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <sstream>
#include <hilog/log.h>
#include <ohaudio/native_audiostreambuilder.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "StarRustDeskAudio"

namespace {
constexpr size_t MAX_BUFFERED_SAMPLES = 48000 * 2;

int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
}

AudioPlayer& AudioPlayer::instance() {
    static AudioPlayer player;
    return player;
}

AudioPlayer::~AudioPlayer() {
    // DiagnosticLog may already have been destroyed during static teardown.
    OH_AudioRenderer* renderer = nullptr;
    OpusDecoder* decoder = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        detachLocked(renderer, decoder);
    }
    releaseDetached(renderer, decoder);
}

int AudioPlayer::start(int sampleRate, int channels) {
    if (sampleRate <= 0 || channels <= 0 || channels > 2) {
        return -1;
    }

    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (running_ && renderer_ != nullptr && sampleRate_ == sampleRate && channels_ == channels) {
            return 0;
        }
    }

    OH_AudioRenderer* oldRenderer = nullptr;
    OpusDecoder* oldDecoder = nullptr;
    reportDiagnostics(true, "restart");
    {
        std::lock_guard<std::mutex> lock(mutex_);
        detachLocked(oldRenderer, oldDecoder);
        health_ = {};
        ++generation_;
        healthStartedAt_ = NowMs();
        lastReportAt_ = 0;
    }
    releaseDetached(oldRenderer, oldDecoder);

    int opusError = OPUS_OK;
    OpusDecoder* decoder = opus_decoder_create(sampleRate, channels, &opusError);
    if (opusError != OPUS_OK || decoder == nullptr) {
        OH_LOG_ERROR(LOG_APP, "opus decoder create failed error=%{public}d", opusError);
        return -2;
    }

    OH_AudioStreamBuilder* builder = nullptr;
    if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS || builder == nullptr) {
        OH_LOG_ERROR(LOG_APP, "audio builder create failed");
        opus_decoder_destroy(decoder);
        return -3;
    }

    OH_AudioStreamBuilder_SetSamplingRate(builder, sampleRate);
    OH_AudioStreamBuilder_SetChannelCount(builder, channels);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);

    OH_AudioRenderer_Callbacks callbacks {};
    callbacks.OH_AudioRenderer_OnWriteData = AudioPlayer::OnWriteData;
    callbacks.OH_AudioRenderer_OnInterruptEvent = AudioPlayer::OnInterrupt;
    callbacks.OH_AudioRenderer_OnError = AudioPlayer::OnError;
    OH_AudioStreamBuilder_SetRendererCallback(builder, callbacks, this);

    OH_AudioRenderer* renderer = nullptr;
    OH_AudioStream_Result result = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer);
    OH_AudioStreamBuilder_Destroy(builder);
    if (result != AUDIOSTREAM_SUCCESS || renderer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "audio renderer create failed result=%{public}d", result);
        if (renderer != nullptr) {
            OH_AudioRenderer_Release(renderer);
        }
        opus_decoder_destroy(decoder);
        return -4;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        renderer_ = renderer;
        decoder_ = decoder;
        decodeBuffer_.assign(static_cast<size_t>(sampleRate) * static_cast<size_t>(channels), 0);
        sampleRate_ = sampleRate;
        channels_ = channels;
        running_ = true;
    }

    // Starting the renderer can invoke OnWriteData immediately. Do not hold
    // mutex_ here because the callback needs it to fill the first buffer.
    result = OH_AudioRenderer_Start(renderer);
    if (result != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "audio renderer start failed result=%{public}d", result);
        OH_AudioRenderer* failedRenderer = nullptr;
        OpusDecoder* failedDecoder = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (renderer_ == renderer) {
                detachLocked(failedRenderer, failedDecoder);
            }
        }
        releaseDetached(failedRenderer, failedDecoder);
        return -5;
    }

    OH_LOG_INFO(LOG_APP, "audio renderer started sampleRate=%{public}d channels=%{public}d", sampleRate, channels);
    return 0;
}

void AudioPlayer::stop() {
    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    reportDiagnostics(true, "stop");
    OH_AudioRenderer* renderer = nullptr;
    OpusDecoder* decoder = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        detachLocked(renderer, decoder);
    }
    releaseDetached(renderer, decoder);
}

void AudioPlayer::pushOpusFrame(const uint8_t* data, int length) {
    std::lock_guard<std::mutex> lock(mutex_);
    ++health_.receivedFrames;
    health_.lastPacketAt = NowMs();
    if (data == nullptr || length <= 0) {
        ++health_.invalidDrops;
        return;
    }
    health_.receivedBytes += static_cast<uint64_t>(length);
    if (!running_ || decoder_ == nullptr || decodeBuffer_.empty()) {
        ++health_.inactiveDrops;
        return;
    }

    int frameSize = opus_decode(decoder_, data, length, decodeBuffer_.data(),
                                static_cast<int>(decodeBuffer_.size() / channels_), 0);
    if (frameSize <= 0) {
        ++health_.decodeErrors;
        health_.lastDecodeError = frameSize;
        OH_LOG_WARN(LOG_APP, "opus decode failed result=%{public}d", frameSize);
        return;
    }
    int sampleCount = frameSize * channels_;
    ++health_.decodedFrames;
    health_.decodedSamples += static_cast<uint64_t>(sampleCount);
    queue_.insert(queue_.end(), decodeBuffer_.data(), decodeBuffer_.data() + sampleCount);
    lastFrameAtMs_ = NowMs();
    while (queue_.size() > MAX_BUFFERED_SAMPLES) {
        queue_.pop_front();
        ++health_.overflowSamples;
    }
}

bool AudioPlayer::isRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_;
}

bool AudioPlayer::hasRecentFrames(int64_t maxAgeMs) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_ && lastFrameAtMs_ > 0 && NowMs() - lastFrameAtMs_ <= maxAgeMs;
}

void AudioPlayer::noteMutedFrame() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++health_.mutedDrops;
}

void AudioPlayer::reportDiagnostics(bool force, const char* reason) {
    std::string message;
    bool warning = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const int64_t now = NowMs();
        if (!running_ && health_.receivedFrames == 0 && health_.mutedDrops == 0) return;
        if (!force && lastReportAt_ != 0 && now - lastReportAt_ < 10000) return;
        lastReportAt_ = now;
        const char* phase = !running_ ? "inactive" : health_.receivedFrames == 0 ? "awaiting_packets" :
            health_.decodedFrames == 0 ? "no_decoded_pcm" : health_.writeCallbacks == 0 ? "awaiting_callback" :
            health_.renderedSamples == 0 ? "no_pcm_consumed" : "pcm_consumed";
        warning = health_.decodeErrors > 0 || health_.rendererErrors > 0 ||
            (running_ && now - healthStartedAt_ > 10000 && health_.receivedFrames == 0);
        std::ostringstream out;
        // Counters only: no encoded audio, PCM samples, waveform or content.
        out << "health reason=" << reason << " generation=" << generation_ << " phase=" << phase
            << " running=" << running_ << " sample_rate=" << sampleRate_ << " channels=" << channels_
            << " received_frames=" << health_.receivedFrames << " received_bytes=" << health_.receivedBytes
            << " decoded_frames=" << health_.decodedFrames << " decoded_samples=" << health_.decodedSamples
            << " decode_errors=" << health_.decodeErrors << " decode_error=" << health_.lastDecodeError
            << " inactive_drops=" << health_.inactiveDrops << " muted_drops=" << health_.mutedDrops
            << " invalid_drops=" << health_.invalidDrops << " overflow_samples=" << health_.overflowSamples
            << " write_callbacks=" << health_.writeCallbacks << " consumed_samples=" << health_.renderedSamples
            << " silence_samples=" << health_.silenceSamples << " underruns=" << health_.underruns
            << " queue_samples=" << queue_.size() << " interrupts=" << health_.interrupts
            << " interrupt_type=" << health_.interruptType << " interrupt_hint=" << health_.interruptHint
            << " renderer_errors=" << health_.rendererErrors << " renderer_error=" << health_.lastRendererError
            << " packet_age_ms=" << (health_.lastPacketAt == 0 ? -1 : now - health_.lastPacketAt)
            << " write_age_ms=" << (health_.lastWriteAt == 0 ? -1 : now - health_.lastWriteAt);
        message = out.str();
    }
    DiagnosticLog::instance().append(warning ? "W" : "I", "audio", message);
}

int32_t AudioPlayer::OnInterrupt(OH_AudioRenderer* renderer, void* userData,
    OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint) {
    auto* player = static_cast<AudioPlayer*>(userData);
    if (!player) return 0;
    std::lock_guard<std::mutex> lock(player->mutex_);
    if (player->renderer_ == renderer && player->running_) {
        ++player->health_.interrupts;
        player->health_.interruptType = static_cast<int>(type);
        player->health_.interruptHint = static_cast<int>(hint);
    }
    return 0;
}

int32_t AudioPlayer::OnError(OH_AudioRenderer* renderer, void* userData, OH_AudioStream_Result error) {
    auto* player = static_cast<AudioPlayer*>(userData);
    if (!player) return 0;
    std::lock_guard<std::mutex> lock(player->mutex_);
    if (player->renderer_ == renderer && player->running_) {
        ++player->health_.rendererErrors;
        player->health_.lastRendererError = static_cast<int>(error);
    }
    return 0;
}

int32_t AudioPlayer::OnWriteData(OH_AudioRenderer* renderer, void* userData, void* buffer, int32_t length) {
    auto* player = static_cast<AudioPlayer*>(userData);
    if (player == nullptr) {
        if (buffer != nullptr && length > 0) {
            std::memset(buffer, 0, static_cast<size_t>(length));
        }
        return length;
    }
    return player->fillBuffer(renderer, buffer, length);
}

int32_t AudioPlayer::fillBuffer(OH_AudioRenderer* renderer, void* buffer, int32_t length) {
    if (buffer == nullptr || length <= 0) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (renderer != renderer_ || !running_) {
        std::memset(buffer, 0, static_cast<size_t>(length));
        return length;
    }
    ++health_.writeCallbacks;
    health_.lastWriteAt = NowMs();
    auto* out = static_cast<int16_t*>(buffer);
    int sampleCapacity = length / static_cast<int32_t>(sizeof(int16_t));
    int sampleCount = std::min(sampleCapacity, static_cast<int>(queue_.size()));
    health_.renderedSamples += static_cast<uint64_t>(sampleCount);
    health_.silenceSamples += static_cast<uint64_t>(sampleCapacity - sampleCount);
    for (int i = 0; i < sampleCount; ++i) {
        out[i] = queue_.front();
        queue_.pop_front();
    }
    if (sampleCount < sampleCapacity) {
        ++health_.underruns;
        std::memset(out + sampleCount, 0, static_cast<size_t>(sampleCapacity - sampleCount) * sizeof(int16_t));
    }
    return length;
}

void AudioPlayer::detachLocked(OH_AudioRenderer*& renderer, OpusDecoder*& decoder) {
    running_ = false;
    lastFrameAtMs_ = 0;
    queue_.clear();
    sampleRate_ = 0;
    channels_ = 0;
    decodeBuffer_.clear();
    renderer = renderer_;
    renderer_ = nullptr;
    decoder = decoder_;
    decoder_ = nullptr;
}

void AudioPlayer::releaseDetached(OH_AudioRenderer* renderer, OpusDecoder* decoder) {
    if (renderer != nullptr) {
        OH_AudioRenderer_Stop(renderer);
        OH_AudioRenderer_Release(renderer);
    }
    if (decoder != nullptr) {
        opus_decoder_destroy(decoder);
    }
}

extern "C" int audio_player_start(int sampleRate, int channels) {
    return AudioPlayer::instance().start(sampleRate, channels);
}

extern "C" void audio_player_stop() {
    AudioPlayer::instance().stop();
}

extern "C" void audio_player_push_opus_frame(const uint8_t* data, int length) {
    AudioPlayer::instance().pushOpusFrame(data, length);
}
