#ifndef RUSTDESK_CORE_AUDIO_PLAYER_H
#define RUSTDESK_CORE_AUDIO_PLAYER_H

#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>
#include <ohaudio/native_audiorenderer.h>
#include <opus.h>

class AudioPlayer {
public:
    static AudioPlayer& instance();

    int start(int sampleRate, int channels);
    void stop();
    void pushOpusFrame(const uint8_t* data, int length);
    bool isRunning() const;
    bool hasRecentFrames(int64_t maxAgeMs) const;
    void noteMutedFrame();
    // Called from polling/export/stop, never from the real-time write callback.
    void reportDiagnostics(bool force = false, const char* reason = "poll");

private:
    AudioPlayer() = default;
    ~AudioPlayer();
    AudioPlayer(const AudioPlayer&) = delete;
    AudioPlayer& operator=(const AudioPlayer&) = delete;

    static int32_t OnWriteData(OH_AudioRenderer* renderer, void* userData, void* buffer, int32_t length);
    static int32_t OnInterrupt(OH_AudioRenderer* renderer, void* userData,
        OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint);
    static int32_t OnError(OH_AudioRenderer* renderer, void* userData, OH_AudioStream_Result error);
    int32_t fillBuffer(OH_AudioRenderer* renderer, void* buffer, int32_t length);
    void detachLocked(OH_AudioRenderer*& renderer, OpusDecoder*& decoder);
    static void releaseDetached(OH_AudioRenderer* renderer, OpusDecoder* decoder);

    mutable std::mutex lifecycleMutex_;
    mutable std::mutex mutex_;
    OH_AudioRenderer* renderer_ = nullptr;
    OpusDecoder* decoder_ = nullptr;
    std::deque<int16_t> queue_;
    std::vector<int16_t> decodeBuffer_;
    int sampleRate_ = 0;
    int channels_ = 0;
    bool running_ = false;
    int64_t lastFrameAtMs_ = 0;
    struct Health {
        uint64_t receivedFrames = 0;
        uint64_t receivedBytes = 0;
        uint64_t decodedFrames = 0;
        uint64_t decodedSamples = 0;
        uint64_t decodeErrors = 0;
        uint64_t inactiveDrops = 0;
        uint64_t mutedDrops = 0;
        uint64_t invalidDrops = 0;
        uint64_t overflowSamples = 0;
        uint64_t writeCallbacks = 0;
        uint64_t renderedSamples = 0;
        uint64_t silenceSamples = 0;
        uint64_t underruns = 0;
        uint64_t interrupts = 0;
        uint64_t rendererErrors = 0;
        int lastDecodeError = 0;
        int lastRendererError = 0;
        int interruptType = -1;
        int interruptHint = -1;
        int64_t lastPacketAt = 0;
        int64_t lastWriteAt = 0;
    } health_;
    uint64_t generation_ = 0;
    int64_t healthStartedAt_ = 0;
    int64_t lastReportAt_ = 0;
};

extern "C" int audio_player_start(int sampleRate, int channels);
extern "C" void audio_player_stop();
extern "C" void audio_player_push_opus_frame(const uint8_t* data, int length);

#endif
