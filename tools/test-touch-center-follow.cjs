const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const near = (a, b, message) => assert(Math.abs(a - b) < 1e-7, `${message || ''}: ${a} != ${b}`);
let passed = 0, now = 1000, calls = [];
const test = (name, run) => { run(); passed++; console.log('PASS ' + name); };
const deviceInfo = { deviceType: 'phone' };
const TouchType = { Down: 0, Move: 1, Up: 2, Cancel: 3 };
const context = vm.createContext({ exports: {}, deviceInfo, TouchType, Date: { now: () => now },
  ConnectionStatus: { CONNECTED: 2 }, INPUT_MODE_MOUSE: 0,
  RustDeskNapi: { appendDiagnosticLog() {} },
  ConnectionService: { sendMouseEvent: (...args) => calls.push(args) },
  setTimeout() { throw Error('Touch follow must not schedule delayed motion'); },
  setInterval() { throw Error('Touch follow must not schedule autonomous motion'); }
});
vm.runInContext(ts.transpile(read('entry/src/main/ets/utils/TouchMouseFollow.ets')), context);
const follow = context.exports.followTouchMouseAxis;
context.followTouchMouseAxis = follow;
const names = ['touchGesturePoint', 'isHandheldDevice', 'shouldFollowTouchMouse',
  'touchMouseFollowBlockReason', 'isRemoteKeyboardBlockingPointer', 'updateCenterFollowPointer',
  'handleTouchpadTouch', 'finishTouchpadTouch', 'remotePointToVisual', 'visualPointToRemote',
  'getDisplayWidth', 'getDisplayHeight', 'getDisplayLeft', 'getDisplayTop',
  'getHorizontalPanLimit', 'getVerticalPanLimit', 'getPanLimit', 'canPanViewport',
  'clampVirtualMouseX', 'clampVirtualMouseY', 'alignVirtualMouseToRemotePosition',
  'updateVirtualMouseMove', 'beginVirtualMouseMove', 'finishVirtualMouseMove',
  'updatePointerFromVirtualMouse', 'syncVirtualMouseToCurrentPointer',
  'virtualMouseOverlayX', 'virtualMouseOverlayY', 'virtualMousePointerX', 'virtualMousePointerY'];
const constants = ['TOUCHPAD_POINTER_SPEED', 'TOUCHPAD_DRAG_START_THRESHOLD', 'TOUCHPAD_DOUBLE_TAP_TIMEOUT_MS',
  'VIRTUAL_MOUSE_POINTER_HOT_X', 'VIRTUAL_MOUSE_POINTER_HOT_Y',
  'VIRTUAL_MOUSE_WIDTH', 'VIRTUAL_MOUSE_HEIGHT', 'VIRTUAL_MOUSE_RIGHT_OUTSIDE_MARGIN',
  'VIRTUAL_MOUSE_BOTTOM_OUTSIDE_MARGIN'].map(name => {
  const match = source.match(new RegExp('const ' + name + ': number = [^;]+;'));
  assert(match, name); return match[0];
}).join('\n');
vm.runInContext(ts.transpile(constants + '\nclass Page {' + names.map(method).join('\n') +
  '} globalThis.Page = Page;'), context);
function make(overrides = {}) {
  deviceInfo.deviceType = 'phone'; calls = []; now = 1000;
  const p = Object.assign(new context.Page(), {
    componentWidth: 400, componentHeight: 400, remoteWidth: 1000, remoteHeight: 1000,
    zoomScale: 2, offsetX: 0, offsetY: 0, lastAbsX: 500, lastAbsY: 500,
    pointerInitialized: true, edgeAutoPanEnabled: true, inputMode: 0, relativeMouseEnabled: false,
    isPanMode: false, showKeyboardPanel: false, remoteKeyboardVisible: false,
    remoteKeyboardEditing: false, remoteKeyboardVisibilityKnown: true, connectionStatus: 2, showVirtualMouse: false,
    leftButtonHeld: false, touchpadDragCandidate: false, tapTimer: -1, lastMoveSentAt: 0, touchpadLastTapAt: 0,
    virtualMouseDragActive: false, hasAuthoritativeRemoteCursor: false,
    stopEdgeAutoPan() { this.stops = (this.stops || 0) + 1; },
    updateEdgeAutoPan() { this.edgeCalls = (this.edgeCalls || 0) + 1; },
    updatePointerFromDelta() { this.legacyCalls = (this.legacyCalls || 0) + 1;
      return { x: this.lastAbsX, y: this.lastAbsY }; },
    updateCursorOverlayFromPosition(x, y) { this.overlay = { x, y }; },
    isSecondTapNear() { return false; },
    sendLeftDown() { this.leftButtonHeld = true; calls.push(['down']); },
    sendLeftUp(x, y) { this.leftButtonHeld = false; calls.push([x, y, 'up']); },
    sendLeftClick() { calls.push(['click']); }, queueTouchpadTap() { calls.push(['tap']); }
  }, overrides);
  for (const name of ['markLocalPointerInput', 'ensurePointerInitialized', 'beginLocalPointerGesture',
    'endLocalPointerGesture', 'requestRemoteInputFocus', 'clearTapTimer', 'flushPendingTap',
    'startRightClickTimer', 'resetToolbarTimer', 'clearLongPressTimer', 'initializeVirtualMousePosition']) {
    p[name] = () => {};
  }
  return p;
}
function touch(p, type, x, y = 100, elapsed = 20) {
  now += elapsed; p.handleTouchpadTouch({ type, touches: [{ x, y, windowX: x, windowY: y }] });
}

test('first movement at center pans immediately, without a dwell', () => {
  const p = make(); touch(p, 0, 100); touch(p, 1, 120, 100, 1);
  near(p.offsetX, -25); near(p.lastAbsX, 531.25);
  near(p.remotePointToVisual(p.lastAbsX, p.lastAbsY).x, 200);
  assert.equal(p.edgeCalls || 0, 0);
});
test('crossing center consumes cursor travel before viewport travel', () => {
  const r = follow(490, 20, 1, 1000, 400, -300, 0, 300);
  near(r.pointer, 510); near(r.offset, -10);
  near(-300 + r.pointer + r.offset, 200);
});
test('already beyond center follows without a cursor snap', () => {
  const r = follow(600, 20, 1, 1000, 400, -300, 0, 300);
  near(r.pointer, 620); near(r.offset, -20);
  near(-300 + r.pointer + r.offset, 300);
});
test('stationary finger never moves canvas, including offscreen cursor', () => {
  for (const pointer of [0, 500, 999]) {
    const r = follow(pointer, 0, 1, 1000, 400, -300, 0, 300);
    near(r.pointer, pointer); near(r.offset, 0);
  }
});
test('five short strokes each respond; no dwell reset between strokes', () => {
  const p = make();
  for (let i = 0; i < 5; i++) {
    touch(p, 0, 100, 100, 1); touch(p, 1, 120, 100, 1); touch(p, 2, 120, 100, 1);
    near(p.offsetX, -25 * (i + 1));
  }
  assert.equal(p.edgeCalls || 0, 0); assert(!calls.some(c => c[0] === 'tap'));
});
test('release flushes final throttled coordinate before left-up', () => {
  const p = make(); touch(p, 0, 100); touch(p, 1, 120);
  p.leftButtonHeld = true;
  touch(p, 1, 126, 100, 1);
  assert.notEqual(calls.at(-1)[0], p.lastAbsX);
  touch(p, 2, 126, 100, 1);
  assert.deepEqual(calls.at(-2), [p.lastAbsX, p.lastAbsY, 0]);
  assert.deepEqual(calls.at(-1), [p.lastAbsX, p.lastAbsY, 'up']);
});
test('cancel releases held button but does not emit a new move or click', () => {
  const p = make(); touch(p, 0, 100); touch(p, 1, 120); p.leftButtonHeld = true;
  calls = []; touch(p, 3, 120);
  assert.deepEqual(calls, [[p.lastAbsX, p.lastAbsY, 'up']]);
});
test('all desktop edges clamp; reversing direction has no dead movement', () => {
  for (const sign of [-1, 1]) {
    const p = make();
    p.updateCenterFollowPointer(sign * 10000, sign * 10000, 1);
    near(p.lastAbsX, sign > 0 ? 999 : 0); near(p.lastAbsY, p.lastAbsX);
    near(p.offsetX, -sign * 200); near(p.offsetY, p.offsetX);
    p.updateCenterFollowPointer(-sign * 8, -sign * 8, 1);
    near(p.lastAbsX, sign > 0 ? 989 : 10);
    near(p.offsetX, -sign * 200);
  }
});
test('zoom factor changes remote distance, not visible gesture speed', () => {
  for (const zoomScale of [1.5, 2, 4]) {
    const p = make({ zoomScale });
    p.updateCenterFollowPointer(20, 10, 1.25);
    near(p.offsetX, -25); near(p.offsetY, -12.5);
    near((p.lastAbsX - 500) * 0.4 * zoomScale, 25);
    near(p.remotePointToVisual(p.lastAbsX, p.lastAbsY).x, 200);
  }
});
test('portrait letterboxing does not pan an axis without overflow', () => {
  const p = make({ componentHeight: 800, remoteWidth: 1920, remoteHeight: 1080,
    lastAbsX: 960, lastAbsY: 540 });
  p.updateCenterFollowPointer(20, 20, 1);
  near(p.offsetX, -20); near(p.offsetY, 0);
  near(p.remotePointToVisual(p.lastAbsX, p.lastAbsY).y, 420);
});
test('offscreen cursor is revealed by viewport, without warping its remote position', () => {
  const p = make({ lastAbsX: 950 });
  p.updateCenterFollowPointer(-20, 0, 1);
  near(p.lastAbsX, 925); near(p.offsetX, -200);
  const visual = p.remotePointToVisual(p.lastAbsX, p.lastAbsY);
  assert(visual.x >= 0 && visual.x <= 400);
});
test('only connected handheld absolute mouse follow is enabled', () => {
  const p = make(); assert(p.shouldFollowTouchMouse());
  for (const type of ['phone', 'tablet', '2in1', 'pc']) {
    deviceInfo.deviceType = type;
    assert.equal(p.shouldFollowTouchMouse(), type === 'phone' || type === 'tablet');
  }
  for (const override of [{ edgeAutoPanEnabled: false }, { inputMode: 1 }, { relativeMouseEnabled: true },
    { isPanMode: true }, { showKeyboardPanel: true, remoteKeyboardVisible: true, remoteKeyboardEditing: true },
    { connectionStatus: 1 }, { zoomScale: 1 },
    { componentWidth: 0 }, { remoteWidth: 0 }]) assert(!make(override).shouldFollowTouchMouse());
});
test('disabled follow keeps legacy movement path', () => {
  const p = make({ edgeAutoPanEnabled: false }); touch(p, 0, 100); touch(p, 1, 120);
  assert.equal(p.legacyCalls, 1); assert.equal(p.edgeCalls, 1); near(p.offsetX, 0);
});
test('virtual mouse and arrow move together to the edge, then pan without an arrow-only phase', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  for (const [x, y] of [[20, 10], [40, 30], [2000, 2000], [1990, 1990]]) {
    p.updateVirtualMouseMove(x, y);
    const visual = p.remotePointToVisual(p.lastAbsX, p.lastAbsY);
    near(p.virtualMouseX, p.virtualMouseOverlayX());
    if (p.lastAbsX < 999) {
      assert(Math.abs(p.virtualMouseX + 1 - visual.x) < 1);
    }
    near(p.virtualMouseY, p.virtualMouseOverlayY());
    near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
    assert.deepEqual(calls.at(-1), [p.lastAbsX, p.lastAbsY, 0]);
  }
  assert.equal(p.edgeCalls || 0, 0); p.finishVirtualMouseMove();
});

test('hidden keyboard capture does not disable center follow after Windows login', () => {
  const p = make({ showKeyboardPanel: true, hasAuthoritativeRemoteCursor: true });
  assert(p.shouldFollowTouchMouse()); touch(p, 0, 100); touch(p, 1, 120);
  near(p.offsetX, -25);
  near(p.remotePointToVisual(p.lastAbsX, p.lastAbsY).x, 200);
});
test('virtual mouse release/restart and disabling follow do not jump', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(20, 0); near(p.offsetX, 0);
  p.finishVirtualMouseMove(); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(20, 0); near(p.offsetX, 0);
  const before = p.lastAbsX; p.edgeAutoPanEnabled = false;
  p.updateVirtualMouseMove(28, 0); near(p.lastAbsX - before, 10);
});
test('control reaching the viewport edge immediately pans image with the arrow pinned to it', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(89, 0);
  near(p.virtualMouseX, 288); near(p.virtualMouseOverlayX(), 288);
  near(p.offsetX, 0);
  const before = p.lastAbsX;
  p.updateVirtualMouseMove(90, 0);
  near(p.virtualMouseX, 288); near(p.virtualMouseOverlayX(), 288);
  near(p.offsetX, -1);
  assert(p.lastAbsX > before);
  p.updateVirtualMouseMove(91, 0);
  near(p.offsetX, -2);
  near(p.virtualMouseX, 288);
});
test('grouped virtual mouse also works when the computed horizontal pan limit is zero', () => {
  const p = make({ showVirtualMouse: true, zoomScale: 1 }); p.beginVirtualMouseMove();
  near(p.getHorizontalPanLimit(p.zoomScale), 0);
  p.updateVirtualMouseMove(1000, 0);
  near(p.virtualMouseX, 288);
  near(p.virtualMousePointerX(), p.virtualMouseOverlayX());
  near(p.offsetX, -256);
  near(p.lastAbsX, 999);
});
test('right-edge drag carries the control and local arrow together into black space', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(1000, 0);
  near(p.lastAbsX, 999);
  near(p.offsetX, -p.getHorizontalPanLimit(p.zoomScale) - 256);
  const remoteRight = p.remotePointToVisual(p.remoteWidth, p.lastAbsY).x;
  assert(remoteRight < p.componentWidth);
  // Both local layers enter the black margin together. The remote input
  // coordinate is still clamped to the desktop's last pixel.
  assert(p.virtualMouseX > remoteRight);
  near(p.virtualMouseX, p.virtualMouseOverlayX());
  assert(p.virtualMouseOverlayX() >= remoteRight);
  assert(p.virtualMouseOverlayX() + 112 <= p.componentWidth);
  assert.deepEqual(calls.at(-1), [999, 500, 0]);
  p.finishVirtualMouseMove();
  const outsideX = p.virtualMouseX;
  p.beginVirtualMouseMove(); near(p.virtualMouseX, outsideX);
  p.updateVirtualMouseMove(-20, 0);
  near(p.lastAbsX, 999);
  assert(p.offsetX > -p.getHorizontalPanLimit(p.zoomScale) - 256);
  p.updateVirtualMouseMove(-300, 0);
  assert(p.lastAbsX < 999);
  near(p.offsetX, -p.getHorizontalPanLimit(p.zoomScale));
});
test('bottom-edge drag carries the control and arrow together into black space', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(0, 1000);
  near(p.lastAbsY, 999);
  near(p.offsetY, -p.getVerticalPanLimit(p.zoomScale) - 308);
  const remoteBottom = p.remotePointToVisual(p.lastAbsX, p.remoteHeight).y;
  assert(remoteBottom < p.componentHeight);
  assert(p.virtualMouseY > remoteBottom);
  near(p.virtualMouseY, p.virtualMouseOverlayY());
  near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
  assert(p.virtualMouseOverlayY() + 138 <= p.componentHeight);
  assert.deepEqual(calls.at(-1), [500, 999, 0]);
  p.finishVirtualMouseMove();
  const outsideY = p.virtualMouseY;
  p.beginVirtualMouseMove(); near(p.virtualMouseY, outsideY);
  p.updateVirtualMouseMove(0, -20);
  near(p.lastAbsY, 999);
  assert(p.offsetY > -p.getVerticalPanLimit(p.zoomScale) - 308);
  p.updateVirtualMouseMove(0, -400);
  assert(p.lastAbsY < 999);
  near(p.offsetY, -p.getVerticalPanLimit(p.zoomScale));
});
test('bottom grouped movement also works without vertical image overflow', () => {
  const p = make({ showVirtualMouse: true, zoomScale: 1 }); p.beginVirtualMouseMove();
  near(p.getVerticalPanLimit(p.zoomScale), 0);
  p.updateVirtualMouseMove(0, 1000);
  near(p.virtualMouseY, 262);
  near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
  near(p.offsetY, -308);
  near(p.lastAbsY, 999);
});
test('virtual mouse reaches the same black area with edge-follow disabled', () => {
  const p = make({ showVirtualMouse: true, edgeAutoPanEnabled: false });
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(20, 0);
  near(p.offsetX, 0);
  near(p.lastAbsX, 525);
  p.updateVirtualMouseMove(1000, 0);
  near(p.lastAbsX, 999);
  near(p.offsetX, -p.getHorizontalPanLimit(p.zoomScale) - 256);
  const remoteRight = p.remotePointToVisual(p.remoteWidth, p.lastAbsY).x;
  assert(p.virtualMouseX > remoteRight);
  near(p.virtualMouseX, p.virtualMouseOverlayX());
  assert(p.virtualMouseOverlayX() >= remoteRight);
  assert(p.virtualMouseOverlayX() + 112 <= p.componentWidth);
  p.finishVirtualMouseMove();
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(-20, 0);
  near(p.lastAbsX, 999);
  p.updateVirtualMouseMove(-300, 0);
  assert(p.lastAbsX < 999);
  near(p.offsetX, -p.getHorizontalPanLimit(p.zoomScale));
});
test('right-edge black margin is removed when virtual mouse is turned off', () => {
  const body = source.slice(source.indexOf('  setVirtualMouseEnabled(enabled:'),
    source.indexOf('  loadToolbarOrderPreferences()'));
  assert(body.includes('this.clampViewportOffset();'));
  assert(source.includes(".backgroundColor('#090D14')"));
});
test('panning elsewhere after reaching the right edge never separates the arrow from its control', () => {
  const p = make({ showVirtualMouse: true, lastAbsY: 999 });
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(1000, 0);
  p.finishVirtualMouseMove();
  assert(p.offsetX < -p.getHorizontalPanLimit(p.zoomScale));
  // A finger on the canvas pans the image back within its ordinary bounds.
  // Synchronizing the remote pointer used to put the arrow beyond the
  // control's on-screen limit, even though both were aligned before this pan.
  p.offsetX = -p.getHorizontalPanLimit(p.zoomScale);
  p.syncVirtualMouseToCurrentPointer();
  near(p.virtualMouseX, p.virtualMouseOverlayX());
  near(p.virtualMousePointerX(), p.virtualMouseOverlayX());
  near(p.virtualMouseY, p.virtualMouseOverlayY());
  near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
  near(p.virtualMouseX, 288);
  near(p.virtualMouseY, 262);
});
test('panning elsewhere after reaching the bottom keeps the arrow on the control', () => {
  const p = make({ showVirtualMouse: true });
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(0, 1000);
  p.finishVirtualMouseMove();
  const outsideY = p.virtualMouseY;
  p.syncVirtualMouseToCurrentPointer();
  near(p.virtualMouseY, outsideY);
  p.offsetY = -p.getVerticalPanLimit(p.zoomScale);
  p.syncVirtualMouseToCurrentPointer();
  near(p.virtualMouseY, p.virtualMouseOverlayY());
  near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
  near(p.virtualMouseY, 262);
});
test('virtual mouse owns other-area touch even when the image has no ordinary pan overflow', () => {
  const body = source.slice(source.indexOf('  handleRemoteTouch(event: TouchEvent): void {'),
    source.indexOf('  handlePointerCompatibilityTouch(event: TouchEvent): void {'));
  assert(body.includes('if ((this.showVirtualMouse && this.isHandheldDevice()) || this.isPanMode)'));
  assert(!body.includes('this.showVirtualMouse && this.isHandheldDevice() && this.canPanViewport()'));
});
test('virtual mouse move handle remains on screen at the physical edge', () => {
  const p = make({ virtualMouseX: 399, virtualMouseY: 399 });
  near(p.virtualMouseOverlayX(), 288);
  near(p.virtualMouseOverlayY(), 262);
  near(p.virtualMousePointerX(), 288);
  near(p.virtualMousePointerY(), 262);
  assert(p.virtualMouseOverlayX() + 112 <= p.componentWidth);
  assert(p.virtualMouseOverlayY() + 138 <= p.componentHeight);
  assert(source.includes('.position({ x: this.virtualMouseOverlayX(), y: this.virtualMouseOverlayY() })'));
  const viewport = source.slice(source.indexOf('  buildRemoteViewportWithQualityMonitor()'),
    source.indexOf('  buildRemoteViewport()'));
  assert(viewport.indexOf('this.buildVirtualMousePointer();') < viewport.indexOf('this.buildVirtualMouseOverlay();'));
});
test('physical mouse retains edge dwell; follow does not request video refresh', () => {
  for (const name of ['handleRemoteMouse', 'handleNativeMouseInput']) {
    assert(method(name).includes('updateEdgeAutoPan(remotePoint.x, remotePoint.y, false)'));
    assert(!method(name).includes('updateCenterFollowPointer'));
  }
  assert(method('runEdgeAutoPanFrame').includes('EDGE_AUTO_PAN_MOUSE_DWELL_MS'));
  assert(!method('updateCenterFollowPointer').includes('refreshVideo'));
  assert(source.includes('停手即停，抬手再滑无需等待'));
});
console.log(`PASSED=${passed} FAILED=0`);
