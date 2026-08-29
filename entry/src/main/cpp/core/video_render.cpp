#include "video_render.h"
#include "diagnostic_log.h"
#include "h264_decoder.h"
#include "software_av1_decoder.h"
#include "software_vp8_decoder.h"
#include "software_vp9_decoder.h"
#include "system_video_decoder.h"
#include "video_decoder_selector.h"
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
    SoftwareVP9,
    H265,
    VP8,
    SoftwareVP8,
    AV1,
    SoftwareAV1,
};

std::mutex g_decoderMutex;
ActiveDecoder g_activeDecoder = ActiveDecoder::None;
std::atomic<bool> g_releaseInProgress{false};
std::atomic<bool> g_flushInProgress{false};
std::once_flag g_decoderCapabilitiesOnce;
VideoDecoderCapabilities g_decoderCapabilities{false, false, false, false, false};
VideoDecodeMode g_h264SystemMode = VideoDecodeMode::Unknown;
VideoDecodeMode g_vp9SystemMode = VideoDecodeMode::Unknown;
VideoDecodeMode g_vp8SystemMode = VideoDecodeMode::Unknown;
VideoDecodeMode g_av1SystemMode = VideoDecodeMode::Unknown;
VideoDecodeMode g_h265SystemMode = VideoDecodeMode::Unknown;

bool hasRustDeskFrameTag(const uint8_t* data, int length) {
    return length > 5 && data[0] == 'S' && data[1] == 'R' && data[2] == 'D' && data[3] == '0';
}

void releaseEveryDecoder() {
    H264Decoder::instance().release();
    VP9Decoder::instance().release();
    SoftwareVP9Decoder::instance().release();
    SystemVideoDecoder::h265().release();
    SystemVideoDecoder::vp8().release();
    SoftwareVP8Decoder::instance().release();
    SystemVideoDecoder::av1().release();
    SoftwareAV1Decoder::instance().release();
}

void ensureH264Decoder(OHNativeWindow* window, int width, int height) {
    if (window == nullptr) {
        OH_LOG_WARN(LOG_APP, "H264 decoder waiting for native window");
        return;
    }
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::H264) {
        releaseEveryDecoder();
        g_activeDecoder = ActiveDecoder::H264;
        DiagnosticLog::instance().append("I", "video", "active_decoder=H264");
    }
    H264Decoder::instance().setSurface(window, width, height);
}

bool ensureVP9Decoder(OHNativeWindow* window, int width, int height) {
    if (window == nullptr) {
        OH_LOG_WARN(LOG_APP, "VP9 decoder waiting for native window");
        return false;
    }
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::VP9) {
        releaseEveryDecoder();
        g_activeDecoder = ActiveDecoder::VP9;
        DiagnosticLog::instance().append("I", "video", "active_decoder=VP9");
    }
    VP9Decoder::instance().setSurface(window, width, height);
    return VP9Decoder::instance().isStarted();
}

void ensureSoftwareVP9Decoder() {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::SoftwareVP9) {
        releaseEveryDecoder();
        g_activeDecoder = ActiveDecoder::SoftwareVP9;
        DiagnosticLog::instance().append("I", "video", "active_decoder=VP9_SOFTWARE");
    }
}

bool ensureSystemDecoder(ActiveDecoder active, SystemVideoDecoder& decoder, OHNativeWindow* window,
                         int width, int height, const char* name) {
    if (window == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != active) {
        releaseEveryDecoder();
        g_activeDecoder = active;
        DiagnosticLog::instance().append("I", "video", "active_decoder=" + std::string(name));
    }
    decoder.setSurface(window, width, height);
    return decoder.isStarted();
}

void ensureSoftwareVP8Decoder() {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::SoftwareVP8) {
        releaseEveryDecoder();
        g_activeDecoder = ActiveDecoder::SoftwareVP8;
        DiagnosticLog::instance().append("I", "video", "active_decoder=VP8_SOFTWARE");
    }
}

void ensureSoftwareAV1Decoder() {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    if (g_activeDecoder != ActiveDecoder::SoftwareAV1) {
        releaseEveryDecoder();
        g_activeDecoder = ActiveDecoder::SoftwareAV1;
        DiagnosticLog::instance().append("I", "video", "active_decoder=AV1_SOFTWARE");
    }
}

void releaseActiveDecoder() {
    std::lock_guard<std::mutex> lock(g_decoderMutex);
    releaseEveryDecoder();
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

VideoDecoderCapabilities VideoRender::decoderCapabilities() {
    std::call_once(g_decoderCapabilitiesOnce, []() {
        g_h264SystemMode = preferredSystemDecoderMode(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
        g_vp9SystemMode = preferredSystemDecoderMode("video/x-vnd.on2.vp9");
        g_vp8SystemMode = preferredSystemDecoderMode("video/x-vnd.on2.vp8");
        g_av1SystemMode = preferredSystemDecoderMode("video/av01");
        g_h265SystemMode = preferredSystemDecoderMode("video/hevc");
        g_decoderCapabilities.h264 = g_h264SystemMode != VideoDecodeMode::Unknown;
        g_decoderCapabilities.vp9 = true;
        g_decoderCapabilities.vp8 = true;
        g_decoderCapabilities.av1 = true;
        g_decoderCapabilities.h265 = g_h265SystemMode != VideoDecodeMode::Unknown;
        DiagnosticLog::instance().append("I", "video",
            "decoder_capabilities h264=" + std::string(g_decoderCapabilities.h264 ? "yes" : "no") +
            " vp9=yes vp8=yes av1=yes h265=" + std::string(g_decoderCapabilities.h265 ? "yes" : "no") +
            " system_modes h264=" + videoDecodeModeName(g_h264SystemMode) +
            " vp9=" + videoDecodeModeName(g_vp9SystemMode) +
            " vp8=" + videoDecodeModeName(g_vp8SystemMode) +
            " av1=" + videoDecodeModeName(g_av1SystemMode) +
            " h265=" + videoDecodeModeName(g_h265SystemMode) +
            " software_fallbacks=vp8,vp9,av1");
    });
    return g_decoderCapabilities;
}

// Detect if the binary data is H264 AnnexB format (starts with 00 00 00 01 or 00 00 01)
static bool isAnnexB(const uint8_t* data, int length) {
    if (length < 3) return false;
    if (length >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) return true;
    if (data[0] == 0 && data[1] == 0 && data[2] == 1) return true;
    return false;
}

void VideoRender::onFrameReceived(const uint8_t* data, int length, int width, int height, bool key, int64_t pts) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        frameWidth_ = width;
        frameHeight_ = height;
        frameLength_ = length;
        hasFrame_ = true;
    }

    if (XComponentRender::instance().window() != nullptr) {
        flushPendingFrames();
        renderFrameNow(data, length, width, height, key, pts);
    } else if (hasRustDeskFrameTag(data, length)) {
        queuePendingFrame(data, length, width, height, key, pts);
    }

    if (frameCallback_) {
        frameCallback_(data, length, width, height);
    }
}

uint64_t VideoRender::decodedFrameCount() const {
    return decodedFrameCount_.load();
}

int VideoRender::activeCodec() const {
    return activeCodec_.load();
}

int VideoRender::activeDecodeMode() const {
    return activeDecodeMode_.load();
}

void VideoRender::markDecodedFrame(int codec, int width, int height, int decodeMode) {
    activeCodec_.store(codec);
    if (decodeMode > 0) {
        activeDecodeMode_.store(decodeMode);
    }
    if (width > 0 && height > 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (decodedFrameWidth_ != width || decodedFrameHeight_ != height) {
            DiagnosticLog::instance().append("I", "video",
                "decoded_size_changed input=" + std::to_string(frameWidth_) + "x" +
                std::to_string(frameHeight_) + " output=" + std::to_string(width) + "x" +
                std::to_string(height));
            decodedFrameWidth_ = width;
            decodedFrameHeight_ = height;
        }
    }
    uint64_t previous = decodedFrameCount_.fetch_add(1);
    if (previous == 0) {
        OH_LOG_INFO(LOG_APP, "First decoded video output codec=%{public}d", codec);
        DiagnosticLog::instance().append("I", "video",
            "first_decoded_output codec=" + std::to_string(codec) +
            " mode=" + std::to_string(activeDecodeMode_.load()));
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
    width = decodedFrameWidth_ > 0 ? decodedFrameWidth_ : frameWidth_;
    height = decodedFrameHeight_ > 0 ? decodedFrameHeight_ : frameHeight_;
    return true;
}

void VideoRender::setSurfaceId(const std::string& surfaceId) {
    bool unchanged = false;
    {
        std::lock_guard<std::mutex> lock(surfaceMutex_);
        unchanged = !surfaceId.empty() && surfaceId == surfaceId_;
        surfaceId_ = surfaceId;
    }
    if (unchanged && XComponentRender::instance().window() != nullptr) {
        flushPendingFramesAsync();
        return;
    }

    if (!surfaceId.empty()) {
        XComponentRender::instance().setSurface(surfaceId);
        flushPendingFramesAsync();
    } else {
        releaseActiveDecoderAsync();
        XComponentRender::instance().release();
    }
}

void VideoRender::prepareSurfaceRebind() {
    DiagnosticLog::instance().append("I", "surface", "layout_rebind_prepare");
    XComponentRender::instance().prepareSurfaceRebind();
    SoftwareVP9Decoder::instance().release();
    SoftwareVP8Decoder::instance().release();
    SoftwareAV1Decoder::instance().release();
}

void VideoRender::rebindSurface(const std::string& surfaceId) {
    DiagnosticLog::instance().append("I", "surface", "layout_rebind_start");
    releaseActiveDecoder();
    {
        std::lock_guard<std::mutex> lock(surfaceMutex_);
        surfaceId_ = surfaceId;
    }
    XComponentRender::instance().rebindSurface(surfaceId);
    DiagnosticLog::instance().append("I", "surface",
        XComponentRender::instance().window() == nullptr ? "layout_rebind_failed" : "layout_rebind_complete");
    flushPendingFramesAsync();
}

std::string VideoRender::getSurfaceId() {
    std::lock_guard<std::mutex> lock(surfaceMutex_);
    return surfaceId_;
}

void VideoRender::resetSession() {
    DiagnosticLog::instance().append("I", "video", "session_reset");
    releaseActiveDecoderAsync();
    std::lock_guard<std::mutex> lock(mutex_);
    pendingFrames_.clear();
    frameWidth_ = 0;
    frameHeight_ = 0;
    decodedFrameWidth_ = 0;
    decodedFrameHeight_ = 0;
    frameLength_ = 0;
    hasFrame_ = false;
    decodedFrameCount_.store(0);
    activeCodec_.store(0);
    activeDecodeMode_.store(0);
}

void VideoRender::renderFrameNow(const uint8_t* data, int length, int width, int height, bool key, int64_t pts) {
    OHNativeWindow* window = XComponentRender::instance().window();
    if (hasRustDeskFrameTag(data, length)) {
        char codec = static_cast<char>(data[4]);
        const uint8_t* payload = data + 5;
        int payloadLength = length - 5;
        if (codec == 'H') {
            activeCodec_.store(1);
            ensureH264Decoder(window, width, height);
            activeDecodeMode_.store(static_cast<int>(H264Decoder::instance().decodeMode()));
            H264Decoder::instance().decodeFrame(payload, payloadLength, key, pts);
        } else if (codec == 'V') {
            activeCodec_.store(2);
            if (g_vp9SystemMode == VideoDecodeMode::Hardware && ensureVP9Decoder(window, width, height)) {
                activeDecodeMode_.store(static_cast<int>(VP9Decoder::instance().decodeMode()));
                VP9Decoder::instance().decodeFrame(payload, payloadLength, key, pts);
            } else {
                ensureSoftwareVP9Decoder();
                activeDecodeMode_.store(static_cast<int>(VideoDecodeMode::Software));
                SoftwareVP9Decoder::instance().decodeFrame(payload, payloadLength, key, pts);
            }
        } else if (codec == '5') {
            activeCodec_.store(3);
            if (ensureSystemDecoder(ActiveDecoder::H265, SystemVideoDecoder::h265(), window,
                                    width, height, "H265")) {
                activeDecodeMode_.store(static_cast<int>(SystemVideoDecoder::h265().decodeMode()));
                SystemVideoDecoder::h265().decodeFrame(payload, payloadLength, key, pts);
            }
        } else if (codec == '8') {
            activeCodec_.store(4);
            if (g_vp8SystemMode == VideoDecodeMode::Hardware &&
                ensureSystemDecoder(ActiveDecoder::VP8, SystemVideoDecoder::vp8(), window,
                                    width, height, "VP8")) {
                activeDecodeMode_.store(static_cast<int>(SystemVideoDecoder::vp8().decodeMode()));
                SystemVideoDecoder::vp8().decodeFrame(payload, payloadLength, key, pts);
            } else {
                ensureSoftwareVP8Decoder();
                activeDecodeMode_.store(static_cast<int>(VideoDecodeMode::Software));
                SoftwareVP8Decoder::instance().decodeFrame(payload, payloadLength, key, pts);
            }
        } else if (codec == 'A') {
            activeCodec_.store(5);
            if (g_av1SystemMode == VideoDecodeMode::Hardware &&
                ensureSystemDecoder(ActiveDecoder::AV1, SystemVideoDecoder::av1(), window,
                                    width, height, "AV1")) {
                activeDecodeMode_.store(static_cast<int>(SystemVideoDecoder::av1().decodeMode()));
                SystemVideoDecoder::av1().decodeFrame(payload, payloadLength, key, pts);
            } else {
                ensureSoftwareAV1Decoder();
                activeDecodeMode_.store(static_cast<int>(VideoDecodeMode::Software));
                SoftwareAV1Decoder::instance().decodeFrame(payload, payloadLength, key, pts);
            }
        } else {
            OH_LOG_WARN(LOG_APP, "Unsupported tagged codec=%{public}c", codec);
        }
    } else if (length >= width * height * 4) {
        releaseActiveDecoder();
        XComponentRender::instance().renderFrame(data, length, width, height);
    } else if (isAnnexB(data, length)) {
        activeCodec_.store(1);
        ensureH264Decoder(window, width, height);
        activeDecodeMode_.store(static_cast<int>(H264Decoder::instance().decodeMode()));
        H264Decoder::instance().decodeFrame(data, length, key, pts);
    } else {
        activeCodec_.store(2);
        if (g_vp9SystemMode == VideoDecodeMode::Hardware && ensureVP9Decoder(window, width, height)) {
            activeDecodeMode_.store(static_cast<int>(VP9Decoder::instance().decodeMode()));
            VP9Decoder::instance().decodeFrame(data, length, key, pts);
        } else {
            ensureSoftwareVP9Decoder();
            activeDecodeMode_.store(static_cast<int>(VideoDecodeMode::Software));
            SoftwareVP9Decoder::instance().decodeFrame(data, length, key, pts);
        }
    }
}

void VideoRender::queuePendingFrame(const uint8_t* data, int length, int width, int height, bool key, int64_t pts) {
    PendingFrame frame;
    frame.data.assign(data, data + length);
    frame.width = width;
    frame.height = height;
    frame.key = key;
    frame.pts = pts;

    std::lock_guard<std::mutex> lock(mutex_);
    while (pendingFrames_.size() >= 120) {
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
        renderFrameNow(frame.data.data(), static_cast<int>(frame.data.size()), frame.width, frame.height,
                       frame.key, frame.pts);
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
