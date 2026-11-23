'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
const tracker = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/model/OrdinaryPointerDiagnostics.ets'), 'utf8');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const constants = source.slice(source.indexOf('const TOUCHPAD_POINTER_SPEED:'), source.indexOf('// RustDesk\'s controlled side'));
function harness(queueResults = []) {
  let now = 1000, next = 0;
  const timers = new Map(), events = [], diagnostics = [];
  const TouchType = { Down: 0, Move: 1, Up: 2, Cancel: 3 };
  const context = { Date: { now: () => now }, Math, Number, TouchType,
    ConnectionStatus: { CONNECTED: 2 }, INPUT_MODE_MOUSE: 'mouse',
    setTimeout: (fn, delay) => { const id = ++next; timers.set(id, { fn, at: now + delay }); return id; },
    clearTimeout: id => timers.delete(id),
    ConnectionService: { sendMouseEvent: (x, y, action) => {
      if (action === 0 && context.page.relativeMouseEnabled) return undefined;
      events.push({ x, y, action }); return queueResults.shift() ?? 0;
    },
      sendRelativeMouseDelta: (x, y) => events.push({ x, y, action: 'relative' }) },
    RustDeskNapi: { appendDiagnosticLog: (tag, message) => diagnostics.push({ tag, message }) } };
  const names = ['handleTouchpadTouch', 'finishTouchpadTouch', 'isSecondTapNear', 'startRightClickTimer',
    'handleDirectTouch', 'finishDirectTouch',
    'clearLongPressTimer', 'queueTouchpadTap', 'flushPendingTap', 'clearTapTimer', 'updatePointerFromDelta',
    'syncOrdinaryMouseButtonPosition', 'sendLeftClick', 'sendLeftDown', 'sendLeftUp',
    'getDisplayWidth', 'getDisplayHeight', 'getDisplayLeft', 'getDisplayTop', 'getDisplayFitHeight', 'isSplitKeyboardActive',
    'updateCursorOverlayFromPosition', 'updateCursorOverlayFromRemote'];
  vm.runInNewContext(ts.transpile(tracker.replace('export class', 'class') + constants + '\nclass Page {' +
    names.map(method).join('\n') + '}\nglobalThis.Page=Page;globalThis.Tracker=OrdinaryPointerDiagnostics;'), context);
  const p = Object.assign(new context.Page(), {
    pointerDelivery: new context.Tracker(),
    lastAbsX: 100, lastAbsY: 100, zoomScale: 1, tapTimer: -1, longPressTimer: -1,
    connectionStatus: 2, inputMode: 'mouse', remoteWidth: 1920, remoteHeight: 1080,
    showVirtualMouse: false, relativeMouseEnabled: false, touchpadFinalMovePending: false,
    lastMoveSentAt: 0, leftButtonHeld: false, touchpadDragCandidate: false,
    pointerTouchThrottledMoves: 0, pointerTouchFinalMoveRequests: 0,
    pointerTouchShortFinalMoveRequests: 0, pointerOrdinaryButtonMoveRequests: 0,
    pendingTapRemoteX: 0, pendingTapRemoteY: 0, pendingTapLocalX: 0, pendingTapLocalY: 0,
    touchpadDragOriginX: 0, touchpadDragOriginY: 0, touchpadLastTapAt: 0,
    showKeyboardPanel: false, remoteKeyboardVisible: false,
    touchGesturePoint: t => ({ x: t.x, y: t.y }),
    beginLocalPointerGesture() {}, endLocalPointerGesture() {}, requestRemoteInputFocus() {}, markLocalPointerInput() {},
    ensurePointerInitialized() {}, resetToolbarTimer() {}, stopEdgeAutoPan() {}, updateEdgeAutoPan() {},
    follow: false, shouldFollowTouchMouse() { return this.follow; }, touchMouseFollowBlockReason: () => 'test',
    updatePointerFromDelta(dx, dy) { this.lastAbsX += dx; this.lastAbsY += dy; return { x: this.lastAbsX, y: this.lastAbsY }; },
    updatePointerFromLocal(x, y) { this.lastAbsX = x; this.lastAbsY = y; return { x, y }; },
    updateCenterFollowPointer(dx, dy, gain) { return this.updatePointerFromDelta(dx * gain, dy * gain); },
    rememberKeyboardInputAnchor() {}
  });
  context.page = p;
  function advance(ms) {
    const end = now + ms;
    while (true) {
      const due = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      now = due[1].at; timers.delete(due[0]); due[1].fn();
    }
    now = end;
  }
  function touch(type, x = 10, y = 10) { p.handleTouchpadTouch({ type, touches: [{ x, y }] }); }
  return { p, events, diagnostics, advance, touch, TouchType, realUpdatePointerFromDelta: context.Page.prototype.updatePointerFromDelta };
}
let count = 0;
function test(name, fn) { fn(); count++; console.log('PASS ' + name); }
test('drag buffers subthreshold motion and presses the original position before moving', () => {
  const h = harness(), { touch, TouchType: t, advance, events } = h;
  touch(t.Down); advance(30); touch(t.Up); advance(400); touch(t.Down);
  advance(20); touch(t.Move, 20, 10); assert.equal(events.length, 0);
  advance(20); touch(t.Move, 31, 10);
  assert.deepEqual(events.slice(0, 3), [{ x: 100, y: 100, action: 0 },
    { x: 100, y: 100, action: 1 }, { x: 121, y: 100, action: 0 }]);
  advance(15); touch(t.Up, 31, 10);
  assert.equal(events.at(-1).action, 2); assert.equal(events.at(-1).x, 121);
  assert(h.diagnostics.some(d => d.message.includes('touchpad_drag confirmed')));
});
test('single tap is delivered exactly once after the double-tap window', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up);
  h.advance(449); assert.equal(h.events.length, 0); h.advance(1);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 2]);
});
test('fast double-tap stays a double-click without a held button', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up);
  h.advance(180); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up); h.advance(1000);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 2, 0, 1, 2]);
  assert(!h.p.leftButtonHeld);
});
test('a second tap with less than 8 vp of jitter remains a double-click at the original pointer', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up);
  h.advance(180); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Move, 17, 10);
  h.touch(h.TouchType.Up, 17, 10); h.advance(1000);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 2, 0, 1, 2]);
  assert(h.events.every(e => e.x === 100));
});
test('an 8 vp swipe suppresses the tap even if it returns to the starting point', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down); h.advance(30); h.touch(t.Move, 18);
  h.advance(30); h.touch(t.Move, 10); h.touch(t.Up);
  h.advance(700);
  assert.deepEqual(h.events.map(e => e.action), [0, 0]);
  h.touch(t.Down); h.touch(t.Up); h.advance(450);
  assert.deepEqual(h.events.slice(-3).map(e => e.action), [0, 1, 2]);
});
test('a slow 9 vp swipe before 600 ms cancels the long press without starting a drag', () => {
  for (const direct of [false, true]) {
    const h = harness(); const t = h.TouchType;
    const input = direct ? (type, x) => h.p.handleDirectTouch({ type, touches: [{ x, y: 10 }] }) : h.touch;
    input(t.Down, 10); h.advance(510); input(t.Move, 19);
    h.advance(200); input(t.Up, 19); h.advance(500);
    assert.deepEqual(h.events.map(e => e.action), [0]);
    assert(!h.p.leftButtonHeld);
  }
});
test('a second touch crossing tap slop but not drag threshold cannot emit a double-click', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down); h.advance(20); h.touch(t.Up);
  h.advance(120); h.touch(t.Down);
  h.advance(30); h.touch(t.Move, 21); h.touch(t.Up, 21);
  h.advance(750);
  assert(!h.events.some(e => e.action !== 0));
});
test('center-follow applies the entire accumulated delta after the original left-down', () => {
  const h = harness(); h.p.follow = true; h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(400); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Move, 20, 10);
  assert.equal(h.events.length, 0); h.advance(1); h.touch(h.TouchType.Move, 30, 10);
  assert.deepEqual(h.events.slice(0, 3), [{ x: 100, y: 100, action: 0 },
    { x: 100, y: 100, action: 1 }, { x: 125, y: 100, action: 0 }]);
  h.touch(h.TouchType.Up, 30, 10); assert.equal(h.events.at(-1).action, 2);
});
test('threshold crossing sends the first drag move despite an active move throttle', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.p.lastMoveSentAt = 1120;
  h.advance(1); h.touch(h.TouchType.Move, 30, 10);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 0]);
});
test('ordinary mouse mode flushes the last throttled position on release without a click', () => {
  const h = harness(); h.touch(h.TouchType.Down, 10, 10); h.advance(20);
  h.touch(h.TouchType.Move, 30, 10); h.advance(1);
  h.touch(h.TouchType.Move, 80, 10);
  assert.equal(h.p.lastAbsX, 170); assert.equal(h.events.at(-1).x, 120);
  h.advance(1); h.touch(h.TouchType.Up, 80, 10);
  assert.deepEqual(h.events.map(e => [e.x, e.y, e.action]), [[120, 100, 0], [170, 100, 0]]);
  assert.equal(h.p.pointerTouchThrottledMoves, 1);
  assert.equal(h.p.pointerTouchFinalMoveRequests, 1);
});
test('short swipe with virtual mouse off settles remote hover and does not click', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down, 10); h.advance(20); h.touch(t.Move, 12);
  h.advance(8); h.touch(t.Move, 26);
  assert.equal(h.p.lastAbsX, 116);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[102, 0]]);
  h.touch(t.Up, 26);
  h.advance(500);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[102, 0], [116, 0]]);
  assert.equal(h.p.pointerTouchShortFinalMoveRequests, 1);

  // Model the RustDesk host: button packets do NOT change its position.
  // Even if the host cursor was moved independently after hovering, a
  // subsequent tap must explicitly return it to the displayed target.
  let hostX = 99, clickedX = null;
  function receive(e) { if (e.action === 0) hostX = e.x; if (e.action === 1) clickedX = hostX; }
  h.events.forEach(receive);
  assert.equal(hostX, h.p.lastAbsX);
  assert.equal(clickedX, null);
  h.events.length = 0;
  hostX = 40;
  h.touch(t.Down, 130); h.touch(t.Up, 130); h.advance(450);
  h.events.forEach(receive);
  assert.equal(clickedX, h.p.lastAbsX);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 2]);
  assert.equal(h.p.pointerOrdinaryButtonMoveRequests, 1);
});
test('subthreshold jitter still flushes hover before the delayed tap', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down, 10); h.advance(20); h.touch(t.Move, 12);
  h.advance(8); h.touch(t.Move, 16); h.touch(t.Up, 16);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[102, 0], [106, 0]]);
  h.advance(450);
  assert.deepEqual(h.events.slice(-3).map(e => [e.x, e.action]), [[106, 0], [106, 1], [106, 2]]);
});
test('a tiny move just after down is flushed even when every move was throttled', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down, 10); h.p.lastMoveSentAt = 1000;
  h.advance(8); h.touch(t.Move, 15);
  assert.deepEqual(h.events, []);
  h.touch(t.Up, 15);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[105, 0]]);
});
test('landscape at 100%: rendered hotspot, remote hover and actual click use the same target', () => {
  const h = harness(); const t = h.TouchType, p = h.p;
  Object.assign(p, {
    lastAbsX: 580, lastAbsY: 1036, componentWidth: 844, componentHeight: 363,
    remoteCursorImageWidth: 32, remoteCursorImageHeight: 32, remoteCursorHotX: 4, remoteCursorHotY: 8,
    updatePointerFromDelta: h.realUpdatePointerFromDelta
  });
  let hostX = 550, hostY = 1010, clicked = null, consumed = 0;
  function receivePending() {
    for (; consumed < h.events.length; consumed++) {
      const e = h.events[consumed];
      if (e.action === 0) { hostX = Math.trunc(e.x); hostY = Math.trunc(e.y); }
      if (e.action === 1) clicked = [hostX, hostY];
    }
  }
  h.touch(t.Down, 100); h.advance(20); h.touch(t.Move, 102); receivePending();
  h.advance(8); h.touch(t.Move, 116); receivePending();
  assert.ok(Math.abs(hostX - p.lastAbsX) > 50, 'throttle creates the predicted/host discrepancy');
  h.touch(t.Up, 116); receivePending();
  const scaleX = p.getDisplayWidth() / p.remoteWidth, scaleY = p.getDisplayHeight() / p.remoteHeight;
  assert.ok(Math.abs(p.cursorX + p.remoteCursorHotX * scaleX - p.getDisplayLeft() - hostX * scaleX) < scaleX);
  assert.ok(Math.abs(p.cursorY + p.remoteCursorHotY * scaleY - p.getDisplayTop() - hostY * scaleY) < scaleY);
  h.advance(500); receivePending();
  assert.equal(clicked, null, 'hover never sends a button packet');
  h.touch(t.Down, 130); h.touch(t.Up, 130); h.advance(450);
  const hovered = [hostX, hostY];
  hostX -= 70; receivePending();
  assert.deepEqual(clicked, hovered);
});
test('long press after minor movement synchronizes to the previewed cursor', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down, 10);
  h.p.lastMoveSentAt = 1000; h.advance(8); h.touch(t.Move, 15);
  assert.deepEqual(h.events, []);
  h.advance(600);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[105, 0], [105, 3], [105, 4]]);
});
test('ordinary mode flushes the last throttled drag move before a single left-up', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Move, 30, 10);
  h.advance(1); h.touch(h.TouchType.Move, 60, 10); h.advance(1); h.touch(h.TouchType.Up, 60, 10);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[100, 0], [100, 1], [120, 0], [150, 0], [150, 2]]);
  assert.equal(h.p.pointerTouchFinalMoveRequests, 1); assert(!h.p.leftButtonHeld);
});
test('ordinary mouse cancellation does not flush a throttled move or create a click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Move, 30, 10);
  h.advance(1); h.touch(h.TouchType.Move, 80, 10); h.touch(h.TouchType.Cancel, 80, 10);
  assert.deepEqual(h.events.map(e => [e.x, e.action]), [[120, 0]]);
  assert.equal(h.p.pointerTouchFinalMoveRequests, 0);
  assert.match(h.p.pointerDelivery.summary(1100, 170, 100, 1, 1), /1:1:final:skipped_cancelled/);
});
test('final move and delayed click stay correlated, with independent queue outcomes and no coordinates', () => {
  const h = harness([0, -2, 0, -1, 0]); const t = h.TouchType;
  h.touch(t.Down); h.advance(20); h.touch(t.Move, 12);
  h.advance(1); h.touch(t.Move, 16); h.touch(t.Up, 16);
  const d = h.p.pointerDelivery;
  const before = d.summary(1021, h.p.lastAbsX, h.p.lastAbsY, 2, 2);
  assert.match(before, /local_to_last_queued_move_vp=8\.0/);
  assert.match(before, /final_move_queue=0\/1\/0/);
  assert.match(before, /pointer_events=1:1:final:failed_-2/);
  h.advance(450);
  const after = d.summary(1471, h.p.lastAbsX, h.p.lastAbsY, 2, 2);
  assert.match(after, /local_to_last_queued_move_vp=0\.0/);
  assert.match(after, /before_press_queue=1\/0\/0 press_queue=0\/1/);
  assert.match(after, /1:1:final:failed_-2,2:1:before_press:queued,3:1:press:failed_-1/);
  assert.doesNotMatch(after, /(?:^|[ _])[xy]=|password|token|clipboard/);
});
test('flushing an earlier tap on a new touch keeps the earlier gesture ID', () => {
  const h = harness(); const t = h.TouchType;
  h.touch(t.Down); h.advance(20); h.touch(t.Up);
  h.advance(100); h.touch(t.Down, 200);
  assert.match(h.p.pointerDelivery.summary(1120, 100, 100, 1, 1),
    /pointer_events=1:1:before_press:queued,2:1:press:queued/);
});
test('interval reset preserves last-success position but new targets and sessions do not', () => {
  const d = harness().p.pointerDelivery;
  assert.equal(d.nextGesture(), 1);
  for (let n = 0; n < 12; n++) d.noteMove(1234.8, 567.2, 0, 'final', 1);
  let summary = d.summary(1000, 1234, 567, 1, 1);
  assert.match(summary, /local_to_last_queued_move_vp=0\.0/);
  assert.match(summary, /final_move_queue=12\/0\/0/);
  assert.equal(summary.match(/:final:queued/g).length, 8);
  assert.doesNotMatch(summary, /1234|567/);
  d.clearInterval();
  assert.match(d.summary(1100, 1234, 567, 1, 1), /local_to_last_queued_move_vp=0\.0 .*pointer_events=none/);
  d.resetTarget();
  assert.match(d.summary(1200, 1234, 567, 1, 1), /local_to_last_queued_move_vp=unknown/);
  assert.equal(d.nextGesture(), 2);
  d.resetSession();
  assert.equal(d.nextGesture(), 1);
});
test('relative mouse drag holds left before sending the accumulated relative movement', () => {
  const h = harness(); Object.assign(h.p, { relativeMouseEnabled: true, remoteWidth: 1000, remoteHeight: 1000,
    getDisplayWidth: () => 1000, getDisplayHeight: () => 1000, updatePointerFromDelta: h.realUpdatePointerFromDelta });
  h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up); h.advance(100);
  h.touch(h.TouchType.Down); h.advance(10); h.touch(h.TouchType.Move, 20, 10);
  assert.equal(h.events.length, 0); h.advance(10); h.touch(h.TouchType.Move, 30, 10);
  assert.equal(h.events[0].action, 1); assert.equal(h.events[1].action, 'relative');
  assert.equal(h.events[1].x, 25); h.touch(h.TouchType.Up, 30, 10);
  assert.equal(h.events.at(-1).action, 2);
});
test('relative mode adds no absolute final move when the finger is lifted', () => {
  const h = harness(); Object.assign(h.p, { relativeMouseEnabled: true, remoteWidth: 1000, remoteHeight: 1000,
    getDisplayWidth: () => 1000, getDisplayHeight: () => 1000, updatePointerFromDelta: h.realUpdatePointerFromDelta });
  h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Move, 30, 10);
  h.advance(1); h.touch(h.TouchType.Move, 60, 10);
  const before = h.events.length; h.touch(h.TouchType.Up, 60, 10);
  assert.equal(h.events.length, before); assert.equal(h.p.pointerTouchFinalMoveRequests, 0);
  assert.deepEqual(h.events.filter(e => e.action === 'relative').map(e => e.x), [25, 37.5]);
});
test('far second press is not mistaken for a double-tap and long press is right click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down, 100, 10); h.advance(600); h.touch(h.TouchType.Up, 100, 10);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 2, 0, 3, 4]);
  assert(h.diagnostics.some(d => d.message.includes('reason=too_far')));
  assert(h.diagnostics.some(d => d.message.includes('right_click') && d.message.includes('long_press')));
});
test('slow second press does not retroactively become a drag and standalone long press remains right click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(451); h.touch(h.TouchType.Down); h.advance(600); h.touch(h.TouchType.Up);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 2, 0, 3, 4]);
});
test('cancel after confirmed drag releases exactly once and never generates a right click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Move, 32, 10);
  h.touch(h.TouchType.Cancel, 32, 10); h.advance(1000);
  assert.deepEqual(h.events.map(e => e.action), [0, 1, 0, 2]);
  assert(!h.p.leftButtonHeld);
});
test('cancel before drag confirmation emits no held mouse button', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Move, 15, 10);
  h.touch(h.TouchType.Cancel, 15, 10); h.advance(1000);
  assert(!h.events.some(e => e.action === 1 || e.action === 3));
});
console.log(`${count} touchpad gesture scenarios passed`);
