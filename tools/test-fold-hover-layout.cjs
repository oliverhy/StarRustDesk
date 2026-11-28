'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
const model = { exports: {} };
vm.runInNewContext(ts.transpile(read('model/FoldHoverLayout.ets')), model);
const { foldHoverLayout, isFoldHoverPosture, manualSplitKeyboardLayout, MANUAL_SPLIT_KEYBOARD_OPTION } = model.exports;
const layout = foldHoverLayout(690, 658, { x: -10, y: 301, width: 720, height: 12 });
assert.equal(layout.top, 297);
assert.equal(layout.lowerStart, 317);
assert.equal(layout.lowerHeight, 341);
assert.equal(foldHoverLayout(690, 658, { x: 330, y: 0, width: 18, height: 658 }), undefined);
assert.equal(foldHoverLayout(690, 280, { x: 0, y: 155, width: 690, height: 12 }), undefined);
assert.equal(foldHoverLayout(690, 658, { x: 100, y: 301, width: 720, height: 12 }), undefined);
assert.equal(foldHoverLayout(690, 658, { x: 0, y: NaN, width: 690, height: 12 }), undefined);
assert(isFoldHoverPosture(true, true, [91], false));
assert(isFoldHoverPosture(true, true, [], false));
assert(isFoldHoverPosture(true, true, [114], true));
assert(!isFoldHoverPosture(true, true, [114], false));
assert(!isFoldHoverPosture(true, true, [90, 90], false));
assert(!isFoldHoverPosture(false, true, [90], true));
assert(!isFoldHoverPosture(true, false, [90], true));
assert.equal(manualSplitKeyboardLayout(360, 740, 450).top, 290);
assert.equal(manualSplitKeyboardLayout(690, 658, 100, layout).lowerStart, 317);
assert.equal(manualSplitKeyboardLayout(210, 740, 0), undefined);
const page = read('pages/RemotePage.ets');
function method(name) {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
}
const events = [];
const timers = new Map();
let nextTimer = 0;
let imeOpenRequests = 0;
let avoidMode = '';
let localPreference = '';
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const sandbox = { TouchType, ConnectionStatus: { CONNECTED: 1 }, VIRTUAL_MODIFIER_CTRL: 17,
  manualSplitKeyboardLayout, MANUAL_SPLIT_KEYBOARD_OPTION, KeyboardAvoidMode: { NONE: 'none' },
  setTimeout: callback => { timers.set(++nextTimer, callback); return nextTimer; },
  clearTimeout: id => timers.delete(id),
  ConnectionService: { sendMouseEvent: (x, y, action) => events.push(action),
    sendKeyEvent: code => events.push(['key', code]), sendShortcutKey: (key, mods) => events.push(['shortcut', key, mods]) },
  RustDeskNapi: { appendDiagnosticLog() {}, setOption(key, value) {
    assert.equal(key, 'remote-split-keyboard'); localPreference = value;
  } } };
const functions = ['applyFoldHoverLayout', 'releaseFoldHoverInputs', 'releaseFoldPadPointer', 'setFoldHoverPadOpen',
  'foldHoverCanInput', 'splitTrackpadCanInput', 'handleFoldHoverKey', 'syncFoldPadPointer', 'handleFoldPadButton', 'handleFoldPadTouch',
  'canUseManualSplitKeyboard', 'getSplitInputPageHeight', 'readManualSplitKeyboardLayout', 'toggleManualSplitKeyboard',
  'refreshFoldHoverLayout'];
vm.runInNewContext(ts.transpile('class FoldPage {' + functions.map(method).join('\n') + '} globalThis.FoldPage = FoldPage;'), sandbox);
const p = Object.assign(new sandbox.FoldPage(), {
  foldHoverTop: 0, foldPadButton: 0, foldPadTouchId: -1, foldPadSecondId: -1, remoteWidth: 1920, remoteHeight: 1080,
  remoteSplitInputMode: 'none', remotePageVisible: true, foldHoverTimer: -1, pageWidth: 690, pageHeight: 658,
  keyboardLayoutHeight: 0, controlMenuKeyboardInset: 0, isHandheldDevice: () => true,
  readFoldHoverLayout: () => undefined, readHorizontalFoldLayout: () => undefined, setControlMenu() {},
  getUIContext: () => ({ setKeyboardAvoidMode: mode => { avoidMode = mode; } }),
  openRemoteKeyboard() { imeOpenRequests++; this.showKeyboardPanel = true; },
  zoomScale: 1, connectionStatus: 1, lastAbsX: 30, lastAbsY: 20, updatePointerFromDelta() {},
  beginLocalPointerGesture() {}, endLocalPointerGesture() {}, ensurePointerInitialized() {},
  clearTapTimer() {}, clearLongPressTimer() {}, stopEdgeAutoPan() {}, releaseRemoteNavigationKeys() {},
  cancelActiveTouchGesture() {}, releaseVirtualModifiers() { this.virtualCtrlSelected = false; },
  closeRemoteKeyboard() { this.showKeyboardPanel = false; },
  sendLeftDown() { this.leftButtonHeld = true; events.push(1); },
  sendLeftUp() { this.leftButtonHeld = false; events.push(2); },
  sendLeftClick() { events.push(1, 2); },
  sendRightDown() { this.rightButtonHeld = true; events.push(3); },
  sendRightUp() { this.rightButtonHeld = false; events.push(4); },
  sendTouchScroll(_x, y) { events.push(['scroll', y]); },
  getPrintableShortcutKeyCode(key) { return key.charCodeAt(0); },
  toggleVirtualModifier(code) { if (code === 17) this.virtualCtrlSelected = !this.virtualCtrlSelected; },
  getVirtualModifierMask() { return this.virtualCtrlSelected ? 1 : 0; },
  sendKeyboardTextSegment(key) { events.push(['text', key]); },
});
const e = (type, touches, changedTouches = touches) => ({ type: TouchType[type], touches, changedTouches, stopPropagation() {} });
const a = { id: 1, windowX: 30, windowY: 25 };
const b = { id: 2, windowX: 40, windowY: 25 };
const c = { id: 3, windowX: 40, windowY: 55 };
p.applyFoldHoverLayout(layout);
p.handleFoldHoverKey('A');
p.handleFoldHoverKey('Ctrl');
p.handleFoldHoverKey('C');
assert.deepEqual(events.splice(0), [['text', 'a'], ['shortcut', 67, 1]]);
p.setFoldHoverPadOpen(true);
p.handleFoldPadTouch(e('Down', [a]));
p.handleFoldPadTouch(e('Up', [], [a]));
assert.deepEqual(events.splice(0), [0, 1, 2]);
p.handleFoldPadButton(1, e('Down', [c]));
p.handleFoldPadTouch(e('Down', [c, a], [a]));
p.handleFoldPadTouch(e('Move', [c, { ...a, windowX: 48 }]));
p.handleFoldPadTouch(e('Up', [c], [a]));
p.handleFoldPadButton(1, e('Up', [], [c]));
assert.deepEqual(events.splice(0), [0, 1, 0, 0, 2]);
p.handleFoldPadTouch(e('Down', [a]));
p.handleFoldPadTouch(e('Down', [a, b], [b]));
p.handleFoldPadTouch(e('Move', [{ ...a, windowY: 40 }, { ...b, windowY: 40 }]));
p.handleFoldPadTouch(e('Up', [b], [a]));
p.handleFoldPadTouch(e('Up', [], [b]));
assert.deepEqual(events.splice(0), [['scroll', 15]]);
p.handleFoldPadButton(2, e('Down', [a]));
p.setFoldHoverPadOpen(false);
p.handleFoldPadButton(2, e('Up', [], [a]));
assert.deepEqual(events.splice(0), [0, 3, 4]);
p.setFoldHoverPadOpen(true);
p.handleFoldPadButton(2, e('Down', [a]));
p.applyFoldHoverLayout(undefined);
assert.deepEqual(events.splice(0), [0, 3, 4]);
assert.equal(p.foldHoverTop, 0);
assert.equal(p.connectionStatus, 1);
p.toggleManualSplitKeyboard();
assert.equal(p.remoteSplitInputMode, 'manual');
assert.equal(p.foldHoverTop, 329);
assert.equal(localPreference, '1');
assert.equal(imeOpenRequests, 1);
p.controlMenuKeyboardInset = 430;
p.refreshFoldHoverLayout();
assert.equal(p.foldHoverTop, 228);
p.closeRemoteKeyboard();
p.refreshFoldHoverLayout();
assert.equal(p.foldHoverTop, 329);
assert.equal(imeOpenRequests, 1, 'resizing or restoring the saved setting must not open the IME');
p.handleFoldPadTouch(e('Down', [a]));
p.handleFoldPadTouch(e('Up', [], [a]));
assert.deepEqual(events.splice(0), [0, 1, 2], 'manual lower pane is an exposed touchpad');
p.readFoldHoverLayout = () => layout;
p.refreshFoldHoverLayout();
assert.equal(p.remoteSplitInputMode, 'manual', 'do not switch before the posture stabilizes');
const callback = timers.get(p.foldHoverTimer);
timers.delete(p.foldHoverTimer); callback();
assert.equal(p.remoteSplitInputMode, 'hover', 'stable physical posture wins');
p.toggleManualSplitKeyboard();
assert.equal(localPreference, '1', 'automatic hover cannot change the manual preference');
p.readFoldHoverLayout = () => undefined;
p.refreshFoldHoverLayout();
assert.equal(p.remoteSplitInputMode, 'manual');
assert.equal(imeOpenRequests, 1);
p.toggleManualSplitKeyboard();
assert.equal(p.remoteSplitInputMode, 'none');
assert.equal(localPreference, '0');
p.showKeyboardPanel = true;
p.toggleManualSplitKeyboard();
assert.equal(p.remoteSplitInputMode, 'manual');
assert.equal(p.showKeyboardPanel, true, 'manual entry preserves existing composition');
assert.equal(avoidMode, 'none');
assert.equal(imeOpenRequests, 1);
p.remoteExternalDisplay = true;
p.refreshFoldHoverLayout();
assert.equal(p.remoteSplitInputMode, 'none', 'do not split external displays');
assert.equal(p.manualSplitKeyboardEnabled, true);
assert.equal(p.connectionStatus, 1);
assert(!method('applyFoldHoverLayout').match(/disconnect|reconnect|onSurfaceDestroy/i));
assert.equal((method('buildRemoteScreen').match(/buildRemoteViewportWithQualityMonitor/g) || []).length, 1);
assert.match(page, /this\.foldHoverTop > 0 \? KeyboardAvoidMode\.NONE : KeyboardAvoidMode\.RESIZE/);
console.log('PASS hover posture, actual crease, stable session layout, IME isolation, typing, touchpad and releases');
