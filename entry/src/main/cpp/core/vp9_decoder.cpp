#include "vp9_decoder.h"
#include "diagnostic_log.h"
#include "video_render.h"
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

namespace {
// OH_AVCODEC_MIMETYPE_VIDEO_VP9 is exported only from API 23. Referencing that
// symbol directly prevents libentry.so from loading at all on API 22 devices.
constexpr const char* VP9_MIME_TYPE = "video/x-vnd.on2.vp9";
constexpr int32_t MAX_COMPRESSED_FRAME_SIZE = 16 * 1024 * 1024;
}

VP9Decoder& VP9Decoder::instance() {
    static VP9Decoder decoder;
    return decoder;
}

void VP9Decoder::setSurface(OHNativeWindow* window, int width, int height) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (window_ == window && width_ == width && height_ == height && (started_ || createFailed_)) {
        return;
    }
    stopLocked();
    window_ = window;
    width_ = width;
    height_ = height;
    createFailed_ = false;
    if (window_ != nullptr) {
        if (!startLocked(window_, width_, height_)) {
            createFailed_ = true;
        }
    }
}

void VP9Decoder::decodeFrame(const uint8_t* data, int length, bool key, int64_t pts) {
    if (data == nullptr || length <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!started_ || codec_ == nullptr) {
        DiagnosticLog::instance().append("W", "vp9", "input_dropped decoder_not_started");
        return;
    }
    inputFrames_ += 1;
    inputBytes_ += static_cast<uint64_t>(length);
    if (inputFrames_ == 1 || (key && !firstKeyLogged_)) {
        if (key) {
            firstKeyLogged_ = true;
        }
        DiagnosticLog::instance().append("I", "vp9",
            "input frame=" + std::to_string(inputFrames_) + " size=" + std::to_string(length) +
            " key=" + std::string(key ? "yes" : "no") + " pts=" + std::to_string(pts));
    }
    while (frames_.size() >= 120) {
        frames_.pop_front();
        DiagnosticLog::instance().append("W", "vp9", "input_queue_overflow dropped_oldest");
    }
    frames_.push_back(EncodedFrame {std::vector<uint8_t>(data, data + length), key, pts});
    feedLocked();
}

bool VP9Decoder::isStarted() {
    std::lock_guard<std::mutex> lock(mutex_);
    return started_ && codec_ != nullptr;
}

VideoDecodeMode VP9Decoder::decodeMode() {
    std::lock_guard<std::mutex> lock(mutex_);
    return decodeMode_;
}

void VP9Decoder::release() {
    OH_AVCodec* codec = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        codec = codec_;
        codec_ = nullptr;
        started_ = false;
        createFailed_ = false;
        decodeMode_ = VideoDecodeMode::Unknown;
        decoderName_.clear();
        window_ = nullptr;
        width_ = 0;
        height_ = 0;
        frames_.clear();
        inputSlots_.clear();
        pts_ = 0;
        lastSourcePts_ = -1;
    }
    // Stop/Destroy may wait for callbacks. Never hold mutex_ here because the
    // callbacks also take it before touching decoder state.
    if (codec != nullptr) {
        DiagnosticLog::instance().append("I", "vp9",
            "release input=" + std::to_string(inputFrames_) + " output=" +
            std::to_string(outputFrames_) + " bytes=" + std::to_string(inputBytes_));
        OH_VideoDecoder_Stop(codec);
        OH_VideoDecoder_Destroy(codec);
    }
}

bool VP9Decoder::startLocked(OHNativeWindow* window, int width, int height) {
    VideoDecoderSelection selection = createPreferredVideoDecoder(VP9_MIME_TYPE);
    codec_ = selection.codec;
    decodeMode_ = selection.mode;
    decoderName_ = selection.name;
    if (codec_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Create VP9 decoder failed");
        DiagnosticLog::instance().append("E", "vp9", "create_decoder_failed");
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
        DiagnosticLog::instance().append("E", "vp9",
            "register_callback_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }

    OH_AVFormat* format = OH_AVFormat_CreateVideoFormat(VP9_MIME_TYPE, width, height);
    if (format == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Create VP9 video format failed");
        DiagnosticLog::instance().append("E", "vp9", "create_format_failed");
        stopLocked();
        return false;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, 60.0);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, MAX_COMPRESSED_FRAME_SIZE);

    ret = OH_VideoDecoder_Configure(codec_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Configure VP9 decoder failed ret=%{public}d", ret);
        DiagnosticLog::instance().append("E", "vp9",
            "configure_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_SetSurface(codec_, window);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Set VP9 decoder surface failed ret=%{public}d", ret);
        DiagnosticLog::instance().append("E", "vp9",
            "set_surface_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_Prepare(codec_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Prepare VP9 decoder failed ret=%{public}d", ret);
        DiagnosticLog::instance().append("E", "vp9",
            "prepare_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_Start(codec_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Start VP9 decoder failed ret=%{public}d", ret);
        DiagnosticLog::instance().append("E", "vp9",
            "start_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }

    started_ = true;
    pts_ = 0;
    lastSourcePts_ = -1;
    inputFrames_ = 0;
    inputBytes_ = 0;
    outputFrames_ = 0;
    firstKeyLogged_ = false;
    OH_LOG_INFO(LOG_APP, "VP9 decoder started %{public}dx%{public}d", width, height);
    DiagnosticLog::instance().append("I", "vp9",
        "decoder_started resolution=" + std::to_string(width) + "x" + std::to_string(height) +
        " max_input=16777216 mode=" + videoDecodeModeName(decodeMode_) + " name=" + decoderName_);
    return true;
}

void VP9Decoder::stopLocked() {
    if (codec_ != nullptr) {
        OH_VideoDecoder_Stop(codec_);
        OH_VideoDecoder_Destroy(codec_);
        codec_ = nullptr;
    }
    started_ = false;
    decodeMode_ = VideoDecodeMode::Unknown;
    decoderName_.clear();
    frames_.clear();
    inputSlots_.clear();
    pts_ = 0;
    lastSourcePts_ = -1;
    inputFrames_ = 0;
    inputBytes_ = 0;
    outputFrames_ = 0;
    firstKeyLogged_ = false;
}

void VP9Decoder::feedLocked() {
    while (started_ && codec_ != nullptr && !frames_.empty() && !inputSlots_.empty()) {
        EncodedFrame frame = std::move(frames_.front());
        frames_.pop_front();
        InputSlot slot = inputSlots_.front();
        inputSlots_.pop_front();
        int32_t capacity = OH_AVBuffer_GetCapacity(slot.buffer);
        uint8_t* dst = OH_AVBuffer_GetAddr(slot.buffer);
        if (dst == nullptr || capacity < static_cast<int32_t>(frame.data.size())) {
            OH_LOG_WARN(LOG_APP, "VP9 input buffer too small capacity=%{public}d frame=%{public}d", capacity, static_cast<int>(frame.data.size()));
            DiagnosticLog::instance().append("E", "vp9",
                "input_buffer_too_small capacity=" + std::to_string(capacity) +
                " frame=" + std::to_string(frame.data.size()) +
                " key=" + std::string(frame.key ? "yes" : "no"));
            inputSlots_.push_back(slot);
            continue;
        }
        memcpy(dst, frame.data.data(), frame.data.size());
        OH_AVCodecBufferAttr attr {};
        if (frame.pts > lastSourcePts_) {
            attr.pts = frame.pts;
            lastSourcePts_ = frame.pts;
            pts_ = std::max(pts_, frame.pts + 1);
        } else {
            attr.pts = pts_;
            pts_ += 33333;
        }
        attr.size = static_cast<int32_t>(frame.data.size());
        attr.offset = 0;
        attr.flags = frame.key ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
        OH_AVBuffer_SetBufferAttr(slot.buffer, &attr);
        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(codec_, slot.index);
        if (ret != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP, "VP9 push input failed ret=%{public}d index=%{public}u", ret, slot.index);
            DiagnosticLog::instance().append("E", "vp9",
                "push_input_failed result=" + std::to_string(ret) +
                " size=" + std::to_string(frame.data.size()));
        }
    }
}

void VP9Decoder::onError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "VP9 decoder error %{public}d", errorCode);
    DiagnosticLog::instance().append("E", "vp9", "decoder_error code=" + std::to_string(errorCode));
}

void VP9Decoder::onStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "VP9 decoder stream changed");
    DiagnosticLog::instance().append("I", "vp9", "stream_changed");
}

void VP9Decoder::onNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    VP9Decoder* decoder = static_cast<VP9Decoder*>(userData);
    if (decoder == nullptr || buffer == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(decoder->mutex_);
    if (!decoder->started_ || decoder->codec_ != codec) {
        return;
    }
    InputSlot slot;
    slot.index = index;
    slot.buffer = buffer;
    decoder->inputSlots_.push_back(slot);
    decoder->feedLocked();
}

void VP9Decoder::onNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    VP9Decoder* decoder = static_cast<VP9Decoder*>(userData);
    if (decoder == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(decoder->mutex_);
    if (!decoder->started_ || decoder->codec_ != codec) {
        return;
    }
    OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (ret != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Render VP9 output failed index=%{public}u ret=%{public}d", index, ret);
        DiagnosticLog::instance().append("E", "vp9",
            "render_output_failed result=" + std::to_string(ret));
    } else {
        decoder->outputFrames_ += 1;
        if (decoder->outputFrames_ == 1) {
            DiagnosticLog::instance().append("I", "vp9", "first_output_rendered");
        }
        VideoRender::instance().markDecodedFrame(2, decoder->width_, decoder->height_,
            static_cast<int>(decoder->decodeMode_));
    }
}
