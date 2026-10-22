// Execute production handlers and the cursor builder with ArkUI/NAPI stubs.
// The simplified hit-test model checks passive descendants; actual platform
// routing and wired projection still require real-device acceptance.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8');
const model = fs.readFileSync(path.join(root, 'entry/src/main/ets/model/PhysicalMousePolicy.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
let now = 1000;
const sent = [], logs = [], roots = [];
let parent;
const MouseAction = { Press: 1, Release: 2, Move: 3, Hover: 4 };
const MouseButton = { None: 0, Left: 1, Right: 2 };
const SourceType = { Mouse: 1, TouchScreen: 2 };
const SourceTool = { Finger: 1, Pen: 2, MOUSE: 7, TOUCHPAD: 9 };
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const HitTestMode = { Default: 0, None: 3 };
function node(kind) {
  const value = { kind, children: [], mode: HitTestMode.Default, attrs: {} };
  (parent ? parent.children : roots).push(value);
  let chain;
  chain = new Proxy(value, { get(target, key) {
    if (key in target) return target[key];
    return (...args) => {
      target.attrs[key] = args;
      if (key === 'hitTestBehavior') target.mode = args[0];
      return chain;
    };
  }});
  return chain;
}
const context = vm.createContext({
  Date: { now: () => now }, Math, Number, MouseAction, MouseButton, SourceType, SourceTool, TouchType,
  HitTestMode, ImageFit: { Fill: 0 }, ImageInterpolation: { None: 0 }, Color: { White: 'white' },
  Image: () => node('Image'), Path: () => node('Path'),
  Stack: { begin(body) {
    const stack = node('Stack'), previous = parent;
    parent = stack;
    try { body(); } finally { parent = previous; }
    return stack;
  }},
  INPUT_MODE_MOUSE: 'mouse', ConnectionStatus: { CONNECTED: 2 },
  NATIVE_MOUSE_ACTION_MOVE: 3, NATIVE_MOUSE_ACTION_PRESS: 1,
  NATIVE_MOUSE_ACTION_RELEASE: 2, NATIVE_MOUSE_ACTION_CANCEL: 13,
  NATIVE_MOUSE_BUTTON_LEFT: 1, NATIVE_MOUSE_BUTTON_RIGHT: 2,
  RustDeskNapi: { appendDiagnosticLog: (...args) => logs.push(args) },
  ConnectionService: { sendMouseEvent: (x, y, action) => sent.push(action), syncNativeModifierState() {} }
});
// Translate only ArkUI's declarative Stack block to the test container. The
// Image/Path property chains and both production conditional branches are kept.
const cursorBuilder = method('buildCursorOverlay')
  .replace('Stack() {', 'Stack.begin(() => {')
  .replace(/\n    }\r?\n    \.width/, '\n    })\n    .width');
const methods = [
  'handleNativeMouseInput', 'handleRemoteMouse', 'mapMouseAction',
  'handleRemoteTouch', 'handlePointerCompatibilityTouch', 'handleRemoteClickFallback',
  'sendLeftClick', 'sendLeftDown', 'sendLeftUp', 'sendRightDown', 'sendRightUp',
  'rememberKeyboardInputAnchor', 'selectKeyboardInputAnchor',
  'releaseHeldMouseButtons', 'reconcilePhysicalMouseButtons',
  'updatePointerFromLocal', 'updateCursorOverlayFromPosition', 'markLocalPointerInput',
  'noteProjectedPhysicalPointer', 'resetPointerDiagnostics'
];
vm.runInContext(ts.transpile(model.replace(/export /g, '') +
  '\nclass Page {' + methods.map(method).join('\n') + cursorBuilder + '}' +
  '\nglobalThis.Page = Page; globalThis.Dedup = PhysicalMouseDeduplicator;'), context);
function page(overrides = {}) {
  now = 1000; sent.length = 0; logs.length = 0;
  const p = Object.assign(new context.Page(), {
    connectionStatus: 2, remoteWidth: 1000, remoteHeight: 500,
    componentWidth: 500, componentHeight: 250, inputMode: 'mouse',
    remoteExternalDisplay: false, showKeyboardPanel: false, isPanMode: false,
    relativeMouseEnabled: false, remoteCursorEmbedded: false,
    remoteCursorImageWidth: 0, remoteCursorImageHeight: 0,
    leftButtonHeld: false, rightButtonHeld: false, lastAbsX: 100, lastAbsY: 100,
    lastMoveSentAt: 0, lastNativeMouseEventAt: 0, lastTouchEventAt: 0,
    lastMappedPhysicalLeftUpAt: 0,
    cursorImageWidth: 24, cursorImageHeight: 24, cursorX: 100, cursorY: 100,
    physicalMouseDeduplicator: new context.Dedup(),
    getDisplayWidth: () => 500, getDisplayHeight: () => 250,
    getDisplayLeft: () => 0, getDisplayTop: () => 0,
    suppressCompatibilityCursor: () => false,
    handleRemoteHover() {}, syncModifiersFromPointerEvent() {}, updateSystemPointerVisibility() {},
    clearLongPressTimer() {}, clearTapTimer() {}, requestRemoteInputFocus() {},
    traceRemoteKeyboardState() {},
    updateEdgeAutoPan() {}, stopEdgeAutoPan() {}, ...overrides
  });
  p.resetPointerDiagnostics();
  return p;
}
const clickEvent = extra => ({ x: 50, y: 50, source: SourceType.Mouse,
  sourceTool: SourceTool.MOUSE, ...extra });
function ark(p, action, button = MouseButton.Left, extra = {}) {
  p.handleRemoteMouse({ ...clickEvent(), action, button, stopPropagation() {}, ...extra });
}
function native(p, action, button = MouseButton.Left) {
  p.handleNativeMouseInput({ x: 50, y: 50, action, button, hover: -1, modifierValid: false });
}
function touch(p, type, empty = false) {
  const points = empty ? [] : [{ x: 50, y: 50 }];
  p.handleRemoteTouch({ ...clickEvent(), type, touches: points, changedTouches: points, stopPropagation() {} });
}
function fallback(p, extra) { now++; p.handleRemoteClickFallback(clickEvent(extra)); }
let checks = 0;
function test(name, run) { run(); checks++; console.log('PASS ' + name); }
function hitCandidates(n) {
  // HitTestMode.None skips self, not descendants (the 1.2.18 regression).
  return n.children.flatMap(hitCandidates).concat(n.mode === HitTestMode.None ? [] : [n.kind]);
}
for (const image of [true, false]) test(`cursor ${image ? 'image' : 'fallback arrow'} and its container ignore input`, () => {
  const p = page({ cursorPixelMap: image ? {} : undefined });
  roots.length = 0; p.buildCursorOverlay();
  assert.equal(roots.length, 1);
  const cursor = roots[0];
  assert.deepEqual(cursor.attrs.zIndex, [11], 'keep projected cursor visible above the input layer');
  assert.equal(cursor.children[0].kind, image ? 'Image' : 'Path');
  assert.deepEqual(hitCandidates(cursor), []);
  cursor.children[0].mode = HitTestMode.Default;
  assert.equal(hitCandidates(cursor).length, 1, 'this test detects the old child interception, not just parent None');
});
test('left-button-held status indicator cannot block a drag or its release', () => {
  const viewport = method('buildRemoteViewport');
  const start = viewport.indexOf('if (this.showLeftButtonHoldIndicator');
  const indicator = viewport.slice(start, viewport.indexOf('.zIndex(30)', start));
  const dot = indicator.slice(indicator.indexOf('Circle()'), indicator.indexOf("Text(translate('左键按住', this.uiLanguage))"));
  const label = indicator.slice(indicator.indexOf("Text(translate('左键按住', this.uiLanguage))"));
  assert.match(dot, /\.hitTestBehavior\(HitTestMode.None\)/);
  assert.match(label, /\.hitTestBehavior\(HitTestMode.None\)/);
});
for (const keyboard of [false, true]) {
  test(`ArkUI left press/release works once with keyboard=${keyboard}`, () => {
    const p = page({ showKeyboardPanel: keyboard });
    ark(p, MouseAction.Press); now += 20; ark(p, MouseAction.Release); fallback(p);
    assert.deepEqual(sent, [1, 2]); assert.equal(p.leftButtonHeld, false);
    assert.equal(p.pointerFallbackClicks, 0);
    assert.equal(p.keyboardInputAnchor.x, 100); assert.equal(p.keyboardInputAnchor.y, 100);
    if (keyboard) assert.equal(p.keyboardFocusSource, 'last_click');
  });
  test(`ArkUI orphan release retains click fallback with keyboard=${keyboard}`, () => {
    const p = page({ showKeyboardPanel: keyboard });
    ark(p, MouseAction.Release); fallback(p);
    assert.deepEqual(sent, [2, 1, 2]); assert.equal(p.pointerFallbackClicks, 1);
  });
  test(`ArkUI right press/release works with keyboard=${keyboard}`, () => {
    const p = page({ showKeyboardPanel: keyboard });
    ark(p, MouseAction.Press, MouseButton.Right); ark(p, MouseAction.Release, MouseButton.Right);
    assert.deepEqual(sent, [3, 4]); assert.equal(p.rightButtonHeld, false);
  });
}
test('physical click-only fallback works with the soft keyboard and a recent finger gesture', () => {
  const p = page({ showKeyboardPanel: true, lastTouchEventAt: 999 });
  fallback(p); assert.deepEqual(sent, [1, 2]);
});
test('fresh finger/pen clicks work during continuous input without bypassing touch duplicate guards', () => {
  for (const tool of [SourceTool.Finger, SourceTool.Pen]) {
    const p = page({ lastTouchEventAt: 999 });
    fallback(p, { source: SourceType.TouchScreen, sourceTool: tool });
    assert.deepEqual(sent, []);
    p.lastTouchEventAt = 0; p.showKeyboardPanel = true;
    fallback(p, { source: SourceType.TouchScreen, sourceTool: tool });
    assert.deepEqual(sent, [1, 2]);
    assert.equal(p.showKeyboardPanel, true, 'clicking a new remote input field keeps capture mounted');
  }
  const p = page({ lastTouchEventAt: 999 });
  fallback(p, { sourceTool: SourceTool.Finger }); assert.deepEqual(sent, []);
});
test('touchpad click-only fallback works when the wrapper reports TouchScreen', () => {
  const p = page({ showKeyboardPanel: true });
  fallback(p, { source: SourceType.TouchScreen, sourceTool: SourceTool.TOUCHPAD });
  assert.deepEqual(sent, [1, 2]);
});
test('physical compatibility touches do not set the finger-gesture suppression timer', () => {
  const p = page({ showKeyboardPanel: true });
  touch(p, TouchType.Down); now += 20; touch(p, TouchType.Up); fallback(p);
  assert.equal(p.lastTouchEventAt, 0); assert.deepEqual(sent, [1, 2]);
});
for (const empty of [false, true]) test(`compatibility orphan up, empty=${empty}, allows click repair`, () => {
  const p = page({ showKeyboardPanel: true });
  touch(p, TouchType.Up, empty); fallback(p);
  assert.deepEqual(sent, [2, 1, 2]); assert.equal(p.lastMappedPhysicalLeftUpAt, 0);
});
test('compatibility up without coordinates after down suppresses the duplicate click', () => {
  const p = page(); touch(p, TouchType.Down); now += 20; touch(p, TouchType.Up, true); fallback(p);
  assert.deepEqual(sent, [1, 2]);
});

for (const empty of [false,true]) test(`compatibility click is not replayed after blur/hover release, empty=${empty}`, () => {
  const p=page(); touch(p,TouchType.Down); now+=20;
  p.releaseHeldMouseButtons('input_blur');
  assert.equal(p.leftButtonHeld,false);
  now+=20; touch(p,TouchType.Up,empty); fallback(p);
  assert.deepEqual(sent,[1,2,2],'cleanup keeps click repair suppressed; no second left-down');
  assert.equal(p.compatibilityLeftSequence,false); assert.equal(p.pointerFallbackClicks,0);
});

test('empty compatibility down does not suppress a later click-only repair', () => {
  const p=page(); touch(p,TouchType.Down,true); now+=20; touch(p,TouchType.Up,true); fallback(p);
  assert.deepEqual(sent,[2,1,2]); assert.equal(p.pointerFallbackClicks,1);
});

test('20261016 local PC log replay sends two balanced clicks, not two duplicate releases', () => {
  const p = page();
  for (const [at, route, action] of [
    [1000, 'touch', TouchType.Down], [1003, 'ark', MouseAction.Press],
    [1080, 'touch', TouchType.Up], [1083, 'ark', MouseAction.Release],
    [1191, 'touch', TouchType.Down], [1193, 'ark', MouseAction.Press],
    [1274, 'touch', TouchType.Up], [1276, 'ark', MouseAction.Release]
  ]) {
    now = at;
    if (route === 'touch') touch(p, action); else ark(p, action);
  }
  fallback(p);
  assert.deepEqual(sent, [1, 2, 1, 2]);
  assert.equal(p.pointerDuplicateEvents, 4);
  assert.equal(p.pointerFallbackClicks, 0);
  assert.equal(logs.filter(v => v[1].startsWith('physical_mouse_duplicate')).length, 4);
});

test('physical compatibility clicks in direct-touch mode use the same letterbox coordinates as ArkUI', () => {
  const p = page({ inputMode: 'touch', getDisplayLeft: () => 12, getDisplayTop: () => 8 });
  touch(p, TouchType.Down); now += 2; ark(p, MouseAction.Press);
  now += 20; touch(p, TouchType.Up); now += 2; ark(p, MouseAction.Release);
  fallback(p);
  assert.deepEqual(sent, [1, 2]);
  assert.equal(p.pointerDuplicateEvents, 2);
});

for (const projected of [false, true]) for (const reverse of [false, true]) {
  for (const emptyUp of [false, true]) {
    test(`compatibility/ArkUI fast double-click stays balanced projected=${projected} reverse=${reverse} emptyUp=${emptyUp}`, () => {
      const p = page({ remoteExternalDisplay: projected });
      for (let click = 0; click < 2; click++) {
        for (const down of [true, false]) {
          const first = () => touch(p, down ? TouchType.Down : TouchType.Up, !down && emptyUp);
          const second = () => ark(p, down ? MouseAction.Press : MouseAction.Release);
          (reverse ? second : first)(); now += 2;
          (reverse ? first : second)(); now += 8;
        }
        fallback(p);
      }
      assert.deepEqual(sent, [1, 2, 1, 2]);
      assert.equal(p.pointerFallbackClicks, 0);
      assert.equal(p.leftButtonHeld, false);
    });
  }
}

test('local ArkUI before queued native delivery does not repeat either left or right release', () => {
  const p = page();
  for (const button of [MouseButton.Left, MouseButton.Right]) {
    ark(p, MouseAction.Press, button); now += 10; native(p, 1, button);
    now += 10; ark(p, MouseAction.Release, button); now += 10; native(p, 2, button);
    now += 100;
  }
  assert.deepEqual(sent, [1, 2, 3, 4]);
  assert.equal(p.pointerDuplicateEvents, 4);
});

test('local native/compatibility/ArkUI paths forward physical buttons only once', () => {
  const p = page();
  native(p, 1); now += 10; touch(p, TouchType.Down); now += 10; ark(p, MouseAction.Press);
  now += 10; touch(p, TouchType.Up); now += 10; native(p, 2); now += 10; ark(p, MouseAction.Release);
  fallback(p);
  assert.deepEqual(sent, [1, 2]);
  assert.equal(p.pointerDuplicateEvents, 4);
  assert.equal(p.pointerFallbackClicks, 0);
});

test('local touchpad wrapped as TouchScreen stays on the physical button path', () => {
  const p = page();
  const pointer = { source: SourceType.TouchScreen, sourceTool: SourceTool.TOUCHPAD };
  for (const down of [true, false]) {
    p.handleRemoteTouch({ ...clickEvent(pointer), type: down ? TouchType.Down : TouchType.Up,
      touches: [{ x: 50, y: 50 }], changedTouches: [], stopPropagation() {} });
    now += 2; ark(p, down ? MouseAction.Press : MouseAction.Release, MouseButton.Left, pointer);
    now += 20;
  }
  assert.deepEqual(sent, [1, 2]);
  assert.equal(p.pointerDuplicateEvents, 2);
  assert.equal(p.lastTouchEventAt, 0);
});

test('duplicate orphan releases still allow one click-only repair', () => {
  const p = page();
  touch(p, TouchType.Up, true); now += 2; ark(p, MouseAction.Release); fallback(p);
  assert.deepEqual(sent, [2, 1, 2]);
  assert.equal(p.pointerFallbackClicks, 1);
});

test('single-route fast clicks and dragging still forward all real presses and releases', () => {
  const p = page();
  for (let i = 0; i < 3; i++) {
    ark(p, MouseAction.Press); now += 5; ark(p, MouseAction.Release); now += 5;
  }
  ark(p, MouseAction.Press); now += 20;
  ark(p, MouseAction.Move, MouseButton.None, { x: 80, pressedButtons: [MouseButton.Left] });
  now += 20; ark(p, MouseAction.Release, MouseButton.Left, { x: 80 });
  assert.deepEqual(sent, [1, 2, 1, 2, 1, 2, 1, 0, 2]);
  assert.equal(p.leftButtonHeld, false);
});

test('ordinary physical presses do not show the simulated drag hint', () => {
  for (const route of [p => ark(p, MouseAction.Press), p => touch(p, TouchType.Down), p => native(p, 1),
    p => ark(p, MouseAction.Move, MouseButton.None, { pressedButtons: [MouseButton.Left] })]) {
    const p = page(); route(p);
    assert.equal(p.leftButtonHeld, true);
    assert.equal(p.showLeftButtonHoldIndicator, false);
  }
});

test('confirmed simulated touch/virtual-mouse drag keeps its held hint until release', () => {
  const p = page(); p.sendLeftDown(100, 100);
  assert.equal(p.showLeftButtonHoldIndicator, true);
  assert.equal(p.leftButtonHeld, true);
  p.sendLeftUp(100, 100);
  assert.deepEqual(sent, [1, 2]);
  assert.equal(p.showLeftButtonHoldIndicator, false);
});

test('projected ArkUI/native/touch button deliveries do not duplicate left or right clicks', () => {
  const p=page({remoteExternalDisplay:true});
  ark(p,MouseAction.Press); now+=10; touch(p,TouchType.Down); now+=10; native(p,1);
  now+=10; touch(p,TouchType.Up); now+=10; native(p,2); now+=10; ark(p,MouseAction.Release); fallback(p);
  now+=200; native(p,1,MouseButton.Right); now+=10; ark(p,MouseAction.Press,MouseButton.Right);
  now+=10; ark(p,MouseAction.Release,MouseButton.Right); now+=10; native(p,2,MouseButton.Right);
  assert.deepEqual(sent,[1,2,3,4]); assert.equal(p.pointerFallbackClicks,0);
});
test('native physical buttons work while the keyboard is visible', () => {
  const p = page({ showKeyboardPanel: true });
  native(p, 1); now += 20; native(p, 2); fallback(p);
  native(p, 1, MouseButton.Right); native(p, 2, MouseButton.Right);
  assert.deepEqual(sent, [1, 2, 3, 4]);
});
test('native orphan release does not suppress click repair', () => {
  const p = page({ showKeyboardPanel: true }); native(p, 2); fallback(p);
  assert.deepEqual(sent, [2, 1, 2]);
});
test('paired native/ArkUI deliveries do not generate an extra click', () => {
  const p = page(); native(p, 1); now += 10; ark(p, MouseAction.Press);
  now += 10; native(p, 2); now += 10; ark(p, MouseAction.Release); fallback(p);
  assert.deepEqual(sent, [1, 2]); assert.equal(p.pointerDuplicateEvents, 2);
});
test('release recovered from button-state movement suppresses a duplicate onClick', () => {
  const p = page(); ark(p, MouseAction.Press); now += 20;
  ark(p, MouseAction.Move, MouseButton.None, { pressedButtons: [] }); fallback(p);
  assert.deepEqual(sent, [1, 2, 0]); assert.equal(p.leftButtonHeld, false);
});
test('cancel balances an active button without completing a click', () => {
  const p = page(); touch(p, TouchType.Down); touch(p, TouchType.Cancel);
  assert.deepEqual(sent, [1, 2]); assert.equal(p.lastMappedPhysicalLeftUpAt, 0);
});
test('disconnected or missing-video-size input never sends a click', () => {
  for (const overrides of [{ connectionStatus: 0 }, { remoteWidth: 0 }]) {
    const p = page(overrides); ark(p, MouseAction.Press); native(p, 1); touch(p, TouchType.Down); fallback(p);
    assert.deepEqual(sent, []);
  }
});
console.log(`${checks} physical mouse click regression checks passed`);
