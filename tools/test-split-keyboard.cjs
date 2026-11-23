'use strict';
// "Picture above keyboard" (控 → 画面 → 上画面下键盘): menu wiring, local
// persistence, keyboard open/close and split geometry, executed against the
// production model and extracted RemotePage methods. Window sizes are
// illustrative fixtures, not measured Pura X Max parameters.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replaceAll('\r\n', '\n');
const load = p => { const c = { exports: {} }; vm.runInNewContext(ts.transpile(read(p)), c); return c.exports; };
const layout = load('entry/src/main/ets/model/SplitKeyboardLayout.ets');
const menu = load('entry/src/main/ets/model/RemoteControlMenu.ets');
const glass = load('entry/src/main/ets/model/RemoteGlassMenu.ets');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const widget = read('entry/src/main/ets/widget/RemoteGlassMenu.ets');
function method(name) {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
function constArray(name) {
  const match = source.match(new RegExp('const ' + name + String.raw`: string\[\] = (\[[\s\S]*?\]);`));
  assert(match, name);
  return Array.from(vm.runInNewContext(match[1]));
}
const CONTROL_TOOLBAR_DEFAULT_ORDER = constArray('CONTROL_TOOLBAR_DEFAULT_ORDER');
const KEYBOARD_MORE_DEFAULT_ORDER = constArray('KEYBOARD_MORE_DEFAULT_ORDER');
const inputConstants = ['TOUCHPAD_POINTER_SPEED', 'TOUCHPAD_DOUBLE_TAP_TIMEOUT_MS', 'TOUCHPAD_DRAG_START_THRESHOLD',
  'TOUCH_TAP_SLOP', 'INPUT_MODE_MOUSE', 'INPUT_MODE_TOUCH'].map(name => {
  const match = source.match(new RegExp('const ' + name + ': (?:number|string) = [^;]+;'));
  assert(match, name); return match[0];
}).join('\n');

const deviceInfo = { deviceType: 'phone' };
const options = new Map();
const setOptionCalls = [];
const logs = [];
const timers = [];
const mouseEvents = [];
const fold = { creaseRects: [], fail: false };
const context = vm.createContext({
  deviceInfo, console,
  RustDeskNapi: {
    getOption: key => options.get(key) ?? '',
    setOption: (key, value) => { setOptionCalls.push([key, value]); options.set(key, value); },
    appendDiagnosticLog: (category, message) => logs.push([category, message]),
  },
  display: { getCurrentFoldCreaseRegion() {
    if (fold.fail) throw new Error('not foldable');
    return { displayId: 0, creaseRects: fold.creaseRects };
  } },
  AppStorage: { get: () => undefined },
  ConnectionStatus: { CONNECTED: 2 },
  ConnectionService: { sendMouseEvent: (...args) => { mouseEvents.push(args); return 0; } },
  TouchType: { Down: 0, Move: 1, Up: 2, Cancel: 3 },
  Alignment: { Top: 'Alignment.Top', Center: 'Alignment.Center' },
  setTimeout: (callback) => { timers.push(callback); return timers.length; },
  clearTimeout: () => {},
  CONTROL_TOOLBAR_DEFAULT_ORDER, KEYBOARD_MORE_DEFAULT_ORDER,
  RemoteGlassMenuState: glass.RemoteGlassMenuState,
  remoteControlCategoryItems: menu.remoteControlCategoryItems,
  SPLIT_KEYBOARD_OPTION: layout.SPLIT_KEYBOARD_OPTION,
  findHorizontalCreaseTopPx: layout.findHorizontalCreaseTopPx,
  splitKeyboardLineVp: layout.splitKeyboardLineVp,
  splitKeyboardViewportHeight: layout.splitKeyboardViewportHeight,
});
const names = ['isHandheldDevice', 'isHandheldLandscape', 'getVisibleControlMenuItems', 'getGlassMenuState',
  'handleGlassMenuAction', 'toolbarOrderLabel', 'readToolbarOrder',
  'loadSplitKeyboardPreference', 'setSplitKeyboardEnabled', 'isSplitKeyboardActive',
  'getEffectiveKeyboardViewportHeight', 'getSplitKeyboardFullPageHeight', 'refreshSplitKeyboardLine',
  'getSplitKeyboardViewportHeight', 'getRemoteCanvasHeight', 'getKeyboardViewportMaxHeight',
  'getKeyboardAvoidance', 'getKeyboardCanvasShiftY', 'snapshotRemoteKeyboardViewport', 'selectKeyboardInputAnchor',
  'onAreaChangeCallback', 'openRemoteKeyboard', 'closeRemoteKeyboard', 'restoreKeyboardAvoidMode',
  'toggleRemoteKeyboard', 'handleRemoteKeyboardHeightChange', 'scheduleRemoteKeyboardClose',
  'cancelRemoteKeyboardClose', 'isRemoteKeyboardBlockingPointer', 'traceRemoteKeyboardState',
  'getDisplayWidth', 'getDisplayHeight', 'getDisplayLeft', 'getDisplayTop', 'remotePointToVisual', 'visualPointToRemote',
  'getDisplayFitHeight', 'getRemoteViewportAlignment', 'getVerticalPanBias', 'getHorizontalPanLimit',
  'getVerticalPanLimit', 'getPanLimit', 'clampHorizontalOffset', 'clampVerticalOffset', 'clampOffsetToLimit',
  'clampViewportOffset', 'applyZoomAt', 'canPanViewport', 'handleTouchpadTouch', 'touchGesturePoint',
  'shouldFollowTouchMouse', 'touchMouseFollowBlockReason', 'updatePointerFromDelta'];
vm.runInContext(ts.transpile(inputConstants + '\nclass Page {' + names.map(method).join('\n') +
  '} globalThis.Page=Page;'), context);

function page(overrides = {}) {
  const calls = { open: 0, close: 0, menu: [], focus: 0 };
  const windowRect = { left: 0, top: 0, width: 1600, height: 2000 };
  const p = Object.assign(new context.Page(), {
    calls, windowRect,
    pageWidth: 800, pageHeight: 1000, componentWidth: 800, componentHeight: 1000, qualityViewportHeight: 1000,
    remoteWidth: 1920, remoteHeight: 1080, zoomScale: 1, offsetX: 0, offsetY: 0,
    lastAbsX: 0, lastAbsY: 0, pointerInitialized: false, lastLocalPointerInputAt: 0, hasAuthoritativeRemoteCursor: false,
    relativeMouseEnabled: false, currentDisplay: 0, keyboardInputAnchor: undefined,
    showKeyboardPanel: false, keyboardViewportHeight: 0, keyboardLayoutWidth: 0, keyboardLayoutHeight: 0,
    keyboardWindowWidth: 0, keyboardWindowHeight: 0, controlMenuKeyboardInset: 0, controlMenuPageOriginY: 0,
    keyboardManualPan: false, keyboardManualShiftY: 0, keyboardAvoidModeChanged: false, viewportPanFramePending: false,
    splitKeyboardEnabled: false, splitKeyboardLineVp: 0, remoteExternalDisplay: false,
    remoteKeyboardWindow: { getWindowProperties: () => ({ windowRect }) },
    remoteKeyboardFocusGeneration: 0, remoteKeyboardEditing: false, remoteKeyboardVisible: false,
    remoteKeyboardVisibilityKnown: false, remoteKeyboardPointerHandoffUntil: 0, remoteKeyboardCloseTimer: -1,
    remotePageVisible: true, connectionStatus: 2, pendingKeyboardText: '', pipSurfaceOwned: false,
    controlMenu: 'view', controlMenuClosing: false, controlToolbarOrder: CONTROL_TOOLBAR_DEFAULT_ORDER.slice(),
    keyboardMoreOrder: KEYBOARD_MORE_DEFAULT_ORDER.slice(), lastSurfaceWidth: 800, lastSurfaceHeight: 1000,
    isPeerAndroid: false, canPanViewport: () => true, isPcDevice: () => deviceInfo.deviceType !== 'phone' &&
      deviceInfo.deviceType !== 'tablet',
    getDesktopDisplayedPercent: () => 100, getUIContext: () => ({ vp2px: v => v * 2, px2vp: v => v / 2 }),
    setControlMenu(category) { this.calls.menu.push(category); this.controlMenu = category; },
    allowWaylandText: () => true, startRemoteKeyboardTracking() {}, releaseRemoteNavigationKeys() {},
    cancelRemoteKeyboardRefocus() {}, flushPendingTap() {}, resetKeyboardCaptureBuffer() {},
    applyKeyboardResizeMode() {}, refocusRemoteKeyboard() { this.calls.focus++; }, releaseVirtualModifiers() {},
    requestRemoteInputFocus() {}, stopEdgeAutoPan() {}, touchMouseFollowBlockReason: () => 'disabled',
    canKeepRemoteKeyboardForPointer: () => false, showPendingKeyboardTextDialog() {},
    bindSurfaceIfReady() {}, scheduleSurfaceRebindIfSizeChanged() {}, discardViewportPanFrame() {},
    keyboardToolsCollapsed: false, relativePointerSampleValid: true,
    inputMode: 'mouse', edgeAutoPanEnabled: false, isPanMode: false, preferAuthoritativeCursor: false,
    touchpadLastTapAt: 0, tapTimer: -1, lastMoveSentAt: 0, leftButtonHeld: false, touchpadDragCandidate: false,
    markLocalPointerInput() {}, ensurePointerInitialized() {}, beginLocalPointerGesture() {}, isSecondTapNear: () => false,
    startRightClickTimer() {}, resetToolbarTimer() {}, clearLongPressTimer() {}, updateCursorOverlayFromRemote() {},
    updateEdgeAutoPan() {}, syncVirtualMouseToCurrentPointer() {}, setPanMode() {},
    remoteKeyboardController: { stopEditing() {} },
  }, overrides);
  const open = context.Page.prototype.openRemoteKeyboard;
  const close = context.Page.prototype.closeRemoteKeyboard;
  p.openRemoteKeyboard = function () { this.calls.open++; return open.call(this); };
  p.closeRemoteKeyboard = function () { this.calls.close++; return close.call(this); };
  return p;
}
function reset() {
  options.clear(); setOptionCalls.length = 0; logs.length = 0; timers.length = 0; mouseEvents.length = 0;
  fold.creaseRects = []; fold.fail = false; deviceInfo.deviceType = 'phone';
}
function near(actual, expected, tolerance = 1e-7) {
  assert(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);
}
let passed = 0;
function test(name, run) { reset(); run(); passed++; console.log('PASS ' + name); }

// covers: TC-001
test('TC-001 switch is listed only in the handheld, non-projected view menu', () => {
  assert.deepEqual(Array.from(menu.remoteControlCategoryItems('view', ['pan', 'splitKeyboard', 'zoomIn'])),
    ['pan', 'splitKeyboard', 'zoomIn']);
  for (const type of ['phone', 'tablet', '2in1', 'pc']) for (const projected of [false, true]) {
    deviceInfo.deviceType = type;
    const p = page({ remoteExternalDisplay: projected });
    const items = Array.from(p.getVisibleControlMenuItems());
    const expected = (type === 'phone' || type === 'tablet') && !projected;
    assert.equal(items.includes('splitKeyboard'), expected, `${type} projected=${projected}`);
    if (expected) {
      const index = items.indexOf('splitKeyboard');
      assert(index > items.indexOf('pan') && index > items.indexOf('edgePan') && index < items.indexOf('zoomIn'),
        items.join(','));
    }
  }
  deviceInfo.deviceType = 'phone';
  const p = page();
  // A saved order without the new key keeps the user's order and appends it.
  const saved = CONTROL_TOOLBAR_DEFAULT_ORDER.filter(item => item !== 'splitKeyboard').reverse();
  options.set('remote-control-toolbar-order', saved.join(','));
  const restored = p.readToolbarOrder('remote-control-toolbar-order', CONTROL_TOOLBAR_DEFAULT_ORDER);
  assert.deepEqual(Array.from(restored), saved.concat(['splitKeyboard']));
  p.controlToolbarOrder = restored;
  assert(p.getVisibleControlMenuItems().includes('splitKeyboard'));
  assert.equal(p.toolbarOrderLabel('splitKeyboard'), '上画面下键盘');
  assert.deepEqual(Array.from(menu.remoteControlMenuWidthLabels('view', ['splitKeyboard'], false)), ['上画面下键盘']);
  // Glass menu: labelled toggle in the first switch group with pan/edgePan.
  assert(widget.includes("case 'splitKeyboard': return '上画面下键盘';"));
  assert(widget.includes("case 'splitKeyboard': return this.state.splitKeyboard;"));
  assert(/isToggle\(key: string\): boolean \{\n\s+return \[[^\]]*'splitKeyboard'/.test(widget));
  assert(widget.includes("key === 'edgePan' || key === 'splitKeyboard'), (key: string) => {"));
  const tsv = read('tools/i18n-en.tsv').split('\n');
  assert(tsv.includes('上画面下键盘\tPicture above keyboard'));
});

// covers: TC-002
test('TC-002 switching on opens the IME immediately in split layout and is saved locally', () => {
  const p = page();
  p.handleGlassMenuAction('splitKeyboard');
  assert.deepEqual(setOptionCalls, [['remote-split-keyboard', '1']]);
  assert.deepEqual(p.calls.menu, ['']);
  assert.equal(p.calls.open, 1);
  assert.equal(p.showKeyboardPanel, true);
  assert.equal(p.isSplitKeyboardActive(), true);
  p.controlMenu = 'view';
  assert.equal(p.getGlassMenuState().splitKeyboard, true);
  const log = logs.map(entry => entry[1]).find(message => message.startsWith('split-keyboard enabled='));
  assert.equal(log, 'split-keyboard enabled=1 keyboard_open=0');
  assert(logs.every(entry => !entry[1].includes('keyboardInput=')));
  // Already open: switching on changes the layout without reopening the IME.
  const q = page(); q.openRemoteKeyboard(); q.calls.open = 0;
  q.setSplitKeyboardEnabled(true);
  assert.equal(q.calls.open, 0); assert.equal(q.isSplitKeyboardActive(), true);
  assert.equal(q.getRemoteCanvasHeight(), '100%');
  // Existing gates in openRemoteKeyboard still apply (not connected: no capture).
  const r = page({ connectionStatus: 0 }); r.setSplitKeyboardEnabled(true);
  assert.equal(r.showKeyboardPanel, false); assert.equal(r.splitKeyboardEnabled, true);
});

// covers: TC-003
test('TC-003 switching off closes the IME and restores the full picture', () => {
  const p = page();
  p.setSplitKeyboardEnabled(true); setOptionCalls.length = 0;
  p.controlMenu = 'view'; // user reopens 控 → 画面
  p.handleGlassMenuAction('splitKeyboard');
  assert.deepEqual(setOptionCalls, [['remote-split-keyboard', '0']]);
  assert.equal(p.calls.close, 1);
  assert.equal(p.showKeyboardPanel, false);
  assert.equal(p.getRemoteCanvasHeight(), '100%');
  assert.equal(p.isSplitKeyboardActive(), false);
  // Switch on, IME already hidden: switching off only saves the option, no close call.
  const q = page();
  q.setSplitKeyboardEnabled(true);
  q.toggleRemoteKeyboard(); // user hides the IME with the keyboard button
  assert.equal(q.showKeyboardPanel, false);
  setOptionCalls.length = 0; q.calls.close = 0;
  q.controlMenu = 'view';
  q.handleGlassMenuAction('splitKeyboard');
  assert.deepEqual(setOptionCalls, [['remote-split-keyboard', '0']]);
  assert.equal(q.calls.close, 0);
  assert.equal(q.splitKeyboardEnabled, false);
  q.controlMenu = 'view';
  assert.equal(q.getGlassMenuState().splitKeyboard, false);
  assert.equal(q.showKeyboardPanel, false);
  assert.equal(q.getRemoteCanvasHeight(), '100%');
});

// covers: TC-004
test('TC-004 split line follows a horizontal crease, else half; a taller IME wins', () => {
  const windowRect = { left: 0, top: 0, width: 1600, height: 2000 };
  const cases = [
    { name: 'horizontal crease in window', rects: [{ left: 0, top: 900, width: 1600, height: 40 }], line: 450 },
    { name: 'vertical crease', rects: [{ left: 780, top: 0, width: 40, height: 2000 }], line: 500 },
    { name: 'no crease', rects: [], line: 500 },
    { name: 'query failure', rects: [], fail: true, line: 500 },
    { name: 'horizontal crease outside window', rects: [{ left: 0, top: 2100, width: 1600, height: 40 }], line: 500 },
  ];
  for (const item of cases) {
    const top = layout.findHorizontalCreaseTopPx(windowRect, item.rects);
    near(layout.splitKeyboardLineVp(top, 0, 2, 0, 1000), item.line);
    fold.creaseRects = item.rects; fold.fail = !!item.fail;
    const p = page({ splitKeyboardEnabled: true });
    p.openRemoteKeyboard();
    near(p.splitKeyboardLineVp, item.line);
    for (const [inset, expected] of [[300, item.line], [600, 400]]) {
      p.controlMenuKeyboardInset = inset;
      p.pageHeight = 1000 - inset; // RESIZE mode shrinks the page, the snapshot does not.
      near(layout.splitKeyboardViewportHeight(item.line, 1000, inset), expected);
      near(p.getSplitKeyboardViewportHeight(), expected, 1e-7);
      // The black viewport itself reaches the IME top, below the picture area.
      near(p.getKeyboardViewportMaxHeight(), 1000 - inset, 1e-7);
    }
  }
  // A narrow horizontal strip is not a crease dividing the window.
  assert.equal(layout.findHorizontalCreaseTopPx(windowRect, [{ left: 0, top: 900, width: 600, height: 40 }]), -1);
  // The crease is queried once per open, not on every layout pass.
  let queries = 0;
  const original = context.display.getCurrentFoldCreaseRegion;
  context.display.getCurrentFoldCreaseRegion = () => { queries++; return { displayId: 0, creaseRects: [] }; };
  const p = page({ splitKeyboardEnabled: true }); p.openRemoteKeyboard();
  for (let i = 0; i < 5; i++) { p.getKeyboardViewportMaxHeight(); p.getRemoteCanvasHeight(); p.getKeyboardAvoidance(); }
  assert.equal(queries, 1);
  context.display.getCurrentFoldCreaseRegion = original;
});

// Split fixture from TC-005: 800×900vp page, IME 380vp, line 450vp, IME-top viewport 520vp.
function splitPage(overrides = {}) {
  const p = page(Object.assign({ splitKeyboardEnabled: true, pageHeight: 900, componentHeight: 900,
    qualityViewportHeight: 900 }, overrides));
  p.openRemoteKeyboard();
  p.controlMenuKeyboardInset = 380; p.pageHeight = 520; p.qualityViewportHeight = 520;
  p.onAreaChangeCallback({ width: 800, height: 900 }, { width: 800, height: 520 });
  return p;
}

// covers: TC-005
test('TC-005 split picture is top-aligned above the line without shift; taps map accurately', () => {
  const p = splitPage();
  near(p.splitKeyboardLineVp, 450);
  assert.notEqual(p.keyboardViewportHeight, 520, 'pre-IME snapshot differs from the visible viewport');
  assert.equal(p.componentHeight, 520);
  const avoidance = p.getKeyboardAvoidance();
  assert.equal(avoidance.shiftY, 0); assert.equal(avoidance.reason, 'split_keyboard');
  assert.equal(p.getKeyboardCanvasShiftY(), 0);
  // The viewport reaches the IME top; only the picture is limited to the line.
  assert.equal(p.getKeyboardViewportMaxHeight(), 520);
  assert.equal(p.getRemoteCanvasHeight(), '100%');
  near(p.getDisplayFitHeight(), 450);
  assert.equal(p.getDisplayTop(), 0);
  assert.equal(p.getDisplayLeft(), 0);
  near(p.getDisplayWidth(), 800); near(p.getDisplayHeight(), 450);
  assert.equal(p.getRemoteViewportAlignment(), 'Alignment.Top');
  assert(/buildRemoteViewport\(\) \{\n\s+Stack\(\{ alignContent: this\.getRemoteViewportAlignment\(\) \}\)/.test(source));
  // Display switch snapshots use the same placement as the live surface.
  assert(/buildDisplaySwitchImage\([^)]*\) \{\n\s+Stack\(\{ alignContent: Alignment\.Center \}\) \{\n\s+\/\/[^\n]*\n\s+Stack\(\{ alignContent: this\.getRemoteViewportAlignment\(\) \}\)/.test(source));
  const centre = p.visualPointToRemote(400, 225);
  near(centre.x, 960, 1); near(centre.y, 540, 1);
  const visual = p.remotePointToVisual(centre.x, centre.y);
  near(visual.x, 400, 1); near(visual.y, 225, 1);
  const back = p.visualPointToRemote(visual.x, visual.y);
  near(back.x, centre.x, 1); near(back.y, centre.y, 1);
  // Height-limited 4:3 desktop: fitted to the 450vp line, not the 520vp viewport.
  const tall = splitPage({ remoteWidth: 1600, remoteHeight: 1200 });
  near(tall.getDisplayHeight(), 450); near(tall.getDisplayWidth(), 600);
  near(tall.getDisplayLeft(), 100); assert.equal(tall.getDisplayTop(), 0);
  const corner = tall.visualPointToRemote(100 + 600 - 0.5, 450 - 0.5);
  near(corner.x, 1599, 1); near(corner.y, 1199, 1);
  // A different line (IME taller than half) still fits and stays on top.
  const q = splitPage(); q.controlMenuKeyboardInset = 600; q.pageHeight = 300;
  q.onAreaChangeCallback({ width: 800, height: 520 }, { width: 800, height: 300 });
  assert.equal(q.getKeyboardViewportMaxHeight(), 300); assert.equal(q.getDisplayTop(), 0);
  near(q.getDisplayHeight(), 300); near(q.getDisplayWidth(), 300 * 1920 / 1080);
  // Switching off/closing restores the centred, non-split geometry.
  const r = page({ pageHeight: 900, componentHeight: 900 });
  r.remoteHeight = 1080; r.remoteWidth = 1920;
  assert.equal(r.getDisplayFitHeight(), 900); near(r.getDisplayTop(), (900 - 450) / 2);
  assert.equal(r.getRemoteViewportAlignment(), 'Alignment.Center');
  // Viewport bindings in the build tree use the effective (split-aware) height.
  assert(source.includes('.constraintSize({ minHeight: this.getEffectiveKeyboardViewportHeight() })'));
  assert.equal((source.match(/this\.getEffectiveKeyboardViewportHeight\(\) > 0 \?\n\s+this\.getEffectiveKeyboardViewportHeight\(\) : newValue\.height as number;/g) || []).length, 2);
  p.traceRemoteKeyboardState('test');
  const trace = logs.findLast(entry => entry[1].startsWith('state reason=test'))[1];
  assert(trace.includes('split_keyboard=1') && trace.includes('split_line=450') && trace.includes('avoid_reason=split_keyboard'), trace);
});

// covers: TC-005 (zoom/pan clamp follows the top-aligned picture)
test('TC-005 zoomed split picture keeps its top edge reachable and no extra black below', () => {
  const p = splitPage();
  p.applyZoomAt(400, 225, 2);
  const top = () => p.remotePointToVisual(0, 0).y;
  const bottom = () => p.remotePointToVisual(0, p.remoteHeight).y;
  p.offsetY = 1e6; p.clampViewportOffset(); near(top(), 0);
  p.offsetY = -1e6; p.clampViewportOffset(); near(bottom(), p.componentHeight);
  assert(p.canPanViewport());
  // Zoomed but still shorter than the viewport: stays on the top edge.
  p.applyZoomAt(400, 225, 1.1); p.offsetY = -40; p.clampViewportOffset(); near(top(), 0);
  p.applyZoomAt(400, 225, 1); assert.equal(p.offsetY, 0); near(top(), 0);
  // Outside the split layout the symmetric clamp is untouched.
  const q = page({ componentHeight: 900 });
  assert.equal(q.getVerticalPanBias(2), 0);
  q.zoomScale = 2; q.offsetY = 1e6; q.clampViewportOffset(); near(q.offsetY, (450 * 2 - 900) / 2);
});

// covers: TC-010
test('TC-010 blank below the split picture is black viewport and a trackpad in mouse mode', () => {
  const p = splitPage();
  const displayBottom = p.getDisplayTop() + p.getDisplayHeight();
  near(displayBottom, 450);
  // 450–520vp lies inside the remote viewport, which reaches the IME top.
  assert(p.getKeyboardViewportMaxHeight() >= 520 && p.componentHeight === 520 && displayBottom < p.componentHeight);
  const viewport = method('buildRemoteViewport');
  assert(/\n    \.width\('100%'\)\n    \.height\('100%'\)\n    \.clip\(true\)\n    \.backgroundColor\('#090D14'\)/.test(viewport));
  const canvas = method('buildRemoteViewportWithQualityMonitor');
  assert(/\.height\(this\.getRemoteCanvasHeight\(\)\)[\s\S]*?\.backgroundColor\('#090D14'\)/.test(canvas));
  assert.equal(p.getRemoteCanvasHeight(), '100%');
  // Mouse mode: capture covers the whole viewport; touch mode: only the picture.
  assert(viewport.includes(".width(this.inputMode === INPUT_MODE_MOUSE ? '100%' : this.getDisplayWidth())"));
  assert(viewport.includes(".height(this.inputMode === INPUT_MODE_MOUSE ? '100%' : this.getDisplayHeight())"));
  // Touch-mode capture is picture-sized and top-aligned, so it ends at 450vp.
  assert.equal(p.getRemoteViewportAlignment(), 'Alignment.Top');
  // Trackpad swipe of 40vp to the right in the blank strip and on the picture.
  const swipe = y => {
    const q = splitPage({ lastAbsX: 960, lastAbsY: 540, pointerInitialized: true });
    mouseEvents.length = 0;
    const at = x => ({ touches: [{ x, y, windowX: x, windowY: y }] });
    q.handleTouchpadTouch(Object.assign({ type: 0 }, at(300)));
    q.handleTouchpadTouch(Object.assign({ type: 1 }, at(340)));
    return mouseEvents.slice();
  };
  const blank = swipe(490), picture = swipe(225);
  assert.equal(blank.length, 1);
  assert.deepEqual(blank, picture);
  near(blank[0][0], 960 + 40 * 1920 / 800 * 1.25); near(blank[0][1], 540);
  assert.equal(blank[0][2], 0);
});

// covers: TC-006
test('TC-006 closing the IME keeps the switch on; reopening returns to split layout', () => {
  for (const via of ['button', 'ime']) {
    const p = page();
    p.setSplitKeyboardEnabled(true); setOptionCalls.length = 0;
    if (via === 'button') p.toggleRemoteKeyboard();
    else {
      p.handleRemoteKeyboardHeightChange(600);
      p.handleRemoteKeyboardHeightChange(0);
      timers.at(-1)();
    }
    assert.equal(p.showKeyboardPanel, false, via);
    assert.equal(p.getRemoteCanvasHeight(), '100%');
    assert.equal(p.isSplitKeyboardActive(), false);
    assert.equal(p.splitKeyboardEnabled, true);
    assert(!setOptionCalls.some(call => call[1] === '0'), via);
    p.toggleRemoteKeyboard();
    assert.equal(p.showKeyboardPanel, true);
    assert.equal(p.isSplitKeyboardActive(), true);
  }
});

// covers: TC-007
test('TC-007 saved switch survives a new session but does not open the IME by itself', () => {
  options.set('remote-split-keyboard', '1');
  const p = page();
  p.loadSplitKeyboardPreference();
  assert.equal(p.splitKeyboardEnabled, true);
  assert.equal(p.calls.open, 0); assert.equal(p.showKeyboardPanel, false);
  assert.equal(p.getGlassMenuState().splitKeyboard, true);
  assert(/this\.loadEdgeAutoPanPreference\(\);\n\s+this\.loadSplitKeyboardPreference\(\);/.test(method('aboutToAppear')));
  assert(!method('loadSplitKeyboardPreference').includes('openRemoteKeyboard'));
  p.toggleRemoteKeyboard();
  assert.equal(p.isSplitKeyboardActive(), true);
  for (const value of ['', '0']) {
    options.set('remote-split-keyboard', value);
    const q = page(); q.loadSplitKeyboardPreference(); assert.equal(q.splitKeyboardEnabled, false);
  }
});

// covers: TC-001 (English label shipped in the generated catalog)
test('TC-001 English catalog contains Picture above keyboard', () => {
  const catalog = load('entry/src/main/ets/utils/I18nCatalog.ets');
  assert.equal(catalog.ENGLISH['上画面下键盘'], 'Picture above keyboard',
    'I18nCatalog.ets not regenerated: run node tools/build-i18n-catalog.cjs');
});
console.log(`split keyboard: ${passed} scenario groups passed`);
