'use strict';
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const cp = require('node:child_process'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const napi = read('entry/src/main/cpp/napi_init.cpp');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const service = read('entry/src/main/ets/service/ConnectionService.ets');
const rust = read('entry/src/main/rust/src/lib.rs');
for (const source of [page, service]) {
  assert(!/native_key_forwarded code=|shifted_number_forwarded hid=|printable_key=\$\{|virtual_key=\$\{|soft_key key=\$\{/.test(source));
}
assert(!/InputTrace napi_(?:key|physical) (?:key|hid)=%/.test(napi));
assert(!/Send(?:Physical)?KeyEvent (?:key|hid)=%/.test(napi));
assert(!rust.includes('format!("scan:{chr}")'));
assert(rust.includes('input_diagnostics::trace_summary(stage, msg)'));
const run = (command, args, options = {}) => {
  const result = cp.spawnSync(command, args, { encoding: 'utf8', timeout: 120000, windowsHide: true, ...options });
  if (result.error || result.status !== 0) throw Error(`${command}: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout;
};
let env = { ...process.env }, compiler = process.env.CXX || 'clang++';
if (process.platform === 'win32') {
  const vswhere = path.join(env['ProgramFiles(x86)'] || 'C:/Program Files (x86)', 'Microsoft Visual Studio/Installer/vswhere.exe');
  if (fs.existsSync(vswhere)) {
    const installation = run(vswhere, ['-latest', '-products', '*', '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).trim();
    if (installation) {
      const vcvars = path.join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
      const output = run(env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `""${vcvars}" >nul && set"`], { windowsVerbatimArguments: true });
      for (const line of output.split(/\r?\n/)) {
        const equals = line.indexOf('='); if (equals <= 0) continue;
        const key = line.slice(0, equals);
        for (const old of Object.keys(env)) if (old.toLowerCase() === key.toLowerCase()) delete env[old];
        env[key] = line.slice(equals + 1);
      }
      compiler = process.env.CXX || 'cl.exe';
    }
  }
}
let temp;
try {
  temp = fs.mkdtempSync(path.join(os.tmpdir(), 'starrustdesk-log-privacy-'));
  const input = path.join(__dirname, 'input-log-privacy-native.cpp');
  const exe = path.join(temp, process.platform === 'win32' ? 'privacy.exe' : 'privacy');
  const msvc = /^(cl|cl\.exe)$/i.test(path.basename(compiler));
  const args = msvc ? ['/nologo', '/std:c++17', '/EHsc', '/utf-8', '/W4', input, `/Fe${exe}`, `/Fo${path.join(temp, 'privacy.obj')}`]
    : ['-std=c++17', '-Wall', '-Wextra', '-pthread', input, '-o', exe];
  run(compiler, args, { env, cwd: temp });
  process.stdout.write(run(exe, [temp], { env, cwd: temp, timeout: 30000 }));
} finally {
  if (temp) {
    assert.equal(path.dirname(path.resolve(temp)), path.resolve(os.tmpdir()));
    assert(path.basename(temp).startsWith('starrustdesk-log-privacy-'));
    fs.rmSync(temp, { recursive: true, force: true });
  }
}
