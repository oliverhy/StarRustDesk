#include "video_decoder_selector.h"

#include <multimedia/player_framework/native_avcapability.h>

namespace {
VideoDecoderSelection createForCategory(const char* mime, OH_AVCodecCategory category,
                                        VideoDecodeMode mode) {
    VideoDecoderSelection selection;
    OH_AVCapability* capability = OH_AVCodec_GetCapabilityByCategory(mime, false, category);
    if (capability == nullptr) {
        return selection;
    }
    const char* name = OH_AVCapability_GetName(capability);
    if (name == nullptr || name[0] == '\0') {
        return selection;
    }
    selection.codec = OH_VideoDecoder_CreateByName(name);
    if (selection.codec != nullptr) {
        selection.mode = mode;
        selection.name = name;
    }
    return selection;
}
}

VideoDecoderSelection createPreferredVideoDecoder(const char* mime) {
    VideoDecoderSelection selection = createForCategory(mime, HARDWARE, VideoDecodeMode::Hardware);
    if (selection.codec != nullptr) {
        return selection;
    }
    return createForCategory(mime, SOFTWARE, VideoDecodeMode::Software);
}

VideoDecodeMode preferredSystemDecoderMode(const char* mime) {
    VideoDecoderSelection hardware = createForCategory(mime, HARDWARE, VideoDecodeMode::Hardware);
    if (hardware.codec != nullptr) {
        OH_VideoDecoder_Destroy(hardware.codec);
        return hardware.mode;
    }
    VideoDecoderSelection software = createForCategory(mime, SOFTWARE, VideoDecodeMode::Software);
    if (software.codec != nullptr) {
        OH_VideoDecoder_Destroy(software.codec);
        return software.mode;
    }
    return VideoDecodeMode::Unknown;
}

const char* videoDecodeModeName(VideoDecodeMode mode) {
    switch (mode) {
        case VideoDecodeMode::Hardware:
            return "hardware";
        case VideoDecodeMode::Software:
            return "software";
        default:
            return "unknown";
    }
}
