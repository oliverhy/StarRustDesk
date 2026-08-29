#ifndef RUSTDESK_CORE_SOFTWARE_VP8_DECODER_H
#define RUSTDESK_CORE_SOFTWARE_VP8_DECODER_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include <vpx/vpx_decoder.h>

class SoftwareVP8Decoder {
public:
    static SoftwareVP8Decoder& instance();

    void decodeFrame(const uint8_t* data, int length, bool key, int64_t pts);
    void release();

private:
    struct EncodedFrame {
        std::vector<uint8_t> data;
        bool key;
        int64_t pts;
        uint64_t generation;
    };

    SoftwareVP8Decoder();
    ~SoftwareVP8Decoder();
    SoftwareVP8Decoder(const SoftwareVP8Decoder&) = delete;
    SoftwareVP8Decoder& operator=(const SoftwareVP8Decoder&) = delete;

    void workerLoop();
    bool initializeDecoder();
    void destroyDecoder();
    bool convertFrame(vpx_image_t* image, std::vector<uint8_t>& bgra);

    std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<EncodedFrame> frames_;
    std::thread worker_;
    bool stopping_{false};
    bool resetRequested_{false};
    bool waitingForKeyframe_{false};
    uint64_t generation_{1};
    uint64_t queuedFrames_{0};
    std::atomic<uint64_t> decodedFrames_{0};
    std::atomic<uint64_t> decodeErrors_{0};
    uint64_t overflowDrops_{0};
    vpx_codec_ctx_t codec_{};
    std::atomic<bool> initialized_{false};
};

#endif
