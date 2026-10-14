'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function harness(disk = new Map()) {
  const requests = [], writes = [], logs = [], toasts = [], rebinds = [], timers = new Map();
  let failWrite = false, attached = true, nextTimer = 0;
  const context = { exports: {}, ConnectionStatus: { CONNECTED: 2 },
    RustDeskNapi: {
      getOption: key => disk.get(key) || '',
      setOption(key, value) { if (failWrite) return -1; disk.set(key, value); writes.push([key, value]); return 0; },
      appendDiagnosticLog: (...args) => logs.push(args)
    },
    RemoteDisplayPolicy: { getMainWindow: () => attached ? {} : undefined },
    RemoteFullscreenPolicy: { setBorderless(enabled) {
      let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
      requests.push({ enabled, resolve, reject }); return promise;
    } },
    setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }
  };
  for (const name of ['model/KeyboardRemapping', 'model/RemoteToolbarPlacement', 'model/RemotePeerOptions', 'service/RemotePeerPreferences']) {
    vm.runInNewContext(ts.transpile(read('entry/src/main/ets/' + name + '.ets').replace(/^import .*\n/gm, '')), context);
    Object.assign(context, context.exports);
  }
  vm.runInNewContext(ts.transpile('class Page {' + ['restoreImmersiveWindowPreference', 'toggleImmersiveWindow',
    'restoreImmersiveWindowOnLeave'].map(method).join('\n') + '} exports.Page = Page;'), context);
  const make = (server = 'srv', peer = 'A', extra = {}) => Object.assign(new context.exports.Page(), {
    peerPreferences: new context.exports.RemotePeerPreferences(server, peer),
    isPcDevice: () => true, fileOnly: false, connectionStatus: 2,
    remotePageVisible: true, isLeavingAfterDisconnect: false, immersivePreferenceRestored: false,
    immersiveWindow: false, immersiveWindowTransitioning: false, immersiveWindowRequestId: 0,
    fullscreenTransitioning: false, isFullScreen: false, pipSurfaceOwned: false, desktopWindowAdjusting: false,
    setControlMenu() {}, closeRemoteKeyboard() {},
    scheduleSurfaceRebindIfSizeChanged() { rebinds.push(peer); },
    showFileToast: message => toasts.push(message), ...extra
  });
  return { make, disk, requests, writes, logs, toasts, rebinds,
    failWrite(value) { failWrite = value; }, attached(value) { attached = value; } };
}
let checks = 0;
async function test(name, run) { await run(); checks++; console.log('PASS ' + name); }
(async () => {
  await test('save only after successful window switch; leave preserves preference; fresh runtime restores it', async () => {
    const h = harness(), p = h.make(); p.toggleImmersiveWindow();
    assert.equal(h.writes.length, 0); assert.equal(h.requests[0].enabled, true);
    h.requests[0].resolve(); await settle();
    assert.equal(p.peerPreferences.get('pc-immersive-window'), '1'); assert.equal(h.writes.length, 1);
    p.remotePageVisible = false; p.restoreImmersiveWindowOnLeave();
    assert.equal(h.requests[1].enabled, false); h.requests[1].resolve(); await settle();
    assert.equal(p.immersiveWindow, false); assert.equal(h.writes.length, 1);
    const fresh = harness(h.disk), restored = fresh.make(); restored.restoreImmersiveWindowPreference();
    assert.equal(fresh.requests.length, 1); assert.equal(fresh.requests[0].enabled, true);
    fresh.requests[0].resolve(); await settle();
    assert.equal(restored.immersiveWindow, true); assert.equal(fresh.writes.length, 0);
    restored.restoreImmersiveWindowPreference(); assert.equal(fresh.requests.length, 1);
  });
  await test('turning off is persisted and later connections stay in the normal window', async () => {
    const h = harness(), p = h.make(); p.peerPreferences.set('pc-immersive-window', '1'); p.peerPreferences.flush();
    p.restoreImmersiveWindowPreference(); h.requests[0].resolve(); await settle();
    p.toggleImmersiveWindow(); assert.equal(h.requests[1].enabled, false);
    h.requests[1].resolve(); await settle(); assert.equal(p.peerPreferences.get('pc-immersive-window'), '0');
    const fresh = harness(h.disk); fresh.make().restoreImmersiveWindowPreference(); assert.equal(fresh.requests.length, 0);
  });
  await test('server and peer settings stay independent', async () => {
    const h = harness(), a = h.make(); a.toggleImmersiveWindow(); h.requests[0].resolve(); await settle();
    for (const [server, peer] of [['srv', 'B'], ['other', 'A'], ['', 'A']]) {
      const p = h.make(server, peer); p.restoreImmersiveWindowPreference();
      assert.equal(p.immersiveWindow, false); assert.equal(p.peerPreferences.get('pc-immersive-window'), '');
    }
    assert.equal(h.requests.length, 1);
  });
  await test('SDK failure rolls back the window state and does not replace the saved setting', async () => {
    const h = harness(), p = h.make(); p.peerPreferences.set('pc-immersive-window', '0'); p.peerPreferences.flush();
    const writes = h.writes.length; p.toggleImmersiveWindow(); h.requests[0].reject({ code: 801 }); await settle();
    assert.equal(p.immersiveWindow, false); assert.equal(p.immersiveWindowTransitioning, false);
    assert.equal(h.writes.length, writes); assert.equal(p.peerPreferences.get('pc-immersive-window'), '0');
    assert.equal(h.toasts.length, 1);
  });
  await test('automatic restore failure preserves the saved choice and does not retry every poll', async () => {
    const h = harness(), p = h.make(); p.peerPreferences.set('pc-immersive-window', '1'); p.peerPreferences.flush();
    p.restoreImmersiveWindowPreference(); h.requests[0].reject({ code: 801 }); await settle();
    p.restoreImmersiveWindowPreference(); assert.equal(h.requests.length, 1);
    assert.equal(p.immersiveWindow, false); assert.equal(p.peerPreferences.get('pc-immersive-window'), '1');
    p.immersivePreferenceRestored = false; p.restoreImmersiveWindowPreference();
    assert.equal(h.requests.length, 2); h.requests[1].resolve(); await settle(); assert(p.immersiveWindow);
  });
  await test('storage failure is reported without interrupting the active window; retry can save it', async () => {
    const h = harness(), p = h.make(); h.failWrite(true);
    p.toggleImmersiveWindow(); h.requests[0].resolve(); await settle();
    assert(p.immersiveWindow); assert.equal(h.disk.size, 0); assert(h.toasts.includes('保存沉浸窗口设置失败，请重试'));
    h.failWrite(false); assert(p.peerPreferences.flush());
    assert.equal(h.make().peerPreferences.get('pc-immersive-window'), '1');
  });
  await test('leaving during window switching ignores stale completion and never saves it', async () => {
    const h = harness(), p = h.make(); p.toggleImmersiveWindow();
    p.remotePageVisible = false; p.restoreImmersiveWindowOnLeave();
    h.requests[0].resolve(); h.requests[1].resolve(); await settle();
    assert.equal(p.immersiveWindow, false); assert.equal(h.writes.length, 0);
    assert.equal(h.toasts.length, 0); assert.equal(h.rebinds.length, 0);
  });
  await test('a late callback cannot save to a different peer or a disconnected session', async () => {
    const h = harness(), p = h.make(); p.toggleImmersiveWindow();
    const b = h.make('srv', 'B'); p.peerPreferences = b.peerPreferences;
    h.requests[0].resolve(); await settle(); assert.equal(h.writes.length, 0); assert.equal(h.rebinds.length, 0);
    const q = h.make(); q.toggleImmersiveWindow(); q.connectionStatus = 3;
    h.requests[1].resolve(); await settle(); assert.equal(h.writes.length, 0);
  });
  await test('handheld/file-only/disconnected sessions do not restore or save PC window settings', async () => {
    const h = harness();
    for (const extra of [{ isPcDevice: () => false }, { fileOnly: true }, { connectionStatus: 1 },
      { remotePageVisible: false }, { isLeavingAfterDisconnect: true }]) {
      const p = h.make('srv', 'A', extra); p.peerPreferences.set('pc-immersive-window', '1'); p.peerPreferences.flush();
      p.restoreImmersiveWindowPreference(); p.toggleImmersiveWindow();
      assert.equal(p.immersivePreferenceRestored, false); assert.equal(p.immersiveWindow, false);
    }
    assert.equal(h.requests.length, 0);
  });
  await test('restore waits for the window and conflicting operations to become available', async () => {
    for (const extra of [{ isFullScreen: true }, { pipSurfaceOwned: true }, { desktopWindowAdjusting: true },
      { fullscreenTransitioning: true }, { immersiveWindowTransitioning: true }]) {
      const h = harness(), p = h.make('srv', 'A', extra); p.peerPreferences.set('pc-immersive-window', '1'); p.peerPreferences.flush();
      p.restoreImmersiveWindowPreference(); assert.equal(h.requests.length, 0); assert.equal(p.immersivePreferenceRestored, false);
      for (const key of Object.keys(extra)) p[key] = false;
      h.attached(false); p.restoreImmersiveWindowPreference(); assert.equal(p.immersivePreferenceRestored, false);
      h.attached(true); p.restoreImmersiveWindowPreference(); assert.equal(h.requests.length, 1);
      h.requests[0].resolve(); await settle(); assert(p.immersiveWindow);
    }
  });
  console.log(`TOTAL=${checks} FAILED=0 (actual persistence and page methods, mocked window SDK)`);
})().catch(error => { console.error(error); process.exitCode = 1; });
