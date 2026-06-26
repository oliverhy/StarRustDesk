#include "vp9_decoder.h"
#include <algorithm>
#include <cstring>
#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_averrors.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskVP9"

VP9Decoder& VP9Decoder::instance() {
    static VP9Decoder decoder;
    return decoder;
}

void VP9Decoder::setSurface(OHNativeWindow* window, int width, int height) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (window_ == window && width_ == width && height_ == height && started_) {
        return;
    }
    stopLocked();
    window_ = window;
    width_ = width;
    height_ = height;
    if (window_ != nullptr) {
        startLocked(window_, width_, height_);
    }
}

void VP9Decoder::decodeFrame(const uint8_t* data, int length) {
    if (data == nullptr || length <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!started_ || codec_ == nullptr) {
        return;
    }
    while (frames_.size() >= 2) {
        frames_.pop_front();
    }
    std::vector<uint8_t> frame(data, data + length);
    frames_.push_back(std::move(frame));
    feedLocked();
}

void VP9Decoder::release() {
    std::lock_guard<std::mutex> lock(mutex_);
    stopLocked();
}

bool VP9Decoder::startLocked(OHNativeWindow* window, int width, int height) {
    codec_ = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_VP9);
    if (codec_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Create VP9 decoder failed");
        return false;
    }

    OH_AVCodecCallback callback {};
    callback.onError = VP9Decoder::onError;
    callback.onStreamChanged = VP9Decoder::onStreamChanged;
    callback.onNeedInputBuffer = VP9Decoder::onNeedInputBuffer;
    callback.onNewOutputBuffer = VP9Decoder::onNewOutputBuffer;
    OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(codec_, callback, this);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Register VP9 callback failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    OH_AVFormat* format = OH_AVFormat_CreateVideoFormat(OH_AVCODEC_MIMETYPE_VIDEO_VP9, width, height);
    if (format == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Create VP9 video format failed");
        stopLocked();
        return false;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, 60.0);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);

    ret = OH_VideoDecoder_Configure(codec_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Configure VP9 decoder failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_SetSurface(codec_, window);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Set VP9 decoder surface failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_Prepare(codec_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Prepare VP9 decoder failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_Start(codec_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Start VP9 decoder failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    started_ = true;
    pts_ = 0;
    OH_LOG_INFO(LOG_APP, "VP9 decoder started %{public}dx%{public}d", width, height);
    return true;
}

void VP9Decoder::stopLocked() {
    if (codec_ != nullptr) {
        OH_VideoDecoder_Stop(codec_);
        OH_VideoDecoder_Destroy(codec_);
        codec_ = nullptr;
    }
    started_ = false;
    frames_.clear();
    inputSlots_.clear();
    pts_ = 0;
}

void VP9Decoder::feedLocked() {
    while (started_ && codec_ != nullptr && !frames_.empty() && !inputSlots_.empty()) {
        std::vector<uint8_t> frame = std::move(frames_.front());
        frames_.pop_front();
        InputSlot slot = inputSlots_.front();
        inputSlots_.pop_front();
        int32_t capacity = OH_AVBuffer_GetCapacity(slot.buffer);
        uint8_t* dst = OH_AVBuffer_GetAddr(slot.buffer);
        if (dst == nullptr || capacity < static_cast<int32_t>(frame.size())) {
            OH_LOG_WARN(LOG_APP, "VP9 input buffer too small capacity=%{public}d frame=%{public}d", capacity, static_cast<int>(frame.size()));
            inputSlots_.push_back(slot);
            continue;
        }
        memcpy(dst, frame.data(), frame.size());
        OH_AVCodecBufferAttr attr {};
        attr.pts = pts_;
        attr.size = static_cast<int32_t>(frame.size());
        attr.offset = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
        OH_AVBuffer_SetBufferAttr(slot.buffer, &attr);
        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(codec_, slot.index);
        if (ret != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP, "VP9 push input failed ret=%{public}d index=%{public}u", ret, slot.index);
        }
        pts_ += 33333;
    }
}

void VP9Decoder::onError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "VP9 decoder error %{public}d", errorCode);
}

void VP9Decoder::onStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "VP9 decoder stream changed");
}

void VP9Decoder::onNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    VP9Decoder* decoder = static_cast<VP9Decoder*>(userData);
    if (decoder == nullptr || buffer == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(decoder->mutex_);
    InputSlot slot;
    slot.index = index;
    slot.buffer = buffer;
    decoder->inputSlots_.push_back(slot);
    decoder->feedLocked();
}

void VP9Decoder::onNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (ret != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Render VP9 output failed index=%{public}u ret=%{public}d", index, ret);
    }
}
