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
} });
const names = ['isHandheldDevice', 'isHandheldLandscape', 'getRemoteCanvasHeight',
  'snapshotRemoteKeyboardViewport', 'hasKeyboardViewportSizeChanged', 'getKeyboardCanvasShiftY', 'getKeyboardViewportMaxHeight',
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
    pointerInitialized: true, showKeyboardPanel: false, keyboardAvoidModeChanged: false,
    keyboardViewportHeight: 0, keyboardLayoutWidth: 0, keyboardLayoutHeight: 0, controlMenuKeyboardInset: 0,
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
  const p = page({ remoteWidth: 800, remoteHeight: 780, lastAbsY: 30 }); open(p, 480);
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
test('hardware/floating keyboards and missing pointer do not force a spurious shift', () => {
  const p = page({ pointerInitialized: false }); open(p, 780);
  assert.equal(p.getKeyboardCanvasShiftY(), 0); assert(!p.keyboardFocusAvailable);
  p.qualityViewportHeight = 480; assert.equal(p.getKeyboardCanvasShiftY(), 0);
  for (const height of [0, NaN, Infinity]) {
    p.qualityViewportHeight = height; assert.equal(p.getKeyboardCanvasShiftY(), 0);
  }
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
