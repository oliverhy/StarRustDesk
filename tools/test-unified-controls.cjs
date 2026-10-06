'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replace(/\r\n/g, '\n');
const pageSource = read('entry/src/main/ets/pages/RemotePage.ets');
const modelSource = read('entry/src/main/ets/model/RemoteControlMenu.ets');
const model = { exports: {} };
vm.runInNewContext(ts.transpile(modelSource), model);
const { REMOTE_CONTROL_CATEGORIES, remoteControlCategoryItems, clampControlMenuAxis,
  compactControlMenuMetrics, placeCompactControlMenu } = model.exports;
const method = name => {
  const start = pageSource.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return pageSource.slice(start, pageSource.indexOf('\n  }', start) + 4);
};
const order = new Function('return [' + pageSource.match(/const CONTROL_TOOLBAR_DEFAULT_ORDER: string\[\] = \[([\s\S]*?)\];/)[1] + ']')();
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
};
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function windowHarness(originalDecor = true, deviceType = 'pc') {
  const calls = [], logs = [];
  let decor = originalDecor, gate, failDecor = false;
  let status = 4;
  const main = {
    getWindowDecorVisible: () => decor,
    setWindowDecorVisible(value) {
      calls.push(['decor', value]);
      if (failDecor) { failDecor = false; throw Object.assign(new Error('unsupported'), { code: 801 }); }
      decor = value;
    },
    getWindowStatus: () => status,
    async maximize(value) { calls.push(['maximize', value]); if (gate) { const p = gate; gate = undefined; await p.promise; } status = value === 1 ? 2 : 1; },
    async recover() { calls.push(['recover']); status = 4; decor = true; },
    getWindowProperties: () => ({ windowRect: { width: 1000, height: 800 } })
  };
  let attached = main;
  const context = vm.createContext({ exports: {}, deviceInfo: { deviceType },
    window: { WindowStatusType: { FLOATING: 4, MAXIMIZE: 2, FULL_SCREEN: 1 },
      MaximizePresentation: { ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER: 3, EXIT_IMMERSIVE: 1, ENTER_IMMERSIVE: 2 } },
    RemoteDisplayPolicy: { getMainWindow: () => attached },
    RustDeskNapi: { appendDiagnosticLog: (...args) => logs.push(args) }
  });
  vm.runInContext(ts.transpile(read('entry/src/main/ets/service/RemoteFullscreenPolicy.ets')
    .replace(/^import .*\n/gm, '')), context);
  return { policy: context.exports.RemoteFullscreenPolicy, calls, logs, decor: () => decor,
    fail() { failDecor = true; }, gate(value) { gate = value; }, detach() { attached = undefined; } };
}
(async () => {
  await test('six categories cover every existing action exactly once and preserve custom ordering', () => {
    assert.deepEqual(Array.from(REMOTE_CONTROL_CATEGORIES), ['screens', 'input', 'keyboard', 'view', 'more', 'disconnect']);
    const actions = REMOTE_CONTROL_CATEGORIES.flatMap(category => Array.from(remoteControlCategoryItems(category, order)));
    assert.equal(new Set(actions).size, actions.length);
    assert.deepEqual([...actions].sort(), order.filter(k => k !== 'keyboard' && k !== 'disconnect').sort());
    assert.deepEqual(Array.from(remoteControlCategoryItems('view', ['pip', 'zoomOut', 'chat', 'fullscreen'])), ['pip', 'zoomOut', 'fullscreen']);
    assert.deepEqual(Array.from(remoteControlCategoryItems('unknown', order)), []);
  });
  await test('menu bounds protect all four edges, including keyboard-resized viewports', () => {
    assert.equal(clampControlMenuAxis(-100, 300, 800), 8);
    assert.equal(clampControlMenuAxis(900, 300, 800), 492);
    assert.equal(clampControlMenuAxis(250, 148, 180), 24);
    const context = { exports: {}, remoteControlCategoryItems, compactControlMenuMetrics, placeCompactControlMenu };
    const methods = ['getControlMenuWidth', 'getControlMenuHeight', 'getControlMenuX', 'getControlMenuY',
      'getControlMenuMetrics', 'getVisibleControlMenuItems', 'getControlMenuViewportHeight', 'getControlMenuAnchor', 'isControlMenuBesideToolbar'];
    vm.runInNewContext(ts.transpile('class Page {' + methods.map(method).join('\n') + '} exports.Page = Page;'), context);
    const page = Object.assign(new context.exports.Page(), {
      pageWidth: 360, pageHeight: 720, controlMenu: 'more', displayCount: 3, controlToolbarOrder: order,
      isFullScreen: false, immersiveWindow: false,
      uiFontScale: 1, desktopViewMode: 'adaptive', controlMenuAnchors: [], controlMenuKeyboardInset: 0,
      showKeyboardPanel: false, isPeerAndroid: false, canPanViewport: () => true,
      adaptiveToolbarButtonWidth: n => n, getRemoteToolbarButtonHeight: () => 40,
      getControlMenuLabelWidth: () => 0,
      isPcDevice: () => false, isHandheldDevice: () => true, isHandheldLandscape: () => false,
      isLargeLayout: () => false, getRemoteToolbarX: () => 8, getRemoteToolbarY: () => 620,
      getSideToolbarHeight: () => 338
    });
    for (const [width, height, pc, landscape, fullscreen, immersive] of [
      [360, 720, false, false, false, false], [360, 180, false, false, false, false],
      [800, 360, false, true, false, false], [1200, 800, true, false, false, false],
      [1200, 800, true, false, true, false], [1200, 800, true, false, false, true]
    ]) {
      Object.assign(page, { pageWidth: width, pageHeight: height, isFullScreen: fullscreen, immersiveWindow: immersive,
        isHandheldDevice: () => !pc, isPcDevice: () => pc, isHandheldLandscape: () => landscape, isLargeLayout: () => pc });
      assert(page.getControlMenuX() >= 8); assert(page.getControlMenuX() + page.getControlMenuWidth() <= width - 8);
      assert(page.getControlMenuY() >= 8); assert(page.getControlMenuY() + page.getControlMenuHeight() <= height - 8);
    }
  });
  await test('open menus stop native and ArkUI input; Escape dismisses locally', () => {
    const context = { exports: {}, KeyType: { Down: 0, Up: 1 } };
    const names = ['syncHardwareKeyState', 'handleNativeMouseInput', 'handleNativeKeyInput', 'handleRemoteMouse', 'handleRemoteAxis', 'handleRemoteTouch', 'handleRemoteKey'];
    vm.runInNewContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} exports.Page = Page;'), context);
    const page = Object.assign(new context.exports.Page(), { controlMenu: 'view', pipSurfaceOwned: false,
      mapControlKeyCode: k => k, setControlMenu(value) { this.controlMenu = value; } });
    // Any accidental forwarding touches an unstubbed API and fails this test.
    for (const name of names.filter(k => k !== 'handleRemoteKey')) page[name]({});
    assert.equal(page.handleRemoteKey({ type: 0, keyCode: 65 }), true);
    assert.equal(page.controlMenu, 'view');
    assert.equal(page.handleRemoteKey({ type: 0, keyCode: 27 }), true);
    assert.equal(page.controlMenu, '');
  });
  await test('borderless opt-in is idempotent and restores the original decoration state', async () => {
    for (const original of [true, false]) {
      const h = windowHarness(original);
      await h.policy.setBorderless(true); await h.policy.setBorderless(true);
      assert.equal(h.decor(), false);
      await h.policy.setBorderless(false); await h.policy.setBorderless(false);
      assert.equal(h.decor(), original);
      assert.deepEqual(h.calls, [['decor', false], ['decor', original]]);
    }
  });
  await test('unsupported window APIs reject truthfully and do not poison the next attempt', async () => {
    const h = windowHarness(); h.fail(); await assert.rejects(h.policy.setBorderless(true));
    assert.equal(h.decor(), true);
    await h.policy.setBorderless(true); await h.policy.setBorderless(false);
    assert.equal(h.decor(), true);
  });
  await test('phone and missing main window never mutate window decoration', async () => {
    const phone = windowHarness(true, 'phone'); await assert.rejects(phone.policy.setBorderless(true)); assert.deepEqual(phone.calls, []);
    const detached = windowHarness(); detached.detach(); await assert.rejects(detached.policy.setBorderless(true)); assert.deepEqual(detached.calls, []);
  });
  await test('fullscreen exit keeps an enabled borderless preference, session exit restores title', async () => {
    const h = windowHarness(); await h.policy.setBorderless(true);
    await h.policy.apply(true); await h.policy.apply(false);
    assert.equal(h.decor(), false);
    await h.policy.setBorderless(false); assert.equal(h.decor(), true);
    assert.deepEqual(h.calls, [['decor', false], ['maximize', 3], ['recover'], ['decor', false], ['decor', true]]);
  });
  await test('late fullscreen completion cannot hide the title after queued session cleanup', async () => {
    const h = windowHarness(), gate = deferred(); await h.policy.setBorderless(true); h.gate(gate);
    const enter = h.policy.apply(true), exit = h.policy.apply(false, false), cleanup = h.policy.setBorderless(false);
    await settle(); assert.deepEqual(h.calls, [['decor', false], ['maximize', 3]]);
    gate.resolve(); await Promise.all([enter, exit, cleanup]);
    assert.equal(h.decor(), true); assert.deepEqual(h.calls.at(-1), ['decor', true]);
  });
  await test('page leaving during borderless entry ignores stale failure and still queues restoration', async () => {
    const requests = [], toasts = [];
    const context = { exports: {}, RustDeskNapi: { appendDiagnosticLog() {} },
      RemoteFullscreenPolicy: { setBorderless(enabled) { const d = deferred(); requests.push({ enabled, ...d }); return d.promise; } } };
    vm.runInNewContext(ts.transpile('class Page {' + ['toggleImmersiveWindow', 'restoreImmersiveWindowOnLeave'].map(method).join('\n') + '} exports.Page = Page;'), context);
    const page = Object.assign(new context.exports.Page(), {
      isPcDevice: () => true, remotePageVisible: true, immersiveWindow: false, immersiveWindowTransitioning: false,
      immersiveWindowRequestId: 0, setControlMenu() {}, closeRemoteKeyboard() {},
      showFileToast: message => toasts.push(message), scheduleSurfaceRebindIfSizeChanged() { throw Error('stale rebind'); }
    });
    page.toggleImmersiveWindow(); page.remotePageVisible = false; page.restoreImmersiveWindowOnLeave();
    assert.deepEqual(requests.map(r => r.enabled), [true, false]);
    requests[0].reject({ code: 801 }); requests[1].resolve(); await settle();
    assert.equal(page.immersiveWindow, false); assert.equal(page.immersiveWindowTransitioning, false); assert.deepEqual(toasts, []);
  });
  console.log(`TOTAL=${passed} FAILED=0 (production logic, mocked window SDK; not device acceptance)`);
})().catch(error => { console.error(error); process.exitCode = 1; });
