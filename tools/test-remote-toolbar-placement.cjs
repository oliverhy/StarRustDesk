'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const model = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteToolbarPlacement.ets')), model);
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const names = ['isPcDevice', 'isHandheldDevice', 'isHandheldLandscape', 'handleHandheldLayoutChange',
  'adaptiveToolbarButtonWidth', 'getRemoteToolbarButtonHeight', 'getRemoteToolbarWidth',
  'getRemoteToolbarHeight', 'getRemoteToolbarCollapsedSize', 'getRemoteToolbarCurrentWidth',
  'getRemoteToolbarCurrentHeight', 'getRemoteToolbarBaseX', 'getRemoteToolbarBaseY',
  'clampRemoteToolbarOffsetX', 'clampRemoteToolbarOffsetY', 'getRemoteToolbarX', 'getRemoteToolbarY',
  'beginRemoteToolbarDrag', 'updateRemoteToolbarDrag', 'finishRemoteToolbarDrag',
  'loadRemoteToolbarPosition', 'setFloatingPanelCollapsed', 'cancelPcToolbarAutoCollapse',
  'schedulePcToolbarAutoCollapse', 'togglePcToolbarPinned', 'isControlMenuBesideToolbar'];
const pageJavaScript = ts.transpile('class Page {' + names.map(method).join('\n') + '} exports.Page = Page;');
function page(type = 'phone', extra = {}, options = new Map()) {
  const writes = [], timers = new Map(), logs = [];
  let nextTimer = 0;
  const context = { exports: {}, ...model.exports, deviceInfo: { deviceType: type }, Curve: { EaseOut: 'ease-out' },
    RustDeskNapi: { getOption: key => options.get(key) || '',
      setOption(key, value) { writes.push([key, value]); options.set(key, value); return 0; },
      appendDiagnosticLog: (...args) => logs.push(args) },
    setTimeout(fn, ms) { const id = ++nextTimer; timers.set(id, { fn, ms }); return id; },
    clearTimeout: id => timers.delete(id) };
  const peerKey = 'test-captured-peer-settings';
  const peerValues = new Map(Object.entries(JSON.parse(options.get(peerKey) || '{}')));
  let peerDirty = false;
  const peerPreferences = {
    has: name => peerValues.has(name),
    get: (name, legacy) => peerValues.get(name) || context.RustDeskNapi.getOption(legacy || ''),
    set(name, value) { peerValues.set(name, value); peerDirty = true; },
    flush() { if (peerDirty) { context.RustDeskNapi.setOption(peerKey, JSON.stringify(Object.fromEntries(peerValues))); peerDirty = false; } }
  };
  vm.runInNewContext(pageJavaScript, context);
  const p = Object.assign(new context.exports.Page(), {
    peerPreferences,
    pageWidth: 360, pageHeight: 800, uiFontScale: 1, isFullScreen: false, immersiveWindow: false,
    remoteToolbarCollapsed: false, remoteToolbarOffsetX: 0, remoteToolbarOffsetY: 0,
    remoteToolbarPositionX: -1, remoteToolbarPositionY: -1, remoteToolbarDragging: false,
    remotePageVisible: true, isLeavingAfterDisconnect: false, desktopWindowActive: true,
    pointerOverRemoteViewport: true, pcToolbarPinned: false, pcToolbarCollapseTimer: -1,
    controlMenu: '', leftButtonHeld: false, rightButtonHeld: false, localPointerGestureActive: false,
    showKeyboardPanel: false, keyboardToolsCollapsed: true, keyboardLayoutHeight: 0,
    handheldLayoutInitialized: false, showVirtualMouse: false,
    getUIContext: () => ({ animateTo(_options, apply) { apply(); } }), ...extra
  });
  return { p, writes, timers, logs, options, context,
    fire() { const pending = [...timers.values()]; timers.clear(); pending.forEach(({ fn }) => fn()); } };
}
const near = (a, b) => assert(Math.abs(a - b) < 1e-7, `${a} vs ${b}`);
let checks = 0;
const bounded = p => {
  const x = p.getRemoteToolbarX(), y = p.getRemoteToolbarY();
  assert(x >= 8 && y >= 8);
  assert(x + p.getRemoteToolbarCurrentWidth() <= p.pageWidth - 8 + 1e-7);
  assert(y + p.getRemoteToolbarCurrentHeight() <= p.pageHeight - 8 + 1e-7);
  assert.equal(p.isControlMenuBesideToolbar(), false);
  checks++;
};
for (const type of ['phone', 'tablet', 'pc', '2in1', 'desktop']) {
  for (const [w, h] of [[240, 180], [280, 640], [360, 800], [800, 360], [720, 720], [839, 600],
    [840, 600], [841, 600], [1024, 768], [1200, 800], [1920, 1080], [2560, 1440]]) {
    for (const scale of [1, 1.3, 1.75, 2.4]) for (const collapsed of [false, true]) {
      for (const mode of ['normal', 'fullscreen', 'borderless']) {
        const { p } = page(type, { pageWidth: w, pageHeight: h, uiFontScale: scale,
          remoteToolbarCollapsed: collapsed, isFullScreen: mode === 'fullscreen', immersiveWindow: mode === 'borderless' });
        bounded(p);
        if (p.isHandheldDevice()) {
          const wanted = collapsed ? w - p.getRemoteToolbarCurrentWidth() - 8 : (w - p.getRemoteToolbarCurrentWidth()) / 2;
          near(p.getRemoteToolbarX(), Math.max(8, wanted));
          near(p.getRemoteToolbarY(), Math.max(8, h - p.getRemoteToolbarCurrentHeight() - 18));
        } else {
          near(p.getRemoteToolbarX(), Math.max(8, (w - p.getRemoteToolbarCurrentWidth()) / 2));
          assert([8, 58].includes(p.getRemoteToolbarBaseY()));
        }
        p.setFloatingPanelCollapsed(false, !collapsed);
        assert.equal(p.remoteToolbarCollapsed, !collapsed);
        bounded(p);
      }
    }
  }
}
// Position is saved once on gesture completion and survives a fresh page/resize.
for (const type of ['phone', 'tablet', 'pc']) {
  const h = page(type, { pageWidth: 1200, pageHeight: 800 });
  h.p.beginRemoteToolbarDrag();
  h.p.updateRemoteToolbarDrag(130, -100);
  assert.equal(h.writes.length, 0, 'No per-frame disk writes');
  const x = h.p.getRemoteToolbarX(), y = h.p.getRemoteToolbarY();
  h.p.finishRemoteToolbarDrag(); h.p.finishRemoteToolbarDrag();
  assert.equal(h.writes.length, 1);
  assert.equal(h.writes[0][0], 'test-captured-peer-settings');
  assert.equal(h.options.has('remote-toolbar-position-v1'), false, 'New positions must not mutate the global default');
  const restored = page(type, { pageWidth: 1200, pageHeight: 800 }, h.options).p;
  restored.loadRemoteToolbarPosition(); near(restored.getRemoteToolbarX(), x); near(restored.getRemoteToolbarY(), y);
  const chosen = [restored.remoteToolbarPositionX, restored.remoteToolbarPositionY];
  for (const [w, height] of [[360, 800], [800, 360], [839, 600], [840, 600], [1920, 1080], [360, 240]]) {
    Object.assign(restored, { pageWidth: w, pageHeight: height });
    restored.setFloatingPanelCollapsed(false, !restored.remoteToolbarCollapsed);
    restored.handleHandheldLayoutChange();
    assert.deepEqual([restored.remoteToolbarPositionX, restored.remoteToolbarPositionY], chosen);
    bounded(restored);
  }
  // The next gesture starts from the restored position instead of jumping.
  const previous = [restored.getRemoteToolbarX(), restored.getRemoteToolbarY()];
  restored.beginRemoteToolbarDrag(); restored.updateRemoteToolbarDrag(0, 0);
  near(restored.getRemoteToolbarX(), previous[0]); near(restored.getRemoteToolbarY(), previous[1]);
  restored.updateRemoteToolbarDrag(NaN, 1); near(restored.getRemoteToolbarX(), previous[0]);
  checks++;
}
for (const raw of ['', 'null', '[]', 'false', '{', '{"x":0.5}', '{"x":"0.5","y":0.2}',
  '{"x":-1,"y":0}', '{"x":2,"y":0}', '{"x":0,"y":1e999}', 'x'.repeat(257)]) {
  assert.equal(model.exports.decodeRemoteToolbarPosition(raw), undefined);
  const h = page('phone', {}, new Map([['remote-toolbar-position-v1', raw]]));
  assert.doesNotThrow(() => h.p.loadRemoteToolbarPosition());
  assert.equal(h.p.remoteToolbarPositionX, -1); bounded(h.p);
}
const unavailable = page('pc');
unavailable.context.RustDeskNapi.getOption = () => { throw Error('storage unavailable'); };
assert.doesNotThrow(() => unavailable.p.loadRemoteToolbarPosition());
unavailable.p.beginRemoteToolbarDrag(); unavailable.p.updateRemoteToolbarDrag(30, 20);
unavailable.context.RustDeskNapi.setOption = () => { throw Error('storage unavailable'); };
assert.doesNotThrow(() => unavailable.p.finishRemoteToolbarDrag());
bounded(unavailable.p);
for (const mode of ['normal', 'fullscreen', 'borderless']) {
  const h = page('pc', { immersiveWindow: mode === 'borderless', isFullScreen: mode === 'fullscreen' });
  h.p.schedulePcToolbarAutoCollapse(); assert.equal(h.timers.size, 1);
  assert.equal([...h.timers.values()][0].ms, 5000); h.fire(); assert(h.p.remoteToolbarCollapsed);
  for (const extra of [{ pcToolbarPinned: true }, { remoteToolbarDragging: true }, { controlMenu: 'input' },
    { pointerOverRemoteViewport: false }, { desktopWindowActive: false }, { leftButtonHeld: true }]) {
    const guarded = page('pc', extra); guarded.p.schedulePcToolbarAutoCollapse(); guarded.fire();
    assert.equal(guarded.p.remoteToolbarCollapsed, false);
  }
  checks++;
}
for (const methodName of ['requestFullscreen', 'toggleImmersiveWindow', 'handleHandheldLayoutChange']) {
  assert(!/remoteToolbarOffset[XY] = 0|remoteToolbarCollapsed = (true|false)/.test(method(methodName)),
    `${methodName} must preserve the user's control layout`);
}
const viewport = method('buildRemoteScreen');
assert.equal((viewport.match(/buildRemoteViewportWithQualityMonitor\(\)/g) || []).length, 1);
assert(!source.includes('buildSideToolbar('));
assert(/if \(this.connectionStatus === ConnectionStatus.CONNECTED && !this.fileOnly\) \{\s*this.buildFloatingToolbar\(\)/.test(source));
const builder = method('buildFloatingToolbar');
assert(builder.includes('buildUnifiedControlItems(false)') && builder.includes('ScrollDirection.Horizontal'));
assert(!builder.includes('buildUnifiedControlItems(true)'));
assert(builder.includes(".id('remoteToolbarPinButton')"));
assert(builder.includes('finishRemoteToolbarDrag()'));
assert(method('buildFloatingDragHandle').includes('finishRemoteToolbarDrag()'));
assert(method('aboutToDisappear').includes('this.remoteToolbarDragging = false'));
assert(source.includes('this.buildPcFullscreenExitButton()'));
console.log(`PASS unified toolbar placement: ${checks} layout/state cases, persistent drag position, fullscreen exit, resize/fold/IME bounds and guarded PC auto-collapse`);
