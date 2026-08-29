#ifndef RUSTDESK_CORE_SYSTEM_VIDEO_DECODER_H
#define RUSTDESK_CORE_SYSTEM_VIDEO_DECODER_H

#include "video_decoder_selector.h"

#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include <native_window/external_window.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>

class SystemVideoDecoder {
public:
    static SystemVideoDecoder& h265();
    static SystemVideoDecoder& vp8();
    static SystemVideoDecoder& av1();

    void setSurface(OHNativeWindow* window, int width, int height);
    void decodeFrame(const uint8_t* data, int length, bool key, int64_t pts);
    bool isStarted();
    VideoDecodeMode decodeMode();
    void release();

private:
    struct InputSlot {
        uint32_t index;
        OH_AVBuffer* buffer;
    };

    struct EncodedFrame {
        std::vector<uint8_t> data;
        bool key;
        int64_t pts;
    };

    SystemVideoDecoder(const char* mime, const char* component, int codecId, bool annexB);
    ~SystemVideoDecoder();
    SystemVideoDecoder(const SystemVideoDecoder&) = delete;
    SystemVideoDecoder& operator=(const SystemVideoDecoder&) = delete;

    bool startLocked(OHNativeWindow* window, int width, int height);
    void stopLocked();
    void feedLocked();
    std::vector<uint8_t> normalizeFrame(const uint8_t* data, int length) const;
    uint32_t bufferFlags(const EncodedFrame& frame) const;

    static bool isAnnexB(const uint8_t* data, int length);
    static uint32_t readBe32(const uint8_t* data);
    static uint32_t hevcNalFlags(const std::vector<uint8_t>& frame);
    static void onError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void onStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void onNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void onNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);

    const char* mime_;
    const char* component_;
    int codecId_;
    bool annexB_;
    std::mutex mutex_;
    OH_AVCodec* codec_{nullptr};
    OHNativeWindow* window_{nullptr};
    int width_{0};
    int height_{0};
    int64_t pts_{0};
    int64_t lastSourcePts_{-1};
    bool started_{false};
    bool createFailed_{false};
    VideoDecodeMode decodeMode_{VideoDecodeMode::Unknown};
    std::string decoderName_;
    uint64_t inputFrames_{0};
    uint64_t inputBytes_{0};
    uint64_t outputFrames_{0};
    bool firstKeyLogged_{false};
    std::deque<EncodedFrame> frames_;
    std::deque<InputSlot> inputSlots_;
};

#endif
