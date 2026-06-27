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

private:
    AudioPlayer() = default;
    ~AudioPlayer();
    AudioPlayer(const AudioPlayer&) = delete;
    AudioPlayer& operator=(const AudioPlayer&) = delete;

    static int32_t OnWriteData(OH_AudioRenderer* renderer, void* userData, void* buffer, int32_t length);
    int32_t fillBuffer(void* buffer, int32_t length);
    void releaseLocked();

    mutable std::mutex mutex_;
    OH_AudioRenderer* renderer_ = nullptr;
    OpusDecoder* decoder_ = nullptr;
    std::deque<int16_t> queue_;
    std::vector<int16_t> decodeBuffer_;
    int sampleRate_ = 0;
    int channels_ = 0;
    bool running_ = false;
};

extern "C" int audio_player_start(int sampleRate, int channels);
extern "C" void audio_player_stop();
extern "C" void audio_player_push_opus_frame(const uint8_t* data, int length);

#endif
