#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = p => fs.readFileSync(path.resolve(__dirname, '..', p), 'utf8').replace(/\r\n/g, '\n');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const model = read('entry/src/main/ets/model/RemoteNavigationKeys.ets');
const packets = [], texts = [], logs = [];
let modifierMask = 0;
const service = {
  sendKeyEvent(code, action) { packets.push([code, action, modifierMask]); },
  syncNativeModifierState(mask) { modifierMask = mask; },
  syncCapsLockState() {}, sendCapsLockEvent() {},
};
function method(name) {
  const start = page.indexOf(`\n  ${name}(`);
  assert(start >= 0, name);
  const end = page.indexOf('\n  }', start) + 4;
  return page.slice(start, end);
}
const methods = ['mapControlKeyCode', 'isModifierControlCode', 'handleRemoteKey',
  'handleNativeKeyInput', 'forwardRemoteNavigationKey', 'releaseRemoteNavigationKeys',
  'handleDirectKeyboardChange', 'resetKeyboardCaptureBuffer'].map(method).join('\n');
const context = vm.createContext({
  ConnectionService: service, ConnectionStatus: { CONNECTED: 2 }, KeyType: { Down: 0, Up: 1 },
  RustDeskNapi: { appendDiagnosticLog: (tag, value) => logs.push([tag, value]) },
  KEYBOARD_CAPTURE_SENTINEL: '1'.repeat(60),
});
const source = model.replace(/^export /gm, '') + `\nclass Probe { ${methods} }\n` +
  'globalThis.Probe = Probe; globalThis.RemoteNavigationKeys = RemoteNavigationKeys;';
vm.runInContext(ts.transpileModule(source,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
function setup(panel = false) {
  packets.length = texts.length = logs.length = 0;
  modifierMask = 0;
  const p = new context.Probe();
  p.connectionStatus = 2; p.showKeyboardPanel = panel; p.showCommunicationPanel = false;
  p.navigationKeys = new context.RemoteNavigationKeys(); p.keyboardComposing = false;
  p.drainNativeInputEvents = () => {};
  p.syncModifiersFromKeyEvent = e => { modifierMask = e.mask || 0; };
  p.sendKeyboardText = text => texts.push(text);
  p.sendControlKey = key => packets.push([key, 2, modifierMask]);
  p.resetKeyboardCaptureBuffer();
  return p;
}
function ark(p, key, type = 0, mask = 0) {
  return p.handleRemoteKey({ keyCode: key, type, mask, keyText: '' });
}
function native(p, key, action = 0, mask = 0) {
  p.handleNativeKeyInput({ keyCode: key, action, modifierMask: mask, modifierValid: true });
}
let cases = 0;
function test(name, run) { run(); cases++; console.log(`PASS ${name}`); }

const navigation = [[2012,38], [2013,40], [2014,37], [2015,39],
  [2068,33], [2069,34], [2081,36], [2082,35], [2083,45]];
for (const panel of [false, true]) {
  test(`all physical navigation keys send balanced packets; keyboard panel=${panel}`, () => {
    const p = setup(panel);
    for (const [harmony, protocol] of navigation) {
      packets.length = 0;
      assert.equal(ark(p, harmony), true);
      assert.equal(ark(p, harmony, 1), true);
      assert.deepEqual(packets, [[protocol,0,0],[protocol,1,0]]);
    }
  });
  test(`native navigation retains Ctrl/Shift and repeat; keyboard panel=${panel}`, () => {
    const p = setup(panel);
    native(p, 2069, 0, 3); native(p, 2069, 0, 3); native(p, 2069, 1, 3);
    assert.deepEqual(packets, [[34,0,3],[34,2,3],[34,1,3]]);
  });
}
test('long-held Up sends down, repeated presses, and one final release', () => {
  const p = setup(true);
  for (let i = 0; i < 6; i++) ark(p, 2012, 0, 2);
  ark(p, 2012, 1, 2);
  assert.deepEqual(packets.map(p => p[1]), [0,2,2,2,2,2,1]);
  assert(packets.every(p => p[2] === 2));
});
for (const first of ['ark', 'native']) {
  test(`mirrored native/ArkUI downs do not double-send (${first} first)`, () => {
    const p = setup();
    const primary = first === 'ark' ? ark : native;
    const mirror = first === 'ark' ? native : ark;
    primary(p, 2013); mirror(p, 2013);
    primary(p, 2013); mirror(p, 2013);
    mirror(p, 2013, 1); primary(p, 2013, 1);
    assert.deepEqual(packets, [[40,0,0],[40,2,0],[40,1,0]]);
  });
}
test('IME composing and candidate selection stay local; committed Chinese sent once', () => {
  const p = setup(true);
  const base = p.keyboardInput;
  p.handleDirectKeyboardChange(base + 'zhong', { value: 'zhong' });
  assert.equal(p.keyboardComposing, true);
  assert.equal(ark(p, 2012), false);
  native(p, 2012);
  assert.equal(packets.length, 0); assert.equal(texts.length, 0);
  p.handleDirectKeyboardChange(base + '中', { value: '' });
  assert.deepEqual(texts, ['中']);
  assert.equal(ark(p, 2012), false, 'same candidate-selection hold must stay local after commit');
  assert.equal(ark(p, 2012, 1), false);
  assert.equal(ark(p, 2012, 1), false, 'pre-IME and dispatch can see the same release');
  assert.equal(packets.length, 0);
  ark(p, 2012); ark(p, 2012, 1);
  assert.deepEqual(packets, [[38,0,0],[38,1,0]]);
  assert(!JSON.stringify(logs).includes('zhong') && !JSON.stringify(logs).includes('中'));
});
test('a remote-held arrow still releases if composition starts before key-up', () => {
  const p = setup(true); ark(p, 2014);
  p.handleDirectKeyboardChange(p.keyboardInput + 'ni', { value: 'ni' });
  ark(p, 2014, 1);
  assert.deepEqual(packets, [[37,0,0],[37,1,0]]);
});
test('letters, Enter and Backspace remain owned by text input while panel is open', () => {
  const p = setup(true);
  for (const code of [2017, 2001, 2054, 2055]) assert.equal(ark(p, code), false);
  assert.equal(packets.length, 0);
});
test('focus loss releases all remote navigation keys and fresh presses are not repeats', () => {
  const p = setup(); ark(p, 2012); ark(p, 2069);
  p.releaseRemoteNavigationKeys('test_blur');
  ark(p, 2012, 1); ark(p, 2069, 1);
  ark(p, 2012);
  assert.deepEqual(packets, [[38,0,0],[34,0,0],[38,1,0],[34,1,0],[38,0,0]]);
});
test('chat, disconnected sessions and unknown key actions cannot emit remote navigation', () => {
  const p = setup(); p.showCommunicationPanel = true;
  ark(p, 2012); native(p, 2012);
  p.showCommunicationPanel = false; p.connectionStatus = 0;
  ark(p, 2012); native(p, 2012);
  p.connectionStatus = 2; ark(p, 2012, 99); native(p, 2012, 99);
  assert.equal(packets.length, 0);
});
assert.match(page, /\.onKeyPreIme\(/, 'navigation must intercept before the hidden input moves its caret');
console.log(`PASS ${cases} keyboard-navigation scenarios`);
