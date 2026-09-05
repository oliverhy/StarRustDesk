#!/usr/bin/env node
'use strict';

// Run: node tools/test-native-input-queue.cjs
// Compiles unchanged production functions, NOT a JS reimplementation. Only
// N-API values, diagnostics and the platform mouse enum are stubbed. All build
// products live in a fresh OS temp directory, never in the hvigor build tree.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');

const sourcePath = path.resolve(__dirname, '../entry/src/main/cpp/napi_init.cpp');
const source = fs.readFileSync(sourcePath, 'utf8').replace(/\r\n/g, '\n');
function between(start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a, `Production extraction anchors missing: ${start}`);
  assert.equal(source.indexOf(start, a + start.length), -1, `Ambiguous anchor: ${start}`);
  return source.slice(a, b);
}
function extractFunction(signature) {
  // Production top-level functions end with an unindented closing brace.
  return between(signature, '\n}\n') + '\n}\n';
}
const production = between('struct NativeMouseInputEvent {',
  'static OH_NativeXComponent* g_registeredMouseXComponent') + '\n' + [
  'static bool IsNativeMouseMove(',
  'static uint64_t QueueNativeInput(',
  'static uint64_t QueueNativeMouseInput(',
  'static uint64_t QueueNativeKeyInput(',
  'static napi_value NativeMouseInputToJs(',
  'static napi_value NativeKeyInputToJs(',
  'static napi_value TakeNativeInputEvents(',
  'static napi_value TakeLegacyNativeEvents(',
  'static napi_value TakeNativeMouseEvents(',
  'static napi_value TakeNativeKeyEvents(',
].map(extractFunction).join('\n');

const stubs = String.raw`
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#define CHECK(condition) do { if (!(condition)) throw std::runtime_error( \
    std::string("line ") + std::to_string(__LINE__) + ": " + #condition); } while (false)
constexpr int32_t OH_NATIVEXCOMPONENT_MOUSE_MOVE = 3;
struct DiagnosticLog {
    static DiagnosticLog& instance() { static DiagnosticLog log; return log; }
    void append(const std::string&, const std::string&, const std::string&) {}
};
struct JsValue;
using napi_value = std::shared_ptr<JsValue>;
using napi_env = void*;
using napi_callback_info = void*;
struct JsValue {
    double number{0};
    bool boolean{false};
    std::map<std::string, napi_value> props;
    std::vector<napi_value> elements;
};
static std::function<void()> onArrayCreate;
static std::string thrownError;
static int napi_create_object(napi_env, napi_value* out) {
    *out = std::make_shared<JsValue>(); return 0;
}
static int napi_create_double(napi_env env, double value, napi_value* out) {
    napi_create_object(env, out); (*out)->number = value; return 0;
}
static int napi_create_int32(napi_env env, int32_t value, napi_value* out) {
    return napi_create_double(env, value, out);
}
static int napi_create_int64(napi_env env, int64_t value, napi_value* out) {
    return napi_create_double(env, static_cast<double>(value), out);
}
static int napi_get_boolean(napi_env env, bool value, napi_value* out) {
    napi_create_object(env, out); (*out)->boolean = value; return 0;
}
static int napi_set_named_property(napi_env, napi_value object, const char* name, napi_value value) {
    object->props[name] = value; return 0;
}
static int napi_create_array_with_length(napi_env env, size_t size, napi_value* out) {
    napi_create_object(env, out); (*out)->elements.resize(size);
    if (onArrayCreate) { auto callback = std::move(onArrayCreate); onArrayCreate = {}; callback(); }
    return 0;
}
static int napi_set_element(napi_env, napi_value array, uint32_t index, napi_value value) {
    array->elements.at(index) = value; return 0;
}
static int napi_throw_error(napi_env, const char* code, const char*) {
    thrownError = code; return 0;
}
`;

const tests = String.raw`
static NativeMouseInputEvent Mouse(float x, int32_t action = OH_NATIVEXCOMPONENT_MOUSE_MOVE,
    int32_t button = 0, int32_t mask = 0, bool valid = true) {
    return {x, x + 1, action, button, -1, 456, mask, valid};
}
static NativeKeyInputEvent Key(int32_t code, int32_t action = 0) {
    return {code, action, 123, 2, true, false, true};
}
static double Number(napi_value item, const char* name) { return item->props.at(name)->number; }
static uint64_t Sequence(napi_value item) { return static_cast<uint64_t>(Number(item, "sequence")); }
static std::vector<napi_value> Drain() { return TakeNativeInputEvents(nullptr, nullptr)->elements; }
static void CheckContract(const std::vector<napi_value>& items) {
    uint64_t last = 0;
    for (const auto& item : items) {
        CHECK(Sequence(item) > last); last = Sequence(item);
        CHECK(item->props.size() == 2);
        CHECK(item->props.count("mouse") + item->props.count("key") + item->props.count("reset") == 1);
        if (item->props.count("reset")) CHECK(item->props.at("reset")->boolean);
    }
}
static void Test(const char* name, const std::function<void()>& body) {
    { std::lock_guard<std::mutex> lock(g_nativeInputMutex);
      g_nativeInputEvents.clear(); g_nativeInputSequence = 0; }
    onArrayCreate = {}; thrownError.clear();
    body();
    std::cout << "PASS " << name << std::endl;
}
int main() {
    try {
        Test("key -> mouse preserves order and payload", [] {
            const auto keySeq = QueueNativeKeyInput(Key(42));
            const auto mouseSeq = QueueNativeMouseInput(Mouse(17, 1, 1));
            auto items = Drain(); CheckContract(items); CHECK(items.size() == 2);
            CHECK(Sequence(items[0]) == keySeq); CHECK(Sequence(items[1]) == mouseSeq);
            CHECK(Number(items[0]->props.at("key"), "keyCode") == 42);
            CHECK(Number(items[0]->props.at("key"), "timestamp") == 123);
            CHECK(Number(items[1]->props.at("mouse"), "x") == 17);
            CHECK(Number(items[1]->props.at("mouse"), "timestamp") == 456);
        });
        Test("mouse moves never coalesce across a key", [] {
            QueueNativeMouseInput(Mouse(1)); QueueNativeKeyInput(Key(42)); QueueNativeMouseInput(Mouse(2));
            auto items = Drain(); CheckContract(items); CHECK(items.size() == 3);
            CHECK(items[0]->props.count("mouse")); CHECK(items[1]->props.count("key"));
            CHECK(items[2]->props.count("mouse"));
            CHECK(Number(items[0]->props.at("mouse"), "x") == 1);
            CHECK(Number(items[2]->props.at("mouse"), "x") == 2);
        });
        Test("compatible contiguous moves coalesce to latest sequence and payload", [] {
            QueueNativeMouseInput(Mouse(1)); QueueNativeMouseInput(Mouse(2));
            auto last = QueueNativeMouseInput(Mouse(3));
            auto items = Drain(); CheckContract(items); CHECK(items.size() == 1);
            CHECK(Sequence(items[0]) == last); CHECK(last == 3);
            CHECK(Number(items[0]->props.at("mouse"), "x") == 3);
        });
        Test("button edges, hover and changed modifier snapshots are boundaries", [] {
            QueueNativeMouseInput(Mouse(1)); QueueNativeMouseInput(Mouse(2, 1, 1));
            QueueNativeMouseInput(Mouse(3)); QueueNativeMouseInput(Mouse(4, 3, 1));
            QueueNativeMouseInput(Mouse(5, 3, 1, 2));
            QueueNativeMouseInput(Mouse(6, 3, 1, 2, false));
            auto hover = Mouse(7); hover.hover = 0; QueueNativeMouseInput(hover);
            QueueNativeMouseInput(Mouse(8));
            auto items = Drain(); CheckContract(items); CHECK(items.size() == 8);
        });
        Test("overflow clears backlog and resets before triggering key or button edge", [] {
            for (bool mouse : {false, true}) {
                for (size_t i = 0; i < NATIVE_INPUT_QUEUE_LIMIT; ++i) QueueNativeKeyInput(Key(10));
                CHECK(g_nativeInputEvents.size() == NATIVE_INPUT_QUEUE_LIMIT);
                auto eventSeq = mouse ? QueueNativeMouseInput(Mouse(99, 2, 1)) : QueueNativeKeyInput(Key(99, 1));
                auto items = Drain(); CheckContract(items); CHECK(items.size() == 2);
                CHECK(items[0]->props.count("reset")); CHECK(Sequence(items[0]) + 1 == eventSeq);
                CHECK(Sequence(items[1]) == eventSeq);
                CHECK(items[1]->props.count(mouse ? "mouse" : "key"));
                CHECK(Number(items[1]->props.at(mouse ? "mouse" : "key"), mouse ? "x" : "keyCode") == 99);
                CHECK(Drain().empty());
            }
        });
        Test("repeated overflow retains reset and newest event", [] {
            for (size_t i = 0; i <= 2 * NATIVE_INPUT_QUEUE_LIMIT; ++i) QueueNativeKeyInput(Key(static_cast<int>(i)));
            auto items = Drain(); CheckContract(items); CHECK(items.size() == 3);
            CHECK(items[0]->props.count("reset"));
            CHECK(Number(items.back()->props.at("key"), "keyCode") == 2 * NATIVE_INPUT_QUEUE_LIMIT);
        });
        Test("drain empties queue without restarting sequence", [] {
            auto first = QueueNativeKeyInput(Key(1)); CHECK(Drain().size() == 1); CHECK(Drain().empty());
            auto next = QueueNativeKeyInput(Key(2)); CHECK(next == first + 1);
            auto items = Drain(); CHECK(items.size() == 1); CHECK(Sequence(items[0]) == next);
        });
        Test("atomic snapshot leaves enqueue during serialization for next drain", [] {
            auto first = QueueNativeKeyInput(Key(1));
            uint64_t second = 0;
            onArrayCreate = [&] {
                // Joining here also verifies that serialization does not hold the queue mutex.
                std::thread producer([&] { second = QueueNativeMouseInput(Mouse(2)); }); producer.join();
            };
            auto before = Drain(); CHECK(before.size() == 1); CHECK(Sequence(before[0]) == first);
            auto after = Drain(); CHECK(after.size() == 1); CHECK(Sequence(after[0]) == second);
            CHECK(second > first); CHECK(Drain().empty());
        });
        Test("legacy key drain does not erase move coalescing boundary", [] {
            QueueNativeMouseInput(Mouse(1)); QueueNativeKeyInput(Key(7));
            CHECK(TakeNativeKeyEvents(nullptr, nullptr)->elements.size() == 1);
            QueueNativeMouseInput(Mouse(2));
            auto items = Drain(); CheckContract(items); CHECK(items.size() == 2);
            CHECK(Sequence(items[0]) == 1); CHECK(Sequence(items[1]) == 3);
        });
        Test("legacy drains reject pending reset without consuming it", [] {
            for (size_t i = 0; i <= NATIVE_INPUT_QUEUE_LIMIT; ++i) QueueNativeKeyInput(Key(1));
            CHECK(!TakeNativeKeyEvents(nullptr, nullptr)); CHECK(thrownError == "ERR_NATIVE_INPUT_RESET");
            CHECK(!TakeNativeMouseEvents(nullptr, nullptr)); CHECK(thrownError == "ERR_NATIVE_INPUT_RESET");
            auto items = Drain(); CHECK(items.size() == 2); CHECK(items[0]->props.count("reset"));
        });
        Test("concurrent keyboard/mouse producers and drains lose no edges", [] {
            uint64_t previous = 0;
            for (int round = 0; round < 40; ++round) {
                std::atomic<bool> start{false}; std::atomic<int> done{0};
                auto producer = [&](bool mouse) {
                    while (!start.load()) std::this_thread::yield();
                    for (int i = 0; i < 64; ++i) {
                        if (mouse) QueueNativeMouseInput(Mouse(static_cast<float>(i), 1 + i % 2, 1));
                        else QueueNativeKeyInput(Key(i, i % 2));
                        std::this_thread::yield();
                    }
                    ++done;
                };
                std::thread keys(producer, false), mice(producer, true);
                std::vector<napi_value> all; start = true;
                while (done.load() != 2) {
                    auto batch = Drain(); all.insert(all.end(), batch.begin(), batch.end());
                    std::this_thread::yield();
                }
                keys.join(); mice.join();
                auto tail = Drain(); all.insert(all.end(), tail.begin(), tail.end());
                CheckContract(all); CHECK(all.size() == 128);
                std::set<int> keyIds, mouseIds;
                for (auto item : all) {
                    CHECK(Sequence(item) == ++previous); CHECK(!item->props.count("reset"));
                    if (item->props.count("key")) keyIds.insert(static_cast<int>(Number(item->props.at("key"), "keyCode")));
                    else mouseIds.insert(static_cast<int>(Number(item->props.at("mouse"), "x")));
                }
                CHECK(keyIds.size() == 64); CHECK(mouseIds.size() == 64); CHECK(Drain().empty());
            }
        });
        std::cout << "11 executable native input queue tests passed" << std::endl;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << std::endl; return 1;
    }
}
`;

function run(file, args, options = {}) {
  const result = cp.spawnSync(file, args, { encoding: 'utf8', timeout: 60000, ...options });
  if (result.error || result.status !== 0) {
    throw new Error(`${file} failed: ${result.error?.message || `exit ${result.status}`}\n${result.stdout || ''}${result.stderr || ''}`);
  }
  return result.stdout;
}
function compilerEnvironment() {
  let env = { ...process.env };
  if (process.platform === 'win32') {
    const vswhere = path.join(env['ProgramFiles(x86)'] || 'C:/Program Files (x86)',
      'Microsoft Visual Studio/Installer/vswhere.exe');
    if (fs.existsSync(vswhere)) {
      const installation = run(vswhere, ['-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']).trim();
      if (installation) {
        const vcvars = path.join(installation, 'VC/Auxiliary/Build/vcvars64.bat');
        const output = run(env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `""${vcvars}" >nul && set"`],
          { windowsVerbatimArguments: true });
        for (const line of output.split(/\r?\n/)) {
          const equals = line.indexOf('=');
          if (equals <= 0) continue;
          const key = line.slice(0, equals);
          // Windows environment names are case-insensitive; remove stale PATH variants.
          for (const old of Object.keys(env)) if (old.toLowerCase() === key.toLowerCase()) delete env[old];
          env[key] = line.slice(equals + 1);
        }
        return { compiler: process.env.CXX || 'cl.exe', env };
      }
    }
  }
  return { compiler: process.env.CXX || 'clang++', env };
}

let temp;
try {
  const { compiler, env } = compilerEnvironment();
  temp = fs.mkdtempSync(path.join(os.tmpdir(), 'starrustdesk-input-queue-'));
  const cpp = path.join(temp, 'test.cpp');
  const exe = path.join(temp, process.platform === 'win32' ? 'test.exe' : 'test');
  fs.writeFileSync(cpp, stubs + '\n' + production + '\n' + tests, 'utf8');
  const msvc = /^(cl|cl\.exe)$/i.test(path.basename(compiler));
  const args = msvc ? ['/nologo', '/std:c++17', '/EHsc', '/W4', '/Od', cpp, `/Fe${exe}`, `/Fo${path.join(temp, 'test.obj')}`]
    : ['-std=c++17', '-O0', '-Wall', '-Wextra', '-pthread', cpp, '-o', exe];
  console.log(`Compiling extracted production queue with ${compiler} (OS temp directory only)`);
  const output = run(compiler, args, { env, cwd: temp });
  if (output.trim()) console.log(output.trim());
  process.stdout.write(run(exe, [], { env, cwd: temp, timeout: 30000 }));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (temp) {
    // Verify this is our own immediate child of OS temp before recursive cleanup.
    assert.equal(path.dirname(path.resolve(temp)), path.resolve(os.tmpdir()));
    assert(path.basename(temp).startsWith('starrustdesk-input-queue-'));
    fs.rmSync(temp, { recursive: true, force: true });
  }
}
