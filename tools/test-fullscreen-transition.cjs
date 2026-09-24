const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const policySource = read('entry/src/main/ets/service/RemoteFullscreenPolicy.ets');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const settle = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); };
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
};
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }
function pageHarness(overrides = {}) {
  const timers = new Map(), calls = [], logs = [], windows = [];
  let timerId = 0;
  const context = vm.createContext({
    ConnectionStatus: { CONNECTED: 2 },
    RustDeskNapi: {
      appendDiagnosticLog: (category, message) => logs.push([category, message]),
      prepareSurfaceRebind: () => { calls.push('prepare'); return 0; },
      rebindSurface: id => { calls.push(['rebind', id]); return 0; },
      setSurfaceId: id => { calls.push(['bind', id]); return 0; },
      refreshVideo: () => calls.push('refresh')
    },
    RemoteFullscreenPolicy: { apply: (enabled, rollback) => {
      const d = deferred(); windows.push({ enabled, rollback, ...d }); return d.promise;
    } },
    setTimeout: (fn, ms) => { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
    clearTimeout: id => timers.delete(id)
  });
  const names = ['requestFullscreen', 'enterFullScreen', 'exitFullScreen', 'restoreFullscreenOnLeave',
    'bindSurfaceIfReady', 'scheduleSurfaceRebindIfSizeChanged', 'rebindSurfaceAfterLayoutChange',
    'readCurrentSurfaceId', 'getDisplayWidth', 'getDisplayHeight', 'requestVideoRefreshAfterSurfaceRebind'];
  vm.runInContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} globalThis.Page = Page;'), context);
  let target = 'surface-a';
  const page = Object.assign(new context.Page(), {
    componentWidth: 1318, componentHeight: 800, remoteWidth: 2560, remoteHeight: 1440,
    surfaceId: target, lastBoundSurfaceId: target, lastSurfaceWidth: 1318, lastSurfaceHeight: 741.375,
    lastLayoutViewportWidth: 1318, lastLayoutViewportHeight: 800,
    surfaceRebindTimer: -1, surfaceRebindForced: false, connectionStatus: 2,
    isFullScreen: false, fullscreenTransitioning: false, fullscreenRequestId: 0,
    remoteToolbarCollapsed: false, remoteToolbarOffsetX: 0, remoteToolbarOffsetY: 0,
    remotePageVisible: true, isLeavingAfterDisconnect: false,
    xComponentController: { getXComponentSurfaceId: () => target },
    showFileToast: message => calls.push(['toast', message]),
    restoreKeyboardAvoidMode() {}, closeRemoteKeyboard() {}, isHandheldDevice() { return false; }
  }, overrides);
  const runTimer = ms => {
    const entry = [...timers].find(([, t]) => t.ms === ms);
    assert(entry, 'expected timer ' + ms); timers.delete(entry[0]); entry[1].fn();
  };
  return { page, timers, calls, logs, windows, runTimer, target: id => { target = id; } };
}
function policyHarness(deviceType = 'phone', initialStatus = 4) {
  const calls = [], logs = [];
  let layoutGate, barGate, maximizeGate, failLayout = 0, failBars = 0, failMaximize = 0;
  let status = initialStatus;
  const main = {
    getWindowStatus: () => status,
    getWindowProperties: () => ({ isLayoutFullScreen: false, isFullScreen: false,
      windowRect: { width: 2800, height: 1840 } }),
    async maximize(presentation) {
      calls.push(['maximize', presentation]);
      if (failMaximize-- > 0) throw Object.assign(new Error('maximize'), { code: 1300003 });
      if (maximizeGate) { const gate = maximizeGate; maximizeGate = undefined; await gate.promise; }
      status = presentation === 1 ? 2 : 1;
    },
    async recover() { calls.push(['recover']); status = 4; },
    async setWindowLayoutFullScreen(enabled) {
      calls.push(['layout', enabled]);
      if (failLayout-- > 0) throw Object.assign(new Error('layout'), { code: 1300002 });
      if (layoutGate) { const gate = layoutGate; layoutGate = undefined; await gate.promise; }
    },
    async setWindowSystemBarEnable(bars) {
      calls.push(['bars', Array.from(bars)]);
      if (failBars-- > 0) throw Object.assign(new Error('bars'), { code: 1300003 });
      if (barGate) { const gate = barGate; barGate = undefined; await gate.promise; }
    }
  };
  let attached = main;
  const context = vm.createContext({ exports: {},
    deviceInfo: { deviceType },
    window: { WindowStatusType: { FULL_SCREEN: 1, MAXIMIZE: 2, FLOATING: 4 },
      MaximizePresentation: { ENTER_IMMERSIVE: 2, ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER: 3,
        EXIT_IMMERSIVE: 1 } },
    RemoteDisplayPolicy: { getMainWindow: () => attached },
    RustDeskNapi: { appendDiagnosticLog: (c, m) => logs.push([c, m]) }
  });
  vm.runInContext(ts.transpile(policySource.replace(/^import .*;\r?\n/gm, '')), context);
  return { policy: context.exports.RemoteFullscreenPolicy, calls, logs,
    failLayout: n => { failLayout = n; }, failBars: n => { failBars = n; },
    failMaximize: n => { failMaximize = n; },
    gateLayout: d => { layoutGate = d; }, gateBars: d => { barGate = d; },
    gateMaximize: d => { maximizeGate = d; }, status: () => status, setStatus: value => { status = value; },
    detach: () => { attached = undefined; } };
}

(async () => {
  await test('fullscreen viewport has one stable ancestor path; toolbar is a sibling', () => {
    const screen = method('buildRemoteScreen');
    assert.equal((screen.match(/buildRemoteViewportWithQualityMonitor\(\)/g) || []).length, 1);
    assert(screen.indexOf('buildRemoteViewportWithQualityMonitor()') < screen.indexOf('if ('));
    assert(!screen.includes('surfaceEpoch'));
    assert(method('buildFullscreenButton').includes("Button(this.fullscreenTransitioning ?"));
    assert(method('buildFullscreenButton').includes('.backgroundColor(this.isFullScreen ?'));
    assert(method('buildControlToolbarItem').includes('this.buildFullscreenButton('));
    assert(!method('buildControlToolbarItem').includes("buildToolbarButton(this.isFullScreen"));
  });
  await test('PC controls float only in fullscreen and expand downward from the top right', () => {
    const screen = method('buildRemoteScreen');
    const floating = method('buildFloatingToolbar');
    const exitButton = method('buildPcFullscreenExitButton');
    assert(source.includes('this.isHandheldDevice() || this.isFullScreen || !this.isLargeLayout()'));
    assert(source.includes('this.isFullScreen && !this.isHandheldDevice()) {\n        this.buildPcFullscreenExitButton()'));
    assert(screen.includes('if (!this.isFullScreen && this.isLargeLayout() && !this.isHandheldDevice())'));
    assert(screen.includes('this.buildSideToolbar()'));
    assert(exitButton.includes("Button(this.fullscreenTransitioning ? '切换中…' : '退出全屏')"));
    assert(exitButton.includes('this.exitFullScreen()'));
    assert(exitButton.includes('this.pageWidth - 100'));
    assert(exitButton.includes('.zIndex(70)'));
    assert(floating.includes('this.isHandheldLandscape() || (this.isFullScreen && !this.isHandheldDevice())'));
    assert(method('getRemoteToolbarBaseX').includes('width - this.getRemoteToolbarCurrentWidth() - 108'));
    assert(method('getRemoteToolbarBaseY').includes('return 8'));
    assert(method('buildControlToolbarItem').includes("item === 'fullscreen'"));
  });
  await test('PC fullscreen floating controls leave an 8 px gap before fixed exit button', () => {
    const context = vm.createContext({});
    vm.runInContext(ts.transpile('class Layout {' + method('getRemoteToolbarBaseX') +
      '} globalThis.Layout = Layout;'), context);
    const layout = Object.assign(new context.Layout(), {
      pageWidth: 1920, isFullScreen: true, isHandheldDevice: () => false,
      isHandheldLandscape: () => false, getRemoteToolbarCurrentWidth: () => 56
    });
    assert.equal(layout.getRemoteToolbarBaseX() + 56 + 8, 1820);
    layout.getRemoteToolbarCurrentWidth = () => 104;
    assert.equal(layout.getRemoteToolbarBaseX() + 104 + 8, 1820);
  });
  await test('log reproduction: 800/866 height toggles never pause or rebind 1318x741 video', () => {
    const h = pageHarness();
    for (let i = 0; i < 20; i++) {
      h.page.componentHeight = i % 2 ? 800 : 866;
      h.page.scheduleSurfaceRebindIfSizeChanged();
      assert(Math.abs(h.page.getDisplayHeight() - 741.375) < 1e-6);
    }
    assert.deepEqual(h.calls, []); assert.equal(h.timers.size, 0);
    assert.equal(h.logs.length, 20);
  });
  await test('real rotation changes surface size and coalesces to one safe rebind', () => {
    const h = pageHarness(); h.page.componentWidth = 800; h.page.componentHeight = 1318;
    for (let i = 0; i < 8; i++) h.page.scheduleSurfaceRebindIfSizeChanged();
    assert.deepEqual(h.calls, ['prepare']); assert.equal(h.timers.size, 1);
    h.runTimer(180);
    assert.deepEqual(h.calls.slice(0, 3), ['prepare', ['rebind', 'surface-a'], 'refresh']);
    assert.equal(h.page.lastSurfaceWidth, 800); assert.equal(h.page.lastSurfaceHeight, 450);
  });
  await test('surface target change rebinds even at identical dimensions', () => {
    const h = pageHarness(); h.target('surface-b'); h.page.scheduleSurfaceRebindIfSizeChanged(); h.runTimer(180);
    assert.equal(h.page.lastBoundSurfaceId, 'surface-b');
    assert.deepEqual(h.calls[1], ['rebind', 'surface-b']);
  });
  await test('onLoad of a replacement XComponent preserves old target until hardware rebind', () => {
    const h = pageHarness(); h.target('surface-b'); h.page.surfaceId = 'surface-b';
    h.page.bindSurfaceIfReady(); assert.equal(h.page.lastBoundSurfaceId, 'surface-a');
    assert.deepEqual(h.calls, ['prepare']); h.runTimer(180);
    assert.equal(h.page.lastBoundSurfaceId, 'surface-b');
    assert.deepEqual(h.calls[1], ['rebind', 'surface-b']);
  });
  await test('bind requests during pending resize do not resume the CPU writer early', () => {
    const h = pageHarness(); h.page.componentWidth = 900; h.page.scheduleSurfaceRebindIfSizeChanged();
    h.page.bindSurfaceIfReady(); assert.deepEqual(h.calls, ['prepare']); h.runTimer(180);
    assert.deepEqual(h.calls[1], ['rebind', 'surface-a']);
  });
  await test('explicit decoded-size recovery survives subsequent no-change events', () => {
    const h = pageHarness(); h.page.scheduleSurfaceRebindIfSizeChanged(true);
    h.page.componentHeight = 866; h.page.scheduleSurfaceRebindIfSizeChanged(); h.runTimer(180);
    assert.deepEqual(h.calls[1], ['rebind', 'surface-a']);
    assert.equal(h.page.surfaceRebindForced, false);
  });
  await test('resize settling to original surface resumes without decoder restart', () => {
    const h = pageHarness(); h.page.componentWidth = 1000; h.page.scheduleSurfaceRebindIfSizeChanged();
    h.page.componentWidth = 1318; h.page.scheduleSurfaceRebindIfSizeChanged(); h.runTimer(180);
    assert.deepEqual(h.calls, ['prepare', ['bind', 'surface-a']]);
    const native = read('entry/src/main/cpp/core/video_render.cpp');
    const unchanged = native.slice(native.indexOf('if (unchanged &&'), native.indexOf('if (!surfaceId.empty())', native.indexOf('if (unchanged &&')));
    assert(unchanged.includes('XComponentRender::instance().setSurface(surfaceId)'));
    assert(!unchanged.includes('release'));
    const xc = read('entry/src/main/cpp/core/xcomponent_render.cpp');
    assert(/surfaceId == surfaceId_[\s\S]*?renderingPaused_\.store\(false\);\s*return;/.test(xc));
  });
  await test('unbound/disconnected surfaces do not start rebinds', () => {
    const h = pageHarness({ lastBoundSurfaceId: '' }); h.page.scheduleSurfaceRebindIfSizeChanged(true);
    assert.equal(h.calls.length, 0);
    h.page.lastBoundSurfaceId = 'surface-a'; h.page.connectionStatus = 3;
    h.page.scheduleSurfaceRebindIfSizeChanged(true); assert.equal(h.calls.length, 0);
  });
  await test('initial onLoad records actual fitted surface, not container dimensions', () => {
    const h = pageHarness({ lastBoundSurfaceId: '', lastSurfaceWidth: 0, lastSurfaceHeight: 0 });
    h.page.bindSurfaceIfReady();
    assert(Math.abs(h.page.lastSurfaceHeight - 741.375) < 1e-6);
    assert(!h.calls.includes('prepare'));
  });
  await test('button state changes immediately, duplicate clicks are ignored until completion', async () => {
    const h = pageHarness(); h.page.enterFullScreen(); h.page.exitFullScreen(); h.page.enterFullScreen();
    assert.equal(h.page.isFullScreen, true); assert.equal(h.page.fullscreenTransitioning, true);
    assert.equal(h.windows.length, 1); h.windows[0].resolve(); await settle();
    assert.equal(h.page.fullscreenTransitioning, false); assert.equal(h.page.isFullScreen, true);
    assert(h.logs.some(([, m]) => m.includes('switch_completed')));
    h.page.exitFullScreen(); assert.equal(h.page.isFullScreen, false);
    h.windows[1].resolve(); await settle(); assert.equal(h.page.fullscreenTransitioning, false);
  });
  await test('PC enters with collapsed control button and failed entry restores toolbar placement', async () => {
    const h = pageHarness({ remoteToolbarCollapsed: false, remoteToolbarOffsetX: 30,
      remoteToolbarOffsetY: -12 });
    h.page.enterFullScreen();
    assert.equal(h.page.remoteToolbarCollapsed, true);
    assert.equal(h.page.remoteToolbarOffsetX, 0);
    assert.equal(h.page.remoteToolbarOffsetY, 0);
    h.windows[0].reject(Object.assign(new Error('failure'), { code: 1300003 }));
    await settle();
    assert.equal(h.page.isFullScreen, false);
    assert.equal(h.page.remoteToolbarCollapsed, false);
    assert.equal(h.page.remoteToolbarOffsetX, 30);
    assert.equal(h.page.remoteToolbarOffsetY, -12);
  });
  await test('handheld fullscreen keeps existing floating control state', async () => {
    const h = pageHarness({ remoteToolbarCollapsed: false, remoteToolbarOffsetX: 12,
      remoteToolbarOffsetY: 16, isHandheldDevice() { return true; } });
    h.page.enterFullScreen();
    assert.equal(h.page.remoteToolbarCollapsed, false);
    assert.equal(h.page.remoteToolbarOffsetX, 12);
    assert.equal(h.page.remoteToolbarOffsetY, 16);
    h.windows[0].resolve(); await settle();
  });
  await test('enter and exit failures restore previous button state and show a tip', async () => {
    for (const previous of [false, true]) {
      const h = pageHarness({ isFullScreen: previous }); h.page.requestFullscreen(!previous);
      h.windows[0].reject(Object.assign(new Error('failure'), { code: 1300003 })); await settle();
      assert.equal(h.page.isFullScreen, previous); assert.equal(h.page.fullscreenTransitioning, false);
      assert(h.calls.some(c => c[0] === 'toast'));
      assert(h.logs.some(([, m]) => m.includes('switch_failed') && m.includes('1300003')));
    }
  });
  await test('leave during transition enqueues restoration and ignores late completion', async () => {
    const h = pageHarness(); h.page.enterFullScreen(); h.page.remotePageVisible = false;
    h.page.restoreFullscreenOnLeave(); h.page.restoreFullscreenOnLeave();
    assert.equal(h.windows.length, 2); assert.equal(h.windows[1].enabled, false);
    assert.equal(h.windows[1].rollback, false); h.windows[0].resolve(); h.windows[1].resolve(); await settle();
    assert.equal(h.page.isFullScreen, false); assert.equal(h.page.fullscreenTransitioning, false);
    assert(!h.logs.some(([, m]) => m.includes('switch_completed')));
    assert(method('aboutToDisappear').includes('restoreFullscreenOnLeave()'));
    assert(method('disconnectSession').includes('restoreFullscreenOnLeave()'));
    assert(method('onBackPress').includes('if (this.fullscreenTransitioning) return true'));
  });
  await test('hidden/leaving pages cannot start fullscreen', () => {
    for (const overrides of [{ remotePageVisible: false }, { isLeavingAfterDisconnect: true }]) {
      const h = pageHarness(overrides); h.page.enterFullScreen(); assert.equal(h.windows.length, 0);
    }
  });
  await test('main-window operations are awaited and page cleanup is serialized', async () => {
    const h = policyHarness(), gate = deferred(); h.gateLayout(gate);
    const enter = h.policy.apply(true), leave = h.policy.apply(false, false);
    await settle(); assert.deepEqual(h.calls, [['layout', true]]);
    gate.resolve(); await Promise.all([enter, leave]);
    assert.deepEqual(h.calls, [['layout', true], ['bars', []], ['layout', false], ['bars', ['status', 'navigation']]]);
    assert(!policySource.includes('getLastWindow'));
  });
  await test('completion waits for system-bar API, not just layout API', async () => {
    const h = policyHarness(), gate = deferred(); h.gateBars(gate); let finished = false;
    const apply = h.policy.apply(true).then(() => { finished = true; }); await settle();
    assert.equal(finished, false); gate.resolve(); await apply; assert.equal(finished, true);
  });
  await test('bar failure rolls both APIs back and subsequent operations still work', async () => {
    const h = policyHarness(); h.failBars(1); await assert.rejects(h.policy.apply(true));
    assert.deepEqual(h.calls, [['layout', true], ['bars', []], ['layout', false], ['bars', ['status', 'navigation']]]);
    assert(h.logs.some(([, m]) => m.includes('window_rollback') && m.includes('result=ok')));
    await h.policy.apply(true); assert.deepEqual(h.calls.at(-1), ['bars', []]);
  });
  await test('failed exit rolls back to enabled; cleanup never rolls back to hidden bars', async () => {
    const h = policyHarness(); await h.policy.apply(true); h.failBars(1);
    await assert.rejects(h.policy.apply(false)); assert.deepEqual(h.calls.at(-1), ['bars', []]);
    h.calls.length = 0; h.failLayout(1); await assert.rejects(h.policy.apply(false, false));
    assert.deepEqual(h.calls, [['layout', false], ['bars', ['status', 'navigation']]]);
  });
  await test('PC floating window uses immersive maximize and recovers on exit', async () => {
    const h = policyHarness('2in1');
    await h.policy.apply(true);
    assert.deepEqual(h.calls, [['maximize', 3]]);
    assert.equal(h.status(), 1);
    await h.policy.apply(false);
    assert.deepEqual(h.calls, [['maximize', 3], ['recover']]);
    assert.equal(h.status(), 4);
    assert(h.logs.some(([, message]) => message.includes('pc_window_restored')));
  });
  await test('PC previously maximized window stays maximized after exit', async () => {
    const h = policyHarness('pc', 2);
    await h.policy.apply(true);
    await h.policy.apply(false);
    assert.deepEqual(h.calls, [['maximize', 3], ['maximize', 1]]);
    assert.equal(h.status(), 2);
  });
  await test('PC manual floating-window restore does not trigger a repeated recover', async () => {
    const h = policyHarness('2in1');
    await h.policy.apply(true);
    h.setStatus(4);
    await h.policy.apply(false);
    assert.deepEqual(h.calls, [['maximize', 3]]);
  });
  await test('PC split-screen state is preserved when fullscreen cannot restore it', async () => {
    const h = policyHarness('pc', 5);
    await assert.rejects(h.policy.apply(true));
    assert.deepEqual(h.calls, []);
    assert.equal(h.status(), 5);
  });
  await test('PC fullscreen enter failure keeps original window and queue recovers', async () => {
    const h = policyHarness('desktop'); h.failMaximize(1);
    await assert.rejects(h.policy.apply(true));
    assert.deepEqual(h.calls, [['maximize', 3]]);
    assert.equal(h.status(), 4);
    await h.policy.apply(true);
    await h.policy.apply(false);
    assert.deepEqual(h.calls.slice(-2), [['maximize', 3], ['recover']]);
  });
  await test('PC leave during pending fullscreen enter restores window in order', async () => {
    const h = policyHarness('2in1'), gate = deferred(); h.gateMaximize(gate);
    const enter = h.policy.apply(true), leave = h.policy.apply(false, false);
    await settle(); assert.deepEqual(h.calls, [['maximize', 3]]);
    gate.resolve(); await Promise.all([enter, leave]);
    assert.deepEqual(h.calls, [['maximize', 3], ['recover']]);
  });
  await test('missing main window produces diagnostic rejection, never targets an overlay', async () => {
    const h = policyHarness(); h.detach(); await assert.rejects(h.policy.apply(true));
    assert.deepEqual(h.calls, []); assert(h.logs.some(([, m]) => m === 'window_unavailable'));
  });
  console.log(`TOTAL=${passed} FAILED=0`);
})().catch(error => { console.error(error); process.exitCode = 1; });
