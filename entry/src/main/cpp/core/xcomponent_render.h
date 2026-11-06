#ifndef RUSTDESK_XCOMPONENT_RENDER_H
#define RUSTDESK_XCOMPONENT_RENDER_H

#include <atomic>
#include <string>
#include <mutex>
#include <vector>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include "video_color.h"

class XComponentRender {
public:
    static XComponentRender& instance();
    // Independent windows must own separate native surfaces. The singleton is
    // retained for the existing primary renderer.
    explicit XComponentRender(bool followSurfaceSize = false)
        : nativeWindow_(nullptr), followSurfaceSize_(followSurfaceSize) {}
    ~XComponentRender() { release(); }
    XComponentRender(const XComponentRender&) = delete;
    XComponentRender& operator=(const XComponentRender&) = delete;

    void setSurface(const std::string& surfaceId);
    void prepareSurfaceRebind();
    void rebindSurface(const std::string& surfaceId);
    bool renderFrame(const uint8_t* data, int length, int width, int height);
    bool renderBGRAFrame(const uint8_t* data, int length, int width, int height);
    OHNativeWindow* window();
    OHNativeWindow* prepareDecoderSurface();
    void resetVideoColor();
    bool isReady() const { return windowReady_.load() && !renderingPaused_.load(); }
    void setHdrDisplayFormats(int formats);
    VideoColorOutput applyVideoColor(OHNativeWindow* expectedWindow, const VideoColorInfo& color);
    void release();

private:
    bool createWindowLocked();
    void configureWindowLocked(int width, int height);
    bool renderPackedFrame(const uint8_t* data, int length, int width, int height, bool rgbaInput);
    void destroyWindowLocked();

    OHNativeWindow* nativeWindow_;
    const bool followSurfaceSize_;
    std::mutex mutex_;
    std::string surfaceId_;
    uint32_t bufferWidth_{0};
    uint32_t bufferHeight_{0};
    int consecutiveNoBuffer_{0};
    std::atomic<bool> renderingPaused_{false};
    std::atomic<bool> windowReady_{false};
    std::atomic<int> hdrDisplayFormats_{0}; // bit 0 HLG, bit 1 HDR10, bit 2 HDR Vivid
    bool cpuConfigured_{false};
    bool colorConfigured_{false};
    VideoColorInfo appliedColor_;
    int appliedHdrFormats_{-1};
    VideoColorOutput appliedOutput_{VideoColorOutput::Unknown};
};

#endif
