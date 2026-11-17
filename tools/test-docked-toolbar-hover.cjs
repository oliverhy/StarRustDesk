'use strict';
// Exercise production cursor/hover policy with a simulated system pointer.
// Platform hit testing and rendered pixels still require a real HarmonyOS device.
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
let visible = true, failQuery = false, failSet = false;
const logs = [], changes = [], sends = [];
const pointer = {
  isPointerVisibleSync() { if (failQuery) throw Error('pointer visibility unavailable'); return visible; },
  setPointerVisibleSync(value) {
    if (failSet) throw Error('pointer visibility denied');
    changes.push(value); visible = value;
  }
};
const context = vm.createContext({ pointer, INPUT_MODE_MOUSE: 'mouse', ConnectionStatus: { CONNECTED: 2 },
  Curve: { EaseOut: 0 },
  LOG_DOMAIN: 0, hilog: { warn() {} }, RustDeskNapi: { appendDiagnosticLog: (...args) => logs.push(args) },
  ConnectionService: { sendMouseEvent: (...args) => sends.push(args) } });
const methods = ['shouldShowCursorOverlay', 'handleRemoteToolbarHover', 'handleNonRemoteHover', 'setFloatingPanelCollapsed',
  'handleRemoteHover', 'updateSystemPointerVisibility', 'setSystemPointerHidden'];
vm.runInContext(ts.transpile(`class Page {${methods.map(method).join('\n')}} globalThis.Page=Page;`), context);
function page(overrides = {}) {
  visible = true; failQuery = false; failSet = false; changes.length = 0; sends.length = 0; logs.length = 0;
  return Object.assign(new context.Page(), {
    remoteToolbarHoverCursorSuppressed: false, remoteExternalDisplay: false,
    projectedPhysicalPointer: false, showCursor: true, showLocalCursor: true,
    systemPointerHidden: false, pointerOverRemoteViewport: true, inputMode: 'mouse',
    connectionStatus: 2, desktopWindowActive: true, relativeMouseEnabled: false,
    hasAuthoritativeRemoteCursor: false, remoteCursorEmbedded: false,
    embeddedCursorOverlayFallback: false, isPanMode: false, pipSurfaceOwned: false,
    remoteToolbarCollapsed: true, keyboardToolsCollapsed: true,
    getUIContext: () => ({ animateTo(_options, apply) { apply(); } }),
    peerPreferences: { set() {} },
    suppressCompatibilityCursor: () => false,
    cancelPcToolbarAutoCollapse() {}, cancelPointerHoverExit() {}, stopEdgeAutoPan() {},
    releaseHeldMouseButtons() {}, schedulePcToolbarAutoCollapse() {}, ...overrides
  });
}
let count = 0;
function test(name, fn) { fn(); count++; console.log('PASS ' + name); }
test('a visible local pointer temporarily replaces the separately drawn cursor over the toolbar', () => {
  const p = page(); assert.equal(p.shouldShowCursorOverlay(), true);
  p.handleRemoteToolbarHover(true);
  assert.equal(p.remoteToolbarHoverCursorSuppressed, true);
  assert.equal(p.shouldShowCursorOverlay(), false);
  assert.equal(p.showCursor, true); assert.equal(p.showLocalCursor, true);
  p.handleRemoteToolbarHover(false);
  assert.equal(p.remoteToolbarHoverCursorSuppressed, false);
  assert.equal(p.shouldShowCursorOverlay(), true); assert.deepEqual(sends, []);
});
test('a hidden local cursor is restored for the toolbar and hidden again on returning to the remote view', () => {
  const p = page({ showLocalCursor: false, systemPointerHidden: true }); visible = false;
  p.handleRemoteToolbarHover(true);
  assert.equal(visible, true); assert.equal(p.systemPointerHidden, false);
  assert.equal(p.remoteToolbarHoverCursorSuppressed, true); assert.equal(p.shouldShowCursorOverlay(), false);
  p.handleRemoteToolbarHover(false); p.handleRemoteHover(true);
  assert.equal(visible, false); assert.equal(p.systemPointerHidden, true);
  assert.equal(p.shouldShowCursorOverlay(), true); assert.deepEqual(changes, [true, false]);
  assert.equal(p.showLocalCursor, false); assert.deepEqual(sends, []);
});
test('an independently projected display keeps its software cursor despite local hover', () => {
  const p = page({ remoteExternalDisplay: true, projectedPhysicalPointer: true });
  p.handleRemoteToolbarHover(true);
  assert.equal(p.remoteToolbarHoverCursorSuppressed, false); assert.equal(p.shouldShowCursorOverlay(), true);
  p.remoteToolbarHoverCursorSuppressed = true;
  assert.equal(p.shouldShowCursorOverlay(), true, 'a display switch cannot strand the projected cursor');
  assert.deepEqual(sends, []);
});
test('an unavailable or hidden system pointer never suppresses the remote cursor', () => {
  for (const scenario of ['query', 'hidden', 'set']) {
    const p = page();
    if (scenario === 'query') failQuery = true;
    if (scenario === 'hidden') visible = false;
    if (scenario === 'set') { visible = false; p.systemPointerHidden = true; failSet = true; }
    p.handleRemoteToolbarHover(true);
    assert.equal(p.remoteToolbarHoverCursorSuppressed, false, scenario);
    assert.equal(p.shouldShowCursorOverlay(), true, scenario);
  }
  assert.deepEqual(sends, []);
});
test('remote movement clears stale toolbar hover suppression', () => {
  const p = page({ remoteToolbarHoverCursorSuppressed: true, pointerOverRemoteViewport: false });
  p.handleRemoteHover(true);
  assert.equal(p.remoteToolbarHoverCursorSuppressed, false); assert.equal(p.shouldShowCursorOverlay(), true);
});
test('expanding the hovered toolbar keeps one pointer until the remote viewport receives input', () => {
  const p = page({ remoteToolbarHoverCursorSuppressed: true, pointerOverRemoteViewport: false });
  p.setFloatingPanelCollapsed(false, false);
  assert.equal(p.remoteToolbarCollapsed, false); assert.equal(p.shouldShowCursorOverlay(), false);
  p.handleRemoteHover(true); assert.equal(p.shouldShowCursorOverlay(), true);
});
test('embedded and relative cursor preferences are not overridden', () => {
  const embedded = page({ suppressCompatibilityCursor: () => true });
  embedded.handleRemoteToolbarHover(true); embedded.handleRemoteToolbarHover(false);
  assert.equal(embedded.shouldShowCursorOverlay(), false);
  const relative = page({ relativeMouseEnabled: true });
  relative.handleRemoteToolbarHover(true); relative.handleRemoteToolbarHover(false);
  assert.equal(relative.shouldShowCursorOverlay(), false);
  relative.hasAuthoritativeRemoteCursor = true;
  assert.equal(relative.shouldShowCursorOverlay(), true);
});
test('focus loss, reconnect, projection changes and disappearance clear temporary hover state', () => {
  for (const name of ['aboutToDisappear', 'resetRemoteViewportForSession', 'onProjectionDisplayChanged',
    'onAppForegroundEpochChanged', 'handleDesktopWindowEvent']) {
    assert(method(name).includes('this.remoteToolbarHoverCursorSuppressed = false'), name);
  }
  assert(source.includes('@State remoteToolbarHoverCursorSuppressed: boolean = false'));
  const touch = method('handleRemoteTouch');
  assert(touch.indexOf('this.remoteToolbarHoverCursorSuppressed = false') > touch.indexOf('if (pointerCompatibilityEvent)'));
  assert(method('handleRemoteMouse').includes('this.remoteToolbarHoverCursorSuppressed = false'));
  assert(method('flushPointerDiagnostics').includes('toolbar_cursor_suppressed='));
});
console.log(`docked toolbar hover: ${count} scenario groups passed`);
