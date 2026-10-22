'use strict';
// Execute extracted production layout methods. Sizes are illustrative viewport
// fixtures, not a claim about Mate X6's actual dimensions or device acceptance.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const deviceInfo = { deviceType: 'phone' };
const logs = [];
const context = vm.createContext({ deviceInfo, RustDeskNapi: {
  appendDiagnosticLog: (category, message) => logs.push([category, message]),
}, ConnectionService: { sendMouseEvent() {} }, INPUT_MODE_MOUSE: 'mouse',
  ViewportFrameCallback: class { constructor(apply) { this.apply = apply; } } });
const names = ['isHandheldDevice', 'isHandheldLandscape', 'getRemoteCanvasHeight',
  'snapshotRemoteKeyboardViewport', 'hasKeyboardViewportSizeChanged', 'getKeyboardCanvasShiftY', 'getKeyboardViewportMaxHeight',
  'getKeyboardAvoidance', 'rememberKeyboardInputAnchor', 'selectKeyboardInputAnchor', 'clearKeyboardInputAnchor',
  'traceRemoteKeyboardState', 'sendLeftClick', 'sendLeftDown', 'sendLeftUp',
  'discardViewportPanFrame', 'flushViewportPanFrame', 'queueViewportPanFrame', 'finishViewportPan',
  'restoreKeyboardAvoidMode', 'getDisplayWidth', 'getDisplayHeight', 'getDisplayLeft', 'getDisplayTop',
  'remotePointToVisual', 'visualPointToRemote'];
vm.runInContext(ts.transpile('class Page {' + names.map(method).join('\n') +
  '} globalThis.Page=Page;'), context);
function page(overrides = {}) {
  const rect = { width: 1600, height: 1680 };
  return Object.assign(new context.Page(), {
    pageWidth: 800, pageHeight: 840, componentWidth: 800, componentHeight: 780,
    qualityViewportHeight: 780, remoteWidth: 1920, remoteHeight: 1080,
    zoomScale: 1, offsetX: 0, offsetY: 0, lastAbsX: 900, lastAbsY: 1030,
    pointerInitialized: true, lastLocalPointerInputAt: 1000, showKeyboardPanel: false, keyboardAvoidModeChanged: false,
    keyboardViewportHeight: 0, keyboardLayoutWidth: 0, keyboardLayoutHeight: 0, controlMenuKeyboardInset: 0,
    currentDisplay: 0, relativeMouseEnabled: false, keyboardManualPan: false, keyboardManualShiftY: 0,
    viewportPanFramePending: false, viewportPanFrameGeneration: 0, callbacks: [],
    getUIContext() { return { postFrameCallback: c => this.callbacks.push(c.apply) }; },
    clampHorizontalOffset: x => x, clampVerticalOffset: y => y,
    syncVirtualMouseToCurrentPointer() {}, clampViewportOffset() {}, touchMouseFollowBlockReason: () => 'disabled',
    remoteKeyboardWindow: { getWindowProperties: () => ({ windowRect: rect }) },
    rect,
  }, overrides);
}
function open(p, visibleHeight) {
  p.snapshotRemoteKeyboardViewport();
  p.showKeyboardPanel = true;
  p.qualityViewportHeight = visibleHeight;
}
function near(actual, expected) { assert(Math.abs(actual - expected) < 1e-7, `${actual} != ${expected}`); }
function focusOnScreen(p) {
  return p.getKeyboardCanvasShiftY() +
    p.remotePointToVisual(p.keyboardFocusRemoteX, p.keyboardFocusRemoteY).y;
}
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }

test('portrait and square inner screens retain the pre-IME canvas', () => {
  for (const [width, height] of [[800, 840], [800, 800], [360, 800]]) {
    const p = page({ pageWidth: width, pageHeight: height, componentWidth: width, componentHeight: height - 60 });
    open(p, height - 360);
    assert(!p.isHandheldLandscape());
    assert.equal(p.getRemoteCanvasHeight(), height - 60);
    near(p.getDisplayWidth() / p.remoteWidth, Math.min(width / 1920, (height - 60) / 1080));
  }
});
test('a low input anchor is moved above the keyboard instead of clipped by half-height lift', () => {
  const p = page(); open(p, 480);
  const unadjusted = p.remotePointToVisual(p.lastAbsX, p.lastAbsY).y - 150;
  assert(unadjusted > 432);
  assert(p.getKeyboardCanvasShiftY() < 0);
  near(focusOnScreen(p), 432);
});
test('a high input anchor remains stationary; avoidance never moves the canvas down', () => {
  const p = page({ remoteWidth: 800, remoteHeight: 780, lastAbsX: 400, lastAbsY: 30 }); open(p, 480);
  assert.equal(p.getKeyboardCanvasShiftY(), 0);
  near(focusOnScreen(p), 30);
});
test('landscape still retains original fit; tablet and folded outer screen use the same path', () => {
  for (const type of ['phone', 'tablet']) {
    deviceInfo.deviceType = type;
    const p = page({ pageWidth: 840, pageHeight: 400, componentWidth: 840, componentHeight: 340 });
    open(p, 150); assert(p.isHandheldLandscape());
    assert.equal(p.getRemoteCanvasHeight(), 340);
    near(p.getDisplayHeight(), 340);
  }
  deviceInfo.deviceType = 'phone';
});
test('avoidance retains user zoom/pan and cursor inverse mapping at repeated zoom levels', () => {
  for (const zoomScale of [1, 2, 4]) {
    const p = page({ zoomScale, offsetX: -70, offsetY: 20 });
    open(p, 480); p.getKeyboardCanvasShiftY();
    assert.equal(p.zoomScale, zoomScale); assert.equal(p.offsetX, -70); assert.equal(p.offsetY, 20);
    const before = p.remotePointToVisual(850, 730);
    const translatedY = before.y + p.getKeyboardCanvasShiftY();
    const back = p.visualPointToRemote(before.x, translatedY - p.getKeyboardCanvasShiftY());
    near(back.x, 850); near(back.y, 730);
  }
});
test('IME height changes do not look like rotation/folding', () => {
  const p = page(); open(p, 480);
  for (const height of [480, 430, 390, 540]) {
    p.pageHeight = height; p.qualityViewportHeight = height;
    assert(!p.hasKeyboardViewportSizeChanged());
    assert.equal(p.keyboardLayoutHeight, 840);
    assert(!p.isHandheldLandscape());
  }
});
test('fold/unfold/rotation invalidates old canvas, including height-only window resize', () => {
  const p = page(); open(p, 480); p.pageWidth = 360;
  assert(p.hasKeyboardViewportSizeChanged());
  p.pageWidth = 800; p.rect.height = 1000;
  assert(p.hasKeyboardViewportSizeChanged());
  p.restoreKeyboardAvoidMode(); p.showKeyboardPanel = false;
  p.pageWidth = 360; p.pageHeight = 800; p.componentWidth = 360; p.componentHeight = 740;
  p.rect.width = 720; p.rect.height = 1600;
  open(p, 400); assert.equal(p.getRemoteCanvasHeight(), 740);
  assert(!p.hasKeyboardViewportSizeChanged());
});
test('keyboard hide clears avoidance without resetting zoom/pan', () => {
  const p = page({ zoomScale: 3, offsetX: -90, offsetY: -40 }); open(p, 480);
  p.restoreKeyboardAvoidMode();
  assert.equal(p.getKeyboardCanvasShiftY(), 0); assert.equal(p.getRemoteCanvasHeight(), '100%');
  assert.equal(p.keyboardWindowHeight, 0); assert(!p.keyboardFocusAvailable);
  assert.equal(p.zoomScale, 3); assert.equal(p.offsetX, -90); assert.equal(p.offsetY, -40);
});
test('hardware/floating keyboards do not shift without occlusion; missing pointer uses visible picture bottom', () => {
  const p = page({ pointerInitialized: false }); open(p, 780);
  assert.equal(p.getKeyboardCanvasShiftY(), 0); assert(!p.keyboardFocusAvailable);
  p.qualityViewportHeight = 480; assert.equal(p.getKeyboardCanvasShiftY(), -183);
  for (const height of [0, NaN, Infinity]) {
    p.qualityViewportHeight = height; assert.equal(p.getKeyboardCanvasShiftY(), 0);
  }
});

test('reported 742/334 viewport at 2.88x reveals the lower picture rather than shifting only 11vp', () => {
  const p = page({ pageWidth: 366, pageHeight: 742, componentWidth: 366, componentHeight: 742,
    remoteWidth: 3840, remoteHeight: 2160, zoomScale: 2.88, pointerInitialized: false });
  for (let i = 0; i < 6; i++) {
    open(p, 408); p.controlMenuKeyboardInset = 334;
    near(p.getKeyboardCanvasShiftY(), -307.46);
    assert.equal(p.getKeyboardAvoidance().source, 'visible_bottom');
    assert.equal(p.zoomScale, 2.88); assert.equal(p.offsetY, 0);
    p.restoreKeyboardAvoidMode(); p.showKeyboardPanel = false;
    assert.equal(p.getKeyboardCanvasShiftY(), 0);
  }
});

test('a dispatched click wins over subsequent hover/cursor echoes and survives closing/reopening the IME', () => {
  const p = page({ pointerInitialized: false });
  p.sendLeftClick(600, 1000); p.lastAbsY = 0; p.pointerInitialized = true;
  open(p, 480);
  assert.equal(p.keyboardFocusSource, 'last_click'); assert.equal(p.keyboardFocusRemoteY, 1000);
  near(focusOnScreen(p), 432);
  p.restoreKeyboardAvoidMode(); p.showKeyboardPanel = false; open(p, 480);
  assert.equal(p.keyboardFocusRemoteY, 1000);
});

test('an initialized centre cursor without input or peer position is not treated as an input anchor', () => {
  const p = page({ pointerInitialized: true, lastLocalPointerInputAt: 0, hasAuthoritativeRemoteCursor: false });
  open(p, 480); assert(!p.keyboardFocusAvailable);
  assert.equal(p.getKeyboardAvoidance().source, 'visible_bottom');
});

test('changing input fields while typing updates the anchor only after the press/release pair', () => {
  const p = page(); open(p, 480); const before = p.getKeyboardCanvasShiftY();
  p.sendLeftDown(900, 30);
  assert.equal(p.getKeyboardCanvasShiftY(), before, 'must not move the release target');
  p.sendLeftUp(900, 30);
  assert.equal(p.keyboardFocusRemoteY, 30); assert.equal(p.getKeyboardCanvasShiftY(), 0);
  p.sendLeftUp(900, 1030, true);
  assert.equal(p.keyboardFocusRemoteY, 30, 'forced cleanup with no down is not an input click');
});

test('invalid/relative coordinates and old monitor/session anchors do not drive avoidance', () => {
  const p = page({ pointerInitialized: false }); p.sendLeftClick(900, 1000);
  p.rememberKeyboardInputAnchor(NaN, 5, true); assert.equal(p.keyboardInputAnchor.y, 1000);
  p.currentDisplay = 1; open(p, 480); assert(!p.keyboardFocusAvailable);
  p.clearKeyboardInputAnchor('display_changed'); assert.equal(p.keyboardInputAnchor, undefined);
  p.relativeMouseEnabled = true; p.sendLeftClick(900, 1000); assert.equal(p.keyboardInputAnchor, undefined);
  p.relativeMouseEnabled = false; p.sendLeftClick(900, 1000); p.remoteWidth = 1600;
  p.selectKeyboardInputAnchor(); assert(!p.keyboardFocusAvailable);
  p.clearKeyboardInputAnchor('session_reset'); assert.equal(p.keyboardInputAnchor, undefined);
});

test('an off-screen old click falls back to visible content, not a different invisible region', () => {
  const p = page({ zoomScale: 4 }); p.sendLeftClick(0, 1079); open(p, 480);
  assert.equal(p.getKeyboardAvoidance().source, 'visible_bottom');
  assert.equal(p.getKeyboardAvoidance().reason, 'anchor_outside_view');
  assert.equal(p.getKeyboardCanvasShiftY(), -300);
});

test('manual IME pan is temporary, bounded, frame-coalesced and does not fight the automatic anchor', () => {
  const p = page({ offsetY: 20, zoomScale: 2 }); open(p, 480);
  const original = p.getKeyboardCanvasShiftY();
  p.queueViewportPanFrame(0, 20); p.queueViewportPanFrame(0, 15); p.callbacks.shift()();
  near(p.getKeyboardCanvasShiftY(), original + 35); assert.equal(p.offsetY, 20); assert.equal(p.zoomScale, 2);
  assert.equal(p.getKeyboardAvoidance().source, 'manual');
  p.queueViewportPanFrame(0, 999); p.callbacks.shift()(); assert.equal(p.getKeyboardCanvasShiftY(), 0);
  p.queueViewportPanFrame(0, -999); p.callbacks.shift()();
  near(p.getKeyboardCanvasShiftY() + p.remotePointToVisual(0, p.remoteHeight).y, 480);
  p.queueViewportPanFrame(0, 50); p.restoreKeyboardAvoidMode(); p.showKeyboardPanel = false;
  p.callbacks.shift()(); assert.equal(p.offsetY, 20); assert(!p.keyboardManualPan);
  assert.equal(p.getKeyboardCanvasShiftY(), 0);
});

test('diagnostics identify anchor source, geometry and reason without recording entered text', () => {
  const p = page({ pointerInitialized: false }); open(p, 480); p.traceRemoteKeyboardState('test');
  const log = logs.at(-1)[1];
  for (const part of ['anchor_source=visible_bottom', 'avoid_reason=no_input_anchor', 'anchor_visual_y=',
    'hidden_h=300', 'avoid_visible_h=480', 'remote_size=1920x1080']) assert(log.includes(part), log);
  assert(!log.includes('keyboardInput='));
});
test('window query failure falls back safely to width invalidation', () => {
  const p = page({ remoteKeyboardWindow: { getWindowProperties() { throw Error('gone'); } } });
  open(p, 480); assert(!p.hasKeyboardViewportSizeChanged());
  p.pageWidth = 360; assert(p.hasKeyboardViewportSizeChanged());
});

test('IME inset also clips fullscreen windows that report an unchanged viewport; already resized windows are not subtracted twice', () => {
  for (const measured of [780, 480]) {
    const p = page(); open(p, measured); p.controlMenuKeyboardInset = 300;
    assert.equal(p.getKeyboardViewportMaxHeight(), 480);
    const focus = p.getKeyboardCanvasShiftY() + p.remotePointToVisual(p.keyboardFocusRemoteX, p.keyboardFocusRemoteY).y;
    near(focus, 432);
    assert.equal(p.getRemoteCanvasHeight(), 780);
    assert.equal(p.zoomScale, 1);
  }
});

test('keyboard size changes only shift the canvas; repeated zoom levels retain pixel scale and pan', () => {
  for (const zoomScale of [1, 2, 4]) {
    const p = page({ zoomScale, offsetX: -70, offsetY: 20 }); open(p, 780);
    const pixelScale = p.getDisplayWidth() * p.zoomScale / p.remoteWidth;
    for (const inset of [300, 350, 240, 0]) {
      p.controlMenuKeyboardInset = inset;
      assert(p.getKeyboardCanvasShiftY() <= 0);
      near(p.getDisplayWidth() * p.zoomScale / p.remoteWidth, pixelScale);
      assert.equal(p.offsetX, -70); assert.equal(p.offsetY, 20);
    }
  }
});
test('PC uses existing resize behavior, not handheld fixed canvas or anchor shift', () => {
  deviceInfo.deviceType = '2in1';
  const p = page(); open(p, 480);
  assert.equal(p.getRemoteCanvasHeight(), '100%'); assert.equal(p.getKeyboardCanvasShiftY(), 0);
  deviceInfo.deviceType = 'phone';
});
assert(source.includes('if (this.hasKeyboardViewportSizeChanged())'));
assert(source.includes('.translate({ y: this.getKeyboardCanvasShiftY() })'));
assert(!method('getKeyboardCanvasShiftY').includes('setSurface'));
assert(method('traceRemoteKeyboardState').includes('ime_shift_y='));
console.log(`foldable keyboard avoidance: ${passed} scenario groups passed`);
