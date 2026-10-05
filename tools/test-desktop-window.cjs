'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replace(/\r\n/g, '\n');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const geometry = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteDesktopView.ets')), geometry);
const { desktopFitScale, desktopScalePercent, desktopZoomScale, desktopWindowFrame } = geometry.exports;
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const near = (a, b) => assert(Math.abs(a - b) < 1e-7, `${a} vs ${b}`);
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
const windowEnums = {
  WindowEventType: { WINDOW_ACTIVE: 2, WINDOW_INACTIVE: 3, WINDOW_HIDDEN: 4, WINDOW_SHOWN: 1 },
  WindowStatusType: { FLOATING: 4, MAXIMIZE: 2, FULL_SCREEN: 1 },
  MaximizePresentation: { ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER: 3 }
};
let count = 0;
async function test(name, run) { await run(); count++; console.log('PASS ' + name); }
function pageHarness(extra = {}, names = []) {
  const timers = new Map(), calls = [], logs = []; let nextTimer = 0;
  const basic = ['getDesktopFitScale', 'refreshDesktopDensity', 'syncDesktopViewScale', 'selectDesktopViewMode',
    'getDesktopDisplayedPercent', 'setDesktopCustomPercent', 'getDisplayWidth', 'getDisplayHeight',
    'getDisplayLeft', 'getDisplayTop', 'applyZoomAt', 'clampViewportOffset', 'getHorizontalPanLimit',
    'getVerticalPanLimit', 'getPanLimit', 'clampHorizontalOffset', 'clampVerticalOffset', 'clampOffsetToLimit',
    'adjustZoom', 'handleDesktopWindowEvent', 'cancelPcToolbarAutoCollapse', 'schedulePcToolbarAutoCollapse',
    'togglePcToolbarPinned', 'startDesktopWindowTracking', 'stopDesktopWindowTracking'];
  const context = { exports: {}, ...geometry.exports, window: windowEnums,
    RustDeskNapi: { appendDiagnosticLog: (...a) => logs.push(a), takeNativeInputEvents: () => { calls.push('queue_drain'); return []; },
      getOption: () => '', setOption: (...a) => calls.push(['option', ...a]) },
    ConnectionService: { releaseModifiers: () => calls.push('modifiers_release') },
    RemoteDisplayPolicy: { getMainWindow: () => extra.main },
    setTimeout(fn) { timers.set(++nextTimer, fn); return nextTimer; }, clearTimeout(id) { timers.delete(id); }
  };
  vm.runInNewContext(ts.transpile('class Page {' + [...new Set([...basic, ...names])].map(method).join('\n') + '} exports.Page = Page;'), context);
  const page = Object.assign(new context.exports.Page(), {
    remotePageVisible: true, isLeavingAfterDisconnect: false, isPcDevice: () => true,
    remoteWidth: 1920, remoteHeight: 1080, componentWidth: 1000, componentHeight: 600,
    desktopViewMode: 'adaptive', desktopCustomPercent: 100, desktopDensity: 1, zoomScale: 1,
    offsetX: 0, offsetY: 0, pcToolbarPinned: false, remoteToolbarCollapsed: false,
    desktopWindowActive: true, desktopWindowRequestId: 0, pcToolbarCollapseTimer: -1,
    controlMenu: '', immersiveWindow: true, isFullScreen: false,
    getUIContext: () => ({ vp2px: n => n }),
    cancelActiveTouchGesture: () => calls.push('gestures_release'), stopEdgeAutoPan() {},
    syncVirtualMouseToCurrentPointer() {}, canPanViewport: () => true, setPanMode() {},
    cancelRemoteKeyboardRefocus: () => calls.push('refocus_cancel'), cancelPointerHoverExit() {},
    releaseVirtualMouseButtons: () => calls.push('virtual_release'),
    releaseRemoteNavigationKeys: () => calls.push('navigation_release'),
    physicalMouseDeduplicator: { clear: () => calls.push('dedup_clear') },
    setSystemPointerHidden: v => calls.push(['system_pointer_hidden', v]),
    requestRemoteInputFocus: () => calls.push('request_focus'),
    setFloatingPanelCollapsed(_keyboard, collapsed) { this.remoteToolbarCollapsed = collapsed; calls.push('collapse'); },
    ...extra
  });
  return { page, calls, logs, timers, fire() { const pending = [...timers.values()]; timers.clear(); pending.forEach(f => f()); } };
}
function policyHarness() {
  const calls = [], logs = []; let areaGate, resizeGate, moveFail = false, attached;
  let rect = { left: 50, top: 60, width: 1200, height: 760 };
  const main = { getWindowStatus: () => 4, getWindowProperties: () => ({ displayId: 1, windowRect: { ...rect } }),
    async resize(width, height) { calls.push(['resize', width, height]); if (resizeGate) await resizeGate.promise; rect = { ...rect, width, height }; },
    async moveWindowTo(left, top) { calls.push(['move', left, top]); if (moveFail) throw Error('move failure'); rect = { ...rect, left, top }; },
    getWindowDecorVisible: () => true, setWindowDecorVisible: b => calls.push(['decor', b]) };
  attached = main;
  const context = { exports: {}, window: windowEnums, deviceInfo: { deviceType: 'pc' }, desktopWindowFrame,
    display: { getDisplayByIdSync: id => { assert.equal(id, 1); return { densityPixels: 1,
      async getAvailableArea() { if (areaGate) await areaGate.promise; return { left: 0, top: 0, width: 1920, height: 1080 }; } }; } },
    RemoteDisplayPolicy: { getMainWindow: () => attached }, RustDeskNapi: { appendDiagnosticLog: (...a) => logs.push(a) } };
  vm.runInNewContext(ts.transpile(read('entry/src/main/ets/service/RemoteFullscreenPolicy.ets').replace(/^import .*\n/gm, '')), context);
  return { main, policy: context.exports.RemoteFullscreenPolicy, calls, logs,
    areaGate(g) { areaGate = g; }, resizeGate(g) { resizeGate = g; }, moveFail() { moveFail = true; },
    detach() { attached = undefined; } };
}
(async () => {
  await test('adaptive preserves aspect and fits portrait/landscape/DPI combinations', () => {
    for (const [w, h, rw, rh] of [[1000, 600, 1920, 1080], [600, 1000, 1920, 1080], [1000, 600, 1080, 1920]]) {
      const fit = desktopFitScale(w, h, rw, rh); near(rw * fit / (rh * fit), rw / rh);
      assert(rw * fit <= w + 0.001 && rh * fit <= h + 0.001);
      near(desktopZoomScale('adaptive', 200, fit, 2), 1);
    }
    assert.equal(desktopFitScale(0, 0, NaN, 1), 1);
  });
  await test('original and custom keep physical pixel scale when viewport or display density changes', () => {
    for (const density of [1, 1.5, 2]) for (const width of [600, 1000, 2000]) {
      const fit = desktopFitScale(width, 800, 1920, 1080);
      near(fit * desktopZoomScale('original', 75, fit, density) * density, 1);
      near(fit * desktopZoomScale('custom', 175, fit, density) * density, 1.75);
    }
    assert.equal(desktopScalePercent(NaN), 100); assert.equal(desktopScalePercent(5), 25); assert.equal(desktopScalePercent(500), 300);
  });
  await test('window fitting includes chrome and stays in shifted/negative display work areas', () => {
    for (const available of [{ left: 0, top: 40, width: 1600, height: 900 }, { left: -1920, top: 0, width: 1920, height: 1080 }]) {
      const f = desktopWindowFrame(1920, 1080, 120, 60, { left: 50, top: 20, width: 1000, height: 800 }, available);
      assert(f); assert(f.left >= available.left && f.top >= available.top);
      assert(f.left + f.width <= available.left + available.width);
      assert(f.top + f.height <= available.top + available.height);
      assert(Math.abs((f.width - 120) / (f.height - 60) - 1920 / 1080) < 0.005);
    }
    assert.equal(desktopWindowFrame(0, 100, 0, 0, { left: 0, top: 0, width: 500, height: 500 }, { left: 0, top: 0, width: 900, height: 900 }), undefined);
  });
  await test('page mode switching resets pan; subsequent resize retains chosen percentage', () => {
    const { page: p } = pageHarness({ offsetX: 20, offsetY: 30 });
    p.selectDesktopViewMode('original'); near(p.getDesktopDisplayedPercent(), 100); near(p.offsetX, 0); near(p.offsetY, 0);
    p.componentWidth = 700; p.syncDesktopViewScale(); near(p.getDesktopDisplayedPercent(), 100);
    p.setDesktopCustomPercent(150); p.componentWidth = 1300; p.syncDesktopViewScale(); near(p.getDesktopDisplayedPercent(), 150);
    p.selectDesktopViewMode('adaptive'); near(p.zoomScale, 1);
  });
  await test('custom zoom retains the remote point at a panned view center and explicit pointer anchor', () => {
    const { page: p } = pageHarness(); p.selectDesktopViewMode('original'); p.offsetX = -50; p.offsetY = 20;
    const old = { z: p.zoomScale, x: p.offsetX, y: p.offsetY };
    p.setDesktopCustomPercent(150);
    near(-p.offsetX / p.zoomScale, -old.x / old.z); near(-p.offsetY / p.zoomScale, -old.y / old.z);
    const rx = 1200, ry = 600;
    const before = { x: 500 + (rx * p.getDisplayWidth() / p.remoteWidth + p.getDisplayLeft() - 500) * p.zoomScale + p.offsetX,
      y: 300 + (ry * p.getDisplayHeight() / p.remoteHeight + p.getDisplayTop() - 300) * p.zoomScale + p.offsetY };
    p.setDesktopCustomPercent(175, rx, ry);
    near(500 + (rx * p.getDisplayWidth() / p.remoteWidth + p.getDisplayLeft() - 500) * p.zoomScale + p.offsetX, before.x);
    near(300 + (ry * p.getDisplayHeight() / p.remoteHeight + p.getDisplayTop() - 300) * p.zoomScale + p.offsetY, before.y);
  });
  await test('handheld scaling stays on the existing relative-fit path', () => {
    const { page: p } = pageHarness({ isPcDevice: () => false, zoomScale: 2 });
    p.syncDesktopViewScale(); near(p.zoomScale, 2);
    p.selectDesktopViewMode('original'); assert.equal(p.desktopViewMode, 'adaptive');
    p.adjustZoom(0.25); near(p.zoomScale, 2.25);
  });
  await test('decoded-size reset retains PC original/custom mode, including identical-size screen transitions', () => {
    const h = pageHarness({ discardViewportPanFrame() {} }, ['resetViewportTransform']);
    h.page.selectDesktopViewMode('custom'); h.page.setDesktopCustomPercent(175);
    h.page.resetViewportTransform(); near(h.page.getDesktopDisplayedPercent(), 175);
    h.page.remoteWidth = 2560; h.page.remoteHeight = 1440; h.page.resetViewportTransform();
    near(h.page.getDesktopDisplayedPercent(), 175);
    h.page.selectDesktopViewMode('original'); h.page.resetViewportTransform(); near(h.page.getDesktopDisplayedPercent(), 100);
  });
  await test('inactive window releases keys, pointer and native queue; active only restores remote input focus', () => {
    const h = pageHarness({ pointerOverRemoteViewport: true, pointerCaptureFocused: true }); const p = h.page;
    p.handleDesktopWindowEvent(3); assert.equal(p.desktopWindowActive, false); assert.equal(p.pointerOverRemoteViewport, false);
    for (const release of ['virtual_release', 'gestures_release', 'navigation_release', 'modifiers_release', 'queue_drain']) assert(h.calls.includes(release));
    assert(h.calls.some(c => Array.isArray(c) && c[0] === 'system_pointer_hidden' && c[1] === false));
    p.handleDesktopWindowEvent(4); p.handleDesktopWindowEvent(2);
    assert.equal(p.desktopWindowActive, true); assert(h.calls.includes('request_focus'));
    h.calls.length = 0; p.pointerOverRemoteViewport = false; p.pointerCaptureFocused = false;
    p.handleDesktopWindowEvent(3); p.handleDesktopWindowEvent(2); assert(!h.calls.includes('request_focus'));
  });
  await test('all forwarding paths and global hardware polling refuse inactive-window input', () => {
    const names = ['syncHardwareKeyState', 'handleNativeMouseInput', 'handleNativeKeyInput', 'handleRemoteMouse',
      'handleRemoteKey', 'handleRemoteAxis', 'handleRemoteTouch', 'handleRemoteClickFallback', 'requestRemoteInputFocus'];
    const h = pageHarness({ desktopWindowActive: false }, names);
    for (const name of names) assert.doesNotThrow(() => h.page[name]({}));
    assert.equal(h.page.handleRemoteKey({}), false);
  });
  await test('reactivation keeps the first newly queued mouse press instead of discarding it', () => {
    const h = pageHarness({ desktopWindowActive: false }); h.page.handleDesktopWindowEvent(2);
    assert.equal(h.page.desktopWindowActive, true); assert(!h.calls.includes('queue_drain'));
  });
  await test('phone window events do not release remote input', () => {
    const h = pageHarness({ isPcDevice: () => false }); h.page.handleDesktopWindowEvent(3); assert.deepEqual(h.calls, []);
  });
  await test('PC focus listener registers once and page cleanup removes the exact callback', () => {
    const calls = []; const main = { on: (...a) => calls.push(['on', ...a]), off: (...a) => calls.push(['off', ...a]) };
    const h = pageHarness({ main }); h.page.startDesktopWindowTracking(); h.page.stopDesktopWindowTracking();
    assert.equal(calls[0][0], 'on'); assert.equal(calls[1][0], 'off'); assert.equal(calls[0][2], calls[1][2]);
    assert.equal(h.page.desktopWindow, undefined);
  });
  await test('auto-collapse works only for unpinned floating PC controls, never during drag/menus', () => {
    const h = pageHarness({ pointerOverRemoteViewport: true }); h.page.schedulePcToolbarAutoCollapse(); h.fire();
    assert.equal(h.page.remoteToolbarCollapsed, true);
    for (const extra of [{ pcToolbarPinned: true }, { controlMenu: 'view' }, { pointerOverRemoteViewport: false },
      { immersiveWindow: false, isFullScreen: false }, { isPcDevice: () => false }, { leftButtonHeld: true }]) {
      const h = pageHarness({ pointerOverRemoteViewport: true, ...extra }); h.page.schedulePcToolbarAutoCollapse(); h.fire();
      assert.equal(h.page.remoteToolbarCollapsed, false);
    }
  });
  await test('manual window adjustment calls resize and move with bounded geometry', async () => {
    const h = policyHarness(); assert.equal(await h.policy.fitRemoteWindow(1920, 1080, 1080, 700, () => true), true);
    assert.equal(h.calls[0][0], 'resize'); assert.equal(h.calls[1][0], 'move'); assert(h.logs.some(l => l[1].includes('fit_applied')));
  });
  await test('leaving page while work-area query is pending never resizes another session', async () => {
    const h = policyHarness(), gate = deferred(); let current = true; h.areaGate(gate);
    const op = h.policy.fitRemoteWindow(1920, 1080, 1080, 700, () => current); await settle(); current = false; gate.resolve();
    assert.equal(await op, false); assert.deepEqual(h.calls, []);
  });
  await test('moving failure rolls size back and the shared window queue remains usable', async () => {
    const h = policyHarness(); h.moveFail(); await assert.rejects(h.policy.fitRemoteWindow(1920, 1080, 1080, 700, () => true));
    assert.deepEqual(h.calls.at(-1), ['resize', 1200, 760]);
    await h.policy.setBorderless(true); assert.deepEqual(h.calls.at(-1), ['decor', false]);
  });
  await test('maximized or fullscreen window cannot be silently restored/resized by adjustment', async () => {
    for (const status of [1, 2]) { const h = policyHarness(); h.main.getWindowStatus = () => status;
      await assert.rejects(h.policy.fitRemoteWindow(1920, 1080, 1080, 700, () => true)); assert.deepEqual(h.calls, []); }
  });
  await test('resize and title cleanup use one queue, including a slow system resize', async () => {
    const h = policyHarness(), gate = deferred(); h.resizeGate(gate);
    const fit = h.policy.fitRemoteWindow(1920, 1080, 1080, 700, () => true), decor = h.policy.setBorderless(true);
    await settle(); assert.equal(h.calls.length, 1); gate.resolve(); await Promise.all([fit, decor]);
    assert.deepEqual(h.calls.map(c => c[0]), ['resize', 'move', 'decor']);
  });
  console.log(`TOTAL=${count} FAILED=0 (production logic with mocked window SDK; device acceptance pending)`);
})().catch(e => { console.error(e); process.exitCode = 1; });
