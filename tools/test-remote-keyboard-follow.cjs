'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
let now, nextTimer, timers, logs, callbacks, focused, sent;
const windows = new Map();
function fakeWindow(name, queryFails = false) {
  const listeners = new Map();
  const win = { name, height: 0, queryFails, detached: [],
    on(event, callback) { assert.equal(event, 'keyboardHeightChange'); listeners.set(callback, callback); },
    off(event, callback) {
      assert.equal(event, 'keyboardHeightChange'); assert.equal(typeof callback, 'function');
      this.detached.push(callback); listeners.delete(callback);
    },
    getWindowAvoidArea() { if (this.queryFails) throw Error('query unavailable'); return { bottomRect: { height: this.height } }; },
    emit(height) { this.height = height; for (const callback of [...listeners.values()]) callback(height); },
    listeners,
  };
  windows.set(name, win); return win;
}
function schedule(fn, delay) { const id = nextTimer++; timers.set(id, { fn, time: now + delay }); return id; }
function advance(ms) {
  const end = now + ms;
  for (;;) {
    const pending = [...timers.entries()].filter(([, t]) => t.time <= end).sort((a, b) => a[1].time - b[1].time)[0];
    if (!pending) break;
    timers.delete(pending[0]); now = pending[1].time; pending[1].fn();
  }
  now = end;
}
const attributes = new Proxy({}, { get(_target, property) {
  return (...args) => {
    if (String(property).startsWith('on')) callbacks[property] = args[0];
    return attributes;
  };
} });
const context = vm.createContext({ exports: {},
  ConnectionStatus: { CONNECTED: 2 }, INPUT_MODE_MOUSE: 'mouse',
  deviceInfo: { deviceType: 'phone' }, KeyboardAvoidMode: { RESIZE: 1 }, Color: { Transparent: 0 },
  window: { AvoidAreaType: { TYPE_KEYBOARD: 4 }, findWindow(name) { if (!windows.has(name)) throw Error('missing'); return windows.get(name); } },
  RemoteDisplayPolicy: { getMainWindow: () => windows.get('main') },
  RustDeskNapi: { appendDiagnosticLog: (category, message) => logs.push([category, message]) },
  TextInput: () => attributes, Date: { now: () => now },
  setTimeout: schedule, clearTimeout: id => timers.delete(id),
});
vm.runInContext(ts.transpile(fs.readFileSync(path.join(root, 'entry/src/main/ets/utils/TouchMouseFollow.ets'), 'utf8')), context);
context.followTouchMouseAxis = context.exports.followTouchMouseAxis;
const names = ['isHandheldDevice', 'shouldFollowTouchMouse', 'touchMouseFollowBlockReason',
  'isRemoteKeyboardBlockingPointer', 'startRemoteKeyboardTracking', 'stopRemoteKeyboardTracking',
  'handleRemoteKeyboardHeightChange', 'handleRemoteKeyboardEditingChange',
  'scheduleRemoteKeyboardClose', 'cancelRemoteKeyboardClose', 'traceRemoteKeyboardState',
  'canKeepRemoteKeyboardForPointer', 'keepRemoteKeyboardForPointer', 'refocusRemoteKeyboard',
  'cancelRemoteKeyboardRefocus', 'requestRemoteInputFocus',
  'toggleRemoteKeyboard', 'openRemoteKeyboard', 'closeRemoteKeyboard',
  'snapshotRemoteKeyboardViewport', 'getKeyboardCanvasShiftY', 'getKeyboardViewportMaxHeight',
  'applyKeyboardResizeMode', 'restoreKeyboardAvoidMode', 'buildKeyboardCapture',
  'updateCenterFollowPointer', 'remotePointToVisual', 'getDisplayWidth', 'getDisplayHeight',
  'getDisplayLeft', 'getDisplayTop', 'getHorizontalPanLimit', 'getVerticalPanLimit', 'getPanLimit', 'canPanViewport'];
vm.runInContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} globalThis.Page = Page;'), context);
function page({ queryFails = false } = {}) {
  now = 1000; nextTimer = 1; timers = new Map(); logs = []; callbacks = {}; focused = []; sent = [];
  windows.clear(); fakeWindow('main'); const owner = fakeWindow('remote', queryFails);
  const ui = { name: 'remote', avoidMode: 0, getWindowName() { return this.name; },
    getKeyboardAvoidMode() { return this.avoidMode; }, setKeyboardAvoidMode(mode) { this.avoidMode = mode; },
    getFocusController: () => ({ requestFocus: id => focused.push(id) }),
  };
  const p = Object.assign(new context.Page(), {
    remotePageVisible: true, connectionStatus: 2, showKeyboardPanel: false,
    remoteKeyboardVisible: false, remoteKeyboardEditing: false, remoteKeyboardVisibilityKnown: false,
    remoteKeyboardFocusGeneration: 0, remoteKeyboardCloseTimer: -1,
    remoteKeyboardRefocusTimer: -1, remoteKeyboardPointerHandoffUntil: 0,
    keyboardAvoidModeChanged: false, keyboardLayoutWidth: 0, keyboardLayoutHeight: 0, keyboardViewportHeight: 0,
    keyboardFocusAvailable: false, pointerInitialized: false, qualityViewportHeight: 400,
    pageWidth: 800, pageHeight: 450, componentWidth: 400, componentHeight: 400,
    remoteWidth: 1000, remoteHeight: 1000, zoomScale: 2, offsetX: 0, offsetY: 0,
    lastAbsX: 500, lastAbsY: 500, edgeAutoPanEnabled: true, inputMode: 'mouse',
    relativeMouseEnabled: false, isPanMode: false,
    getUIContext: () => ui, allowWaylandText: () => true, isHandheldLandscape: () => true,
    releaseRemoteNavigationKeys() {}, releaseVirtualModifiers() {}, resetKeyboardCaptureBuffer() {},
    stopEdgeAutoPan() { this.panStops = (this.panStops || 0) + 1; },
    markLocalPointerInput() {}, ensurePointerInitialized() {}, updateCursorOverlayFromPosition() {},
    sendControlKey: key => sent.push(key),
  });
  p.startRemoteKeyboardTracking(); p.buildKeyboardCapture();
  return { p, owner, ui };
}
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }

test('zero-height seed and initial non-editing event do not cancel opening', () => {
  const { p } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(false); advance(80);
  assert.equal(p.showKeyboardPanel, true); assert.deepEqual(focused, ['remoteKeyboardCapture']);
  assert(p.shouldFollowTouchMouse());
});
test('real keyboard visibility pauses follow, not capture alone', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(true);
  assert(p.shouldFollowTouchMouse()); owner.emit(300);
  assert(!p.shouldFollowTouchMouse()); assert.equal(p.touchMouseFollowBlockReason(), 'keyboard_visible');
});
test('Windows password submission does not force-close a still-visible IME', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(true); owner.emit(300);
  callbacks.onSubmit(); assert.deepEqual(sent, [13]); assert(p.showKeyboardPanel);
  assert(!p.shouldFollowTouchMouse()); advance(200); assert(p.showKeyboardPanel);
});
test('system hide restores center follow immediately and cleans capture without zoom reset', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(true); owner.emit(300);
  owner.emit(0); assert(p.shouldFollowTouchMouse()); assert(p.showKeyboardPanel);
  p.hasAuthoritativeRemoteCursor = true;
  p.updateCenterFollowPointer(20, 0, 1.25);
  assert.equal(p.offsetX, -25); assert.equal(p.zoomScale, 2);
  assert.equal(p.remotePointToVisual(p.lastAbsX, p.lastAbsY).x, 200);
  advance(120); assert(!p.showKeyboardPanel); assert.equal(p.keyboardViewportHeight, 0);
  assert.equal(p.offsetX, -25); assert.equal(p.zoomScale, 2); assert(p.shouldFollowTouchMouse());
});
test('hardware keyboard with editing focus does not freeze follow', () => {
  const { p } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(true);
  assert(p.shouldFollowTouchMouse()); callbacks.onBlur(); assert(p.shouldFollowTouchMouse());
  advance(120); assert(!p.showKeyboardPanel);
});
test('lost editing focus restores follow even if the window hide notification is missing', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(true); owner.emit(300);
  callbacks.onBlur(); assert(p.shouldFollowTouchMouse());
  advance(120); assert(!p.showKeyboardPanel); assert(p.shouldFollowTouchMouse());
});
test('editing fallback handles hide when window visibility cannot be read', () => {
  const { p } = page({ queryFails: true }); p.openRemoteKeyboard(); callbacks.onEditChange(true);
  assert(!p.shouldFollowTouchMouse()); callbacks.onEditChange(false);
  assert(p.shouldFollowTouchMouse()); advance(120); assert(!p.showKeyboardPanel);
});
test('transient toolbar blur and refocus keep the IME capture active', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); callbacks.onEditChange(true); owner.emit(300);
  callbacks.onBlur(); owner.emit(0); advance(30); callbacks.onEditChange(true); owner.emit(300);
  advance(200); assert(p.showKeyboardPanel); assert(!p.shouldFollowTouchMouse());
});

test('remote pointer click retains hidden capture focus and recovers a transient IME hide', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); advance(80);
  callbacks.onEditChange(true); owner.emit(300); focused.length = 0;
  p.requestRemoteInputFocus(); assert.deepEqual(focused, []);
  assert(p.showKeyboardPanel); callbacks.onBlur(); owner.emit(0);
  advance(150); assert.deepEqual(focused, ['remoteKeyboardCapture']);
  callbacks.onEditChange(true); owner.emit(300); advance(300);
  assert(p.showKeyboardPanel); assert(!p.shouldFollowTouchMouse());
});

test('repeated remote field changes preserve viewport, zoom and text capture buffer', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); advance(80);
  p.keyboardInput = 'COMPOSING_BUFFER'; p.resetKeyboardCaptureBuffer = () => { throw Error('must not reset on pointer'); };
  callbacks.onEditChange(true); owner.emit(300);
  const canvas = p.keyboardViewportHeight; p.offsetX = -70; p.offsetY = 35; p.zoomScale = 3;
  for (let i = 0; i < 5; i++) {
    p.requestRemoteInputFocus(); callbacks.onBlur(); owner.emit(0); advance(150);
    callbacks.onEditChange(true); owner.emit(300); advance(30);
    assert(p.showKeyboardPanel); assert.equal(p.keyboardViewportHeight, canvas);
    assert.equal(p.zoomScale, 3); assert.equal(p.offsetX, -70); assert.equal(p.offsetY, 35);
    assert.equal(p.keyboardInput, 'COMPOSING_BUFFER');
  }
});

test('explicit close during pointer recovery cancels every pending keyboard refocus', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); advance(80);
  callbacks.onEditChange(true); owner.emit(300); focused.length = 0;
  p.requestRemoteInputFocus(); callbacks.onBlur(); owner.emit(0); advance(120);
  p.closeRemoteKeyboard(); advance(400);
  assert(!p.showKeyboardPanel); assert.equal(p.remoteKeyboardPointerHandoffUntil, 0);
  assert(!focused.includes('remoteKeyboardCapture'));
});

test('system hide after pointer handoff ends is respected without keyboard resurrection', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); advance(80);
  callbacks.onEditChange(true); owner.emit(300); p.requestRemoteInputFocus();
  advance(310); focused.length = 0; owner.emit(0); callbacks.onEditChange(false); advance(200);
  assert(!p.showKeyboardPanel); assert(!focused.includes('remoteKeyboardCapture'));
});

test('failed focus recovery is bounded rather than repeatedly reopening the IME', () => {
  const { p, owner, ui } = page(); p.openRemoteKeyboard(); advance(80);
  callbacks.onEditChange(true); owner.emit(300); p.requestRemoteInputFocus();
  callbacks.onBlur(); owner.emit(0); let attempts = 0;
  ui.getFocusController = () => ({ requestFocus(id) {
    if (id === 'remoteKeyboardCapture') { attempts++; throw Error('unavailable'); }
  } });
  advance(650); assert(!p.showKeyboardPanel); assert(attempts <= 3);
  assert(logs.some(([, message]) => message.includes('reason=refocus_failed')));
});

test('modal, disconnected and disposed windows cannot refocus continuous remote input', () => {
  for (const flag of ['showCommunicationPanel', 'showRemoteFileBrowser', 'showToolbarOrderEditor',
    'showGestureHelp', 'showMobileActions']) {
    const { p } = page(); p.openRemoteKeyboard(); advance(80); focused.length = 0;
    p[flag] = true; p.requestRemoteInputFocus(); p.refocusRemoteKeyboard(); advance(150);
    assert(!focused.includes('remoteKeyboardCapture'), flag);
  }
  for (const leave of [p => { p.connectionStatus = 0; }, p => { p.remotePageVisible = false; }]) {
    const { p } = page(); p.openRemoteKeyboard(); advance(80); focused.length = 0;
    p.keepRemoteKeyboardForPointer(); leave(p); advance(150);
    assert.deepEqual(focused, []);
  }
});

test('physical/default focus never opens soft keyboard without an explicit user request', () => {
  const { p } = page(); p.requestRemoteInputFocus(); advance(400);
  assert(!p.showKeyboardPanel); assert.deepEqual(focused, ['remoteNativeInputCapture']);
  focused.length = 0; p.refocusRemoteKeyboard(); p.keepRemoteKeyboardForPointer(); advance(400);
  assert(!p.showKeyboardPanel); assert.deepEqual(focused, []);
  assert(!method('handleNativeKeyInput').includes('openRemoteKeyboard'));
  assert(!method('handleRemoteKey').includes('openRemoteKeyboard'));
});
test('close cancels delayed open focus; old close cannot steal reopened focus', () => {
  const { p } = page(); p.openRemoteKeyboard(); p.closeRemoteKeyboard(); advance(100);
  assert(!focused.includes('remoteKeyboardCapture'));
  focused.length = 0; p.openRemoteKeyboard(); p.closeRemoteKeyboard(); p.openRemoteKeyboard();
  advance(100); assert.deepEqual(focused, ['remoteKeyboardCapture']);
});
test('a disconnected session cannot receive delayed keyboard focus', () => {
  const { p } = page(); p.openRemoteKeyboard(); p.connectionStatus = 0; advance(100);
  assert.deepEqual(focused, []);
});
test('cleanup removes only its own callback and ignores already queued old-window events', () => {
  const { p, owner, ui } = page(); const oldListener = p.remoteKeyboardHeightListener;
  const unrelated = () => {}; owner.on('keyboardHeightChange', unrelated);
  const projected = fakeWindow('projected'); ui.name = 'projected'; p.startRemoteKeyboardTracking();
  assert(owner.listeners.has(unrelated)); assert.equal(owner.detached.length, 1);
  oldListener(300); assert(!p.remoteKeyboardVisible);
  projected.emit(250); assert(p.remoteKeyboardVisible);
  p.remotePageVisible = false; p.remoteKeyboardFocusGeneration++; p.stopRemoteKeyboardTracking();
  assert.equal(projected.listeners.size, 0); oldListener(300); assert(!p.remoteKeyboardVisible);
});
test('invalid heights cannot change the actual visibility state', () => {
  const { p, owner } = page(); owner.emit(300);
  for (const invalid of [-1, NaN, Infinity]) p.handleRemoteKeyboardHeightChange(invalid);
  assert(p.remoteKeyboardVisible);
});
test('edge toggle and authoritative cursor cannot disable follow after hide', () => {
  const { p, owner } = page(); p.openRemoteKeyboard(); owner.emit(300); owner.emit(0);
  p.edgeAutoPanEnabled = false; assert(!p.shouldFollowTouchMouse());
  p.edgeAutoPanEnabled = true; p.hasAuthoritativeRemoteCursor = true; assert(p.shouldFollowTouchMouse());
});
test('diagnostics report safe state and follow reason without keyboard text', () => {
  const { p, owner } = page(); p.keyboardInput = 'SECRET_SENTINEL';
  p.openRemoteKeyboard(); callbacks.onEditChange(true); owner.emit(300); callbacks.onSubmit(); owner.emit(0); advance(120);
  assert(logs.some(([, message]) => message.includes('follow_reason=keyboard_visible')));
  assert(logs.some(([, message]) => message.includes('reason=close') && message.includes('follow_reason=enabled')));
  assert(!JSON.stringify(logs).includes('SECRET_SENTINEL'));
});
for (const name of ['updateEdgeAutoPan', 'runEdgeAutoPanFrame']) {
  assert(method(name).includes('this.isRemoteKeyboardBlockingPointer()'));
  assert(!method(name).includes('this.showKeyboardPanel'));
}
assert(method('aboutToDisappear').includes('this.stopRemoteKeyboardTracking();'));
assert(method('onProjectionDisplayChanged').includes('this.startRemoteKeyboardTracking();'));
assert(method('flushPointerDiagnostics').includes('follow_reason='));
test('repeated software keyboard toggles preserve the independent shortcut panel and viewport transform', () => {
  for (const collapsed of [true, false]) {
    const { p } = page(); p.keyboardToolsCollapsed = collapsed;
    const zoom = p.zoomScale, x = p.offsetX, y = p.offsetY;
    for (let i = 0; i < 3; i++) {
      p.openRemoteKeyboard(); assert.equal(p.keyboardToolsCollapsed, collapsed);
      p.closeRemoteKeyboard(); assert.equal(p.keyboardToolsCollapsed, collapsed);
      assert.equal(p.zoomScale, zoom); assert.equal(p.offsetX, x); assert.equal(p.offsetY, y);
    }
  }
});
console.log(`PASSED=${passed} FAILED=0`);
