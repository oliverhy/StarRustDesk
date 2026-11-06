'use strict';
// Exercise the production routing/worker against deterministic codec and surface doubles.
// This does not establish real hardware decoding compatibility.
const cp = require('node:child_process'), fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const root = path.resolve('entry/src/main/cpp/core');
const projectIncludes = /^#include "(?:h264_decoder|software_vp9_decoder|system_video_decoder|xcomponent_render|secondary_video_render|diagnostic_log|rustdesk_ffi)\.h"\s*$/gm;
const header = fs.readFileSync(path.join(root, 'secondary_video_render.h'), 'utf8').replace(projectIncludes, '');
const source = fs.readFileSync(path.join(root, 'secondary_video_render.cpp'), 'utf8').replace(projectIncludes, '')
  .replace(/^#include <hilog\/log\.h>\s*$/m, '');
const preamble = `
#define OH_LOG_INFO(...) ((void)0)
#define LOG_APP 0
#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <cstdint>
using OHNativeWindow = int;
struct VideoColorInfo {};
std::atomic<bool> allowHardware{true}, allowSoftware{true};
std::atomic<int> h264Frames{0}, h265Frames{0}, vp9Frames{0}, refreshes{0};
class DiagnosticLog { public: static DiagnosticLog& instance() { static DiagnosticLog d; return d; }
  void append(const std::string&, const std::string&, const std::string&) {} };
void rust_refresh_video() { ++refreshes; }
class XComponentRender { bool ready_{false}; int window_{1}; public:
  explicit XComponentRender(bool) {}
  void setSurface(const std::string& id) { ready_ = !id.empty(); }
  bool isReady() const { return ready_; }
  void release() { ready_ = false; }
  OHNativeWindow* prepareDecoderSurface() { return ready_ ? &window_ : nullptr; }
  bool renderBGRAFrame(const uint8_t*, int, int, int) { return ready_; }
};
class H264Decoder { std::function<void(bool)> output_; bool software_, started_{false}; public:
  H264Decoder(XComponentRender*, std::function<void(bool)> out, std::function<void(int)>, bool soft=false)
    : output_(std::move(out)), software_(soft) {}
  void setSurface(OHNativeWindow*,int,int) { started_ = software_ ? allowSoftware.load() : allowHardware.load(); }
  bool isStarted() const { return started_; }
  void decodeFrame(const uint8_t*,int,bool,int64_t) { ++h264Frames; output_(true); }
};
class SystemVideoDecoder { std::function<void(bool)> output_; bool software_, started_{false}; public:
  SystemVideoDecoder(std::function<void(bool)> out, bool soft) : output_(std::move(out)), software_(soft) {}
  static std::unique_ptr<SystemVideoDecoder> createH265Secondary(XComponentRender*,
    std::function<void(bool)> out, std::function<void(int)>, bool soft=false) {
    return std::make_unique<SystemVideoDecoder>(std::move(out), soft);
  }
  void setSurface(OHNativeWindow*,int,int) { started_ = software_ ? allowSoftware.load() : allowHardware.load(); }
  bool isStarted() const { return started_; }
  void decodeFrame(const uint8_t*,int,bool,int64_t) { ++h265Frames; output_(true); }
};
class SoftwareVP9Decoder { using Output = std::function<bool(const uint8_t*,int,int,int,const VideoColorInfo&)>;
  Output output_; public: explicit SoftwareVP9Decoder(Output out) : output_(std::move(out)) {}
  void decodeFrame(const uint8_t* data,int length,bool,int64_t) {
    ++vp9Frames; output_(data,length,1920,1080,VideoColorInfo{});
  }
};
`;
const tests = `
#include <chrono>
#include <iostream>
#include <stdexcept>
using namespace std::chrono_literals;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class F> void waitFor(F condition, const char* message) {
  for (int i=0; i<2000 && !condition(); ++i) std::this_thread::sleep_for(1ms);
  require(condition(), message);
}
int main() {
  const uint8_t frame[] = {0,0,0,1,0x65};
  SecondaryVideoRender s;
  require(!s.enqueue(frame,5,1920,1080,true,1,'H'), "no surface");
  require(s.setSurface("surface"), "surface setup");
  require(!s.enqueue(frame,5,1920,1080,true,1,'X'), "unknown codec accepted");
  require(!s.enqueue(frame,5,17000,1080,true,1,'H'), "invalid dimensions accepted");
  require(!s.enqueue(frame,16*1024*1024+1,1920,1080,true,1,'H'), "oversize accepted");
  require(s.enqueue(frame,5,1920,1080,true,1,'H'), "h264 enqueue");
  waitFor([&]{ return h264Frames.load() && s.presentedFrames(); }, "h264 output");
  require(s.enqueue(frame,5,1920,1080,true,2,'5'), "h265 enqueue");
  waitFor([&]{ return h265Frames.load() && s.presentedFrames(); }, "h265 output");
  require(s.enqueue(frame,5,1920,1080,true,3,'V'), "vp9 enqueue");
  waitFor([&]{ return vp9Frames.load() && s.presentedFrames(); }, "vp9 output");
  require(refreshes.load() >= 1, "codec switch refresh");
  s.reset();
  require(!s.enqueue(frame,5,1920,1080,true,4,'H'), "enqueue after reset");
  allowHardware=false; allowSoftware=true;
  require(s.setSurface("surface"), "surface restart");
  const auto previous = h264Frames.load();
  require(s.enqueue(frame,5,1280,720,true,5,'H'), "software fallback enqueue");
  waitFor([&]{ return h264Frames.load()>previous && s.presentedFrames(); }, "software fallback");
  s.reset(); allowSoftware=false;
  require(s.setSurface("surface"), "surface restart after fallback");
  require(s.enqueue(frame,5,1280,720,true,6,'5'), "failing decoder enqueue");
  waitFor([&]{ return s.error()==-7; }, "decoder failure not reported");
  require(!s.enqueue(frame,5,1280,720,true,7,'5'), "accepted frames after failure");
  s.reset(); allowHardware=true; allowSoftware=true;
  require(s.setSurface("surface"), "recovery surface");
  const auto previousVp9=vp9Frames.load();
  require(s.enqueue(frame,5,1280,720,true,8,'V'), "recovery enqueue");
  waitFor([&]{ return vp9Frames.load()>previousVp9 && s.presentedFrames(); }, "recovery output");
  std::cout << "PASS secondary worker: H.264/H.265/VP9 routing, switch, fallback, failure, reset and bounds\\n";
}
`;
const vswhere=path.join(process.env['ProgramFiles(x86)']||'C:/Program Files (x86)','Microsoft Visual Studio/Installer/vswhere.exe');
const install=cp.execFileSync(vswhere,['-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'],{encoding:'utf8'}).trim();
if(!install) throw new Error('Visual C++ compiler unavailable');
const vars=path.join(install,'VC/Auxiliary/Build/vcvars64.bat');
const result=cp.execFileSync(process.env.ComSpec||'cmd.exe',['/d','/s','/c',`""${vars}" >nul && set"`],{encoding:'utf8',windowsVerbatimArguments:true});
const env={...process.env};
for(const line of result.split(/\r?\n/)){const i=line.indexOf('='); if(i<=0)continue;const key=line.slice(0,i);for(const old of Object.keys(env))if(old.toLowerCase()===key.toLowerCase())delete env[old];env[key]=line.slice(i+1);}
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'srd-secondary-video-'));
const cpp=path.join(temp,'test.cpp'), exe=path.join(temp,'test.exe');
fs.writeFileSync(cpp,preamble+'\n'+header+'\n'+source+'\n'+tests);
cp.execFileSync('cl.exe',['/nologo','/EHsc','/std:c++17',`/Fe:${exe}`,cpp],{cwd:temp,env,stdio:'inherit'});
cp.execFileSync(exe,[],{cwd:temp,env,stdio:'inherit'});
