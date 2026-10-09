'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname,
  '../entry/src/main/ets/service/ConnectionService.ets'), 'utf8').replace(/^import .*\r?\n/gm, '');
const compile = code => ts.transpileModule(code, { compilerOptions: {
  target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
}}).outputText;
function harness(capabilities = 8) {
  const calls = [], logs = [];
  const native = new Proxy({}, { get: (_, name) => (...args) => {
    if (name === 'getInputCapabilities') return capabilities;
    if (name === 'appendDiagnosticLog') { logs.push(args); return 0; }
    calls.push([name, ...args]); return 0;
  }});
  const context = { exports: {}, RustDeskNapi: native, hilog: { info() {} } };
  vm.runInNewContext(compile(source), context);
  return { S: context.exports.ConnectionService, calls, logs,
    keys: () => calls.filter(c => c[0] === 'sendKeyEvent').map(c => c.slice(1, 3)),
    clear: () => { calls.length = 0; logs.length = 0; } };
}
let checks = 0;
function test(name, run) { run(); checks++; console.log('PASS ' + name); }
test('hardware snapshot then physical Command down is sent once, with one release', () => {
  const h = harness(), { S } = h;
  S.syncHardwareModifierState(false, false, false, true);
  S.sendKeyEvent(91, 0, 2076);
  S.syncNativeModifierState(8); S.syncHeldModifierState(false, false, false, true);
  S.sendLetterKeyEvent('q', 0x14, 0, 8); S.sendLetterKeyEvent('q', 0x14, 1, 8);
  S.sendKeyEvent(91, 1, 2076); S.syncHardwareModifierState(false, false, false, false);
  assert.deepEqual(h.keys(), [[91, 0], [91, 1]]);
  assert.deepEqual(h.calls.filter(c => c[0] === 'sendPhysicalKeyEvent').map(c => c.slice(1)),
    [[0x14, 0, 8], [0x14, 1, 8]]);
  S.sendMouseEvent(1, 1, 1); assert.equal(h.calls.at(-1)[4], 0);
});
test('Mac auto Shift letters, numbers and punctuation stay physical rather than injecting text', () => {
  const h = harness(), { S } = h;
  S.sendKeyEvent(16, 0, 2047);
  S.sendLetterKeyEvent('a', 4, 0, 2); S.sendLetterKeyEvent('a', 4, 1, 2);
  for (const code of [0x1e, 0x33]) {
    S.sendPhysicalKeyEvent(code, 0, 2); S.sendPhysicalKeyEvent(code, 1, 2);
  }
  S.sendKeyEvent(16, 1, 2047);
  assert.equal(h.calls.some(c => c[0] === 'sendText'), false);
  assert.deepEqual(h.keys(), [[16, 0], [16, 1]]);
  assert.equal(h.calls.filter(c => c[0] === 'sendPhysicalKeyEvent').length, 6);
});
test('left/right modifiers and virtual + physical owners release independently', () => {
  const h = harness(), { S } = h;
  S.sendKeyEvent(16, 0, 2047); S.sendKeyEvent(161, 0, 2048);
  S.syncHardwareModifierState(false, true, false); S.sendKeyEvent(16, 1, 2047);
  S.sendMouseEvent(1, 1, 1); assert.equal(h.calls.at(-1)[4], 2);
  S.sendKeyEvent(161, 1, 2048);
  assert.deepEqual(h.keys(), [[16, 0], [161, 0], [16, 1], [161, 1]]);
  h.clear();
  S.sendKeyEvent(17, 0, 10017); S.sendKeyEvent(17, 0, 2072);
  S.sendKeyEvent(17, 1, 2072); assert.deepEqual(h.keys(), [[17, 0]]);
  S.sendKeyEvent(17, 1, 10017); assert.deepEqual(h.keys(), [[17, 0], [17, 1]]);
});
test('snapshot right-side handoff does not leave a phantom left modifier', () => {
  const h = harness(), { S } = h;
  S.syncNativeModifierState(4); S.sendKeyEvent(165, 0, 2046);
  S.syncHardwareModifierState(false, false, true); S.sendKeyEvent(165, 1, 2046);
  assert.deepEqual(h.keys(), [[18, 0], [18, 1], [165, 0], [165, 1]]);
});
test('focus loss and mode changes balance physical keys and each sent modifier once', () => {
  const h = harness(), { S } = h;
  S.syncHardwareModifierState(true, false, false, true);
  S.sendKeyEvent(91, 0, 2076); S.sendPhysicalKeyEvent(4, 0, 9);
  h.clear(); S.configureInputModes(2, false);
  assert.deepEqual(h.keys(), [[17, 1], [91, 1]]);
  assert(h.calls.some(c => c[0] === 'sendPhysicalKeyEvent' && c[2] === 1));
  assert.equal(h.calls.at(-1)[0], 'setInputModes');
  h.clear(); S.releaseModifiers(); assert.deepEqual(h.keys(), []);
});
test('snapshot-only modifiers still enable mouse shortcuts without direct key callbacks', () => {
  const h = harness(), { S } = h;
  S.syncHeldModifierState(true, true, false); S.sendMouseEvent(1, 1, 1);
  assert.equal(h.calls.at(-1)[4], 3);
  S.syncHeldModifierState(false, false, false);
  assert.deepEqual(h.keys(), [[17, 0], [16, 0], [17, 1], [16, 1]]);
});
test('Windows Shift-number restore and selected Legacy compatibility are preserved', () => {
  const h = harness(0), { S } = h;
  S.sendKeyEvent(16, 0, 2047); S.sendPhysicalKeyEvent(0x1e, 0, 2);
  assert(h.calls.some(c => c[0] === 'sendText' && c[1] === '!'));
  assert.deepEqual(h.keys(), [[16, 0], [16, 0]]);
  S.sendPhysicalKeyEvent(0x1e, 1, 0); S.sendKeyEvent(16, 1, 2047);
  assert.equal(h.keys().filter(c => c[1] === 1).length, 1);
  const mac = harness(); mac.S.configureInputModes(2, false); mac.clear();
  mac.S.sendLetterKeyEvent('a', 4, 0, 2);
  assert(mac.calls.some(c => c[0] === 'sendPhysicalKeyEvent'));
  mac.S.sendText('中文'); assert.deepEqual(mac.calls.at(-1), ['sendText', '中文']);
});
console.log(`TOTAL=${checks} FAILED=0 (production modifier routing; Mac device acceptance pending)`);
