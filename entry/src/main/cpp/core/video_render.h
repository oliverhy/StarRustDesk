#ifndef RUSTDESK_CORE_VIDEO_RENDER_H
#define RUSTDESK_CORE_VIDEO_RENDER_H

#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <vector>

class VideoRender {
public:
    static VideoRender& instance();

    void onFrameReceived(const uint8_t* data, int length, int width, int height);

    void setFrameCallback(std::function<void(const uint8_t*, int, int, int)> callback);

    bool getLatestFrame(uint8_t*& data, int& length, int& width, int& height);

    void setSurfaceId(const std::string& surfaceId);
    std::string getSurfaceId();
    void resetSession();

private:
    struct PendingFrame {
        std::vector<uint8_t> data;
        int width;
        int height;
    };

    VideoRender() {}
    void renderFrameNow(const uint8_t* data, int length, int width, int height);
    void queuePendingFrame(const uint8_t* data, int length, int width, int height);
    void flushPendingFrames();
    void flushPendingFramesAsync();

    std::mutex mutex_;
    std::deque<PendingFrame> pendingFrames_;
    int frameWidth_{0};
    int frameHeight_{0};
    int frameLength_{0};
    bool hasFrame_{false};
    std::string surfaceId_;
    std::function<void(const uint8_t*, int, int, int)> frameCallback_;
};

#endif
