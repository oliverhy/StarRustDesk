'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');
const source = read('entry/src/main/ets/pages/RemotePage.ets');
function method(name) {
  let start = source.indexOf('\n  ' + name + '(');
  if (start < 0) start = source.indexOf('\n  async ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const names = ['startClipboardSync', 'stopClipboardSync', 'pauseClipboardSync', 'ensureClipboardSyncRunning',
  'clipboardCanAccess', 'recordClipboardDiagnostic', 'requestClipboardPoll', 'scheduleClipboardPoll',
  'syncClipboardFromUserPaste', 'pollClipboardSync'];
let text, remote, results, sent, writes, logs, toasts, listener, timers, nextTimer, background, pendingRead, pendingWrite;
const napi = {
  observeClipboardChanges(cb) { listener = cb; return true; },
  stopObservingClipboardChanges(cb) { assert.equal(cb, listener); listener = undefined; },
  takeRemoteClipboardText() { const value = remote; remote = ''; return value; },
  getInputCapabilities() { return 0; },
  getClipboardTextForSyncAsync() {
    if (pendingRead) return pendingRead.promise;
    if (results.length) return Promise.resolve(results.shift());
    return Promise.resolve({ text, failed: false, code: 0 });
  },
  async setClipboardTextAsync(value) {
    writes.push(value);
    if (pendingWrite) { const result = await pendingWrite.promise; if (result !== 0) return result; }
    text = value;
    if (listener) listener();
    return 0;
  },
  sendClipboardText(value) { sent.push(value); return napi.sendResults.length ? napi.sendResults.shift() : 0; },
  sendResults: [],
  appendDiagnosticLog(category, state) { logs.push([category, state]); },
};
const context = vm.createContext({
  ConnectionStatus: { CONNECTED: 2 }, RustDeskNapi: napi,
  RemoteSessionBackgroundTask: { isAppBackground: () => background },
  setTimeout: (fn, delay) => { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; },
  clearTimeout: id => timers.delete(id),
});
vm.runInContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} globalThis.Page = Page;'), context);
function deferred() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}
function create() {
  text = ''; remote = ''; results = []; sent = []; writes = []; logs = []; toasts = []; listener = undefined;
  timers = new Map(); nextTimer = 0; background = false; pendingRead = undefined; pendingWrite = undefined;
  napi.sendResults = [];
  const p = Object.assign(new context.Page(), {
    remotePageVisible: true, isLeavingAfterDisconnect: false, clipboardSyncEnabled: true,
    connectionStatus: 2, desktopWindowActive: true, clipboardTimer: -1, clipboardPolling: false,
    clipboardGeneration: 0, clipboardChangeRevision: 0, clipboardPollRequested: false,
    clipboardPendingRemoteText: '', lastLocalClipboardText: '', clipboardBaselineInitialized: false,
    clipboardReadDiagnostic: '', clipboardWriteDiagnostic: '', clipboardSendDiagnostic: '',
    clipboardListener: undefined, clipboardObserverAttempted: false, waylandTextAllowed: true,
    isPcDevice: () => true, showFileToast: message => toasts.push(message),
  });
  p.ensureClipboardSyncRunning();
  return p;
}
async function poll(p) {
  if (p.clipboardTimer !== -1) { timers.delete(p.clipboardTimer); p.clipboardTimer = -1; }
  await p.pollClipboardSync();
}
function copy(value) { text = value; if (listener) listener(); }
async function test(name, body) { await body(); console.log('PASS ' + name); }

(async () => {
  await test('same local value can be sent again after a remote copy', async () => {
    const p = create(); copy('local_A'); await poll(p);
    remote = 'remote_B'; await poll(p); assert.equal(text, 'remote_B');
    copy('local_A'); await poll(p); assert.deepEqual(sent, ['local_A', 'local_A']);
    assert.deepEqual(writes, ['remote_B']);
  });
  await test('failed initial and subsequent enqueue retry without changing the baseline', async () => {
    const p = create(); napi.sendResults = [-1, 0, -2, 0]; copy('first'); await poll(p);
    assert.equal(p.clipboardBaselineInitialized, false); await poll(p); assert.equal(p.lastLocalClipboardText, 'first');
    copy('next'); await poll(p); assert.equal(p.lastLocalClipboardText, 'first'); await poll(p);
    assert.equal(p.lastLocalClipboardText, 'next'); assert.deepEqual(sent, ['first', 'first', 'next', 'next']);
  });
  await test('failed read is not mistaken for an empty clipboard and later recovers', async () => {
    const p = create(); results.push({ text: '', failed: true, code: 201 }); await poll(p);
    assert.equal(p.clipboardBaselineInitialized, false); copy('read_recovered'); await poll(p);
    assert.deepEqual(sent, ['read_recovered']);
  });
  await test('remote to local remains available when system clipboard reads are denied', async () => {
    const p = create(); remote = 'remote_text'; results.push({ text: '', failed: true, code: 201 });
    await poll(p); assert.equal(text, 'remote_text'); assert.deepEqual(writes, ['remote_text']);
    assert.equal(p.lastLocalClipboardText, 'remote_text'); assert.deepEqual(sent, []);
  });
  await test('a failed remote write is retried and only then becomes the baseline', async () => {
    const p = create(); copy('old'); await poll(p); remote = 'new_remote';
    pendingWrite = deferred(); const running = poll(p); await Promise.resolve(); pendingWrite.resolve(-1); await running;
    assert.equal(p.lastLocalClipboardText, 'old'); assert.equal(p.clipboardPendingRemoteText, 'new_remote');
    pendingWrite = undefined; await poll(p); assert.equal(text, 'new_remote'); assert.equal(p.lastLocalClipboardText, 'new_remote');
  });
  await test('a newer local copy takes priority over a pending remote update', async () => {
    const p = create(); copy('old'); await poll(p); copy('local_new'); remote = 'remote_old'; await poll(p);
    assert.equal(text, 'local_new'); assert.deepEqual(writes, []); assert.deepEqual(sent, ['old', 'local_new']);
  });
  await test('clipboard updates during an async read invalidate the stale result', async () => {
    const p = create(); pendingRead = deferred(); const running = poll(p); copy('new_value');
    pendingRead.resolve({ text: 'stale_value', failed: false, code: 0 }); await running;
    assert.deepEqual(sent, []); assert.equal(p.clipboardPollRequested, true);
    pendingRead = undefined; await poll(p); assert.deepEqual(sent, ['new_value']);
  });
  await test('focus loss, background and disconnected generation prevent stale sends', async () => {
    for (const mode of ['focus', 'background', 'stop']) {
      const p = create(); pendingRead = deferred(); const running = poll(p);
      if (mode === 'focus') { p.desktopWindowActive = false; p.clipboardChangeRevision++; }
      if (mode === 'background') background = true;
      if (mode === 'stop') p.pauseClipboardSync();
      pendingRead.resolve({ text: 'stale', failed: false, code: 0 }); await running;
      assert.deepEqual(sent, []); assert.deepEqual(writes, []);
      if (mode === 'stop') assert.equal(listener, undefined);
    }
  });
  await test('an old async poll cannot clear or enqueue into a replacement session', async () => {
    const p = create(); pendingRead = deferred(); const oldRead = pendingRead; const running = poll(p);
    p.pauseClipboardSync(); p.ensureClipboardSyncRunning(); pendingRead = deferred();
    const current = poll(p); assert.equal(p.clipboardPolling, true);
    oldRead.resolve({ text: 'old_session', failed: false, code: 0 }); await running;
    assert.equal(p.clipboardPolling, true); assert.deepEqual(sent, []);
    pendingRead.resolve({ text: 'new_session', failed: false, code: 0 }); await current;
    assert.deepEqual(sent, ['new_session']); assert.equal(p.clipboardPolling, false);
  });
  await test('a remote write completing after focus loss does not commit its baseline', async () => {
    const p = create(); copy('before_focus_loss'); await poll(p); remote = 'pending_remote';
    pendingWrite = deferred(); const running = poll(p); await Promise.resolve();
    p.desktopWindowActive = false; p.clipboardChangeRevision++;
    pendingWrite.resolve(0); await running; pendingWrite = undefined;
    assert.equal(p.lastLocalClipboardText, 'before_focus_loss');
    p.desktopWindowActive = true; copy('copied_while_away'); await poll(p);
    assert.equal(text, 'copied_while_away'); assert.equal(sent.at(-1), 'copied_while_away');
  });
  await test('authorized user action can resend identical text without generating a paste key', async () => {
    const p = create(); copy('manual'); await poll(p); await p.syncClipboardFromUserPaste();
    assert.deepEqual(sent, ['manual', 'manual']); assert(toasts.includes('已请求同步，请在远端粘贴'));
    assert(!/sendKey|sendPresetShortcut/.test(method('syncClipboardFromUserPaste')));
  });
  await test('manual read failure and concurrent change never enqueue stale data', async () => {
    const p = create(); results.push({ text: '', failed: true, code: 201 }); await p.syncClipboardFromUserPaste();
    assert.deepEqual(sent, []); assert(toasts.includes('无法读取剪贴板，请检查系统权限后重试'));
    pendingRead = deferred(); const running = p.syncClipboardFromUserPaste(); copy('newer');
    pendingRead.resolve({ text: 'stale', failed: false, code: 0 }); await running;
    assert.deepEqual(sent, []); assert(toasts.includes('剪贴板内容已变化，请重新同步'));
  });
  await test('updates in background do not read the system clipboard and logging excludes contents', async () => {
    const p = create(); background = true; copy('private_synthetic_value'); await poll(p);
    assert.deepEqual(sent, []); assert.deepEqual(writes, []);
    background = false; await poll(p); assert.deepEqual(sent, ['private_synthetic_value']);
    assert(!JSON.stringify(logs).includes('private_synthetic_value'));
  });
  await test('permission fallback is a genuine system PasteButton with success-only sync', async () => {
    const ui = read('entry/src/main/ets/widget/RemoteGlassMenu.ets');
    assert(ui.includes('PasteButton({ text: PasteDescription.PASTE'));
    assert(ui.includes("result === PasteButtonOnClickResult.SUCCESS ? 'clipboard-paste-authorized' : 'clipboard-paste-denied'"));
    const handler = method('handleGlassMenuAction');
    assert(handler.includes("case 'clipboard-paste-authorized': this.syncClipboardFromUserPaste()"));
    assert(handler.includes("case 'clipboard-paste-denied': this.showFileToast"));
  });
  console.log('14 clipboard regression groups passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
