#include "audio_player.h"
#include "diagnostic_log.h"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#define CHECK(x) do { if (!(x)) throw std::runtime_error(std::string("line ") + std::to_string(__LINE__) + ": " + #x); } while (false)
static std::vector<std::string> logs;
static OH_AudioRenderer* current = nullptr;
static int decodeResult = 4;
static int failStage = 0;
static bool inCallback = false;
DiagnosticLog& DiagnosticLog::instance() { static DiagnosticLog log; return log; }
void DiagnosticLog::append(const char*, const char*, const std::string& message) {
    CHECK(!inCallback); logs.push_back(message);
}
int OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder** b, int) {
    *b = failStage == 3 ? nullptr : new OH_AudioStreamBuilder(); return *b ? 0 : -3;
}
int OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder*, int) { return 0; }
int OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder*, int) { return 0; }
int OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder*, int) { return 0; }
int OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder*, int) { return 0; }
int OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder*, int) { return 0; }
int OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder*, int) { return 0; }
int OH_AudioStreamBuilder_SetRendererCallback(OH_AudioStreamBuilder* b, OH_AudioRenderer_Callbacks c, void* u) {
    b->callbacks = c; b->user = u; return 0;
}
int OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder* b, OH_AudioRenderer** r) {
    *r = failStage == 4 ? nullptr : new OH_AudioRenderer{b->callbacks, b->user};
    current = *r; return *r ? 0 : -4;
}
int OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder* b) { delete b; return 0; }
static void Write(OH_AudioRenderer* r, int samples = 16) {
    std::vector<int16_t> buffer(samples, 123);
    inCallback = true;
    CHECK(r->callbacks.OH_AudioRenderer_OnWriteData(r, r->user, buffer.data(), samples * 2) == samples * 2);
    inCallback = false;
}
int OH_AudioRenderer_Start(OH_AudioRenderer* r) { Write(r); return failStage == 5 ? -5 : 0; }
int OH_AudioRenderer_Stop(OH_AudioRenderer* r) { Write(r); return 0; }
int OH_AudioRenderer_Release(OH_AudioRenderer* r) { if (r == current) current = nullptr; delete r; return 0; }
OpusDecoder* opus_decoder_create(int, int c, int* error) {
    *error = failStage == 2 ? -2 : 0; return *error ? nullptr : new OpusDecoder{c};
}
void opus_decoder_destroy(OpusDecoder* d) { delete d; }
int opus_decode(OpusDecoder* d, const uint8_t*, int, int16_t* out, int capacity, int) {
    if (decodeResult <= 0) return decodeResult;
    CHECK(decodeResult <= capacity); std::fill_n(out, decodeResult * d->channels, static_cast<int16_t>(321)); return decodeResult;
}
static void Has(const std::string& text) { CHECK(!logs.empty()); CHECK(logs.back().find(text) != std::string::npos); }
static void Report() { AudioPlayer::instance().reportDiagnostics(true, "test"); }
int main() {
    try {
        auto& p = AudioPlayer::instance(); uint8_t packet[] = {0x80};
        CHECK(p.start(0, 2) == -1);
        for (int stage : {2, 3, 4, 5}) {
            failStage = stage; CHECK(p.start(48000, 2) == -stage); CHECK(!p.isRunning());
        }
        failStage = 0;
        CHECK(p.start(48000, 2) == 0); Report();
        Has("phase=awaiting_packets"); Has("received_frames=0"); Has("write_callbacks=1"); Has("underruns=1");
        auto count = logs.size(); p.reportDiagnostics(); CHECK(logs.size() == count);
        p.pushOpusFrame(packet, 1); Report(); Has("received_frames=1"); Has("decoded_frames=1");
        Has("queue_samples=8"); CHECK(p.hasRecentFrames(6000));
        auto* renderer = current; Write(renderer); Report(); Has("consumed_samples=8"); Has("phase=pcm_consumed");
        CHECK(p.start(48000, 2) == 0); Report(); Has("received_frames=1"); // same format is not a new session
        decodeResult = -4; p.pushOpusFrame(packet, 1); Report(); Has("decode_errors=1"); Has("decode_error=-4");
        p.pushOpusFrame(nullptr, 0); p.noteMutedFrame(); Report(); Has("invalid_drops=1"); Has("muted_drops=1");
        inCallback = true;
        renderer->callbacks.OH_AudioRenderer_OnInterruptEvent(renderer, renderer->user, 1, 2);
        renderer->callbacks.OH_AudioRenderer_OnError(renderer, renderer->user, -7);
        inCallback = false;
        Report(); Has("interrupts=1"); Has("interrupt_hint=2"); Has("renderer_error=-7");
        decodeResult = 48000; p.pushOpusFrame(packet, 1); p.pushOpusFrame(packet, 1);
        Report(); Has("overflow_samples=96000"); Has("queue_samples=96000");
        p.stop(); Has("reason=stop"); CHECK(!p.isRunning());
        p.pushOpusFrame(packet, 1); Report(); Has("inactive_drops=1");
        CHECK(p.start(44100, 1) == 0); Report(); Has("received_frames=0"); Has("renderer_errors=0");
        CHECK(!p.hasRecentFrames(6000));
        OH_AudioRenderer foreign; foreign.callbacks = current->callbacks; foreign.user = current->user;
        Write(&foreign); Report(); Has("write_callbacks=1"); // stale/foreign callback cannot consume this session
        CHECK(p.start(48000, 2) == 0); decodeResult = -4; p.pushOpusFrame(packet, 1);
        Report(); Has("phase=no_decoded_pcm");
        p.stop();
        std::cout << "Audio health: packet/decode/render/drop/interrupt/error/lifecycle/throttle tests passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
