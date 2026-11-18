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
  'moveVirtualMouseAxis', 'updateVirtualMouseMove', 'beginVirtualMouseMove', 'finishVirtualMouseMove',
  'updatePointerFromVirtualMouse', 'syncVirtualMouseToCurrentPointer',
  'clickVirtualMouseButton', 'beginVirtualMouseButtonDrag', 'finishVirtualMouseButtonDrag',
  'virtualMouseOverlayX', 'virtualMouseOverlayY', 'virtualMousePointerX', 'virtualMousePointerY'];
const constants = ['TOUCHPAD_POINTER_SPEED', 'TOUCH_MOVE_THRESHOLD', 'TOUCH_TAP_SLOP',
  'TOUCHPAD_DRAG_START_THRESHOLD', 'TOUCHPAD_DOUBLE_TAP_TIMEOUT_MS',
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
    virtualMouseDragActive: false, virtualMouseLeftDown: false, virtualMouseRightDown: false,
    pointerVirtualMoves: 0, pointerVirtualButtonMoves: 0, hasAuthoritativeRemoteCursor: false,
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
test('enabling near the bottom keeps the existing remote hotspot while the panel stays visible', () => {
  const p = make({ showVirtualMouse: true, componentWidth: 844, componentHeight: 363,
    remoteWidth: 1920, remoteHeight: 1080, zoomScale: 1, lastAbsX: 516, lastAbsY: 718 });
  p.syncVirtualMouseToCurrentPointer();
  const visual = p.remotePointToVisual(516, 718);
  near(p.virtualMousePointerX() + 1, visual.x);
  near(p.virtualMousePointerY() + 1, visual.y);
  assert(p.virtualMousePointerY() > p.virtualMouseOverlayY(), 'the panel, not the hotspot, must be clamped');
  assert(p.virtualMouseOverlayY() + 138 <= p.componentHeight);
  assert.deepEqual(calls, [], 'enabling or aligning must not move or click the remote');
});
test('virtual button moves the official-style host to the target before clicking', () => {
  const p = make({ showVirtualMouse: true, componentWidth: 844, componentHeight: 363,
    remoteWidth: 1920, remoteHeight: 1080, zoomScale: 1, lastAbsX: 516, lastAbsY: 718 });
  p.syncVirtualMouseToCurrentPointer();
  p.sendLeftClick = (x, y) => { calls.push([x, y, 1]); calls.push([x, y, 2]); };
  p.clickVirtualMouseButton('left');
  assert.deepEqual(calls.map(c => c[2]), [0, 1, 2]);
  let hostPosition = [100, 100], clicked = null;
  for (const [x, y, action] of calls) {
    if (action === 0) hostPosition = [Math.trunc(x), Math.trunc(y)];
    if (action === 1) clicked = [...hostPosition]; // host ignores x/y on DOWN
  }
  assert(Math.abs(clicked[0] - 516) <= 1 && Math.abs(clicked[1] - 718) <= 1);
  assert.equal(p.pointerVirtualButtonMoves, 1);
});
test('right and middle virtual buttons each send one position before their balanced click', () => {
  const p = make({showVirtualMouse:true}); p.syncVirtualMouseToCurrentPointer();
  p.sendRightDown = (x,y) => calls.push([x,y,3]);
  p.sendRightUp = (x,y) => calls.push([x,y,4]);
  p.clickVirtualMouseButton('right');
  assert.deepEqual(calls.map(c => c[2]), [0,3,4]);
  calls=[]; p.clickVirtualMouseButton('middle');
  assert.deepEqual(calls.map(c => c[2]), [0,5,6]);
});
test('virtual input is blocked while disconnected or geometry is not ready', () => {
  for (const state of [{connectionStatus:0},{remoteWidth:0},{remoteHeight:0},
    {componentWidth:0},{componentHeight:0}]) {
    const p=make({showVirtualMouse:true,...state});
    p.clickVirtualMouseButton('left'); p.beginVirtualMouseButtonDrag('left');
    p.updateVirtualMouseMove(20,20);
    assert.deepEqual(calls,[]); assert.equal(p.virtualMouseLeftDown,false);
  }
});
test('virtual drag synchronizes before down and before release, cancel only releases', () => {
  const p = make({ showVirtualMouse: true });
  p.sendLeftDown = (x,y) => { p.leftButtonHeld = true; calls.push([x,y,1]); };
  p.sendLeftUp = (x,y) => { p.leftButtonHeld = false; calls.push([x,y,2]); };
  p.beginVirtualMouseButtonDrag('left');
  assert.deepEqual(calls.map(c => c[2]), [0,1]);
  p.updateVirtualMouseMove(20,15);
  const target = [p.lastAbsX,p.lastAbsY];
  p.lastAbsX = 0; p.lastAbsY = 0; // stale peer feedback must not change the release target
  p.finishVirtualMouseButtonDrag('left');
  assert.deepEqual(calls.slice(-2).map(c => c[2]), [0,2]);
  near(calls.at(-2)[0], target[0]); near(calls.at(-2)[1], target[1]);
  near(calls.at(-1)[0], target[0]); near(calls.at(-1)[1], target[1]);
  p.beginVirtualMouseButtonDrag('left'); calls=[];
  p.finishVirtualMouseButtonDrag('left', true);
  assert.deepEqual(calls.map(c => c[2]), [2], 'cancel must release without moving or clicking');
});
test('virtual pointer remains aligned after landscape portrait and zoom changes', () => {
  const p = make({ showVirtualMouse: true, componentWidth:844, componentHeight:363,
    remoteWidth:1920, remoteHeight:1080, zoomScale:1, lastAbsX:516, lastAbsY:718 });
  for (const [w,h,zoom] of [[844,363,1],[391,777,1],[391,777,1.3],[844,363,1]]) {
    p.componentWidth=w; p.componentHeight=h; p.zoomScale=zoom;
    p.offsetX=0; p.offsetY=0; p.syncVirtualMouseToCurrentPointer();
    const visual = p.remotePointToVisual(p.lastAbsX,p.lastAbsY);
    near(p.virtualMousePointerX()+1,visual.x); near(p.virtualMousePointerY()+1,visual.y);
    assert(p.virtualMouseOverlayX()+112<=w && p.virtualMouseOverlayY()+138<=h);
  }
  assert.deepEqual(calls,[]);
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
  near(p.offsetX, -110.6);
  near(p.lastAbsX, 999);
});
test('right-edge drag pans the canvas but never moves the hotspot into black space', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(1000, 0);
  near(p.lastAbsX, 999);
  const edge = p.remotePointToVisual(999, p.lastAbsY);
  near(p.virtualMousePointerX() + 1, edge.x);
  near(p.virtualMouseX, p.virtualMouseOverlayX());
  assert(p.virtualMouseOverlayX() + 112 <= p.componentWidth);
  near(calls.at(-1)[0], 999);
  p.finishVirtualMouseMove();
  const edgeX = p.virtualMouseX;
  p.beginVirtualMouseMove(); near(p.virtualMouseX, edgeX);
  p.updateVirtualMouseMove(-20, 0);
  assert(p.lastAbsX < 999);
  near(p.virtualMousePointerX() + 1, p.remotePointToVisual(p.lastAbsX, p.lastAbsY).x);
  p.updateVirtualMouseMove(-300, 0);
  assert(p.lastAbsX < 999);
});
test('bottom-edge drag keeps the hotspot at the last remote pixel', () => {
  const p = make({ showVirtualMouse: true }); p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(0, 1000);
  near(p.lastAbsY, 999);
  near(p.virtualMousePointerY() + 1, p.remotePointToVisual(p.lastAbsX, 999).y);
  near(p.virtualMouseY, p.virtualMouseOverlayY());
  near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
  assert(p.virtualMouseOverlayY() + 138 <= p.componentHeight);
  near(calls.at(-1)[1], 999);
  p.finishVirtualMouseMove();
  const outsideY = p.virtualMouseY;
  p.beginVirtualMouseMove(); near(p.virtualMouseY, outsideY);
  p.updateVirtualMouseMove(0, -20);
  assert(p.lastAbsY < 999);
  near(p.virtualMousePointerY() + 1, p.remotePointToVisual(p.lastAbsX, p.lastAbsY).y);
  p.updateVirtualMouseMove(0, -400);
  assert(p.lastAbsY < 999);
});
test('bottom grouped movement also works without vertical image overflow', () => {
  const p = make({ showVirtualMouse: true, zoomScale: 1 }); p.beginVirtualMouseMove();
  near(p.getVerticalPanLimit(p.zoomScale), 0);
  p.updateVirtualMouseMove(0, 1000);
  near(p.virtualMouseY, 262);
  near(p.virtualMousePointerY(), p.virtualMouseOverlayY());
  near(p.offsetY, -136.6);
  near(p.lastAbsY, 999);
});
test('all four virtual pointer edges stay on real remote pixels and reverse immediately', () => {
  for (const [dx,dy] of [[-1000,0],[1000,0],[0,-1000],[0,1000]]) {
    const p=make({showVirtualMouse:true}); p.beginVirtualMouseMove();
    p.updateVirtualMouseMove(dx,dy);
    const visual=p.remotePointToVisual(p.lastAbsX,p.lastAbsY);
    near(p.virtualMousePointerX()+1,visual.x); near(p.virtualMousePointerY()+1,visual.y);
    if(dx<0) near(p.lastAbsX,0); if(dx>0) near(p.lastAbsX,999);
    if(dy<0) near(p.lastAbsY,0); if(dy>0) near(p.lastAbsY,999);
    const previous=[p.lastAbsX,p.lastAbsY];
    p.updateVirtualMouseMove(dx-Math.sign(dx)*20,dy-Math.sign(dy)*20);
    if(dx) assert(Math.abs(p.lastAbsX-previous[0])>0);
    if(dy) assert(Math.abs(p.lastAbsY-previous[1])>0);
  }
});
test('virtual hotspot follows sent coordinates across aspect ratios, zooms and repeated direction changes', () => {
  let seed=0x45ab23;
  const random=()=>{ seed=(Math.imul(seed,1664525)+1013904223)>>>0; return seed/0x100000000; };
  for (const [width,height] of [[844,363],[391,777],[1200,800],[240,320]]) {
    for (const zoomScale of [0.75,1,1.5,2.5]) {
      const p=make({showVirtualMouse:true,componentWidth:width,componentHeight:height,
        remoteWidth:1920,remoteHeight:1080,lastAbsX:960,lastAbsY:540,zoomScale});
      p.beginVirtualMouseMove(); let ox=0,oy=0;
      for(let i=0;i<50;i++) {
        ox+=(random()-0.5)*240; oy+=(random()-0.5)*240;
        p.updateVirtualMouseMove(ox,oy);
        const visual=p.remotePointToVisual(p.lastAbsX,p.lastAbsY);
        if(Math.abs(p.virtualMousePointerX()+1-visual.x)>1e-7 || Math.abs(p.virtualMousePointerY()+1-visual.y)>1e-7)
          console.log('virtual alignment failure',JSON.stringify({width,height,zoomScale,i,ox,oy,
            offsetX:p.offsetX,offsetY:p.offsetY,pointerX:p.virtualMouseX,pointerY:p.virtualMouseY,
            remoteX:p.lastAbsX,remoteY:p.lastAbsY,visual}));
        near(p.virtualMousePointerX()+1,visual.x,`x ${width}x${height} zoom=${zoomScale}`);
        near(p.virtualMousePointerY()+1,visual.y,`y ${width}x${height} zoom=${zoomScale}`);
        assert(p.lastAbsX>=0 && p.lastAbsX<=1919 && p.lastAbsY>=0 && p.lastAbsY<=1079);
        assert(p.virtualMouseOverlayX()>=0 && p.virtualMouseOverlayX()+112<=width);
        assert(p.virtualMouseOverlayY()>=0 && p.virtualMouseOverlayY()+138<=height);
      }
    }
  }
});
test('edge-follow disabled still keeps the virtual hotspot on the image', () => {
  const p = make({ showVirtualMouse: true, edgeAutoPanEnabled: false });
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(20, 0);
  near(p.offsetX, 0);
  near(p.lastAbsX, 525);
  p.updateVirtualMouseMove(1000, 0);
  near(p.lastAbsX, 999);
  near(p.virtualMousePointerX() + 1, p.remotePointToVisual(999, p.lastAbsY).x);
  near(p.virtualMouseX, p.virtualMouseOverlayX());
  assert(p.virtualMouseOverlayX() + 112 <= p.componentWidth);
  p.finishVirtualMouseMove();
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(-20, 0);
  assert(p.lastAbsX < 999);
  p.updateVirtualMouseMove(-300, 0);
  assert(p.lastAbsX < 999);
});
test('right-edge black margin is removed when virtual mouse is turned off', () => {
  const body = source.slice(source.indexOf('  setVirtualMouseEnabled(enabled:'),
    source.indexOf('  loadToolbarOrderPreferences()'));
  assert(body.includes('this.clampViewportOffset();'));
  assert(source.includes(".backgroundColor('#090D14')"));
});
test('panning elsewhere retains the hotspot even when the body is clamped', () => {
  const p = make({ showVirtualMouse: true });
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(1000, 0);
  p.finishVirtualMouseMove();
  assert(p.offsetX < -p.getHorizontalPanLimit(p.zoomScale));
  p.offsetX = -p.getHorizontalPanLimit(p.zoomScale);
  p.syncVirtualMouseToCurrentPointer();
  near(p.virtualMousePointerX() + 1, p.remotePointToVisual(p.lastAbsX, p.lastAbsY).x);
  assert(p.virtualMouseOverlayX() + 112 <= p.componentWidth);
});
test('panning elsewhere after reaching the bottom keeps the hotspot accurate', () => {
  const p = make({ showVirtualMouse: true });
  p.beginVirtualMouseMove();
  p.updateVirtualMouseMove(0, 1000);
  p.finishVirtualMouseMove();
  const outsideY = p.virtualMouseY;
  p.syncVirtualMouseToCurrentPointer();
  near(p.virtualMouseY, outsideY);
  p.offsetY = -p.getVerticalPanLimit(p.zoomScale);
  p.syncVirtualMouseToCurrentPointer();
  near(p.virtualMousePointerY() + 1, p.remotePointToVisual(p.lastAbsX, p.lastAbsY).y);
  assert(p.virtualMouseOverlayY() + 138 <= p.componentHeight);
});
test('virtual mouse owns other-area touch even when the image has no ordinary pan overflow', () => {
  const body = source.slice(source.indexOf('  handleRemoteTouch(event: TouchEvent): void {'),
    source.indexOf('  handlePointerCompatibilityTouch(event: TouchEvent): void {'));
  assert(body.includes('if ((this.showVirtualMouse && this.isHandheldDevice()) || this.isPanMode)'));
  assert(!body.includes('this.showVirtualMouse && this.isHandheldDevice() && this.canPanViewport()'));
});
test('virtual mouse move handle remains on screen without shifting the hotspot', () => {
  const p = make({ virtualMouseX: 398, virtualMouseY: 398 });
  near(p.virtualMouseOverlayX(), 288);
  near(p.virtualMouseOverlayY(), 262);
  near(p.virtualMousePointerX(), 398);
  near(p.virtualMousePointerY(), 398);
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
