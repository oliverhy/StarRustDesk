#include "system_video_decoder.h"

#include "diagnostic_log.h"
#include "video_render.h"

#include <algorithm>
#include <cstring>
#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_averrors.h>
#include <multimedia/player_framework/native_avformat.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskSystemVideo"

namespace {
constexpr const char* H265_MIME_TYPE = "video/hevc";
constexpr const char* VP8_MIME_TYPE = "video/x-vnd.on2.vp8";
constexpr const char* AV1_MIME_TYPE = "video/av01";
constexpr int32_t MAX_COMPRESSED_FRAME_SIZE = 16 * 1024 * 1024;
constexpr size_t MAX_QUEUED_FRAMES = 120;
}

SystemVideoDecoder::SystemVideoDecoder(const char* mime, const char* component, int codecId, bool annexB)
    : mime_(mime), component_(component), codecId_(codecId), annexB_(annexB) {}

SystemVideoDecoder::~SystemVideoDecoder() {
    release();
}

SystemVideoDecoder& SystemVideoDecoder::h265() {
    static SystemVideoDecoder decoder(H265_MIME_TYPE, "h265", 3, true);
    return decoder;
}

SystemVideoDecoder& SystemVideoDecoder::vp8() {
    static SystemVideoDecoder decoder(VP8_MIME_TYPE, "vp8", 4, false);
    return decoder;
}

SystemVideoDecoder& SystemVideoDecoder::av1() {
    static SystemVideoDecoder decoder(AV1_MIME_TYPE, "av1", 5, false);
    return decoder;
}

void SystemVideoDecoder::setSurface(OHNativeWindow* window, int width, int height) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (window_ == window && width_ == width && height_ == height && (started_ || createFailed_)) {
        return;
    }
    stopLocked();
    window_ = window;
    width_ = width;
    height_ = height;
    createFailed_ = false;
    if (window_ != nullptr && !startLocked(window_, width_, height_)) {
        createFailed_ = true;
    }
}

void SystemVideoDecoder::decodeFrame(const uint8_t* data, int length, bool key, int64_t pts) {
    std::vector<uint8_t> normalized = normalizeFrame(data, length);
    if (normalized.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!started_ || codec_ == nullptr) {
        DiagnosticLog::instance().append("W", component_, "input_dropped decoder_not_started");
        return;
    }
    inputFrames_ += 1;
    inputBytes_ += normalized.size();
    if (inputFrames_ == 1 || (key && !firstKeyLogged_)) {
        firstKeyLogged_ = firstKeyLogged_ || key;
        DiagnosticLog::instance().append("I", component_,
            "input frame=" + std::to_string(inputFrames_) + " size=" + std::to_string(normalized.size()) +
            " key=" + std::string(key ? "yes" : "no") + " pts=" + std::to_string(pts));
    }
    while (frames_.size() >= MAX_QUEUED_FRAMES) {
        frames_.pop_front();
        DiagnosticLog::instance().append("W", component_, "input_queue_overflow dropped_oldest");
    }
    frames_.push_back(EncodedFrame {std::move(normalized), key, pts});
    feedLocked();
}

bool SystemVideoDecoder::isStarted() {
    std::lock_guard<std::mutex> lock(mutex_);
    return started_ && codec_ != nullptr;
}

VideoDecodeMode SystemVideoDecoder::decodeMode() {
    std::lock_guard<std::mutex> lock(mutex_);
    return decodeMode_;
}

void SystemVideoDecoder::release() {
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
    if (codec != nullptr) {
        DiagnosticLog::instance().append("I", component_,
            "release input=" + std::to_string(inputFrames_) + " output=" +
            std::to_string(outputFrames_) + " bytes=" + std::to_string(inputBytes_));
        OH_VideoDecoder_Stop(codec);
        OH_VideoDecoder_Destroy(codec);
    }
}

bool SystemVideoDecoder::startLocked(OHNativeWindow* window, int width, int height) {
    VideoDecoderSelection selection = createPreferredVideoDecoder(mime_);
    codec_ = selection.codec;
    decodeMode_ = selection.mode;
    decoderName_ = selection.name;
    if (codec_ == nullptr) {
        DiagnosticLog::instance().append("E", component_, "create_decoder_failed");
        return false;
    }

    OH_AVCodecCallback callback {};
    callback.onError = SystemVideoDecoder::onError;
    callback.onStreamChanged = SystemVideoDecoder::onStreamChanged;
    callback.onNeedInputBuffer = SystemVideoDecoder::onNeedInputBuffer;
    callback.onNewOutputBuffer = SystemVideoDecoder::onNewOutputBuffer;
    OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(codec_, callback, this);
    if (ret != AV_ERR_OK) {
        DiagnosticLog::instance().append("E", component_,
            "register_callback_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }

    OH_AVFormat* format = OH_AVFormat_CreateVideoFormat(mime_, width, height);
    if (format == nullptr) {
        DiagnosticLog::instance().append("E", component_, "create_format_failed");
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
        DiagnosticLog::instance().append("E", component_, "configure_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }
    ret = OH_VideoDecoder_SetSurface(codec_, window);
    if (ret != AV_ERR_OK) {
        DiagnosticLog::instance().append("E", component_, "set_surface_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }
    ret = OH_VideoDecoder_Prepare(codec_);
    if (ret != AV_ERR_OK) {
        DiagnosticLog::instance().append("E", component_, "prepare_failed result=" + std::to_string(ret));
        stopLocked();
        return false;
    }
    ret = OH_VideoDecoder_Start(codec_);
    if (ret != AV_ERR_OK) {
        DiagnosticLog::instance().append("E", component_, "start_failed result=" + std::to_string(ret));
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
    DiagnosticLog::instance().append("I", component_,
        "decoder_started resolution=" + std::to_string(width) + "x" + std::to_string(height) +
        " mode=" + videoDecodeModeName(decodeMode_) + " name=" + decoderName_);
    return true;
}

void SystemVideoDecoder::stopLocked() {
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

void SystemVideoDecoder::feedLocked() {
    while (started_ && codec_ != nullptr && !frames_.empty() && !inputSlots_.empty()) {
        EncodedFrame frame = std::move(frames_.front());
        frames_.pop_front();
        InputSlot slot = inputSlots_.front();
        inputSlots_.pop_front();
        int32_t capacity = OH_AVBuffer_GetCapacity(slot.buffer);
        uint8_t* destination = OH_AVBuffer_GetAddr(slot.buffer);
        if (destination == nullptr || capacity < static_cast<int32_t>(frame.data.size())) {
            DiagnosticLog::instance().append("E", component_,
                "input_buffer_too_small capacity=" + std::to_string(capacity) +
                " frame=" + std::to_string(frame.data.size()));
            inputSlots_.push_back(slot);
            continue;
        }
        std::memcpy(destination, frame.data.data(), frame.data.size());
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
        attr.flags = bufferFlags(frame);
        OH_AVBuffer_SetBufferAttr(slot.buffer, &attr);
        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(codec_, slot.index);
        if (ret != AV_ERR_OK) {
            DiagnosticLog::instance().append("E", component_,
                "push_input_failed result=" + std::to_string(ret) +
                " size=" + std::to_string(frame.data.size()));
        }
    }
}

std::vector<uint8_t> SystemVideoDecoder::normalizeFrame(const uint8_t* data, int length) const {
    if (data == nullptr || length <= 0) {
        return {};
    }
    if (!annexB_ || isAnnexB(data, length)) {
        return std::vector<uint8_t>(data, data + length);
    }
    if (length > 4) {
        uint32_t firstLength = readBe32(data);
        if (firstLength > 0 && firstLength + 4 <= static_cast<uint32_t>(length)) {
            std::vector<uint8_t> output;
            int offset = 0;
            while (offset + 4 <= length) {
                uint32_t size = readBe32(data + offset);
                offset += 4;
                if (size == 0 || offset + static_cast<int>(size) > length) {
                    break;
                }
                output.insert(output.end(), {0, 0, 0, 1});
                output.insert(output.end(), data + offset, data + offset + size);
                offset += static_cast<int>(size);
            }
            return output;
        }
    }
    std::vector<uint8_t> output {0, 0, 0, 1};
    output.insert(output.end(), data, data + length);
    return output;
}

uint32_t SystemVideoDecoder::bufferFlags(const EncodedFrame& frame) const {
    if (frame.key) {
        return AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
    }
    return annexB_ ? hevcNalFlags(frame.data) : AVCODEC_BUFFER_FLAGS_NONE;
}

bool SystemVideoDecoder::isAnnexB(const uint8_t* data, int length) {
    return (length >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) ||
        (length >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1);
}

uint32_t SystemVideoDecoder::readBe32(const uint8_t* data) {
    return (static_cast<uint32_t>(data[0]) << 24) |
        (static_cast<uint32_t>(data[1]) << 16) |
        (static_cast<uint32_t>(data[2]) << 8) | static_cast<uint32_t>(data[3]);
}

uint32_t SystemVideoDecoder::hevcNalFlags(const std::vector<uint8_t>& frame) {
    bool sawCodecData = false;
    bool sawSlice = false;
    for (size_t i = 0; i + 5 < frame.size(); ++i) {
        size_t nalOffset = 0;
        if (frame[i] == 0 && frame[i + 1] == 0 && frame[i + 2] == 1) {
            nalOffset = i + 3;
        } else if (frame[i] == 0 && frame[i + 1] == 0 && frame[i + 2] == 0 && frame[i + 3] == 1) {
            nalOffset = i + 4;
        } else {
            continue;
        }
        if (nalOffset >= frame.size()) {
            continue;
        }
        uint8_t type = (frame[nalOffset] >> 1) & 0x3F;
        if (type == 19 || type == 20 || type == 21) {
            return AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
        }
        if (type == 32 || type == 33 || type == 34) {
            sawCodecData = true;
        } else if (type <= 31) {
            sawSlice = true;
        }
    }
    return sawCodecData && !sawSlice ? AVCODEC_BUFFER_FLAGS_CODEC_DATA : AVCODEC_BUFFER_FLAGS_NONE;
}

void SystemVideoDecoder::onError(OH_AVCodec*, int32_t errorCode, void* userData) {
    SystemVideoDecoder* decoder = static_cast<SystemVideoDecoder*>(userData);
    if (decoder != nullptr) {
        DiagnosticLog::instance().append("E", decoder->component_,
            "decoder_error code=" + std::to_string(errorCode));
    }
}

void SystemVideoDecoder::onStreamChanged(OH_AVCodec*, OH_AVFormat*, void* userData) {
    SystemVideoDecoder* decoder = static_cast<SystemVideoDecoder*>(userData);
    if (decoder != nullptr) {
        DiagnosticLog::instance().append("I", decoder->component_, "stream_changed");
    }
}

void SystemVideoDecoder::onNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer,
                                           void* userData) {
    SystemVideoDecoder* decoder = static_cast<SystemVideoDecoder*>(userData);
    if (decoder == nullptr || buffer == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(decoder->mutex_);
    if (!decoder->started_ || decoder->codec_ != codec) {
        return;
    }
    decoder->inputSlots_.push_back(InputSlot {index, buffer});
    decoder->feedLocked();
}

void SystemVideoDecoder::onNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer*, void* userData) {
    SystemVideoDecoder* decoder = static_cast<SystemVideoDecoder*>(userData);
    if (decoder == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(decoder->mutex_);
    if (!decoder->started_ || decoder->codec_ != codec) {
        return;
    }
    OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    VideoRender::instance().markDecodedFrame(decoder->codecId_, decoder->width_, decoder->height_,
        static_cast<int>(decoder->decodeMode_), ret == AV_ERR_OK);
    if (ret != AV_ERR_OK) {
        DiagnosticLog::instance().append("E", decoder->component_,
            "render_output_failed result=" + std::to_string(ret));
        return;
    }
    decoder->outputFrames_ += 1;
    if (decoder->outputFrames_ == 1) {
        DiagnosticLog::instance().append("I", decoder->component_, "first_output_rendered");
    }
}
