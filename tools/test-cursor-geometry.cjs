'use strict';
// Exercise the production cursor mapper and viewport callback without a device.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const viewport = source.indexOf('  buildRemoteViewport()');
const callback = source.indexOf('.onAreaChange((oldValue: Area, newValue: Area) => {', viewport);
assert(viewport >= 0 && callback >= 0);
const bodyStart = source.indexOf('=> {', callback) + 4;
const bodyEnd = source.indexOf('\n    })', bodyStart);
assert(bodyEnd > bodyStart);
const areaMethod = `handleViewportArea(oldValue: Area, newValue: Area): void {${source.slice(bodyStart, bodyEnd)}\n  }`;
let cursorData = { valid: false }, sent = [];
const context = vm.createContext({
  RustDeskNapi: { getRemoteCursorData: () => cursorData },
  ConnectionService: { sendMouseEvent: (...args) => sent.push(args) },
  image: { PixelMapFormat: { RGBA_8888: 1 }, createPixelMapSync: () => ({}) }
});
const names = ['getDisplayWidth', 'getDisplayHeight', 'getDisplayLeft', 'getDisplayTop',
  'refreshCursorOverlayGeometry', 'updateCursorOverlayFromPosition', 'pollRemoteCursorImage'];
vm.runInContext(ts.transpile(`class Page {${names.map(method).join('\n')}\n${areaMethod}} globalThis.Page=Page;`), context);
const near = (actual, expected) => assert(Math.abs(actual - expected) < 1e-7, `${actual} != ${expected}`);
function page(overrides = {}) {
  sent = []; cursorData = { valid: false };
  return Object.assign(new context.Page(), {
    componentWidth: 844, componentHeight: 363, remoteWidth: 1920, remoteHeight: 1080,
    lastAbsX: 628, lastAbsY: 1036, remoteCursorAbsX: 628, remoteCursorAbsY: 1036,
    pointerInitialized: true, showCursor: true, preferAuthoritativeCursor: false,
    hasAuthoritativeRemoteCursor: false, remoteCursorImageWidth: 32, remoteCursorImageHeight: 32,
    remoteCursorHotX: 4, remoteCursorHotY: 8, pointerViewportCursorReflows: 0, pointerShapeCursorReflows: 0,
    lastRemoteCursorImageSequence: -1, cursorPixelMapCache: new Map(),
    showKeyboardPanel: false, keyboardViewportHeight: 0, displaySwitchActive: false,
    zoomScale: 1, offsetX: 0, offsetY: 0,
    isHandheldDevice: () => true, stopEdgeAutoPan() {}, syncDesktopViewScale() {},
    clampViewportOffset() {}, syncVirtualMouseToCurrentPointer() {}, scheduleSurfaceRebindIfSizeChanged() {},
    ...overrides
  });
}
let checks = 0;
function test(name, fn) { fn(); checks++; console.log('PASS ' + name); }
test('landscape to portrait and back reflows the arrow at the same remote hotspot', () => {
  const p = page(); p.updateCursorOverlayFromPosition(p.lastAbsX, p.lastAbsY);
  const x = p.cursorX, y = p.cursorY;
  p.handleViewportArea({}, { width: 391, height: 777 });
  const portraitScale = 391 / 1920;
  near(p.cursorX, (628 - 4) * portraitScale);
  near(p.cursorY, (777 - 1080 * portraitScale) / 2 + (1036 - 8) * portraitScale);
  assert.notEqual(p.cursorX, x); assert.notEqual(p.cursorY, y);
  near(p.cursorImageWidth, 32 * portraitScale); near(p.cursorImageHeight, 32 * portraitScale);
  p.handleViewportArea({}, { width: 844, height: 363 });
  near(p.cursorX, x); near(p.cursorY, y); assert.equal(p.pointerViewportCursorReflows, 2);
  assert.deepEqual(sent, []);
});
test('same-size callbacks and hidden cursors never reflow or resurrect a pointer', () => {
  const p = page(); p.updateCursorOverlayFromPosition(p.lastAbsX, p.lastAbsY);
  p.handleViewportArea({}, { width: 844, height: 363 });
  assert.equal(p.pointerViewportCursorReflows, 0);
  p.showCursor = false; const before = [p.cursorX, p.cursorY];
  p.handleViewportArea({}, { width: 391, height: 777 });
  assert.equal(p.showCursor, false); assert.deepEqual([p.cursorX, p.cursorY], before);
  assert.equal(p.pointerViewportCursorReflows, 0); assert.deepEqual(sent, []);
});
test('keyboard viewport retains the original canvas dimensions and scale', () => {
  const p = page({ showKeyboardPanel: true, keyboardViewportHeight: 363 });
  p.updateCursorOverlayFromPosition(p.lastAbsX, p.lastAbsY);
  const before = [p.cursorX, p.cursorY, p.cursorImageWidth, p.cursorImageHeight];
  p.handleViewportArea({}, { width: 844, height: 150 });
  assert.deepEqual([p.cursorX, p.cursorY, p.cursorImageWidth, p.cursorImageHeight], before);
  assert.equal(p.pointerViewportCursorReflows, 0); assert.deepEqual(sent, []);
});
test('reflow uses local prediction unless the active drag is following the remote cursor', () => {
  const p = page({ lastAbsX: 800, lastAbsY: 300, remoteCursorAbsX: 100, remoteCursorAbsY: 200,
    hasAuthoritativeRemoteCursor: true });
  p.refreshCursorOverlayGeometry('viewport');
  const scale = 363 / 1080, left = (844 - 1920 * scale) / 2;
  near(p.cursorX, left + (800 - 4) * scale);
  p.preferAuthoritativeCursor = true; p.refreshCursorOverlayGeometry('viewport');
  near(p.cursorX, left + (100 - 4) * scale);
  assert.equal(p.lastAbsX, 800); assert.equal(p.remoteCursorAbsX, 100); assert.deepEqual(sent, []);
});
test('cursor shape and hotspot update even with local prediction only', () => {
  const p = page(); p.updateCursorOverlayFromPosition(p.lastAbsX, p.lastAbsY);
  cursorData = { valid: true, sequence: 1, id: 5, width: 40, height: 48, hotx: 12, hoty: 18, colors: [] };
  p.pollRemoteCursorImage();
  const scale = 363 / 1080, left = (844 - 1920 * scale) / 2;
  near(p.cursorX, left + (628 - 12) * scale); near(p.cursorY, (1036 - 18) * scale);
  near(p.cursorImageWidth, 40 * scale); near(p.cursorImageHeight, 48 * scale);
  assert.equal(p.pointerShapeCursorReflows, 1); assert.equal(p.hasAuthoritativeRemoteCursor, false);
  assert.deepEqual(sent, []);
});
test('invalid or offscreen positions never produce a cursor or send input', () => {
  for (const override of [{ pointerInitialized: false }, { remoteWidth: 0 },
    { lastAbsX: NaN }, { lastAbsX: 1920 }, { lastAbsY: -1 }]) {
    const p = page(override); p.refreshCursorOverlayGeometry('viewport');
    assert.equal(p.pointerViewportCursorReflows, 0); assert.equal(p.cursorX, undefined);
  }
  assert.deepEqual(sent, []);
});
test('the new interval diagnostic fields use counts and add no per-event logging', () => {
  const start = source.indexOf('\n  flushPointerDiagnostics()');
  const end = source.indexOf('\n  }', start);
  const text = source.slice(start, end);
  for (const field of ['touch_move_throttled', 'touch_final_move_requests',
    'cursor_viewport_reflows', 'cursor_shape_reflows']) assert(text.includes(field));
  const helper = method('refreshCursorOverlayGeometry');
  assert(!helper.includes('appendDiagnosticLog'));
});
console.log(`cursor geometry: ${checks} scenarios passed`);
