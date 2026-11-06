'use strict';
// Compiles the production queue/slot functions with host-only test types; it
// does not claim to exercise HarmonyOS GameControllerKit callbacks or devices.
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const cp = require('node:child_process'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/cpp/core/gamepad_input.cpp'), 'utf8').replace(/\r/g, '');
const header = fs.readFileSync(path.join(root, 'entry/src/main/cpp/core/gamepad_input.h'), 'utf8').replace(/\r/g, '');
const cut = (text, start, end) => { const a = text.indexOf(start), b = text.indexOf(end, a + start.length); assert(a >= 0 && b > a); return text.slice(a, b); };
const fn = name => cut(source, name, '\n}\n') + '\n}\n';
const production = cut(header, 'struct GamepadInputEvent {', '\n\n// Loading') + '\n' +
  cut(source, 'constexpr size_t kMaxEvents', '\nusing ButtonCallback') + '\n' +
  [fn('int32_t SlotLocked('), fn('void PushLocked('), fn('std::vector<GamepadInputEvent> TakeGamepadInput(')].join('\n');
const stubs = String.raw`
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <deque>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#define CHECK(x) do { if (!(x)) throw std::runtime_error("check failed: " #x); } while(false)
`;
const tests = String.raw`
int main() {
  { std::lock_guard<std::mutex> lock(g_mutex);
    CHECK(SlotLocked("synthetic-a", true) == 1);
    CHECK(SlotLocked("synthetic-a", true) == 1);
    CHECK(SlotLocked("synthetic-b", true) == 2);
    CHECK(SlotLocked("unknown", false) == 0);
    PushLocked(GamepadInputEvent{1, 1, 1, 0, 0.1, 0.2});
    PushLocked(GamepadInputEvent{1, 1, 1, 0, 0.5, 0.6});
    PushLocked(GamepadInputEvent{0, 1, 2301, 0});
    PushLocked(GamepadInputEvent{1, 1, 1, 0, 0.7, 0.8});
  }
  auto events = TakeGamepadInput();
  CHECK(events.size() == 3 && events[0].x == 0.5 && events[1].kind == 0 && events[2].x == 0.7);
  CHECK(TakeGamepadInput().empty());
  { std::lock_guard<std::mutex> lock(g_mutex);
    for (int i = 0; i < 512; ++i) PushLocked(GamepadInputEvent{0, 1, 2301, i % 2});
    PushLocked(GamepadInputEvent{0, 1, 2302, 0});
  }
  events = TakeGamepadInput();
  CHECK(events.size() == 1 && events[0].kind == 3);
  std::vector<std::thread> producers;
  for (int n = 0; n < 4; ++n) producers.emplace_back([n] {
    for (int i = 0; i < 50; ++i) { std::lock_guard<std::mutex> lock(g_mutex);
      PushLocked(GamepadInputEvent{0, n + 1, 2301, i % 2}); }
  });
  for (auto& thread : producers) thread.join();
  events = TakeGamepadInput(); CHECK(events.size() == 200);
  std::cout << "PASS native gamepad queue: ephemeral slots, axis coalescing, ordered edges, overflow reset, concurrency\n";
}
`;
function run(exe, args, options = {}) {
  const r = cp.spawnSync(exe, args, { encoding: 'utf8', timeout: 60000, ...options });
  if (r.error || r.status !== 0) throw new Error((r.error?.message || `exit ${r.status}`) + '\n' + (r.stdout || '') + (r.stderr || ''));
  return (r.stdout || '') + (r.stderr || '');
}
function compilerEnv() {
  const env = { ...process.env };
  if (process.platform !== 'win32') return { compiler: process.env.CXX || 'clang++', env };
  const vswhere = path.join(env['ProgramFiles(x86)'] || 'C:/Program Files (x86)', 'Microsoft Visual Studio/Installer/vswhere.exe');
  const installation = run(vswhere, ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).trim();
  const vcvars = path.join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
  const vars = run(env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `""${vcvars}" >nul && set"`], { windowsVerbatimArguments: true });
  for (const line of vars.split(/\r?\n/)) {
    const at = line.indexOf('='); if (at <= 0) continue;
    const key = line.slice(0, at);
    for (const old of Object.keys(env)) if (old.toLowerCase() === key.toLowerCase()) delete env[old];
    env[key] = line.slice(at + 1);
  }
  return { compiler: process.env.CXX || 'cl.exe', env };
}
let temp;
try {
  const { compiler, env } = compilerEnv();
  temp = fs.mkdtempSync(path.join(os.tmpdir(), 'starrustdesk-gamepad-queue-'));
  const cpp = path.join(temp, 'test.cpp'), exe = path.join(temp, process.platform === 'win32' ? 'test.exe' : 'test');
  fs.writeFileSync(cpp, stubs + production + tests, 'utf8');
  const msvc = /^(cl|cl\.exe)$/i.test(path.basename(compiler));
  const args = msvc ? ['/nologo', '/std:c++17', '/EHsc', '/W4', '/Od', cpp, `/Fe${exe}`, `/Fo${path.join(temp, 'test.obj')}`] :
    ['-std=c++17', '-O0', '-pthread', cpp, '-o', exe];
  run(compiler, args, { env, cwd: temp });
  process.stdout.write(run(exe, [], { env, cwd: temp }));
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally {
  if (temp) {
    assert.equal(path.dirname(path.resolve(temp)), path.resolve(os.tmpdir()));
    assert(path.basename(temp).startsWith('starrustdesk-gamepad-queue-'));
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 6, retryDelay: 150 });
  }
}
