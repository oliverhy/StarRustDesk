#ifndef RUSTDESK_SECONDARY_VIDEO_RENDER_H
#define RUSTDESK_SECONDARY_VIDEO_RENDER_H

#include <cstdint>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "h264_decoder.h"
#include "software_vp9_decoder.h"
#include "system_video_decoder.h"
#include "xcomponent_render.h"

// Owns its surface and codec instances; never touches primary renderer state.
// The bounded receive queue keeps decoder/driver work off the network thread.
class SecondaryVideoRender {
public:
    SecondaryVideoRender();
    ~SecondaryVideoRender();
    SecondaryVideoRender(const SecondaryVideoRender&) = delete;
    SecondaryVideoRender& operator=(const SecondaryVideoRender&) = delete;

    bool setSurface(const std::string& surfaceId);
    bool enqueue(const uint8_t* data, int length, int width, int height, bool key, int64_t pts, int codec);
    void reset();
    uint64_t presentedFrames() const { return presentedFrames_.load(); }
    int error() const { return error_.load(); }

private:
    struct Frame {
        std::vector<uint8_t> data;
        int width{0};
        int height{0};
        int codec{0};
        bool key{false};
        int64_t pts{0};
        uint64_t generation{0};
    };
    void run();
    void process(const Frame& frame);
    void releaseDecodersLocked();
    bool startDecoderLocked(const Frame& frame);
    void reportOutput(bool presented, uint64_t generation, int codec);
    void reportDecoderError(int code, uint64_t generation);

    std::mutex stateMutex_;
    XComponentRender surface_{true};
    std::atomic<uint64_t> presentedFrames_{0};
    std::atomic<int> error_{0};
    std::atomic<bool> active_{false};
    std::atomic<uint64_t> generation_{1};
    std::atomic<bool> errorsEnabled_{false};
    std::atomic<int> failedOutputs_{0};
    std::unique_ptr<SoftwareVP9Decoder> vp9_;
    std::unique_ptr<H264Decoder> h264_;
    std::unique_ptr<SystemVideoDecoder> h265_;
    int activeCodec_{0};
    int activeWidth_{0};
    int activeHeight_{0};
    uint64_t activeGeneration_{0};
    std::mutex queueMutex_;
    std::condition_variable ready_;
    std::deque<Frame> frames_;
    size_t queuedBytes_{0};
    int queuedCodec_{0};
    bool refreshPending_{false};
    bool stopping_{false};
    std::thread worker_;
};

#endif
