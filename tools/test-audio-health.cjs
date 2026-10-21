'use strict';
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const cp = require('node:child_process'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
function run(file, args, options = {}) {
  const r = cp.spawnSync(file, args, {encoding: 'utf8', timeout: 60000, ...options});
  if (r.error || r.status !== 0) throw Error(`${file}: ${r.error?.message || r.status}\n${r.stdout || ''}${r.stderr || ''}`);
  return r.stdout;
}
const source = fs.readFileSync(path.join(root, 'entry/src/main/cpp/napi_init.cpp'), 'utf8');
assert.match(source, /IsRemoteAudioActive[\s\S]*?reportDiagnostics\(\)/);
assert.match(source, /GetDiagnosticLog[\s\S]*?reportDiagnostics\(true, "export"\)/);
assert.match(source, /OnRustAudioFrame[\s\S]*?noteMutedFrame\(\)/);
let temp;
try {
  temp = fs.mkdtempSync(path.join(os.tmpdir(), 'starrustdesk-audio-health-'));
  const sdk = path.join(temp, 'sdk');
  for (const directory of ['ohaudio', 'hilog']) fs.mkdirSync(path.join(sdk, directory), {recursive: true});
  for (const header of ['ohaudio/native_audiorenderer.h', 'ohaudio/native_audiostreambuilder.h', 'opus.h']) {
    fs.writeFileSync(path.join(sdk, header), '#include "audio-test-platform.h"\n');
  }
  fs.writeFileSync(path.join(sdk, 'hilog/log.h'), '#define LOG_APP 0\n#define OH_LOG_ERROR(...) ((void)0)\n#define OH_LOG_WARN(...) ((void)0)\n#define OH_LOG_INFO(...) ((void)0)\n');
  let env = {...process.env}, compiler = process.env.CXX || 'clang++';
  if (process.platform === 'win32') {
    const vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe';
    const installation = run(vswhere, ['-latest', '-products', '*', '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).trim();
    assert(installation, 'Native C++ test compiler is required');
    const vcvars = path.join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
    const output = run(env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `""${vcvars}" >nul && set"`], {windowsVerbatimArguments: true});
    for (const line of output.split(/\r?\n/)) {
      const i = line.indexOf('='); if (i <= 0) continue; const key = line.slice(0, i);
      for (const old of Object.keys(env)) if (old.toLowerCase() === key.toLowerCase()) delete env[old];
      env[key] = line.slice(i + 1);
    }
    compiler = process.env.CXX || 'cl.exe';
  }
  const exe = path.join(temp, process.platform === 'win32' ? 'test.exe' : 'test');
  const includes = [sdk, path.join(root, 'tools/native'), path.join(root, 'entry/src/main/cpp/core')];
  const files = [path.join(root, 'tools/native/audio-health-test.cpp'), path.join(root, 'entry/src/main/cpp/core/audio_player.cpp')];
  const msvc = /^(cl|cl\.exe)$/i.test(path.basename(compiler));
  const args = msvc ? ['/nologo', '/std:c++17', '/EHsc', '/W4', ...includes.map(p => '/I' + p), ...files, '/Fe' + exe]
    : ['-std=c++17', '-pthread', ...includes.map(p => '-I' + p), ...files, '-o', exe];
  console.log(run(compiler, args, {env, cwd: temp}));
  process.stdout.write(run(exe, [], {env, cwd: temp}));
} catch (e) {console.error(e.message); process.exitCode = 1;}
finally {
  if (temp) {
    assert.equal(path.dirname(path.resolve(temp)), path.resolve(os.tmpdir()));
    assert(path.basename(temp).startsWith('starrustdesk-audio-health-'));
    fs.rmSync(temp, {recursive: true, force: true});
  }
}
