#ifndef RUSTDESK_CORE_H264_DECODER_H
#define RUSTDESK_CORE_H264_DECODER_H

#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>
#include <native_window/external_window.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>

class H264Decoder {
public:
    static H264Decoder& instance();

    void setSurface(OHNativeWindow* window, int width, int height);
    void decodeFrame(const uint8_t* data, int length);
    void release();

private:
    struct InputSlot {
        uint32_t index;
        OH_AVBuffer* buffer;
    };

    H264Decoder() {}
    ~H264Decoder() { release(); }

    bool startLocked(OHNativeWindow* window, int width, int height);
    void stopLocked();
    void feedLocked();
    static std::vector<uint8_t> normalizeH264(const uint8_t* data, int length);
    static bool isAnnexB(const uint8_t* data, int length);
    static uint32_t readBe32(const uint8_t* data);
    static uint32_t nalFlags(const std::vector<uint8_t>& frame);

    static void onError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void onStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void onNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void onNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);

    std::mutex mutex_;
    OH_AVCodec* codec_{nullptr};
    OHNativeWindow* window_{nullptr};
    int width_{0};
    int height_{0};
    int64_t pts_{0};
    bool started_{false};
    std::deque<std::vector<uint8_t>> frames_;
    std::deque<InputSlot> inputSlots_;
};

#endif
