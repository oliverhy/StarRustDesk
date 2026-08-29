#ifndef RUSTDESK_CORE_VIDEO_DECODER_SELECTOR_H
#define RUSTDESK_CORE_VIDEO_DECODER_SELECTOR_H

#include <string>

#include <multimedia/player_framework/native_avcodec_videodecoder.h>

enum class VideoDecodeMode {
    Unknown = 0,
    Hardware = 1,
    Software = 2,
};

struct VideoDecoderSelection {
    OH_AVCodec* codec{nullptr};
    VideoDecodeMode mode{VideoDecodeMode::Unknown};
    std::string name;
};

VideoDecoderSelection createPreferredVideoDecoder(const char* mime);
VideoDecodeMode preferredSystemDecoderMode(const char* mime);
const char* videoDecodeModeName(VideoDecodeMode mode);

#endif
