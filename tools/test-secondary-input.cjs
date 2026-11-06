'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const page = fs.readFileSync(path.join(root, 'pages/ExtendedDisplayPage.ets'), 'utf8');
const ability = fs.readFileSync(path.join(root, 'entryability/ExtendedDisplayAbility.ets'), 'utf8');
assert(page.includes('@Entry({ useSharedStorage: true })') && ability.includes("loadContent('pages/ExtendedDisplayPage', this.displayStorage)"),
  'the remote display index must use the storage supplied by the secondary ability');
assert(page.includes("@Watch('onRemoteDisplayChanged')") && ability.includes("setOrCreate('remoteDisplay', id)"),
  'switching the extension target must update the existing secondary window');
assert(page.includes("Button('本次请求 VP9').onClick(() => this.retryWithVp9())") &&
  page.includes('主画面也会受影响') && page.includes('重新连接后恢复原设置'),
  'an unsupported codec must require a clearly explained session-only request');
const remotePage = fs.readFileSync(path.join(root, 'pages/RemotePage.ets'), 'utf8');
assert(remotePage.includes('this.extendedRemoteDisplay === remoteDisplay'),
  'only selecting the currently extended display should close the extension');
const model = fs.readFileSync(path.join(root, 'model/SecondaryPointerPolicy.ets'), 'utf8');
const method = name => { const match = new RegExp('\\n  private ' + name + '\\(').exec(page); assert(match, name);
  return page.slice(match.index, page.indexOf('\n  }', match.index) + 4); };
const calls = [];
const c = { exports: {}, Number, Math, Date: { now: () => 10000 }, setTimeout: () => 1, clearTimeout: () => {},
  SourceType: { TouchScreen: 1, Mouse: 2 }, SourceTool: { MOUSE: 1, TOUCHPAD: 2, Finger: 3, Pen: 4 },
  MouseAction: { Move: 0, Hover: 1, Press: 2, Release: 3 }, MouseButton: { Left: 1, Right: 2, Middle: 3 },
  AxisAction: { BEGIN: 1, UPDATE: 2 },
  TouchType: { Down: 1, Move: 2, Up: 3, Cancel: 4 },
  isTouchOnlyMouseEvent: (touch, mouse, physical, finger) => touch && !mouse && !physical && finger,
  RustDeskNapi: {
    sendSecondaryPointer: (...args) => { calls.push(['pointer', ...args]); return 0; },
    sendSecondaryWheel: (...args) => { calls.push(['wheel', ...args]); return 0; },
    releaseSecondaryButtons: token => { calls.push(['release', token]); return 0; },
    stopSecondaryDisplay: token => { calls.push(['stop', token]); return 0; },
    appendDiagnosticLog: () => 0
  }
};
vm.runInNewContext(ts.transpile(model), c); c.secondaryRemotePoint = c.exports.secondaryRemotePoint;
vm.runInNewContext(ts.transpile(fs.readFileSync(path.join(root, 'model/SecondaryTouchGesture.ets'), 'utf8')), c);
c.SecondaryTouchGesture = c.exports.SecondaryTouchGesture;
vm.runInNewContext(ts.transpile('class Page {' + ['releaseInputs','modifiers','point','mouse','axis','touch','clearTouchLongPress','sendTouchActions'].map(method).join('\n') + '} globalThis.Page=Page;'), c);
const p = Object.assign(new c.Page(), { frameReady: true, token: 7, touchId: -1, mouseButtons: 0,
  touchDraining: false, lastTouchAt: 0, lastMoveAt: 0, areaWidth: 1000, areaHeight: 1000,
  remoteWidth: 1920, remoteHeight: 1080, zoom: 1, panX: 0, panY: 0, longPressTimer: -1,
  touchGesture: new c.SecondaryTouchGesture(), focusInput() {}, showTouchCursor() {},
  touchWheel: { reset() {}, convert: (x,y) => ({x,y}) }, wheel: { reset() {}, convert: (x,y) => ({x,y}) } });
const event = (action, button, x, y, extra={}) => ({ action, button, x, y, source: 2, sourceTool: 1,
  stopPropagation() {}, ...extra });
p.mouse(event(2, 1, 500, 500));
assert.deepEqual(calls[0], ['pointer', 7, 960, 540, 1, 0]);
p.mouse(event(3, 1, 500, 500)); assert.equal(calls[1][4], 2);
p.axis({ action: 2, sourceTool: 2, deviceId: 1, getHorizontalAxisValue: () => 0, getVerticalAxisValue: () => 2 });
assert.deepEqual(calls[2], ['wheel', 7, 960, 540, 0, -2, 0], 'wheel keeps the secondary pointer location');
p.mouse(event(2, 1, 500, 10)); assert.equal(calls.length, 3, 'black bars must not click');
p.mouse(event(2, 1, 500, 500, { source: 1, sourceTool: 3 }));
assert.equal(calls.length, 3, 'synthesized touch mouse must not duplicate');
const touch = (type, touches, changedTouches) => ({ type, touches, changedTouches, stopPropagation() {} });
const finger = { id: 2, x: 500, y: 500 };
p.touch(touch(1, [finger], [finger])); assert.equal(calls.length, 3, 'touch down must not immediately press');
p.touch(touch(1, [finger, { id: 3, x: 600, y: 500 }], [{ id: 3, x: 600, y: 500 }]));
const count = calls.length; p.touch(touch(3, [], [finger]));
assert.equal(calls.length, count + 2, 'two-finger tap emits one balanced right click');
assert.equal(calls.at(-2)[4], 3); assert.equal(calls.at(-1)[4], 4);
p.releaseInputs(); assert.deepEqual(calls.at(-1), ['release', 7]);
vm.runInNewContext(ts.transpile('class SwitchPage {' + method('onRemoteDisplayChanged') +
  '} globalThis.SwitchPage=SwitchPage;'), c);
const sw = Object.assign(new c.SwitchPage(), { timer: -1, retryTimer: -1, token: 42, started: true, frameReady: true,
  remoteWidth: 1920, remoteHeight: 1080, releaseInputs: () => calls.push(['release-switch']),
  onSurface: () => calls.push(['restart']) });
sw.onRemoteDisplayChanged();
assert.deepEqual(calls.slice(-3), [['release-switch'], ['stop', 42], ['restart']]);
assert.equal(sw.token, 0); assert.equal(sw.started, false); assert.equal(sw.frameReady, false);
assert.equal(sw.remoteWidth, 0); assert.equal(sw.remoteHeight, 0);
vm.runInNewContext(ts.transpile('class CursorPage {' + method('showTouchCursor') +
  '} globalThis.CursorPage=CursorPage;'), c);
const cursor = Object.assign(new c.CursorPage(), { areaWidth: 1000, areaHeight: 1000,
  remoteWidth: 1920, remoteHeight: 1080, zoom: 1, panX: 0, panY: 0, touchCursorVisible: false });
cursor.showTouchCursor({x: 960, y: 540});
assert.equal(cursor.touchCursorX, 500); assert.equal(cursor.touchCursorY, 500);
assert.equal(cursor.touchCursorVisible, true);
assert(page.includes('this.frameReady && this.touchCursorVisible') && page.includes('HitTestMode.None'),
  'the touch indicator must not intercept remote input');
console.log('PASS secondary input: physical mouse, letterbox, touch dedup, multitouch cancel and releases');
