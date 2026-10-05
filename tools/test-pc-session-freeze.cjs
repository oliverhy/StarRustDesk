'use strict';
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
for (const name of ['h264_decoder', 'vp9_decoder', 'system_video_decoder']) {
  const source = read(`entry/src/main/cpp/core/${name}.cpp`);
  for (const callback of ['onNeedInputBuffer', 'onNewOutputBuffer']) {
    const start = source.indexOf(`::${callback}(`);
    const body = source.slice(start, source.indexOf('\n}', start) + 2);
    assert(body.indexOf('callbackQueue_.post') < body.indexOf('lock(decoder->mutex_)'));
    assert.match(body, /!active->load\(\)/);
    assert.match(body, /decoder->codec_ != codec/);
  }
  assert.match(source, /callbackContext_\.get\(\)/);
  assert.match(source, /stopLocked\(\) \{\s+if \(callbackContext_\) callbackContext_->active->store\(false\)/);
}
const video = read('entry/src/main/cpp/core/video_render.cpp');
const receive = video.slice(video.indexOf('void VideoRender::onFrameReceived'), video.indexOf('uint64_t VideoRender::decodedFrameCount'));
assert.doesNotMatch(receive, /renderFrameNow|flushPendingFrames\(\)/);
assert.match(receive, /queuePendingFrame/);
assert.match(receive, /flushPendingFramesAsync/);
assert.match(video, /pendingFrameBytes_ \+ frame.data.size\(\) > MAX_PENDING_BYTES/);
assert.match(video, /frameWorker_\.post/);
for (const operation of ['resetSession', 'rebindSurface', 'restartDecoder']) {
  const start = video.indexOf(`void VideoRender::${operation}(`);
  const body = video.slice(start, video.indexOf('\n}', start) + 2);
  assert.match(body, /rendering\(renderMutex_\)/);
}
const rust = read('entry/src/main/rust/src/lib.rs');
assert.match(rust, /health_timer.tick\(\)/);
assert.match(rust, /health.received\(last_message_at\)/);
assert.match(rust, /video_messages > 0 && test_delay_messages > 0/);
assert.match(rust, /session_health::display_rect\(&CURRENT_DISPLAY, &DISPLAY_INFOS\)/);
assert.doesNotMatch(rust, /DISPLAY_INFOS.try_lock\(\)/);

const vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe';
const vs = cp.execFileSync(vswhere, ['-latest', '-products', '*', '-requires',
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], {encoding:'utf8'}).trim();
const out = path.join(root, 'build-artifacts/pc-session-freeze-tests');
fs.mkdirSync(out, {recursive:true});
const exe = path.join(out, 'test-video-task-queue.exe');
const command = `call "${path.join(vs, 'VC/Auxiliary/Build/vcvars64.bat')}" >nul && ` +
  `cl /nologo /std:c++17 /EHsc /O2 /I"${path.join(root, 'entry/src/main/cpp/core')}" ` +
  `"${path.join(root, 'tools/native/test-video-task-queue.cpp')}" /Fe:"${exe}" /Fo:"${out}/"`;
cp.execFileSync('cmd.exe', ['/d','/s','/c',command], {cwd:root,windowsVerbatimArguments:true,stdio:'pipe'});
process.stdout.write(cp.execFileSync(exe, [], {encoding:'utf8', timeout:10000}));
const rustc = path.join(process.env.USERPROFILE, '.cargo/bin/rustc.exe');
const rustExe = path.join(out, 'test-session-health.exe');
cp.execFileSync(rustc, ['--edition=2021', '--test', path.join(root, 'entry/src/main/rust/src/session_health.rs'), '-o', rustExe], {cwd:root,stdio:'pipe'});
process.stdout.write(cp.execFileSync(rustExe, [], {encoding:'utf8', timeout:10000}));
console.log('PASS PC session freeze integration guards');
