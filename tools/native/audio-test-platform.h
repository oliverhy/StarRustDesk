#pragma once
#include <cstdint>

// Host-only SDK/Opus seams; tests compile the real AudioPlayer implementation.
using OH_AudioStream_Result = int;
using OH_AudioInterrupt_ForceType = int;
using OH_AudioInterrupt_Hint = int;
constexpr int AUDIOSTREAM_SUCCESS = 0;
constexpr int AUDIOSTREAM_TYPE_RENDERER = 1;
constexpr int AUDIOSTREAM_SAMPLE_S16LE = 1;
constexpr int AUDIOSTREAM_ENCODING_TYPE_RAW = 1;
constexpr int AUDIOSTREAM_LATENCY_MODE_FAST = 1;
constexpr int AUDIOSTREAM_USAGE_MUSIC = 1;
constexpr int OPUS_OK = 0;
struct OH_AudioRenderer;
struct OH_AudioRenderer_Callbacks {
    int32_t (*OH_AudioRenderer_OnWriteData)(OH_AudioRenderer*, void*, void*, int32_t) = nullptr;
    int32_t (*OH_AudioRenderer_OnInterruptEvent)(OH_AudioRenderer*, void*, int, int) = nullptr;
    int32_t (*OH_AudioRenderer_OnError)(OH_AudioRenderer*, void*, int) = nullptr;
};
struct OH_AudioRenderer { OH_AudioRenderer_Callbacks callbacks; void* user = nullptr; };
struct OH_AudioStreamBuilder { OH_AudioRenderer_Callbacks callbacks; void* user = nullptr; };
struct OpusDecoder { int channels; };
int OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder**, int);
int OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder*, int);
int OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder*, int);
int OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder*, int);
int OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder*, int);
int OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder*, int);
int OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder*, int);
int OH_AudioStreamBuilder_SetRendererCallback(OH_AudioStreamBuilder*, OH_AudioRenderer_Callbacks, void*);
int OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder*, OH_AudioRenderer**);
int OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder*);
int OH_AudioRenderer_Start(OH_AudioRenderer*);
int OH_AudioRenderer_Stop(OH_AudioRenderer*);
int OH_AudioRenderer_Release(OH_AudioRenderer*);
OpusDecoder* opus_decoder_create(int, int, int*);
void opus_decoder_destroy(OpusDecoder*);
int opus_decode(OpusDecoder*, const uint8_t*, int, int16_t*, int, int);
