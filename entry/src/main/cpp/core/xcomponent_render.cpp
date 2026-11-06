#include "xcomponent_render.h"
#include <cstring>
#include <cstdio>
#include <hilog/log.h>
#include <native_buffer/native_buffer.h>
#include <libyuv/scale_argb.h>
#include <unistd.h>
#include "diagnostic_log.h"
#include "native_frame_bounds.h"

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
        if (followSurfaceSize_) {
            int scaling = OH_NativeWindow_NativeWindowSetScalingModeV2(nativeWindow_, OH_SCALING_MODE_SCALE_TO_WINDOW_V2);
            if (scaling != 0) OH_LOG_WARN(LOG_APP, "Secondary surface scaling setup failed ret=%{public}d", scaling);
        }
        bufferWidth_ = 0;
        bufferHeight_ = 0;
    consecutiveNoBuffer_ = 0;
        OH_LOG_INFO(LOG_APP, "Native window created for surface %{public}s ret=%{public}d", surfaceId_.c_str(), ret);
        // The decoder owns its buffer format. Do not force HDR Surface output
        // to BGRA8888. CPU decoders configure BGRA only on their first write.
        cpuConfigured_ = false;
        windowReady_.store(true);
        return true;
    } else {
        OH_LOG_ERROR(LOG_APP, "Failed to create native window for surface %{public}s ret=%{public}d", surfaceId_.c_str(), ret);
        return false;
    }
}

void XComponentRender::configureWindowLocked(int width, int height) {
    if (!nativeWindow_) return;

    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
    OH_NativeWindow_SetColorSpace(nativeWindow_, OH_COLORSPACE_SRGB_FULL);
    uint64_t usage = NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;
    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_USAGE, usage);
    OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_TIMEOUT, 16);
    // Independent extension windows follow the XComponent's actual size;
    // forcing video geometry here leaves full-screen content at native pixels.
    if (!followSurfaceSize_) OH_NativeWindow_NativeWindowHandleOpt(nativeWindow_, SET_BUFFER_GEOMETRY, width, height);
    bufferWidth_ = width;
    bufferHeight_ = height;
    cpuConfigured_ = true;
    colorConfigured_ = false;
}

void XComponentRender::setHdrDisplayFormats(int formats) {
    const int previous = hdrDisplayFormats_.exchange(formats & 7);
    if (previous != (formats & 7)) DiagnosticLog::instance().append("I", "video-color",
        "display_hdr_formats=" + std::to_string(formats & 7));
}

VideoColorOutput XComponentRender::applyVideoColor(OHNativeWindow* expectedWindow, const VideoColorInfo& color) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderingPaused_.load() || nativeWindow_ == nullptr || expectedWindow != nativeWindow_)
        return VideoColorOutput::Unknown;
    if (colorConfigured_ && appliedColor_ == color && appliedHdrFormats_ == hdrDisplayFormats_.load())
        return appliedOutput_;
    cpuConfigured_ = false;
    colorConfigured_ = true;
    appliedColor_ = color;
    appliedHdrFormats_ = hdrDisplayFormats_.load();
    appliedOutput_ = VideoColorOutput::Unknown;
    if (!color.isHdr()) {
        // Leave unspecified metadata to the decoder; do not relabel an unknown stream SDR.
        if (color.dynamicRange() == VideoDynamicRange::Unknown) return VideoColorOutput::Unknown;
        if (color.primaries == 1) {
            const auto space = color.range == 1 ? OH_COLORSPACE_BT709_FULL : OH_COLORSPACE_BT709_LIMIT;
            if (OH_NativeWindow_SetColorSpace(nativeWindow_, space) != 0) return VideoColorOutput::Unknown;
        }
        return appliedOutput_ = VideoColorOutput::SDR;
    }
    if (color.primaries != 9 || (color.transfer != 16 && color.transfer != 18))
        return appliedOutput_ = VideoColorOutput::Unsupported;
    const auto space = color.transfer == 16 ?
        (color.range == 1 ? OH_COLORSPACE_BT2020_PQ_FULL : OH_COLORSPACE_BT2020_PQ_LIMIT) :
        (color.range == 1 ? OH_COLORSPACE_BT2020_HLG_FULL : OH_COLORSPACE_BT2020_HLG_LIMIT);
    const int result = OH_NativeWindow_SetColorSpace(nativeWindow_, space);
    if (result != 0) {
        DiagnosticLog::instance().append("W", "video-color", "surface_color_failed result=" + std::to_string(result));
        return appliedOutput_ = VideoColorOutput::Unsupported;
    }
    // Compositor owns output conversion/metadata. No fabricated mastering metadata,
    // no global Vivid-only decoder conversion option on HDR10/HLG/SDR streams.
    const int required = color.vivid ? 4 : color.transfer == 16 ? 2 : 1;
    return appliedOutput_ = color.bitDepth >= 10 && (hdrDisplayFormats_.load() & required) != 0 ?
        VideoColorOutput::HDRSurface : VideoColorOutput::SystemManaged;
}

void XComponentRender::resetVideoColor() {
    std::lock_guard<std::mutex> lock(mutex_);
    colorConfigured_ = false;
    if (nativeWindow_) OH_NativeWindow_SetColorSpace(nativeWindow_, OH_COLORSPACE_NONE);
}

OHNativeWindow* XComponentRender::prepareDecoderSurface() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderingPaused_.load()) return nullptr;
    // Called after the old decoder is drained. A window previously configured
    // by the CPU writer must not carry its BGRA8888 constraint into Main10.
    if (cpuConfigured_) { destroyWindowLocked(); createWindowLocked(); }
    return nativeWindow_;
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

    if (!cpuConfigured_ || bufferWidth_ != (uint32_t)width || bufferHeight_ != (uint32_t)height) {
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
    int strideBytes = config.stride;
    int bpp = 4;

    // A surface resize can return an old, smaller buffer for a few frames.
    // Never infer its capacity from the requested video dimensions.
    if (!nativeFrameSourceValid(width, height, length) ||
        !nativeFrameBufferValid(config.width, config.height, strideBytes) ||
        (rgbaInput && !nativeFrameFits(width, height, length, config.width, config.height, strideBytes)) ||
        config.format != NATIVEBUFFER_PIXEL_FMT_BGRA_8888) {
        static std::atomic<uint64_t> invalidBuffers{0};
        const uint64_t count = invalidBuffers.fetch_add(1) + 1;
        if (count == 1 || count % 120 == 0) {
            OH_LOG_WARN(LOG_APP, "Skip incompatible surface buffer frame=%{public}dx%{public}d buffer=%{public}dx%{public}d stride=%{public}d format=%{public}d count=%{public}llu",
                width, height, config.width, config.height, strideBytes, config.format,
                static_cast<unsigned long long>(count));
        }
        if (fenceFd >= 0) close(fenceFd);
        OH_NativeWindow_NativeWindowAbortBuffer(nativeWindow_, buffer);
        return false;
    }

    void* mapped = nullptr;
    ret = OH_NativeBuffer_Map(nativeBuffer, &mapped);
    uint8_t* dst = static_cast<uint8_t*>(mapped);
    if (ret != 0 || !dst) {
        OH_LOG_ERROR(LOG_APP, "NativeBuffer map failed ret=%{public}d stride=%{public}d", ret, strideBytes);
        if (fenceFd >= 0) {
            close(fenceFd);
        }
        OH_NativeWindow_NativeWindowAbortBuffer(nativeWindow_, buffer);
        return false;
    }

    if (!rgbaInput && (config.width != width || config.height != height)) {
        // The compositor may resize the surface independently of the requested
        // video geometry. Scale into the actual buffer, never past its edges.
        const int scaled = libyuv::ARGBScale(data, width * bpp, width, height, dst,
            strideBytes, config.width, config.height, libyuv::kFilterBilinear);
        if (scaled != 0) {
            OH_NativeBuffer_Unmap(nativeBuffer);
            if (fenceFd >= 0) close(fenceFd);
            OH_NativeWindow_NativeWindowAbortBuffer(nativeWindow_, buffer);
            return false;
        }
    } else {
        for (int y = 0; y < height; y++) {
            uint8_t* dstRow = dst + static_cast<size_t>(y) * static_cast<size_t>(strideBytes);
            const uint8_t* srcRow = data + static_cast<size_t>(y) * static_cast<size_t>(width) * bpp;
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
    }

    OH_NativeBuffer_Unmap(nativeBuffer);
    if (fenceFd >= 0) {
        close(fenceFd);
    }
    ret = OH_NativeWindow_NativeWindowFlushBuffer(nativeWindow_, buffer, -1, region);
    static std::atomic<uint64_t> renderedFrames{0};
    const uint64_t count = renderedFrames.fetch_add(1) + 1;
    if (count == 1 || count % 300 == 0 || ret != 0) {
        OH_LOG_INFO(LOG_APP, "Flush mapped frame count=%{public}llu size=%{public}dx%{public}d stride=%{public}d ret=%{public}d",
            static_cast<unsigned long long>(count), width, height, strideBytes, ret);
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
    windowReady_.store(false);
    if (nativeWindow_) {
        OH_NativeWindow_DestroyNativeWindow(nativeWindow_);
        nativeWindow_ = nullptr;
    }
    bufferWidth_ = 0;
    bufferHeight_ = 0;
    consecutiveNoBuffer_ = 0;
    cpuConfigured_ = false;
    colorConfigured_ = false;
}
