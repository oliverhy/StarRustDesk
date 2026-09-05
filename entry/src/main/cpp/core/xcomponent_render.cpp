#include "xcomponent_render.h"
#include <cstring>
#include <cstdio>
#include <hilog/log.h>
#include <native_buffer/native_buffer.h>
#include <unistd.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskXComponent"

XComponentRender& XComponentRender::instance() {
    static XComponentRender render;
    return render;
}

void XComponentRender::setSurface(const std::string& surfaceId) {
    renderingPaused_.store(true);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!surfaceId.empty() && surfaceId == surfaceId_ && nativeWindow_ != nullptr) {
        renderingPaused_.store(false);
        return;
    }

    destroyWindowLocked();
    surfaceId_ = surfaceId;
    if (surfaceId_.empty()) return;

    createWindowLocked();
    renderingPaused_.store(false);
}

void XComponentRender::prepareSurfaceRebind() {
    renderingPaused_.store(true);
    // Synchronize with an in-flight CPU buffer write. Once this lock has been
    // acquired and released, no software frame can still be using the old
    // native window.
    std::lock_guard<std::mutex> lock(mutex_);
}

void XComponentRender::rebindSurface(const std::string& surfaceId) {
    renderingPaused_.store(true);
    std::lock_guard<std::mutex> lock(mutex_);
    destroyWindowLocked();
    surfaceId_ = surfaceId;
    if (!surfaceId_.empty()) {
        createWindowLocked();
    }
    renderingPaused_.store(false);
}

bool XComponentRender::createWindowLocked() {
    if (surfaceId_.empty()) {
        return false;
    }
    uint64_t sid = 0;
    try {
        sid = std::stoull(surfaceId_);
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "Invalid surface id %{public}s", surfaceId_.c_str());
        return false;
    }

    int ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(sid, &nativeWindow_);
    if (nativeWindow_) {
        bufferWidth_ = 0;
        bufferHeight_ = 0;
    consecutiveNoBuffer_ = 0;
        OH_LOG_INFO(LOG_APP, "Native window created for surface %{public}s ret=%{public}d", surfaceId_.c_str(), ret);
        configureWindowLocked(640, 360);
        return true;
    } else {
        OH_LOG_ERROR(LOG_APP, "Failed to create native window for surface %{public}s ret=%{public}d", surfaceId_.c_str(), ret);
        return false;
    }
}

void XComponentRender::configureWindowLocked(int width, int height) {
    if (!nativeWindow_) return;

    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_USAGE, usage);
    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_TIMEOUT, 16);
    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_BUFFER_GEOMETRY, width, height);
    bufferWidth_ = width;
    bufferHeight_ = height;
}

bool XComponentRender::renderFrame(const uint8_t* data, int length, int width, int height) {
    return renderPackedFrame(data, length, width, height, true);
}

bool XComponentRender::renderBGRAFrame(const uint8_t* data, int length, int width, int height) {
    return renderPackedFrame(data, length, width, height, false);
}

bool XComponentRender::renderPackedFrame(const uint8_t* data, int length, int width, int height, bool rgbaInput) {
    if (renderingPaused_.load()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderingPaused_.load()) {
        return false;
    }
    if (!nativeWindow_ || !data || length <= 0) {
        OH_LOG_WARN(LOG_APP, "Skip render nativeWindow=%{public}d data=%{public}d length=%{public}d", nativeWindow_ ? 1 : 0, data ? 1 : 0, length);
        return false;
    }

    if (bufferWidth_ != (uint32_t)width || bufferHeight_ != (uint32_t)height) {
        configureWindowLocked(width, height);
    }

    Region region;
    memset(&region, 0, sizeof(Region));

    OHNativeWindowBuffer* buffer = nullptr;
    int fenceFd = -1;
    int ret = OH_NativeWindow_NativeWindowRequestBuffer(nativeWindow_, &buffer, &fenceFd);
    if (ret != 0 || !buffer) {
        OH_LOG_ERROR(LOG_APP, "RequestBuffer failed ret=%{public}d noBufferCount=%{public}d", ret, consecutiveNoBuffer_);
        if (++consecutiveNoBuffer_ >= 3) {
            destroyWindowLocked();
            createWindowLocked();
        }
        return false;
    }
        consecutiveNoBuffer_ = 0;

    OH_NativeBuffer* nativeBuffer = nullptr;
    ret = OH_NativeBuffer_FromNativeWindowBuffer(buffer, &nativeBuffer);
    if (ret != 0 || !nativeBuffer) {
        OH_LOG_ERROR(LOG_APP, "FromNativeWindowBuffer failed ret=%{public}d", ret);
        OH_NativeWindow_NativeWindowAbortBuffer(nativeWindow_, buffer);
        return false;
    }

    OH_NativeBuffer_Config config;
    memset(&config, 0, sizeof(config));
    OH_NativeBuffer_GetConfig(nativeBuffer, &config);
    int strideBytes = config.stride > 0 ? config.stride : width * 4;
    int bpp = 4;

    void* mapped = nullptr;
    ret = OH_NativeBuffer_Map(nativeBuffer, &mapped);
    uint8_t* dst = static_cast<uint8_t*>(mapped);
    if (!dst) {
        OH_LOG_ERROR(LOG_APP, "NativeBuffer map failed ret=%{public}d stride=%{public}d", ret, strideBytes);
        if (fenceFd >= 0) {
            close(fenceFd);
        }
        OH_NativeWindow_NativeWindowAbortBuffer(nativeWindow_, buffer);
        return false;
    }

    if (length >= width * height * 4) {
        for (int y = 0; y < height; y++) {
            uint8_t* dstRow = dst + y * strideBytes;
            const uint8_t* srcRow = data + y * width * bpp;
            if (!rgbaInput) {
                memcpy(dstRow, srcRow, static_cast<size_t>(width) * bpp);
            } else {
                for (int x = 0; x < width; x++) {
                    // Convert RGBA -> BGRA (HarmonyOS native window format)
                    dstRow[x * 4] = srcRow[x * 4 + 2];     // B
                    dstRow[x * 4 + 1] = srcRow[x * 4 + 1]; // G
                    dstRow[x * 4 + 2] = srcRow[x * 4];     // R
                    dstRow[x * 4 + 3] = srcRow[x * 4 + 3]; // A
                }
            }
        }
    } else {
        OH_LOG_WARN(LOG_APP, "Skip encoded or incomplete frame length=%{public}d expected=%{public}d", length, width * height * 4);
        OH_NativeBuffer_Unmap(nativeBuffer);
        if (fenceFd >= 0) {
            close(fenceFd);
        }
        OH_NativeWindow_NativeWindowAbortBuffer(nativeWindow_, buffer);
        return false;
    }

    OH_NativeBuffer_Unmap(nativeBuffer);
    if (fenceFd >= 0) {
        close(fenceFd);
    }
    ret = OH_NativeWindow_NativeWindowFlushBuffer(nativeWindow_, buffer, -1, region);
    static uint64_t renderedFrames = 0;
    renderedFrames += 1;
    if (renderedFrames == 1 || renderedFrames % 300 == 0 || ret != 0) {
        OH_LOG_INFO(LOG_APP, "Flush mapped frame count=%{public}llu size=%{public}dx%{public}d stride=%{public}d ret=%{public}d",
            static_cast<unsigned long long>(renderedFrames), width, height, strideBytes, ret);
    }
    return ret == 0;
}

OHNativeWindow* XComponentRender::window() {
    if (renderingPaused_.load()) {
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderingPaused_.load()) {
        return nullptr;
    }
    return nativeWindow_;
}

void XComponentRender::release() {
    renderingPaused_.store(true);
    std::lock_guard<std::mutex> lock(mutex_);
    destroyWindowLocked();
}

void XComponentRender::destroyWindowLocked() {
    if (nativeWindow_) {
        OH_NativeWindow_DestroyNativeWindow(nativeWindow_);
        nativeWindow_ = nullptr;
    }
    bufferWidth_ = 0;
    bufferHeight_ = 0;
    consecutiveNoBuffer_ = 0;
}
