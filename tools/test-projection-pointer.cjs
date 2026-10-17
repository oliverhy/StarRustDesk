const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/pages/RemotePage.ets', 'utf8');
const model = fs.readFileSync('entry/src/main/ets/model/PhysicalMousePolicy.ets', 'utf8');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
let now = 1000, enabled = false;
const sent = [], logs = [];
const MouseAction = { Press: 1, Release: 2, Move: 3, Hover: 4 };
const MouseButton = { Left: 1, Right: 2 };
const SourceType = { Mouse: 1, TouchScreen: 2 };
const SourceTool = { Finger: 1, Pen: 2, MOUSE: 7, TOUCHPAD: 9 };
const context = vm.createContext({
  Date: { now: () => now }, Math, Number, MouseAction, MouseButton, SourceType, SourceTool,
  TouchType: { Down: 0, Up: 1, Move: 2, Cancel: 3 },
  INPUT_MODE_MOUSE: 'mouse', ConnectionStatus: { CONNECTED: 2 },
  NATIVE_MOUSE_ACTION_MOVE: 3, NATIVE_MOUSE_ACTION_PRESS: 1,
  NATIVE_MOUSE_ACTION_RELEASE: 2, NATIVE_MOUSE_ACTION_CANCEL: 13,
  NATIVE_MOUSE_BUTTON_LEFT: 1, NATIVE_MOUSE_BUTTON_RIGHT: 2,
  RustDeskNapi: { getOption: () => enabled ? '1' : '0', appendDiagnosticLog: (...v) => logs.push(v) },
  ConnectionService: { sendMouseEvent: (...v) => sent.push(v), syncNativeModifierState() {} }
});
vm.runInContext(ts.transpile(model.replace(/export /g, '') + `
globalThis.Dedup = PhysicalMouseDeduplicator;
globalThis.isTouchOnly = isTouchOnlyMouseEvent;
class Page {${[
  'handleNativeMouseInput', 'handleRemoteMouse', 'mapMouseAction',
  'updatePointerFromLocal', 'updateCursorOverlayFromPosition', 'markLocalPointerInput',
  'noteProjectedPhysicalPointer', 'shouldShowCursorOverlay',
  'resetPointerDiagnostics', 'flushPointerDiagnostics', 'onProjectionDisplayChanged',
  'touchMouseFollowBlockReason', 'isRemoteKeyboardBlockingPointer',
  'handleRemoteClickFallback'
].map(method).join('\n')}}
globalThis.Page = Page;`), context);
let checks = 0;
function test(name, run) { run(); checks++; console.log('PASS ' + name); }
const d = new context.Dedup();
test('native click cannot swallow following unpressed movement', () => {
  d.rememberNative(1, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 51, 60, 1010), false);
});
test('only matching action and position are deduplicated, once', () => {
  d.rememberNative(0, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1010), true);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1011), false);
  d.rememberNative(0, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 51, 60, 1010), false);
  d.rememberNative(1, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(2, 50, 60, 1010), false);
});
test('expired, invalid and reset samples never suppress new input', () => {
  d.rememberNative(0, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1080), false);
  d.rememberNative(0, NaN, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1010), false);
  d.rememberNative(0, 50, 60, 1000); d.clear();
  assert.equal(d.consumeDuplicate(0, 50, 60, 1010), false);
});

test('projected delivery pairs work in either order and across three paths', () => {
  for (const order of [[1,2,4], [2,4,1], [4,1,2], [8,1,2]]) {
    d.clear();
    assert.equal(d.consumePointerDuplicate(0,50,60,1000,order[0]),false);
    assert.equal(d.consumePointerDuplicate(0,50.2,60.1,1010,order[1]),true);
    assert.equal(d.consumePointerDuplicate(0,50,60,1020,order[2]),true);
    assert.equal(d.consumePointerDuplicate(0,51,60,1021,order[0]),false);
    assert.equal(d.consumePointerDuplicate(2,51,60,1022,order[1]),false);
  }
});

test('same-origin events and real fast double-clicks are never suppressed', () => {
  d.clear();
  for (let i=0;i<2;i++) {
    assert.equal(d.consumePointerDuplicate(1,50,60,1000+i*20,2),false);
    assert.equal(d.consumePointerDuplicate(2,50,60,1005+i*20,2),false);
  }
  for (const action of [1,2,1,2]) assert.equal(d.consumePointerDuplicate(action,50,60,1050,1),true);
  assert.equal(d.consumePointerDuplicate(0,50,60,1200,1),false);
  d.clear(); assert.equal(d.consumePointerDuplicate(2,50,60,1201,2),false);
});
test('coordinate-free compatibility releases match once per origin and learn their position', () => {
  d.clear();
  assert.equal(d.consumePointerDuplicate(1,0,0,1000,8,false),false);
  assert.equal(d.consumePointerDuplicate(0,0,0,1000,8,false),false);
  assert.equal(d.consumePointerDuplicate(2,0,0,1000,8,false),false);
  assert.equal(d.consumePointerDuplicate(2,50,60,1001,2),true);
  assert.equal(d.consumePointerDuplicate(2,70,60,1002,1),false, 'do not reuse a position-free wildcard');
  assert.equal(d.consumePointerDuplicate(2,50,60,1003,4),true);
  assert.equal(d.consumePointerDuplicate(2,50,60,1004,2),false, 'same path is a new release');
  assert.equal(d.consumePointerDuplicate(2,50,60,1100,1),false, 'old pairs expire');
  d.clear(); assert.equal(d.consumePointerDuplicate(2,50,60,1101,2),false);
});

test('explicit mouse/touchpad survives touch wrapper; real finger/pen stays filtered', () => {
  assert.equal(context.isTouchOnly(true, false, true, false), false);
  assert.equal(context.isTouchOnly(false, true, false, true), false);
  assert.equal(context.isTouchOnly(true, false, false, true), true);
  assert.equal(context.isTouchOnly(false, false, false, true), true);
});
function page(overrides = {}) {
  const p = Object.assign(new context.Page(), {
    connectionStatus: 2, remoteWidth: 1000, remoteHeight: 500,
    componentWidth: 600, componentHeight: 400, inputMode: 'mouse',
    zoomScale: 1, offsetX: 0, offsetY: 0, showKeyboardPanel: false,
    remoteKeyboardVisible: false, remoteKeyboardEditing: false, remoteKeyboardVisibilityKnown: true,
    remoteExternalDisplay: true, remoteProjectionDisplayId: 8, projectedPhysicalPointer: false,
    showCursor: false, relativeMouseEnabled: false, hasAuthoritativeRemoteCursor: false,
    remoteCursorEmbedded: false, embeddedCursorOverlayFallback: false,
    remoteCursorImageWidth: 0, remoteCursorImageHeight: 0,
    cursorCompatibilityMode: 'auto', lastMoveSentAt: 0, lastNativeMouseEventAt: 0,
    lastTouchEventAt: 0, lastMappedPhysicalLeftUpAt: 0,
    physicalMouseDeduplicator: new context.Dedup(),
    getDisplayWidth: () => 500, getDisplayHeight: () => 250,
    getDisplayLeft: () => 50, getDisplayTop: () => 75,
    suppressCompatibilityCursor() { return this.cursorCompatibilityMode === 'embedded'; },
    handleRemoteHover() {}, syncModifiersFromPointerEvent() {}, updateSystemPointerVisibility() {},
    clearLongPressTimer() {}, clearTapTimer() {}, requestRemoteInputFocus() {},
    reconcilePhysicalMouseButtons() {}, updateEdgeAutoPan() {}, stopEdgeAutoPan() {},
    isHandheldDevice() { return false; },
    startRemoteKeyboardTracking() { this.keyboardTrackingRestarts = (this.keyboardTrackingRestarts || 0) + 1; },
    sendLeftDown(x,y) { sent.push([x,y,1]); }, sendLeftUp(x,y) { sent.push([x,y,2]); },
    sendRightDown(x,y) { sent.push([x,y,3]); }, sendRightUp(x,y) { sent.push([x,y,4]); },
    sendLeftClick(x,y) { sent.push([x,y,'click']); },
    releaseHeldMouseButtons(reason) { this.releaseReason = reason; },
    ...overrides
  });
  p.resetPointerDiagnostics(); sent.length = 0;
  return p;
}
function ark(p, x, y, extra = {}) {
  p.handleRemoteMouse({ action: MouseAction.Move, button: 0, x, y,
    source: SourceType.Mouse, sourceTool: SourceTool.MOUSE,
    stopPropagation() {}, ...extra });
}
function native(p, x, y, action = 3, button = 0) {
  p.handleNativeMouseInput({ x,y,action,button,hover:-1,modifierValid:false });
}
test('native button followed by ArkUI movement forwards and positions overlay', () => {
  const p = page(); now = 1000; native(p, 100, 100, 1, 1);
  now += 16; ark(p, 160, 175);
  assert.deepEqual(sent.at(-1), [220, 200, 0]);
  assert.equal(p.cursorX, 160); assert.equal(p.cursorY, 175);
  assert.equal(p.shouldShowCursorOverlay(), true);
});
test('same native/ArkUI move forwards once; different next move still works', () => {
  const p = page(); now = 1000; native(p, 100, 100);
  now += 16; ark(p, 150, 175);
  assert.equal(sent.length, 1); assert.equal(p.pointerDuplicateEvents, 1);
  now += 16; ark(p, 160, 175);
  assert.equal(sent.length, 2); assert.deepEqual(sent.at(-1), [220,200,0]);
});

test('ArkUI before delayed native delivery forwards once, without losing next move', () => {
  const p=page(); now=1000; ark(p,150,175);
  now+=16; native(p,100,100);
  assert.equal(sent.length,1); assert.equal(p.pointerDuplicateEvents,1);
  now+=16; native(p,101,100);
  assert.deepEqual(sent.at(-1),[202,200,0]);
});

test('native TV pixels normalize to ArkUI vp and deduplicate at non-phone density', () => {
  const p=page(); now=1000;
  p.handleNativeMouseInput({x:200,y:200,action:3,button:0,hover:-1,modifierValid:false,
    surfaceWidth:1000,surfaceHeight:500});
  assert.deepEqual(sent.at(-1),[200,200,0]);
  now+=16; ark(p,150,175);
  assert.equal(sent.length,1); assert.equal(p.pointerDuplicateEvents,1);
});

test('projected root fallback maps direct-touch letterboxes and keeps matching paths single', () => {
  const p=page({inputMode:'touch'}); now=1000;
  p.handleRemoteMouse({action:3,button:0,x:150,y:175,source:1,sourceTool:7,
    targetDisplayId:8,stopPropagation(){}},false,true);
  assert.deepEqual(sent.at(-1),[200,200,0]);
  assert.equal(p.pointerTargetDisplayId,8);
  now+=16; native(p,100,100);
  assert.equal(sent.length,1);
});
test('matching native buttons do not double-click or drop the next release', () => {
  const p = page(); now = 1000; native(p, 100,100,1,1);
  now += 10; ark(p,150,175,{action:MouseAction.Press,button:MouseButton.Left});
  now += 10; ark(p,150,175,{action:MouseAction.Release,button:MouseButton.Left});
  assert.deepEqual(sent.map(v => v[2]), [1,2]);
});
test('projected physical cursor displays in direct-touch mode without changing preference', () => {
  const p = page({inputMode:'touch'}); now = 1000;
  ark(p,100,100,{source:SourceType.TouchScreen});
  assert.equal(p.projectedPhysicalPointer,true);
  assert.equal(p.shouldShowCursorOverlay(),true);
  assert.equal(p.inputMode,'touch');
  assert.deepEqual(sent.at(-1),[200,200,0]);
  p.remoteExternalDisplay=false;
  assert.equal(p.shouldShowCursorOverlay(),false,'local/mirror touch-mode behavior stays unchanged');
});
test('finger compatibility cannot take over physical cursor or send another move', () => {
  const p = page(); now=1000;
  ark(p,100,100,{source:SourceType.TouchScreen,sourceTool:SourceTool.Finger});
  assert.equal(sent.length,0); assert.equal(p.pointerFilteredEvents,1);
  assert.equal(p.projectedPhysicalPointer,false);
});
test('relative mode and explicit embedded preference keep their cursor constraints', () => {
  const p=page({showCursor:true,projectedPhysicalPointer:true,relativeMouseEnabled:true});
  assert.equal(p.shouldShowCursorOverlay(),false);
  p.hasAuthoritativeRemoteCursor=true; assert.equal(p.shouldShowCursorOverlay(),true);
  p.cursorCompatibilityMode='embedded'; assert.equal(p.shouldShowCursorOverlay(),false);
});
test('display transition clears stale pairing and relative baseline', () => {
  const p=page({remotePageVisible:true,projectedPhysicalPointer:true,relativePointerSampleValid:true});
  p.physicalMouseDeduplicator.rememberNative(0,10,10,1000);
  p.onProjectionDisplayChanged();
  assert.equal(p.relativePointerSampleValid,false); assert.equal(p.projectedPhysicalPointer,false);
  assert.equal(p.physicalMouseDeduplicator.consumeDuplicate(0,10,10,1010),false);
  assert.equal(p.releaseReason,'projection_display_changed');
});
test('diagnostics disabled by default; rate-limited movement and display reasons when enabled', () => {
  const p=page(); logs.length=0; now=5000; enabled=false;
  ark(p,100,100); p.flushPointerDiagnostics(); assert.equal(logs.length,0);
  now+=2000; enabled=true; ark(p,110,110); p.flushPointerDiagnostics();
  assert.equal(logs.length,1); assert.match(logs[0][1],/ark_move=1/);
  assert.match(logs[0][1],/physical_move_dispatch=1/); assert.match(logs[0][1],/overlay=true/);
  p.flushPointerDiagnostics(); assert.equal(logs.length,1);
  now+=2000; p.flushPointerDiagnostics();
  assert.match(logs.at(-1)[1],/native_move=0 ark_move=0 touch_move=0/);
  assert.doesNotMatch(logs.map(v=>v[1]).join('\n'), /password|token|clipboard/);
});
test('cursor overlay does not intercept input and is explicitly above the surface', () => {
  const start=source.indexOf('\n  buildCursorOverlay()');
  const overlay=source.slice(start,source.indexOf('\n  }',start)+4);
  assert.match(overlay,/\.zIndex\(11\)/);
  // None on the parent does not disable child hit testing. Check both branches.
  const image=overlay.slice(overlay.indexOf('Image('),overlay.indexOf('} else {'));
  const arrow=overlay.slice(overlay.indexOf('Path()'),overlay.indexOf('\n    }'));
  assert.match(image,/\.hitTestBehavior\(HitTestMode.None\)/);
  assert.match(arrow,/\.hitTestBehavior\(HitTestMode.None\)/);
  assert.equal((overlay.match(/\.hitTestBehavior\(HitTestMode.None\)/g)||[]).length,3);
});
test('projected hit-test fallback is scoped, real native input only uses C callbacks', () => {
  const viewport=method('buildRemoteViewport');
  assert(viewport.includes('this.remoteExternalDisplay ? HitTestMode.Transparent : HitTestMode.Block'));
  assert(viewport.includes('this.remoteExternalDisplay ? HitTestMode.Default : HitTestMode.None'));
  assert(viewport.includes('this.handleRemoteMouse(event, false, true)'));
  const nativeLayer=viewport.slice(viewport.indexOf('XComponent({'),viewport.indexOf('if (!this.hasVideo)'));
  assert(!nativeLayer.includes('.onMouse('),'libraryname XComponent delivers mouse to C, not ArkTS');
  assert.match(viewport,/\.onMouse\(\(event: MouseEvent\) => \{\s+if \(!this.remoteExternalDisplay\) return;/);
});
console.log(`${checks} projection pointer regression checks passed`);
