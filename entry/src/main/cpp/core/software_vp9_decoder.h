#ifndef RUSTDESK_CORE_SOFTWARE_VP9_DECODER_H
#define RUSTDESK_CORE_SOFTWARE_VP9_DECODER_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

#include <vpx/vpx_decoder.h>
#include "video_color.h"

class SoftwareVP9Decoder {
public:
    using OutputCallback = std::function<bool(const uint8_t*, int, int, int, const VideoColorInfo&)>;
    static SoftwareVP9Decoder& instance();
    // A separate decoder is needed for each independently encoded screen.
    // An empty callback retains the existing primary-renderer behavior.
    explicit SoftwareVP9Decoder(OutputCallback outputCallback = {});
    ~SoftwareVP9Decoder();

    void decodeFrame(const uint8_t* data, int length, bool key, int64_t pts);
    int queuedFrameCount() {
        std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
        return lock.owns_lock() ? static_cast<int>(frames_.size()) : -1;
    }
    void release();

private:
    struct EncodedFrame {
        std::vector<uint8_t> data;
        bool key;
        int64_t pts;
        uint64_t generation;
    };

    SoftwareVP9Decoder(const SoftwareVP9Decoder&) = delete;
    SoftwareVP9Decoder& operator=(const SoftwareVP9Decoder&) = delete;

    void workerLoop();
    bool initializeDecoder();
    void destroyDecoder();
    bool convertFrame(vpx_image_t* image, std::vector<uint8_t>& bgra);

    std::mutex mutex_;
    // Serialize presentation against reset, without holding the input queue lock.
    std::mutex presentationMutex_;
    std::condition_variable condition_;
    std::deque<EncodedFrame> frames_;
    OutputCallback outputCallback_;
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
    // Construct the worker last: it can observe every field as soon as it starts.
    std::thread worker_;
};

#endif
