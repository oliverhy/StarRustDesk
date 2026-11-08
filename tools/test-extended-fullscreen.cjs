'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r/g, '');
const source = read('entry/src/main/ets/service/ExtendedDisplayFullscreen.ets').replace(/^import .*\n/gm, '');
const log = [];
const windowApi = { WindowStatusType: { FULL_SCREEN: 1, MAXIMIZE: 2, FLOATING: 4, MINIMIZE: 5 },
  MaximizePresentation: { EXIT_IMMERSIVE: 1, ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER: 3 } };
const context = { exports: {}, window: windowApi, RustDeskNapi: { appendDiagnosticLog: (...args) => log.push(args) } };
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020,
  module: ts.ModuleKind.CommonJS } }).outputText, context);
const Policy = context.exports.ExtendedDisplayFullscreen;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function fakeWindow(initial) {
  let status = initial, listener, maximizeGate, enterFailure = false, failBeforeEnter = false, ignoreEnter = false;
  const calls = [];
  function notify() { if (listener) listener(status); }
  return { calls, getWindowStatus: () => status, getWindowProperties: () => ({ isFullScreen: status === 1 }),
    getImmersiveModeEnabledState: () => status === 1,
    on(kind, fn) { assert.equal(kind, 'windowStatusChange'); listener = fn; },
    off(kind, fn) { assert.equal(kind, 'windowStatusChange'); assert.equal(fn, listener); listener = undefined; },
    async maximize(mode) { calls.push(['maximize', mode]); if (maximizeGate) await maximizeGate.promise;
      if (mode === 3) { if (failBeforeEnter) throw Object.assign(Error('private'), { code: 801 });
        if (!ignoreEnter) status = 1; notify(); if (enterFailure) throw Object.assign(Error('private'), { code: 801 }); }
      else { status = 2; notify(); } },
    async recover() { calls.push(['recover']); status = 4; notify(); },
    external(value) { status = value; notify(); }, gate(g) { maximizeGate = g; },
    failEnter() { enterFailure = true; }, failBeforeEnter() { failBeforeEnter = true; }, suppressEnter() { ignoreEnter = true; } };
}
let count = 0;
async function test(name, fn) { await fn(); count++; console.log('PASS ' + name); }
(async () => {
  await test('extension enters actual immersive fullscreen and restores floating window only', async () => {
    const primary = fakeWindow(4), ext = fakeWindow(4), state = [];
    const p = new Policy(ext, (full, busy) => state.push([full, busy])); p.start();
    assert.deepEqual(state.at(-1), [false, false]); assert(await p.toggle());
    assert.deepEqual(state.at(-1), [true, false]); assert.deepEqual(ext.calls, [['maximize', 3]]);
    assert(await p.toggle()); assert.deepEqual(state.at(-1), [false, false]);
    assert.deepEqual(ext.calls.at(-1), ['recover']); assert.equal(primary.calls.length, 0); p.dispose();
  });
  await test('maximized extension is restored to maximized, not floating', async () => {
    const ext = fakeWindow(2), p = new Policy(ext, () => {}); p.start();
    assert(await p.toggle()); assert(await p.toggle());
    assert.deepEqual(ext.calls, [['maximize', 3], ['maximize', 1]]); p.dispose();
  });
  await test('fullscreen entered by the system is detected and exits safely', async () => {
    const ext = fakeWindow(4), state = [], p = new Policy(ext, (...args) => state.push(args)); p.start();
    ext.external(1); assert.deepEqual(state.at(-1), [true, false]);
    assert(await p.toggle()); assert.deepEqual(ext.calls, [['maximize', 1]]);
    ext.external(4); assert.deepEqual(state.at(-1), [false, false]); p.dispose();
  });
  await test('system exit clears stale restore state before a later system fullscreen', async () => {
    const ext = fakeWindow(4), p = new Policy(ext, () => {}); p.start(); assert(await p.toggle());
    ext.external(2); ext.external(1); assert(await p.toggle());
    assert.deepEqual(ext.calls, [['maximize', 3], ['maximize', 1]]); p.dispose();
  });
  await test('unsupported or partially failed fullscreen restores prior window state', async () => {
    const unsupported = fakeWindow(5), p = new Policy(unsupported, () => {}); p.start();
    assert.equal(await p.toggle(), false); assert.deepEqual(unsupported.calls, []); p.dispose();
    const ext = fakeWindow(4), state = [], q = new Policy(ext, (...args) => state.push(args)); q.start(); ext.failEnter();
    assert.equal(await q.toggle(), false); assert.deepEqual(ext.calls, [['maximize', 3], ['recover']]);
    assert.deepEqual(state.at(-1), [false, false]); q.dispose();
    const verify = fakeWindow(2), r = new Policy(verify, () => {}); r.start(); verify.suppressEnter();
    assert.equal(await r.toggle(), false); assert.deepEqual(verify.calls, [['maximize', 3]]); r.dispose();
    const untouched = fakeWindow(4), u = new Policy(untouched, () => {}); u.start(); untouched.failBeforeEnter();
    assert.equal(await u.toggle(), false); assert.deepEqual(untouched.calls, [['maximize', 3]]); u.dispose();
    assert(log.some(([, msg]) => msg.includes('fullscreen_failed entering=1 code=801')));
    assert(!log.some(([, msg]) => msg.includes('private')));
  });
  await test('double clicks are suppressed and closing during an async transition cannot update a dead page', async () => {
    const ext = fakeWindow(4), state = [], p = new Policy(ext, (...args) => state.push(args)), gate = deferred();
    p.start(); ext.gate(gate); const first = p.toggle(); assert.equal(await p.toggle(), false);
    const before = state.length; p.dispose(); gate.resolve(); assert.equal(await first, false);
    assert.equal(state.length, before); assert.deepEqual(ext.calls, [['maximize', 3]]);
  });
  const page = read('entry/src/main/ets/pages/ExtendedDisplayPage.ets');
  assert(page.includes('context.windowStage.getMainWindowSync()'), 'use extension ability window, never the primary global window');
  assert(page.includes("Button(translate('全屏'") && page.includes("Button(translate('退出全屏'"));
  assert(page.includes('if (!this.fullscreen)') && page.includes('if (this.fullscreen)'));
  assert(page.includes('event.stopPropagation()') && page.includes('this.keyboardFocus(false)'));
  assert(page.includes('this.fullscreenPolicy?.dispose()') && page.includes('this.areaWidth = Math.max(1, Number(area.width))'));
  console.log(`PASS ${count} extension fullscreen policy cases and page wiring (device acceptance pending)`);
})().catch(error => { console.error(error); process.exitCode = 1; });
