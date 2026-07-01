#include "video_render.h"
#include "h264_decoder.h"
#include "vp9_decoder.h"
#include "xcomponent_render.h"
#include <cstring>
#include <hilog/log.h>
#include <atomic>
#include <mutex>
#include <thread>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskVideo"

namespace {
enum class ActiveDecoder {
    None,
    H264,
    VP9,
};

std::mutex g_decoderMutex;
ActiveDecoder g_activeDecoder = ActiveDecoder::None;
std::atomic<bool> g_releaseInProgress{false};
std::atomic<bool> g_flushInProgress{false};

bool hasRustDeskFrameTag(const uint8_t* data, int length) {
    return length > 5 && data[0] == 'S' && data[1] == 'R' && data[2] == 'D' && data[3] == '0';
}

void ensureH264Decoder(OHNativeWindow* window, int width, int height) {
    if (window == nullptr) {
        OH_LOG_WARN(LOG_APP, "H264 decoder waiting for native window");
        return;
    }
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::H264) {
        VP9Decoder::instance().release();
        g_activeDecoder = ActiveDecoder::H264;
    }
    H264Decoder::instance().setSurface(window, width, height);
}

void ensureVP9Decoder(OHNativeWindow* window, int width, int height) {
    if (window == nullptr) {
        OH_LOG_WARN(LOG_APP, "VP9 decoder waiting for native window");
        return;
    }
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::VP9) {
        H264Decoder::instance().release();
        g_activeDecoder = ActiveDecoder::VP9;
    }
    VP9Decoder::instance().setSurface(window, width, height);
}

void releaseActiveDecoder() {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    H264Decoder::instance().release();
    VP9Decoder::instance().release();
    g_activeDecoder = ActiveDecoder::None;
}

void releaseActiveDecoderAsync() {
    bool expected = false;
    if (!g_releaseInProgress.compare_exchange_strong(expected, true)) {
        return;
    }

    std::thread([]() {
        releaseActiveDecoder();
        g_releaseInProgress.store(false);
    }).detach();
}
}

VideoRender& VideoRender::instance() {
    static VideoRender render;
    return render;
}

// Detect if the binary data is H264 AnnexB format (starts with 00 00 00 01 or 00 00 01)
static bool isAnnexB(const uint8_t* data, int length) {
    if (length < 3) return false;
    if (length >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) return true;
    if (data[0] == 0 && data[1] == 0 && data[2] == 1) return true;
    return false;
}

void VideoRender::onFrameReceived(const uint8_t* data, int length, int width, int height) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        frameWidth_ = width;
        frameHeight_ = height;
        frameLength_ = length;
        hasFrame_ = true;
    }

    if (!surfaceId_.empty() && XComponentRender::instance().window() != nullptr) {
        flushPendingFrames();
        renderFrameNow(data, length, width, height);
    } else if (hasRustDeskFrameTag(data, length)) {
        queuePendingFrame(data, length, width, height);
    }

    if (frameCallback_) {
        frameCallback_(data, length, width, height);
    }
}

void VideoRender::setFrameCallback(std::function<void(const uint8_t*, int, int, int)> callback) {
    frameCallback_ = callback;
}

bool VideoRender::getLatestFrame(uint8_t*& data, int& length, int& width, int& height) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!hasFrame_) return false;
    data = nullptr;
    length = frameLength_;
    width = frameWidth_;
    height = frameHeight_;
    return true;
}

void VideoRender::setSurfaceId(const std::string& surfaceId) {
    if (!surfaceId.empty() && surfaceId == surfaceId_ && XComponentRender::instance().window() != nullptr) {
        flushPendingFramesAsync();
        return;
    }

    surfaceId_ = surfaceId;
    if (!surfaceId.empty()) {
        XComponentRender::instance().setSurface(surfaceId);
        flushPendingFramesAsync();
    } else {
        releaseActiveDecoderAsync();
        XComponentRender::instance().release();
    }
}

std::string VideoRender::getSurfaceId() {
    return surfaceId_;
}

void VideoRender::resetSession() {
    releaseActiveDecoderAsync();
    std::lock_guard<std::mutex> lock(mutex_);
    pendingFrames_.clear();
    frameWidth_ = 0;
    frameHeight_ = 0;
    frameLength_ = 0;
    hasFrame_ = false;
}

void VideoRender::renderFrameNow(const uint8_t* data, int length, int width, int height) {
    OHNativeWindow* window = XComponentRender::instance().window();
    if (hasRustDeskFrameTag(data, length)) {
        char codec = static_cast<char>(data[4]);
        const uint8_t* payload = data + 5;
        int payloadLength = length - 5;
        if (codec == 'H') {
            ensureH264Decoder(window, width, height);
            H264Decoder::instance().decodeFrame(payload, payloadLength);
        } else if (codec == 'V') {
            ensureVP9Decoder(window, width, height);
            VP9Decoder::instance().decodeFrame(payload, payloadLength);
        } else {
            OH_LOG_WARN(LOG_APP, "Unsupported tagged codec=%{public}c", codec);
        }
    } else if (length >= width * height * 4) {
        releaseActiveDecoder();
        XComponentRender::instance().renderFrame(data, length, width, height);
    } else if (isAnnexB(data, length)) {
        ensureH264Decoder(window, width, height);
        H264Decoder::instance().decodeFrame(data, length);
    } else {
        ensureVP9Decoder(window, width, height);
        VP9Decoder::instance().decodeFrame(data, length);
    }
}

void VideoRender::queuePendingFrame(const uint8_t* data, int length, int width, int height) {
    PendingFrame frame;
    frame.data.assign(data, data + length);
    frame.width = width;
    frame.height = height;

    std::lock_guard<std::mutex> lock(mutex_);
    while (pendingFrames_.size() >= 2) {
        pendingFrames_.pop_front();
    }
    pendingFrames_.push_back(std::move(frame));
}

void VideoRender::flushPendingFrames() {
    if (XComponentRender::instance().window() == nullptr) {
        return;
    }

    std::deque<PendingFrame> frames;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        frames.swap(pendingFrames_);
    }

    for (const PendingFrame& frame : frames) {
        renderFrameNow(frame.data.data(), static_cast<int>(frame.data.size()), frame.width, frame.height);
    }
}

void VideoRender::flushPendingFramesAsync() {
    bool expected = false;
    if (!g_flushInProgress.compare_exchange_strong(expected, true)) {
        return;
    }

    std::thread([]() {
        VideoRender::instance().flushPendingFrames();
        g_flushInProgress.store(false);
    }).detach();
}
