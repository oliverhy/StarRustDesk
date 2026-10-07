'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
function harness(disk = new Map()) {
  const timers = new Map(), writes = [], logs = [];
  let next = 0, failRead = false, failWrite = false;
  const context = { exports: {}, RustDeskNapi: {
    getOption(key) { if (failRead) throw Error('read'); return disk.get(key) || ''; },
    setOption(key, value) { if (failWrite) throw Error('write'); writes.push([key, value]); disk.set(key, value); return 0; },
    appendDiagnosticLog: (...args) => logs.push(args), getInputCapabilities: () => 2
  }, setTimeout(fn, ms) { const id = ++next; timers.set(id, { fn, ms }); return id; },
    clearTimeout: id => timers.delete(id) };
  for (const file of ['model/RemoteToolbarPlacement', 'model/RemotePeerOptions', 'model/InputCompatibility',
    'service/RemotePeerPreferences']) {
    const code = read('entry/src/main/ets/' + file + '.ets').replace(/^import .*\n/gm, '');
    vm.runInNewContext(ts.transpile(code), context);
    Object.assign(context, context.exports);
  }
  return { ...context.exports, context, disk, writes, logs, timers,
    make: (server, peer) => new context.exports.RemotePeerPreferences(server, peer),
    failRead(value) { failRead = value; }, failWrite(value) { failWrite = value; },
    fire() { const pending = [...timers.values()]; timers.clear(); pending.forEach(({ fn }) => fn()); } };
}
let checks = 0;
function test(name, run) { run(); checks++; console.log('PASS ' + name); }
test('server + peer namespaces avoid punctuation/separator/public collisions', () => {
  const h = harness(), key = h.remotePeerPreferenceKey;
  const pairs = [['', '123'], ['public', '123'], ['srv-a', 'b'], ['srv', 'a-b'],
    ['srv', '1.2.3.4'], ['srv', '1234'], ['[2001:db8::1]:21116', '[2001:db8::2]:21118'],
    ['other:21116', '123'], ['srv', '123']];
  assert.equal(new Set(pairs.map(([server, peer]) => key(server, peer))).size, pairs.length);
  assert.equal(key('  SRV:21116  ', '1 2\u200B3'), key('srv:21116', '123'));
  assert.equal(key('srv', ''), '');
  assert.equal(key('srv', 'x'.repeat(513)), '');
});
test('native persistence reads complete encoded keys for IPv6 and long server addresses', () => {
  const h = harness();
  const server = '[2001:db8:1234:5678:90ab:cdef:1234:5678]:21116';
  const peer = '[2001:db8:1234:5678:90ab:cdef:8765:4321]:21118';
  const key = h.remotePeerPreferenceKey(server, peer);
  assert(Buffer.byteLength(key, 'utf8') > 127, 'reproduces the legacy native key truncation boundary');
  const p = h.make(server, peer); p.set('input-mode', 'touch'); p.dispose();
  assert.equal(h.make(server, peer).get('input-mode'), 'touch');
  assert.equal(h.disk.get(key.slice(0, 127)), undefined, 'truncated reads would miss the saved record');
  const native = read('entry/src/main/cpp/napi_init.cpp');
  const getter = native.slice(native.indexOf('static napi_value GetOption('), native.indexOf('static std::string EscapeJsonString('));
  assert(!/char\s+key\s*\[/.test(getter), 'no fixed-size option key buffer');
  assert(getter.includes('nullptr, 0, &keyLen') && getter.includes('keyLen <= 16384'));
  assert(getter.includes("std::vector<char> keyBuffer(keyLen + 1, '\\0')"));
  assert(getter.includes('Config::instance().get(std::string(keyBuffer.data(), keyLen))'));
});
test('legacy defaults are inherited; A changes never mutate B or any global default', () => {
  const h = harness(new Map([['show-local-cursor', '1'], ['show-virtual-mouse', '0']]));
  const a = h.make('srv', 'A'), b = h.make('srv', 'B'), other = h.make('other', 'A');
  assert.equal(a.get('show-local-cursor', 'show-local-cursor'), '1');
  a.set('show-local-cursor', '0'); a.set('show-virtual-mouse', '1');
  assert.equal(b.get('show-local-cursor', 'show-local-cursor'), '1');
  assert.equal(other.get('show-virtual-mouse', 'show-virtual-mouse'), '0');
  h.fire(); assert.equal(h.writes.length, 1);
  assert.equal(h.disk.get('show-local-cursor'), '1'); assert.equal(h.disk.get('show-virtual-mouse'), '0');
  assert.equal(h.make('srv', 'A').get('show-local-cursor'), '0');
  assert.equal(h.make('srv', 'B').get('show-local-cursor'), '');
});
test('a fresh runtime restores all whitelisted option types without pressed-input state', () => {
  const h = harness(), p = h.make('srv', 'A');
  const values = { 'input-mode': 'touch', 'keyboard-compat': '2', 'relative-mouse': '0', 'cursor-compat': 'separate',
    'edge-auto-pan-enabled': '1', 'remote-control-toolbar-order': 'input,keyboard,disconnect',
    'remote-keyboard-toolbar-order': 'ctrl,shift,alt', 'remote-keyboard-more-order': 'Up,Down,Esc',
    'remote-toolbar-position-v1': '{"x":0.8,"y":0.4}', 'keyboard-toolbar-position-v1': '{"x":0.2,"y":0.1}',
    'remote-toolbar-collapsed': '1', 'keyboard-tools-collapsed': '0', 'pc-toolbar-pinned': '1',
    'desktop-view-mode': 'custom', 'desktop-custom-percent': '175', 'handheld-zoom': '2.5',
    'show-local-cursor': '0', 'show-virtual-mouse': '1' };
  for (const [name, value] of Object.entries(values)) assert(p.set(name, value), name);
  assert.equal(h.writes.length, 0); p.dispose(); assert.equal(h.writes.length, 1);
  const restored = harness(h.disk).make('srv', 'A');
  for (const [name, value] of Object.entries(values)) assert.equal(restored.get(name), value, name);
  for (const name of ['password', 'clipboard', 'Ctrl', 'virtualShiftSelected', 'leftButtonHeld', 'fullscreen', 'showKeyboardPanel']) {
    assert.equal(p.set(name, '1'), false); assert.equal(restored.has(name), false);
  }
});
test('sliders batch updates; disposal flushes the latest value once and rejects stale writes', () => {
  const h = harness(), a = h.make('srv', 'A');
  for (let percent = 25; percent <= 300; percent++) a.set('desktop-custom-percent', String(percent));
  assert.equal(h.timers.size, 1); assert.equal(h.writes.length, 0);
  a.dispose(); assert.equal(h.writes.length, 1); assert.equal(h.timers.size, 0);
  assert.equal(a.set('desktop-custom-percent', '100'), false);
  const b = h.make('srv', 'B'); b.set('desktop-custom-percent', '75'); h.fire();
  assert.equal(h.make('srv', 'A').get('desktop-custom-percent'), '300');
  assert.equal(h.make('srv', 'B').get('desktop-custom-percent'), '75');
});
test('old-page timers retain their captured identity after another peer opens', () => {
  const h = harness(), a = h.make('srv', 'A'); a.set('input-mode', 'touch');
  const b = h.make('srv', 'B'); b.set('input-mode', 'mouse'); h.fire();
  assert.equal(h.make('srv', 'A').get('input-mode'), 'touch');
  assert.equal(h.make('srv', 'B').get('input-mode'), 'mouse');
  assert.notEqual(h.writes[0][0], h.writes[1][0]);
});
test('corrupt/oversized preferences fall back and unknown fields cannot be persisted', () => {
  const h = harness(), key = h.remotePeerPreferenceKey('srv', 'A');
  for (const value of ['{', 'null', '[]', '{"desktop-custom-percent":"9999"}', 'x'.repeat(16385)]) {
    h.disk.set(key, value); assert.equal(h.make('srv', 'A').has('desktop-custom-percent'), false);
  }
  h.disk.set(key, '{"input-mode":"touch","password":"not-a-real-secret","virtualCtrlSelected":"1"}');
  const p = h.make('srv', 'A'); assert.equal(p.get('input-mode'), 'touch');
  assert.equal(p.has('password'), false); p.set('show-local-cursor', '0'); p.flush();
  assert(!h.disk.get(key).includes('password')); assert(!h.disk.get(key).includes('virtualCtrlSelected'));
  assert.equal(p.set('handheld-zoom', 'NaN'), false); assert.equal(p.set('handheld-zoom', '10'), false);
  assert.equal(p.set('remote-toolbar-position-v1', '{"x":-1,"y":1}'), false);
  assert.equal(h.make('', '').set('input-mode', 'mouse'), false);
});
test('storage failures cannot interrupt a session; save retry retains current preferences', () => {
  const h = harness(); h.failRead(true);
  let p; assert.doesNotThrow(() => { p = h.make('srv', 'A'); });
  assert.equal(p.get('input-mode', 'legacy'), ''); h.failRead(false);
  p.set('input-mode', 'touch'); h.failWrite(true); assert.equal(p.flush(), false);
  assert.equal(p.get('input-mode'), 'touch'); h.failWrite(false); assert.equal(p.flush(), true);
  assert.equal(h.make('srv', 'A').get('input-mode'), 'touch');
  assert(h.logs.every(args => !args.join(' ').includes('srv') && !args.join(' ').includes('input-mode')));
});

const pageSource = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = pageSource.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return pageSource.slice(start, pageSource.indexOf('\n  }', start) + 4);
};
function pageHarness(h, server, id, pc = false) {
  const names = ['inputModeOptionKey', 'compatibilityOptionKey', 'loadInputMode', 'loadLocalCursorPreference',
    'loadEdgeAutoPanPreference', 'loadVirtualMousePreference', 'loadToolbarOrderPreferences', 'readToolbarOrder',
    'loadInputCompatibility', 'loadRemoteToolbarPosition', 'loadPeerToolbarState', 'resetRemoteViewportForSession',
    'resetViewportTransform', 'setInputMode', 'setLocalCursorPreference', 'saveToolbarOrder'];
  const constants = ['CONTROL_TOOLBAR_DEFAULT_ORDER', 'KEYBOARD_TOOLBAR_DEFAULT_ORDER', 'KEYBOARD_MORE_DEFAULT_ORDER']
    .map(name => pageSource.match(new RegExp(`const ${name}: string\\[\\] = \\[[\\s\\S]*?\\];`))[0]).join('\n');
  Object.assign(h.context, { INPUT_MODE_MOUSE: 'mouse', INPUT_MODE_TOUCH: 'touch' });
  vm.runInNewContext(ts.transpile(constants + '\nclass Page {' + names.map(method).join('\n') + '} exports.Page = Page;'), h.context);
  return Object.assign(new h.context.exports.Page(), {
    peerPreferences: h.make(server, id), peerPreferenceServer: server, connectedPeerId: id,
    isPcDevice: () => pc, isHandheldLandscape: () => false, inputMode: 'mouse', relativeMouseEnabled: false,
    cancelActiveTouchGesture() {}, stopEdgeAutoPan() {}, ensurePointerInitialized() {}, updateSystemPointerVisibility() {},
    applyInputCompatibility() {}, discardViewportPanFrame() {}, syncDesktopViewScale() {},
    physicalMouseDeduplicator: { clear() {} }, resetPointerDiagnostics() {},
    virtualCtrlSelected: false, virtualShiftSelected: false
  });
}
test('production page restores isolated input, toolbar order/state/positions and view scale', () => {
  const h = harness(new Map([['show-local-cursor', '1']]));
  const a = pageHarness(h, 'srv', 'A');
  a.setInputMode('touch'); a.setLocalCursorPreference(false);
  a.keyboardMoreOrder = ['Up', 'Down', 'Esc']; a.saveToolbarOrder('keyboardMore');
  for (const [name, value] of [['keyboard-compat', '2'], ['cursor-compat', 'separate'], ['relative-mouse', '0'],
    ['remote-toolbar-collapsed', '1'], ['keyboard-tools-collapsed', '0'],
    ['remote-toolbar-position-v1', '{"x":0.8,"y":0.4}'], ['keyboard-toolbar-position-v1', '{"x":0.2,"y":0.1}'],
    ['desktop-view-mode', 'custom'], ['desktop-custom-percent', '175'], ['handheld-zoom', '2.5']]) {
    a.peerPreferences.set(name, value);
  }
  a.peerPreferences.dispose();
  const restored = pageHarness(h, 'srv', 'A');
  for (const name of ['loadInputMode', 'loadLocalCursorPreference', 'loadToolbarOrderPreferences', 'loadInputCompatibility',
    'loadRemoteToolbarPosition', 'loadPeerToolbarState', 'resetRemoteViewportForSession']) restored[name]();
  assert.equal(restored.inputMode, 'touch'); assert.equal(restored.showLocalCursor, false);
  assert.equal(restored.keyboardMoreOrder[0], 'Up'); assert.equal(restored.keyboardCompatibilityMode, 2);
  assert.equal(restored.remoteToolbarCollapsed, true); assert.equal(restored.keyboardToolsCollapsed, false);
  assert.equal(restored.remoteToolbarPositionX, 0.8); assert.equal(restored.keyboardToolsPositionX, 0.2);
  assert.equal(restored.zoomScale, 2.5); restored.resetViewportTransform(); assert.equal(restored.zoomScale, 2.5);
  assert.equal(restored.virtualCtrlSelected, false); assert.equal(restored.virtualShiftSelected, false);
  const pcPage = pageHarness(h, 'srv', 'A', true); pcPage.resetRemoteViewportForSession();
  assert.equal(pcPage.desktopViewMode, 'custom'); assert.equal(pcPage.desktopCustomPercent, 175);
  assert.equal(pcPage.rememberedHandheldZoomScale, 1);
  for (const [server, id] of [['srv', 'B'], ['other', 'A']]) {
    const b = pageHarness(h, server, id); b.loadInputMode(); b.loadLocalCursorPreference(); b.loadRemoteToolbarPosition();
    b.loadPeerToolbarState(); b.resetRemoteViewportForSession();
    assert.equal(b.inputMode, 'mouse'); assert.equal(b.showLocalCursor, true);
    assert.equal(b.remoteToolbarPositionX, -1); assert.equal(b.remoteToolbarCollapsed, false); assert.equal(b.zoomScale, 1);
  }
  assert.equal(h.disk.get('show-local-cursor'), '1');
});
test('page lifecycle captures identity before loading and flushes only the old owner on leave', () => {
  const appear = method('aboutToAppear');
  assert(appear.indexOf('new RemotePeerPreferences(') < appear.indexOf('resetRemoteViewportForSession()'));
  assert(appear.indexOf('connectedPeerId =') < appear.indexOf('new RemotePeerPreferences('));
  assert(method('aboutToDisappear').includes('this.peerPreferences?.dispose()'));
  const saves = ['setInputMode', 'setLocalCursorPreference', 'setVirtualMouseEnabled', 'setEdgeAutoPanEnabled',
    'saveToolbarOrder', 'finishRemoteToolbarDrag', 'finishKeyboardToolsDrag', 'togglePcToolbarPinned'];
  for (const name of saves) assert(!method(name).includes('RustDeskNapi.setOption('), `${name} must not mutate global defaults`);
  assert(!method('applyPinchTransform').includes('peerPreferences'));
  assert(method('finishMultiTouchGesture').includes("peerPreferences.set('handheld-zoom'"));
  assert(method('setFloatingPanelCollapsed').includes("'keyboard-tools-collapsed' : 'remote-toolbar-collapsed'"));
});
console.log(`TOTAL=${checks} FAILED=0 (peer preference logic, isolated storage/timers and production restore/save paths; device acceptance pending)`);
