#ifndef RUSTDESK_CORE_VIDEO_RENDER_H
#define RUSTDESK_CORE_VIDEO_RENDER_H

#include <cstdint>
#include <atomic>
#include <deque>
#include <functional>
#include <mutex>
#include <vector>

struct VideoDecoderCapabilities {
    bool h264;
    bool vp9;
    bool vp8;
    bool av1;
    bool h265;
};

class VideoRender {
public:
    static VideoRender& instance();

    void onFrameReceived(const uint8_t* data, int length, int width, int height, bool key, int64_t pts);

    void setFrameCallback(std::function<void(const uint8_t*, int, int, int)> callback);

    bool getLatestFrame(uint8_t*& data, int& length, int& width, int& height);
    uint64_t decodedFrameCount() const;
    int activeCodec() const;
    int activeDecodeMode() const;
    void markDecodedFrame(int codec, int width = 0, int height = 0, int decodeMode = 0);

    void setSurfaceId(const std::string& surfaceId);
    void prepareSurfaceRebind();
    void rebindSurface(const std::string& surfaceId);
    std::string getSurfaceId();
    void resetSession();
    VideoDecoderCapabilities decoderCapabilities();

private:
    struct PendingFrame {
        std::vector<uint8_t> data;
        int width;
        int height;
        bool key;
        int64_t pts;
    };

    VideoRender() {}
    void renderFrameNow(const uint8_t* data, int length, int width, int height, bool key, int64_t pts);
    void queuePendingFrame(const uint8_t* data, int length, int width, int height, bool key, int64_t pts);
    void flushPendingFrames();
    void flushPendingFramesAsync();

    std::mutex mutex_;
    std::deque<PendingFrame> pendingFrames_;
    int frameWidth_{0};
    int frameHeight_{0};
    int decodedFrameWidth_{0};
    int decodedFrameHeight_{0};
    int frameLength_{0};
    bool hasFrame_{false};
    std::atomic<uint64_t> decodedFrameCount_{0};
    std::atomic<int> activeCodec_{0};
    std::atomic<int> activeDecodeMode_{0};
    std::mutex surfaceMutex_;
    std::string surfaceId_;
    std::function<void(const uint8_t*, int, int, int)> frameCallback_;
};

#endif
