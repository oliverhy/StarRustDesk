'use strict';
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
const constants = source.slice(source.indexOf('const TOUCHPAD_POINTER_SPEED:'), source.indexOf('// RustDesk\'s controlled side'));
function harness() {
  let now = 1000, next = 0;
  const timers = new Map(), events = [], diagnostics = [];
  const TouchType = { Down: 0, Move: 1, Up: 2, Cancel: 3 };
  const context = { Date: { now: () => now }, Math, Number, TouchType,
    setTimeout: (fn, delay) => { const id = ++next; timers.set(id, { fn, at: now + delay }); return id; },
    clearTimeout: id => timers.delete(id),
    ConnectionService: { sendMouseEvent: (x, y, action) => events.push({ x, y, action }),
      sendRelativeMouseDelta: (x, y) => events.push({ x, y, action: 'relative' }) },
    RustDeskNapi: { appendDiagnosticLog: (tag, message) => diagnostics.push({ tag, message }) } };
  const names = ['handleTouchpadTouch', 'finishTouchpadTouch', 'isSecondTapNear', 'startRightClickTimer',
    'clearLongPressTimer', 'queueTouchpadTap', 'flushPendingTap', 'clearTapTimer', 'updatePointerFromDelta'];
  vm.runInNewContext(ts.transpile(constants + '\nclass Page {' + names.map(method).join('\n') + '}\nglobalThis.Page=Page;'), context);
  const p = Object.assign(new context.Page(), {
    lastAbsX: 100, lastAbsY: 100, zoomScale: 1, tapTimer: -1, longPressTimer: -1,
    lastMoveSentAt: 0, leftButtonHeld: false, touchpadDragCandidate: false,
    pendingTapRemoteX: 0, pendingTapRemoteY: 0, pendingTapLocalX: 0, pendingTapLocalY: 0,
    touchpadDragOriginX: 0, touchpadDragOriginY: 0, touchpadLastTapAt: 0,
    showKeyboardPanel: false, remoteKeyboardVisible: false,
    touchGesturePoint: t => ({ x: t.x, y: t.y }),
    beginLocalPointerGesture() {}, endLocalPointerGesture() {}, requestRemoteInputFocus() {}, markLocalPointerInput() {},
    ensurePointerInitialized() {}, resetToolbarTimer() {}, stopEdgeAutoPan() {}, updateEdgeAutoPan() {},
    follow: false, shouldFollowTouchMouse() { return this.follow; }, touchMouseFollowBlockReason: () => 'test',
    updatePointerFromDelta(dx, dy) { this.lastAbsX += dx; this.lastAbsY += dy; return { x: this.lastAbsX, y: this.lastAbsY }; },
    updateCenterFollowPointer(dx, dy, gain) { return this.updatePointerFromDelta(dx * gain, dy * gain); },
    sendLeftDown(x, y) { this.leftButtonHeld = true; events.push({ x, y, action: 1 }); },
    sendLeftUp(x, y) { this.leftButtonHeld = false; events.push({ x, y, action: 2 }); },
    sendLeftClick(x, y) { events.push({ x, y, action: 1 }, { x, y, action: 2 }); }
  });
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
  assert.deepEqual(events.slice(0, 2), [{ x: 100, y: 100, action: 1 }, { x: 121, y: 100, action: 0 }]);
  advance(15); touch(t.Up, 31, 10);
  assert.equal(events.at(-1).action, 2); assert.equal(events.at(-1).x, 121);
  assert(h.diagnostics.some(d => d.message.includes('touchpad_drag confirmed')));
});
test('single tap is delivered exactly once after the double-tap window', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up);
  h.advance(449); assert.equal(h.events.length, 0); h.advance(1);
  assert.deepEqual(h.events.map(e => e.action), [1, 2]);
});
test('fast double-tap stays a double-click without a held button', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up);
  h.advance(180); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up); h.advance(1000);
  assert.deepEqual(h.events.map(e => e.action), [1, 2, 1, 2]);
  assert(!h.p.leftButtonHeld);
});
test('a jittering second tap below threshold remains a double-click at the original pointer', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Up);
  h.advance(180); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Move, 19, 10);
  h.touch(h.TouchType.Up, 19, 10); h.advance(1000);
  assert.deepEqual(h.events.map(e => e.action), [1, 2, 1, 2]);
  assert(h.events.every(e => e.x === 100));
});
test('center-follow applies the entire accumulated delta after the original left-down', () => {
  const h = harness(); h.p.follow = true; h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(400); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Move, 20, 10);
  assert.equal(h.events.length, 0); h.advance(1); h.touch(h.TouchType.Move, 30, 10);
  assert.deepEqual(h.events.slice(0, 2), [{ x: 100, y: 100, action: 1 }, { x: 125, y: 100, action: 0 }]);
  h.touch(h.TouchType.Up, 30, 10); assert.equal(h.events.at(-1).action, 2);
});
test('threshold crossing sends the first drag move despite an active move throttle', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.p.lastMoveSentAt = 1120;
  h.advance(1); h.touch(h.TouchType.Move, 30, 10);
  assert.deepEqual(h.events.map(e => e.action), [1, 0]);
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
test('far second press is not mistaken for a double-tap and long press is right click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down, 100, 10); h.advance(600); h.touch(h.TouchType.Up, 100, 10);
  assert.deepEqual(h.events.map(e => e.action), [1, 2, 3, 4]);
  assert(h.diagnostics.some(d => d.message.includes('reason=too_far')));
  assert(h.diagnostics.some(d => d.message.includes('right_click') && d.message.includes('long_press')));
});
test('slow second press does not retroactively become a drag and standalone long press remains right click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(451); h.touch(h.TouchType.Down); h.advance(600); h.touch(h.TouchType.Up);
  assert.deepEqual(h.events.map(e => e.action), [1, 2, 3, 4]);
});
test('cancel after confirmed drag releases exactly once and never generates a right click', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Move, 32, 10);
  h.touch(h.TouchType.Cancel, 32, 10); h.advance(1000);
  assert.deepEqual(h.events.map(e => e.action), [1, 0, 2]);
  assert(!h.p.leftButtonHeld);
});
test('cancel before drag confirmation emits no held mouse button', () => {
  const h = harness(); h.touch(h.TouchType.Down); h.advance(20); h.touch(h.TouchType.Up);
  h.advance(100); h.touch(h.TouchType.Down); h.advance(25); h.touch(h.TouchType.Move, 15, 10);
  h.touch(h.TouchType.Cancel, 15, 10); h.advance(1000);
  assert(!h.events.some(e => e.action === 1 || e.action === 3));
});
console.log(`${count} touchpad gesture scenarios passed`);
