// Optional, playback-only renderer for the paired Sunshine test client.
// No microphone, files, input samples in logs, or shared RustDesk audio state.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <hilog/log.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <opus.h>
extern "C" {
#include "Limelight.h"
extern uint32_t EncryptionFeaturesEnabled;
}

namespace {
constexpr size_t Stereo=2, Capacity=48000*Stereo*60/1000;
struct Sound {
    std::mutex lock;
    OH_AudioRenderer* output{};
    OpusDecoder* codec{};
    std::array<int16_t, Capacity> queue{};
    std::array<int16_t,5760*Stereo> scratch{};
    size_t pos{}, count{};
    uint64_t decoded{}, played{}, audible{}, overflow{}, errors{};
    bool active{};
} sound;

int32_t writeAudio(OH_AudioRenderer*,void*,void* dst,int32_t bytes) {
    if (!dst || bytes<=0) return 0;
    std::memset(dst,0,bytes);
    auto* out=static_cast<int16_t*>(dst);
    std::lock_guard<std::mutex> guard(sound.lock);
    if (!sound.active) return 0;
    size_t n=std::min(sound.count,static_cast<size_t>(bytes)/sizeof(int16_t));
    size_t left=std::min(n,Capacity-sound.pos);
    std::copy_n(sound.queue.data()+sound.pos,left,out);
    std::copy_n(sound.queue.data(),n-left,out+left);
    sound.played+=n;
    if (std::any_of(out,out+n,[](int16_t x){return x>32 || x< -32;})) ++sound.audible;
    sound.pos=(sound.pos+n)%Capacity; sound.count-=n;
    return 0;
}
void cleanup(){
    auto* output=sound.output; sound.output=nullptr;
    {std::lock_guard<std::mutex> guard(sound.lock); sound.active=false;}
    if (output){ OH_AudioRenderer_Stop(output); OH_AudioRenderer_Release(output); }
    if (sound.codec){opus_decoder_destroy(sound.codec);sound.codec=nullptr;}
    std::lock_guard<std::mutex> guard(sound.lock);
    if (sound.decoded || sound.errors)
        OH_LOG_Print(LOG_APP,LOG_INFO,0x0001,"SesameSecureClient",
          "stream_audio_end decoded=%{public}llu played_samples=%{public}llu audible_blocks=%{public}llu overflow=%{public}llu errors=%{public}llu",
          (unsigned long long)sound.decoded,(unsigned long long)sound.played,(unsigned long long)sound.audible,
          (unsigned long long)sound.overflow,(unsigned long long)sound.errors);
    sound.queue.fill(0);sound.scratch.fill(0);sound.pos=sound.count=0;
    sound.decoded=sound.played=sound.audible=sound.overflow=sound.errors=0;
}
int init(int config,const POPUS_MULTISTREAM_CONFIGURATION o,void*,int){
    if ((EncryptionFeaturesEnabled&6u)!=6u || config!=AUDIO_CONFIGURATION_STEREO || !o ||
        o->sampleRate!=48000 || o->channelCount!=2 || o->streams!=1 || o->coupledStreams!=1 ||
        o->mapping[0]!=0 || o->mapping[1]!=1) return -1;
    int err=0;
    sound.codec=opus_decoder_create(48000,2,&err);
    if (!sound.codec || err!=OPUS_OK){cleanup();return -2;}
    OH_AudioStreamBuilder* b{};
    if (OH_AudioStreamBuilder_Create(&b,AUDIOSTREAM_TYPE_RENDERER)!=AUDIOSTREAM_SUCCESS || !b){cleanup();return -3;}
    OH_AudioRenderer_Callbacks cb{}; cb.OH_AudioRenderer_OnWriteData=writeAudio;
    bool configured=OH_AudioStreamBuilder_SetSamplingRate(b,48000)==AUDIOSTREAM_SUCCESS &&
        OH_AudioStreamBuilder_SetChannelCount(b,2)==AUDIOSTREAM_SUCCESS &&
        OH_AudioStreamBuilder_SetSampleFormat(b,AUDIOSTREAM_SAMPLE_S16LE)==AUDIOSTREAM_SUCCESS &&
        OH_AudioStreamBuilder_SetEncodingType(b,AUDIOSTREAM_ENCODING_TYPE_RAW)==AUDIOSTREAM_SUCCESS &&
        OH_AudioStreamBuilder_SetRendererInfo(b,AUDIOSTREAM_USAGE_MUSIC)==AUDIOSTREAM_SUCCESS &&
        OH_AudioStreamBuilder_SetRendererCallback(b,cb,nullptr)==AUDIOSTREAM_SUCCESS;
    if (configured) OH_AudioStreamBuilder_SetLatencyMode(b,AUDIOSTREAM_LATENCY_MODE_FAST);
    bool ready=configured && OH_AudioStreamBuilder_GenerateRenderer(b,&sound.output)==AUDIOSTREAM_SUCCESS && sound.output;
    OH_AudioStreamBuilder_Destroy(b);
    if (!ready || OH_AudioRenderer_Start(sound.output)!=AUDIOSTREAM_SUCCESS){cleanup();return -4;}
    {std::lock_guard<std::mutex> guard(sound.lock); sound.active=true;}
    return 0;
}
void decode(char* data,int len){
    if (!data || len<=0 || !sound.codec) return;
    const int n=opus_decode(sound.codec,reinterpret_cast<const unsigned char*>(data),len,sound.scratch.data(),5760,0);
    std::lock_guard<std::mutex> guard(sound.lock);
    if (!sound.active) return;
    if (n<=0){++sound.errors;return;}
    ++sound.decoded;
    const size_t samples=static_cast<size_t>(n)*Stereo;
    const size_t take=std::min(samples,Capacity);
    const size_t drop=sound.count+take>Capacity?sound.count+take-Capacity:0;
    sound.overflow+=drop+samples-take; sound.pos=(sound.pos+drop)%Capacity; sound.count-=drop;
    const size_t tail=(sound.pos+sound.count)%Capacity, left=std::min(take,Capacity-tail);
    const auto* src=sound.scratch.data()+samples-take;
    std::copy_n(src,left,sound.queue.data()+tail); std::copy_n(src+left,take-left,sound.queue.data());
    sound.count+=take;
}
void stop(){std::lock_guard<std::mutex> guard(sound.lock);sound.active=false;}
}
AUDIO_RENDERER_CALLBACKS sesameStreamAudio(){
    AUDIO_RENDERER_CALLBACKS ar{}; ar.init=init;ar.stop=stop;ar.cleanup=cleanup;ar.decodeAndPlaySample=decode;
    return ar;
}
void sesameStreamAudioReport(){
    uint64_t decoded,played,audible,overflow,errors;
    {std::lock_guard<std::mutex> guard(sound.lock);
     decoded=sound.decoded;played=sound.played;audible=sound.audible;overflow=sound.overflow;errors=sound.errors;}
    OH_LOG_Print(LOG_APP,LOG_INFO,0x0001,"SesameSecureClient",
      "stream_audio_health decoded=%{public}llu played_samples=%{public}llu audible_blocks=%{public}llu overflow=%{public}llu errors=%{public}llu",
      (unsigned long long)decoded,(unsigned long long)played,(unsigned long long)audible,
      (unsigned long long)overflow,(unsigned long long)errors);
}
