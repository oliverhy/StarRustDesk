#include "audio_player.h"
#include <algorithm>
#include <chrono>
#include <cstring>
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
    stop();
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
    {
        std::lock_guard<std::mutex> lock(mutex_);
        detachLocked(oldRenderer, oldDecoder);
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
    OH_AudioRenderer* renderer = nullptr;
    OpusDecoder* decoder = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        detachLocked(renderer, decoder);
    }
    releaseDetached(renderer, decoder);
}

void AudioPlayer::pushOpusFrame(const uint8_t* data, int length) {
    if (data == nullptr || length <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_ || decoder_ == nullptr || decodeBuffer_.empty()) {
        return;
    }

    int frameSize = opus_decode(decoder_, data, length, decodeBuffer_.data(),
                                static_cast<int>(decodeBuffer_.size() / channels_), 0);
    if (frameSize <= 0) {
        OH_LOG_WARN(LOG_APP, "opus decode failed result=%{public}d", frameSize);
        return;
    }
    int sampleCount = frameSize * channels_;
    queue_.insert(queue_.end(), decodeBuffer_.data(), decodeBuffer_.data() + sampleCount);
    lastFrameAtMs_ = NowMs();
    while (queue_.size() > MAX_BUFFERED_SAMPLES) {
        queue_.pop_front();
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

int32_t AudioPlayer::OnWriteData(OH_AudioRenderer*, void* userData, void* buffer, int32_t length) {
    auto* player = static_cast<AudioPlayer*>(userData);
    if (player == nullptr) {
        if (buffer != nullptr && length > 0) {
            std::memset(buffer, 0, static_cast<size_t>(length));
        }
        return length;
    }
    return player->fillBuffer(buffer, length);
}

int32_t AudioPlayer::fillBuffer(void* buffer, int32_t length) {
    if (buffer == nullptr || length <= 0) {
        return 0;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    auto* out = static_cast<int16_t*>(buffer);
    int sampleCapacity = length / static_cast<int32_t>(sizeof(int16_t));
    int sampleCount = std::min(sampleCapacity, static_cast<int>(queue_.size()));
    for (int i = 0; i < sampleCount; ++i) {
        out[i] = queue_.front();
        queue_.pop_front();
    }
    if (sampleCount < sampleCapacity) {
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
