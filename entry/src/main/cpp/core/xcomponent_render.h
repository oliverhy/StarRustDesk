#ifndef RUSTDESK_XCOMPONENT_RENDER_H
#define RUSTDESK_XCOMPONENT_RENDER_H

#include <string>
#include <mutex>
#include <vector>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>

class XComponentRender {
public:
    static XComponentRender& instance();

    void setSurface(const std::string& surfaceId);
    void renderFrame(const uint8_t* data, int length, int width, int height);
    OHNativeWindow* window();
    void release();

private:
    XComponentRender() : nativeWindow_(nullptr) {}
    ~XComponentRender() { release(); }

    bool createWindowLocked();
    void configureWindowLocked(int width, int height);
    void destroyWindowLocked();

    OHNativeWindow* nativeWindow_;
    std::mutex mutex_;
    std::string surfaceId_;
    uint32_t bufferWidth_{0};
    uint32_t bufferHeight_{0};
    int consecutiveNoBuffer_{0};
};

#endif
