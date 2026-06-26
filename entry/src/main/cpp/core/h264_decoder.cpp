#include "h264_decoder.h"
#include <algorithm>
#include <cstring>
#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_averrors.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskH264"

H264Decoder& H264Decoder::instance() {
    static H264Decoder decoder;
    return decoder;
}

void H264Decoder::setSurface(OHNativeWindow* window, int width, int height) {
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

void H264Decoder::decodeFrame(const uint8_t* data, int length) {
    std::vector<uint8_t> frame = normalizeH264(data, length);
    if (frame.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!started_ || codec_ == nullptr) {
        return;
    }
    while (frames_.size() >= 2) {
        frames_.pop_front();
    }
    frames_.push_back(std::move(frame));
    feedLocked();
}

void H264Decoder::release() {
    std::lock_guard<std::mutex> lock(mutex_);
    stopLocked();
}

bool H264Decoder::startLocked(OHNativeWindow* window, int width, int height) {
    codec_ = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (codec_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Create H264 decoder failed");
        return false;
    }

    OH_AVCodecCallback callback {};
    callback.onError = H264Decoder::onError;
    callback.onStreamChanged = H264Decoder::onStreamChanged;
    callback.onNeedInputBuffer = H264Decoder::onNeedInputBuffer;
    callback.onNewOutputBuffer = H264Decoder::onNewOutputBuffer;
    OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(codec_, callback, this);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Register callback failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    OH_AVFormat* format = OH_AVFormat_CreateVideoFormat(OH_AVCODEC_MIMETYPE_VIDEO_AVC, width, height);
    if (format == nullptr) {
        OH_LOG_ERROR(LOG_APP, "Create video format failed");
        stopLocked();
        return false;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, 60.0);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);

    ret = OH_VideoDecoder_Configure(codec_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Configure decoder failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_SetSurface(codec_, window);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Set decoder surface failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_Prepare(codec_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Prepare decoder failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    ret = OH_VideoDecoder_Start(codec_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "Start decoder failed ret=%{public}d", ret);
        stopLocked();
        return false;
    }

    started_ = true;
    pts_ = 0;
    OH_LOG_INFO(LOG_APP, "H264 decoder started %{public}dx%{public}d", width, height);
    return true;
}

void H264Decoder::stopLocked() {
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

void H264Decoder::feedLocked() {
    while (started_ && codec_ != nullptr && !frames_.empty() && !inputSlots_.empty()) {
        std::vector<uint8_t> frame = std::move(frames_.front());
        frames_.pop_front();
        InputSlot slot = inputSlots_.front();
        inputSlots_.pop_front();
        int32_t capacity = OH_AVBuffer_GetCapacity(slot.buffer);
        uint8_t* dst = OH_AVBuffer_GetAddr(slot.buffer);
        if (dst == nullptr || capacity < static_cast<int32_t>(frame.size())) {
            OH_LOG_WARN(LOG_APP, "Input buffer too small capacity=%{public}d frame=%{public}d", capacity, static_cast<int>(frame.size()));
            inputSlots_.push_back(slot);
            continue;
        }
        memcpy(dst, frame.data(), frame.size());
        OH_AVCodecBufferAttr attr {};
        attr.pts = pts_;
        attr.size = static_cast<int32_t>(frame.size());
        attr.offset = 0;
        attr.flags = nalFlags(frame);
        OH_AVBuffer_SetBufferAttr(slot.buffer, &attr);
        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(codec_, slot.index);
        if (ret != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP, "Push input failed ret=%{public}d index=%{public}u", ret, slot.index);
        }
        pts_ += 33333;
    }
}

std::vector<uint8_t> H264Decoder::normalizeH264(const uint8_t* data, int length) {
    if (data == nullptr || length <= 0) {
        return std::vector<uint8_t>();
    }
    if (isAnnexB(data, length)) {
        return std::vector<uint8_t>(data, data + length);
    }
    if (length > 4) {
        uint32_t nalLength = readBe32(data);
        if (nalLength > 0 && nalLength + 4 <= static_cast<uint32_t>(length)) {
            std::vector<uint8_t> out;
            int offset = 0;
            while (offset + 4 <= length) {
                uint32_t size = readBe32(data + offset);
                offset += 4;
                if (size == 0 || offset + static_cast<int>(size) > length) {
                    break;
                }
                out.push_back(0);
                out.push_back(0);
                out.push_back(0);
                out.push_back(1);
                out.insert(out.end(), data + offset, data + offset + size);
                offset += static_cast<int>(size);
            }
            return out;
        }
    }
    std::vector<uint8_t> out;
    out.push_back(0);
    out.push_back(0);
    out.push_back(0);
    out.push_back(1);
    out.insert(out.end(), data, data + length);
    return out;
}

bool H264Decoder::isAnnexB(const uint8_t* data, int length) {
    if (length >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) {
        return true;
    }
    if (length >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1) {
        return true;
    }
    return false;
}

uint32_t H264Decoder::readBe32(const uint8_t* data) {
    return (static_cast<uint32_t>(data[0]) << 24) |
        (static_cast<uint32_t>(data[1]) << 16) |
        (static_cast<uint32_t>(data[2]) << 8) |
        static_cast<uint32_t>(data[3]);
}

uint32_t H264Decoder::nalFlags(const std::vector<uint8_t>& frame) {
    bool sawCodecData = false;
    bool sawSlice = false;
    for (size_t i = 0; i + 4 < frame.size(); i++) {
        size_t nalOffset = 0;
        if (frame[i] == 0 && frame[i + 1] == 0 && frame[i + 2] == 1) {
            nalOffset = i + 3;
        } else if (i + 5 < frame.size() && frame[i] == 0 && frame[i + 1] == 0 && frame[i + 2] == 0 && frame[i + 3] == 1) {
            nalOffset = i + 4;
        } else {
            continue;
        }
        if (nalOffset >= frame.size()) {
            continue;
        }
        uint8_t type = frame[nalOffset] & 0x1F;
        if (type == 5) {
            return AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
        }
        if (type == 7 || type == 8) {
            sawCodecData = true;
        } else if (type == 1) {
            sawSlice = true;
        }
    }
    if (sawCodecData && !sawSlice) {
        return AVCODEC_BUFFER_FLAGS_CODEC_DATA;
    }
    return AVCODEC_BUFFER_FLAGS_NONE;
}

void H264Decoder::onError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "Decoder error %{public}d", errorCode);
}

void H264Decoder::onStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "Decoder stream changed");
}

void H264Decoder::onNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    H264Decoder* decoder = static_cast<H264Decoder*>(userData);
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

void H264Decoder::onNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (ret != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP, "Render H264 output failed index=%{public}u ret=%{public}d", index, ret);
    }
}
