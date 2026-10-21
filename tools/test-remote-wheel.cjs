'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/model/RemoteWheelNormalizer.ets'), 'utf8');
const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8').replace(/\r\n/g, '\n');
const context = vm.createContext({exports: {}, Math, Number});
vm.runInContext(ts.transpileModule(source, {compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021}}).outputText, context);
const Normalizer = context.exports.RemoteWheelNormalizer;
let count = 0;
const test = (name, run) => {run(); count++; console.log('PASS ' + name);};
test('logged 88/89-detent jumps become one detent without an integer backlog', () => {
  const n = new Normalizer();
  for (const [i, raw] of [1100, 1112.5, -1100, 1100, -1100].entries()) {
    const result = n.convert(0, raw, 'mouse', 1, i * 100);
    assert.equal(result.y, Math.sign(raw)); assert.equal(result.limited, true);
  }
  assert.equal(n.convert(0, 0, 'mouse', 1, 600).y, 0);
});
test('normal mouse notches, horizontal input, fractions and reversal', () => {
  const n = new Normalizer();
  assert.equal(n.convert(15, -15, 'mouse', 1, 0).x, 1);
  assert.equal(n.convert(0, 5, 'mouse', 1, 40).y, 0);
  assert.equal(n.convert(0, 5, 'mouse', 1, 80).y, 0);
  assert.equal(n.convert(0, -15, 'mouse', 1, 120).y, -1);
});
test('continuous touchpad fractions accumulate independently of mouse angle units', () => {
  const n = new Normalizer();
  assert.equal(n.convert(0, 20, 'touchpad', 2, 0).y, 0);
  assert.equal(n.convert(0, 20, 'touchpad', 2, 40).y, 1);
  assert.equal(n.convert(0, -4000, 'touchpad', 2, 80).y, -3);
  assert.equal(n.convert(0, -1, 'touchpad', 2, 120).y, 0);
});
test('touch and virtual inputs are bounded and do not inherit another source remainder', () => {
  const n = new Normalizer();
  n.convert(0, 39, 'touchpad', 1, 0);
  assert.equal(n.convert(0, 1, 'virtual', -1, 1).y, 1);
  assert.equal(n.convert(0, 1200, 'touch', -1, 2).y, 3);
  assert.equal(n.convert(0, 0, 'touch', -1, 40).y, 0);
});
test('burst output has a bounded budget and no delayed replay', () => {
  const n = new Normalizer(); let total = 0;
  for (let i = 0; i < 32; i++) total += n.convert(0, 1500, 'mouse', 1, i).y;
  assert.equal(total, 3);
  assert.equal(n.convert(0, 0, 'mouse', 1, 32).y, 0);
  assert.equal(n.convert(0, 15, 'mouse', 1, 33).y, 1);
});
test('device change, inactivity, clock reversal and explicit reset clear fractions', () => {
  for (const [device, time, reset] of [[2, 1, false], [1, 300, false], [1, -1, false], [1, 1, true]]) {
    const n = new Normalizer(); n.convert(0, 10, 'mouse', 1, 0); if (reset) n.reset();
    assert.equal(n.convert(0, 5, 'mouse', device, time).y, 0);
  }
});
test('non-finite input never reaches the protocol and next event recovers', () => {
  for (const value of [NaN, Infinity, -Infinity]) {
    const n = new Normalizer(); assert.equal(n.convert(0, value, 'mouse', 1, 0).y, 0);
    assert.equal(n.convert(0, 15, 'mouse', 1, 1).y, 1);
  }
});
test('actual axis handler preserves modifiers, direction, gates and sampled diagnostics', () => {
  function method(name) {const a = page.indexOf('\n  ' + name + '('); assert(a >= 0); return page.slice(a, page.indexOf('\n  }', a) + 4);}
  const sent = [], logs = []; let modifiers = 0;
  const sandbox = vm.createContext({Date: {now: () => 1000}, Math, Number, SourceTool: {TOUCHPAD: 5},
    AxisAction: {BEGIN: 1, UPDATE: 2, END: 3}, ConnectionStatus: {CONNECTED: 1},
    RustDeskNapi: {appendDiagnosticLog: (...v) => logs.push(v)},
    ConnectionService: {sendMouseWheel: (...v) => sent.push(v)}});
  vm.runInContext(ts.transpile('class Page {' + method('handleRemoteAxis') + '}; globalThis.Page = Page;'), sandbox);
  const p = Object.assign(new sandbox.Page(), {connectionStatus: 1, remoteWheel: new Normalizer(),
    wheelDiagnosticAt: 0, wheelDiagnosticEvents: 0, wheelDiagnosticLimited: 0,
    syncModifiersFromPointerEvent: () => modifiers++, stopEdgeAutoPan() {}, clearLongPressTimer() {},
    clearTapTimer() {}, requestRemoteInputFocus() {}});
  const event = {action: 2, sourceTool: 7, deviceId: 1, scrollStep: 3,
    getHorizontalAxisValue: () => 0, getVerticalAxisValue: () => 1100};
  p.handleRemoteAxis(event); assert.deepEqual(sent, [[0, -1]]); assert.equal(modifiers, 1);
  assert.match(logs[0][1], /source=mouse tool=7.*raw_y=1100.*y=-1.*limited=1/);
  p.controlMenu = 'more'; p.handleRemoteAxis(event); assert.equal(sent.length, 1);
  p.controlMenu = ''; p.handleRemoteAxis({...event, action: 3});
  assert.equal(sent.length, 1);
});
console.log(`${count} remote wheel tests passed`);
