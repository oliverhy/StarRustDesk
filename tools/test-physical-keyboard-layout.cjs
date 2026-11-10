'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, 'entry/src/main/ets', name + '.ets'), 'utf8').replace(/\r\n/g, '\n');
const plain = value => JSON.parse(JSON.stringify(value));
const tick = () => new Promise(resolve => setImmediate(resolve));
const keyboard = (id = 7, uniq = 'test-only-keyboard-identity') => ({
  id, name: 'Logitech dual-OS keyboard', vendor: 1133, product: 1, bus: 5, uniq, phys: '',
  sources: ['keyboard'], isVirtual: false, type: 2,
});
function harness(disk = new Map()) {
  const calls = [], logs = [], timers = new Map(), listeners = new Set(), states = [], applies = [], bindingStates = [];
  let timer = 0, devices = [keyboard()], list = null, failInfo = -1, failWrite = false, silentWrite = false, failListener = false;
  const context = vm.createContext({ exports: {}, hilog: { info() {} },
    setTimeout(fn, ms) { const id = ++timer; timers.set(id, { fn, ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
    inputDevice: {
      KeyboardType: { UNKNOWN: 1, ALPHABETIC_KEYBOARD: 2 },
      async getDeviceList() { return list ? list() : devices.map(d => d.id); },
      async getDeviceInfo(id) { if (id === failInfo) throw Error('test query failure'); return devices.find(d => d.id === id); },
      async getKeyboardType(id) { return devices.find(d => d.id === id).type; },
      on(_, fn) { if (failListener) throw Error('unavailable'); listeners.add(fn); },
      off(_, fn) { listeners.delete(fn); },
    },
    RustDeskNapi: new Proxy({}, { get(_, name) {
      if (name === 'getInputCapabilities') return () => 8;
      if (name === 'appendDiagnosticLog') return (...args) => logs.push(args);
      if (name === 'getOption') return key => disk.get(key) || '';
      if (name === 'setOption') return (key, value) => {
        if (failWrite) return -1;
        if (!silentWrite) disk.set(key, value);
        return 0;
      };
      return (...args) => { calls.push([name, ...args]); return 0; };
    } }),
  });
  for (const file of ['model/KeyboardRemapping', 'model/PhysicalKeyboardLayout', 'model/RemoteToolbarPlacement',
    'model/RemotePeerOptions', 'service/RemotePeerPreferences', 'service/ConnectionService', 'service/PhysicalKeyboardLayoutService']) {
    const source = read(file).replace(/^import[\s\S]*?from ['"][^'"]+['"];?\n/gm, '');
    const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021,
      module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
    assert.equal(compiled.diagnostics.length, 0, file);
    vm.runInContext(compiled.outputText, context, { filename: file });
    Object.assign(context, context.exports);
  }
  const service = new context.PhysicalKeyboardLayoutService(s => states.push(s), (swap, bindings) => {
    applies.push(swap); bindingStates.push(plain(bindings));
  });
  return { context, service, states, applies, bindingStates, calls, logs, disk, timers, listeners, S: context.ConnectionService,
    devices(value) { devices = value; }, list(value) { list = value; }, failInfo(value) { failInfo = value; },
    failWrite(value) { failWrite = value; }, silentWrite(value) { silentWrite = value; }, failListener(value) { failListener = value; },
    change() { for (const listener of listeners) listener({ type: 'change', deviceId: 7 }); },
    keys() { return calls.filter(c => c[0] === 'sendKeyEvent').map(c => c.slice(1)); },
    clear() { calls.length = logs.length = 0; },
  };
}
const tests = [];
const test = (name, run) => tests.push([name, run]);
const capture = (h, first, second) => {
  const c = new h.context.KeyboardLayoutCapture(7); c.begin();
  c.input(first, 0, 7); c.input(first, 1, 7); c.input(second, 0, 7); c.input(second, 1, 7);
  return c;
};
test('calibration detects identity and a genuine Command/Option swap', () => {
  const h = harness();
  assert.equal(capture(h, 2076, 2045).result(), false);
  assert.equal(capture(h, 2045, 2076).result(), true);
});
test('capture requires release, ignores repeats and never accepts wrong devices or ordinary text', () => {
  const h = harness(), c = new h.context.KeyboardLayoutCapture(7); c.begin();
  c.input(2045, 0, 8); assert.equal(c.error, 'device'); assert.equal(c.phase, 'command');
  c.input(2017, 0, 7); assert.equal(c.error, 'modifier'); assert.equal(c.phase, 'command');
  c.input(2045, 0, 7); c.input(2076, 0, 7); assert.equal(c.phase, 'command-release');
  c.input(2076, 1, 7); assert.equal(c.phase, 'command-release');
  c.input(2045, 1, 7); assert.equal(c.phase, 'option');
  c.input(2045, 0, 7); assert.equal(c.error, 'same'); assert.equal(c.result(), undefined);
  c.input(2076, 0, 7); c.input(2076, 1, 7); assert.equal(c.result(), true);
  c.begin(); assert.equal(c.result(), undefined, 'restart discards the prior draft');
  for (const code of [2077, 2046, 2072, 2073, 2047, 2086]) c.input(code, 0, 7);
  assert.equal(c.phase, 'command', 'right modifiers and unrelated keys cannot silently calibrate');
});
test('fingerprints require physical identity, survive ephemeral ID changes and do not expose identity', () => {
  const h = harness(), f = h.context.physicalKeyboardFingerprint, d = keyboard();
  assert.equal(f({ ...d, uniq: '', phys: '' }), '');
  assert.equal(f(d), f({ ...d, id: 99 }));
  assert.notEqual(f(d), f({ ...d, uniq: 'another-keyboard' }));
  assert.match(f(d), /^keyboard-v1-[0-9a-f]{16}$/);
  assert(!f(d).includes(d.uniq) && !f(d).includes('Logitech'));
  assert.equal(f({ ...d, uniq: 'x'.repeat(513) }), '');
  assert.equal(f({ ...d, name: '' }), '');
});
test('calibration records reject corrupt, duplicate, secret-bearing and oversized data', () => {
  const h = harness(), decode = h.context.decodeKeyboardLayoutRecords, fp = h.context.physicalKeyboardFingerprint(keyboard());
  const row = { fingerprint: fp, swap: true };
  assert.deepEqual(plain(decode(JSON.stringify([row]))), [row]);
  for (const raw of ['{', 'null', '{}', '[null]', 'x'.repeat(8193), JSON.stringify([row, row]),
    JSON.stringify([{ ...row, password: 'test-only' }]), JSON.stringify([{ ...row, swap: '1' }]),
    JSON.stringify([{ fingerprint: 'bad', swap: true }]), JSON.stringify(Array(25).fill(row))]) {
    assert.equal(decode(raw).length, 0);
  }
});
test('auto never guesses a swap from the keyboard vendor or model', async () => {
  const h = harness(); h.service.start('auto'); await tick();
  assert.equal(h.service.snapshot().count, 1); assert.equal(h.service.snapshot().calibrated, false);
  assert.equal(h.applies.at(-1), false); assert.equal(h.timers.size, 0);
  h.service.stop(); assert.equal(h.listeners.size, 0);
});
test('confirmed calibration persists and system mode disables it without deleting it', async () => {
  const h = harness(); h.service.start('apple'); await tick();
  assert(h.service.saveCalibration(h.service.snapshot(), true)); assert.equal(h.applies.at(-1), true);
  h.service.setMode('system'); assert.equal(h.applies.at(-1), false);
  h.service.setMode('auto'); assert.equal(h.applies.at(-1), true);
  h.service.setMode('invalid'); assert.equal(h.applies.at(-1), true);
  const serialized = [...h.disk.values()].join('');
  assert(!serialized.includes('Logitech') && !serialized.includes('test-only-keyboard-identity'));
  assert(h.logs.every(l => !l.join(' ').includes('Logitech') && !l.join(' ').includes('test-only-keyboard-identity')));
  h.service.stop(); const next = harness(h.disk); next.devices([keyboard(42)]); next.service.start('auto'); await tick();
  assert.equal(next.applies.at(-1), true, 'known identity survives device ID changes and a fresh runtime');
});
test('calibration is not restored onto another keyboard or after identity disappears', async () => {
  const h = harness(); h.service.start('apple'); await tick(); assert(h.service.saveCalibration(h.service.snapshot(), true));
  h.devices([keyboard(8, 'different-hardware')]); h.change(); assert.equal(h.applies.at(-1), false); await tick();
  assert.equal(h.service.snapshot().calibrated, false);
  h.devices([keyboard(8, '')]); h.change(); await tick(); assert.equal(h.service.snapshot().calibrated, false);
});
test('unidentified keyboards allow session-only calibration, not brand-based persistence', async () => {
  const h = harness(); h.devices([keyboard(7, '')]); h.service.start('apple'); await tick();
  assert(h.service.saveCalibration(h.service.snapshot(), true)); assert.equal(h.applies.at(-1), true); assert.equal(h.disk.size, 0);
  h.service.stop(); h.service.start('auto'); await tick(); assert.equal(h.applies.at(-1), false);
});
test('multiple keyboards pause correction and reject calibration, including a changed inventory', async () => {
  const h = harness(); h.service.start('apple'); await tick(); const captured = h.service.snapshot();
  assert(h.service.saveCalibration(captured, true));
  h.devices([keyboard(), keyboard(9, 'second')]); h.change();
  assert.equal(h.applies.at(-1), false); assert.equal(h.service.saveCalibration(captured, true), false);
  await tick(); assert.equal(h.service.snapshot().count, 2); assert.equal(h.applies.at(-1), false);
  assert.equal(h.service.saveCalibration(h.service.snapshot(), true), false);
});
test('multi-device capture uses only enumerated devices and accepts an explicitly confirmed composite keyboard', () => {
  const h = harness(), c = new h.context.KeyboardLayoutCapture(-1, [7, 9], true); c.begin();
  c.input(2045, 0, 99); assert.equal(c.error, 'device'); assert.equal(c.phase, 'command');
  c.input(2017, 0, 7); assert.equal(c.error, 'modifier');
  c.input(2045, 0, 7); c.input(2045, 1, 9); assert.equal(c.phase, 'command-release');
  c.input(2045, 1, 7); c.input(2076, 0, 9); c.input(2076, 1, 9);
  assert.equal(c.result(), true); assert.deepEqual(plain(c.devices()), [7, 9]);
  c.begin(); assert.deepEqual(plain(c.devices()), [], 'restarting calibration discards the previous capture');
});
test('multi-keyboard calibration is scoped per device and restores only stable identities', async () => {
  const h = harness(); h.devices([keyboard(7, 'first'), keyboard(9, 'second')]);
  h.service.start('apple'); await tick(); const revision = h.service.snapshot().revision;
  assert(h.service.saveCalibrationForDevices(revision, [7], true));
  assert.deepEqual(h.bindingStates.at(-1), [
    { deviceId:7, swap:true, calibrated:true }, { deviceId:9, swap:false, calibrated:false }]);
  assert.equal(h.applies.at(-1), false, 'unknown devices do not inherit a multi-device swap');
  h.service.stop(); const next = harness(h.disk);
  next.devices([keyboard(17, 'first'), keyboard(19, 'second')]); next.service.start('auto'); await tick();
  assert.deepEqual(next.bindingStates.at(-1), [
    { deviceId:17, swap:true, calibrated:true }, { deviceId:19, swap:false, calibrated:false }]);
  next.service.setMode('system'); assert.deepEqual(next.bindingStates.at(-1), []);
  next.service.setMode('auto'); assert.equal(next.bindingStates.at(-1)[0].swap, true);
});
test('composite calibration is atomic, rejects stale devices and preserves ambiguous identities only for the session', async () => {
  const h = harness(); h.devices([keyboard(7, 'same'), keyboard(9, 'same'), keyboard(11, 'other')]);
  h.service.start('apple'); await tick(); const revision = h.service.snapshot().revision;
  for (const ids of [[7, 7], [7, 99], [], [7, 9, 11]])
    assert.equal(h.service.saveCalibrationForDevices(revision, ids, true), false);
  assert(h.service.saveCalibrationForDevices(revision, [7, 9], true));
  assert.equal(h.disk.size, 0, 'duplicate fingerprints cannot be persisted');
  assert.deepEqual(h.bindingStates.at(-1).map(b=>b.swap), [true, true, false]);
  h.change(); await tick(); assert.deepEqual(h.bindingStates.at(-1).map(b=>b.swap), [false, false, false]);
  assert.equal(h.service.saveCalibrationForDevices(revision, [7], true), false, 'stale inventories are rejected');
  assert(h.logs.every(entry => !entry.join(' ').includes('same') && !entry.join(' ').includes('Logitech')));
});
test('distinct composite devices save together or leave all mappings unchanged on storage failure', async () => {
  const h = harness(); h.devices([keyboard(7, 'first'), keyboard(9, 'second')]);
  h.service.start('apple'); await tick(); const revision = h.service.snapshot().revision;
  h.failWrite(true); assert.equal(h.service.saveCalibrationForDevices(revision, [7, 9], true), false);
  assert.deepEqual(h.bindingStates.at(-1).map(b=>b.swap), [false, false]);
  h.failWrite(false); assert(h.service.saveCalibrationForDevices(revision, [7, 9], true));
  assert.deepEqual(h.bindingStates.at(-1).map(b=>b.swap), [true, true]);
  assert(![...h.disk.values()].join('').includes('first') && ![...h.disk.values()].join('').includes('second'));
});
test('device change releases held mapped keys and a reused device ID cannot inherit another keyboard profile', async () => {
  const h = harness(); h.devices([keyboard(7, 'first'), keyboard(9, 'second')]);
  const service = new h.context.PhysicalKeyboardLayoutService(()=>{}, (swap, bindings)=>h.S.configureHardwareKeyboardLayout(swap, bindings));
  service.start('apple'); await tick(); assert(service.saveCalibrationForDevices(service.snapshot().revision, [7], true));
  h.clear(); h.S.sendHardwareControlKey(18,0,2045,'native',7);
  assert(h.keys().some(k=>k[0]===91&&k[1]===0));
  h.devices([keyboard(7, 'replacement'), keyboard(9, 'second')]); h.change();
  assert(h.keys().some(k=>k[0]===91&&k[1]===1), 'inventory invalidation releases held keys before rebinding');
  await tick(); h.clear(); h.S.sendHardwareControlKey(18,0,2045,'native',7);
  assert.equal(h.keys().at(-1)[0],18, 'reused runtime ID with a different identity remains system-original');
  service.stop();
});
test('keyboard-source unknown devices may be calibrated, while mouse, virtual and keypad devices are excluded', async () => {
  const h = harness(); h.devices([keyboard(), { ...keyboard(8), sources: ['mouse'] },
    { ...keyboard(9), isVirtual: true }, { ...keyboard(10, 'unknown-interface'), type: 1 },
    { ...keyboard(11), type: 3 }]);
  h.service.start('auto'); await tick(); assert.equal(h.service.snapshot().count, 2);
  assert.deepEqual(plain(h.service.calibrationDeviceIds()), [7, 10]);
  assert.deepEqual(h.bindingStates.at(-1).map(b=>b.swap), [false, false]);
});
test('incomplete enumeration fails closed rather than applying a calibration to an uncertain keyboard', async () => {
  const h = harness(); h.service.start('apple'); await tick(); assert(h.service.saveCalibration(h.service.snapshot(), true));
  h.devices([keyboard(), keyboard(9, 'second')]); h.failInfo(9); h.change(); await tick();
  assert.equal(h.service.snapshot().ready, false); assert.equal(h.applies.at(-1), false);
});
test('enumeration has a bounded timeout and late results cannot re-enable correction', async () => {
  const h = harness(); let resolve; h.list(() => new Promise(r => { resolve = r; })); h.service.start('auto');
  assert.equal(h.timers.size, 1); const deadline = [...h.timers.values()][0]; assert.equal(deadline.ms, 4000);
  deadline.fn(); await tick(); assert.equal(h.service.snapshot().ready, false); assert.equal(h.timers.size, 0);
  resolve([7]); await tick(); assert.equal(h.service.snapshot().ready, false);
});
test('older inventories and stopped services cannot overwrite current state', async () => {
  const h = harness(), pending = []; h.list(() => new Promise(r => pending.push(r))); h.service.start('auto');
  h.change(); pending[1]([7]); await tick(); assert.equal(h.service.snapshot().ready, true);
  const revision = h.service.snapshot().revision; pending[0]([]); await tick(); assert.equal(h.service.snapshot().revision, revision);
  assert.equal(h.service.snapshot().count, 1);
  h.change(); h.service.stop(); const stateCount = h.states.length; pending[2]([7]); await tick();
  assert.equal(h.states.length, stateCount); assert.equal(h.applies.at(-1), false); assert.equal(h.timers.size, 0);
});
test('failed or silently dropped storage cannot activate a new calibration', async () => {
  for (const failure of ['failWrite', 'silentWrite']) {
    const h = harness(); h.service.start('apple'); await tick(); h[failure](true);
    assert.equal(h.service.saveCalibration(h.service.snapshot(), true), false);
    assert.equal(h.service.snapshot().calibrated, false); assert.equal(h.applies.at(-1), false);
    h[failure](false); assert(h.service.saveCalibration(h.service.snapshot(), false));
  }
});
test('missing device listener and throwing UI callbacks do not crash discovery or teardown', async () => {
  const h = harness(); h.failListener(true); h.service.start('auto'); await tick();
  assert.equal(h.service.snapshot().ready, true);
  const service = new h.context.PhysicalKeyboardLayoutService(() => { throw Error('UI'); }, () => { throw Error('wire'); });
  service.start('auto'); await tick(); service.stop();
  assert(h.logs.some(l => l[1] === 'state_apply_failed')); assert(h.logs.some(l => l[1] === 'state_publish_failed'));
});
test('left/right Command and Option swap once across keys, letter masks and real key-up', () => {
  for (const [source, identity, target, rawMask, expectedMask] of [[18,2045,91,4,8], [165,2046,92,4,8],
    [91,2076,18,8,4], [92,2077,165,8,4]]) {
    const h = harness(); h.S.configureHardwareKeyboardLayout(true); h.clear();
    h.S.syncNativeModifierState(rawMask); h.S.sendHardwareControlKey(source,0,identity);
    h.S.sendLetterKeyEvent('c',6,0,rawMask); h.S.sendLetterKeyEvent('c',6,1,rawMask);
    assert(h.keys().some(k => k[0] === target && k[1] === 0));
    assert(h.calls.filter(c => c[0] === 'sendPhysicalKeyEvent').every(c => c[3] === expectedMask));
    h.S.sendHardwareControlKey(source,1,identity); h.S.sendMouseEvent(0,0,1);
    assert(h.keys().some(k => k[0] === target && k[1] === 1)); assert.equal(h.calls.at(-1)[4],0);
  }
});
test('snapshot-only hardware masks are corrected without double mapping', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(true); h.clear();
  h.S.syncHeldModifierState(false,false,true,false); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],8);
  h.S.syncHeldModifierState(false,false,false,true); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],4);
  h.S.syncHeldModifierState(false,false,false,false); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],0);
});
test('explicit custom modifier rules take precedence and do not re-map the calibrated target', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(true);
  h.S.configureKeyboardRemapping(JSON.stringify({version:1,enabled:true,rules:[
    {source:18,target:91,modifiers:0,enabled:true}, {source:17,target:91,modifiers:0,enabled:true}]}));
  h.clear(); h.S.sendHardwareControlKey(18,0,2045); h.S.sendLetterKeyEvent('v',25,0,4);
  assert.equal(h.keys()[0][0],91); assert.equal(h.calls.at(-1)[3],8);
  h.S.releaseModifiers(); h.clear(); h.S.sendHardwareControlKey(17,0,2072); h.S.sendLetterKeyEvent('c',6,0,1);
  assert.equal(h.keys()[0][0],91); assert.equal(h.calls.at(-1)[3],8);
});
test('virtual modifiers remain independent and are not corrected as physical keys', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(true); h.clear();
  h.S.sendHardwareControlKey(18,0,2045); h.S.sendKeyEvent(18,0,10018); h.S.sendMouseEvent(0,0,1);
  assert.equal(h.calls.at(-1)[4],12);
  h.S.sendHardwareControlKey(18,1,2045); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],4);
  h.S.sendKeyEvent(18,1,10018); h.S.sendMouseEvent(0,0,1); assert.equal(h.calls.at(-1)[4],0);
});
test('only the calibrated keyboard swaps modifiers while another keyboard and virtual controls stay independent', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(false, [
    {deviceId:7,swap:true,calibrated:true}, {deviceId:9,swap:false,calibrated:false}]); h.clear();
  h.S.syncNativeModifierState(4);
  assert.equal(h.keys().length, 0, 'ambiguous global snapshot cannot create a phantom modifier');
  h.S.sendHardwareControlKey(18,0,2045,'native',7); h.S.sendLetterKeyEvent('c',6,0,4);
  assert(h.keys().some(k=>k[0]===91&&k[1]===0)); assert.equal(h.calls.find(c=>c[0]==='sendPhysicalKeyEvent')[3],8);
  h.S.sendHardwareControlKey(18,0,2045,'ark',7);
  assert.equal(h.keys().filter(k=>k[0]===91&&k[1]===0).length,1, 'same-device native/ArkUI events deduplicate');
  h.S.sendHardwareControlKey(18,0,2045,'native',9); h.S.sendMouseEvent(0,0,1);
  assert.equal(h.calls.at(-1)[4],12, 'both keyboards can hold their own modifier');
  h.S.sendHardwareControlKey(18,1,2045,'native',7); h.S.sendMouseEvent(0,0,1);
  assert.equal(h.calls.at(-1)[4],4, 'releasing one keyboard leaves the other held');
  h.S.sendHardwareControlKey(18,1,2045,'native',9); h.S.sendMouseEvent(0,0,1);
  assert.equal(h.calls.at(-1)[4],0);
  h.S.sendHardwareControlKey(18,0,2045,'native',-1); assert.equal(h.keys().at(-1)[0],18, 'unknown device stays system-original');
  h.S.releaseModifiers(); h.clear(); h.S.sendKeyEvent(18,0,10018); h.S.sendMouseEvent(0,0,1);
  assert.equal(h.calls.at(-1)[4],4, 'virtual modifier remains unmodified');
  assert(h.logs.every(entry=>!entry.join(' ').includes('2045') && !entry.join(' ').includes('deviceId')));
});
test('two keyboards holding the same modifier release it only after both release', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(false, [
    {deviceId:7,swap:true,calibrated:true}, {deviceId:9,swap:false,calibrated:false}]); h.clear();
  h.S.sendHardwareControlKey(17,0,2072,'native',7); h.S.sendHardwareControlKey(17,0,2072,'native',9);
  assert.equal(h.keys().filter(k=>k[0]===17&&k[1]===0).length,1);
  h.S.sendHardwareControlKey(17,1,2072,'native',7); assert.equal(h.keys().filter(k=>k[0]===17&&k[1]===1).length,0);
  h.S.sendHardwareControlKey(17,1,2072,'native',9); assert.equal(h.keys().filter(k=>k[0]===17&&k[1]===1).length,1);
});
test('a missing or unknown event device never inherits even a single calibrated keyboard', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(true, [{deviceId:7,swap:true,calibrated:true}]);
  h.clear(); h.S.syncNativeModifierState(4); assert.equal(h.keys().length,0);
  h.S.sendHardwareControlKey(18,0,2045,'native',99); assert.equal(h.keys().at(-1)[0],18);
  h.S.sendHardwareControlKey(18,1,2045,'native',99); h.S.sendHardwareControlKey(18,0,2045,'native',-1);
  assert.equal(h.keys().at(-1)[0],18); h.S.releaseModifiers(); h.clear();
  h.S.sendHardwareControlKey(18,0,2045,'native',7); assert.equal(h.keys().at(-1)[0],91);
});
test('layout diagnostics disclose only bounded status, never hardware identifiers or key contents', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(false, [
    {deviceId:43872,swap:true,calibrated:true}, {deviceId:98103,swap:false,calibrated:false}]); h.clear();
  h.S.syncNativeModifierState(4); h.S.sendHardwareControlKey(18,0,2045,'native',43872);
  h.S.sendHardwareControlKey(18,1,2045,'native',43872);
  const logs = h.logs.map(entry=>entry.join(' ')).join('\n');
  assert(logs.includes('snapshot_suppressed') && logs.includes('device_route'));
  for (const forbidden of ['43872','98103','2045','keyCode','deviceId']) assert(!logs.includes(forbidden));
});
test('layout changes release old keys and leave Ctrl, Shift, Chinese text and shortcuts unchanged', () => {
  const h = harness(); h.S.configureHardwareKeyboardLayout(true); h.clear();
  h.S.sendHardwareControlKey(18,0,2045); h.S.configureHardwareKeyboardLayout(false);
  assert(h.keys().some(k => k[0] === 91 && k[1] === 1));
  h.clear(); h.S.sendHardwareControlKey(18,0,2045); assert.equal(h.keys()[0][0],18);
  h.S.releaseModifiers(); h.S.configureHardwareKeyboardLayout(true); h.clear();
  h.S.sendHardwareControlKey(17,0,2072); h.S.sendHardwareControlKey(16,0,2047);
  assert.deepEqual(h.keys().map(k => k.slice(0,2)), [[17,0],[16,0]]);
  h.S.releaseModifiers(); h.clear(); h.S.sendText('中文输入与粘贴'); h.S.sendShortcutKey(114,1); h.S.sendPrintableShortcutKey(67,1);
  assert.deepEqual(h.calls[0],['sendText','中文输入与粘贴']); assert.equal(h.keys()[0][0],114);
  assert(h.calls.some(c => c[0] === 'sendPrintableShortcutKey' && c[1] === 67 && c[2] === 1));
});
test('layout mode is per server and remote peer, separate from calibration and custom mappings', () => {
  const h = harness(), p = new h.context.RemotePeerPreferences('server-A','123');
  assert(p.set('keyboard-layout-mode','apple')); assert(p.flush());
  assert.equal(new h.context.RemotePeerPreferences('server-A','123').get('keyboard-layout-mode'),'apple');
  assert.equal(new h.context.RemotePeerPreferences('server-B','123').get('keyboard-layout-mode'),'');
  assert.equal(new h.context.RemotePeerPreferences('server-A','456').get('keyboard-layout-mode'),'');
  assert.equal(p.set('keyboard-layout-mode','swap'),false); assert.equal(p.set('physical-keyboard-layout-v1','[]'),false);
  assert.equal(p.get('keyboard-remap-v1'),'');
});
const method = (file, name) => {
  const source = read(file), start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name); return source.slice(start, source.indexOf('\n  }', start) + 4);
};
test('calibration dialog consumes key events locally and cannot save an incomplete or cancelled draft', () => {
  const h = harness(), ctx = h.context; ctx.KeyType = {Down:0,Up:1};
  vm.runInContext(ts.transpile('class Dialog {' + ['begin','handleKey','prompt','save'].map(n => method('widget/KeyboardLayoutCalibrationDialog',n)).join('\n') + '} exports.Dialog=Dialog;'),ctx);
  let saves = 0, closed = 0;
  const dialog = Object.assign(new ctx.exports.Dialog(), { capture:new ctx.KeyboardLayoutCapture(7), phase:'idle', ready:false,
    swap:false,error:'',onSave:()=>{saves++;return false;},close:()=>closed++ });
  dialog.begin(); dialog.save(); assert.equal(saves,0);
  for (const [keyCode,type] of [[2045,0],[2045,1],[2076,0],[2076,1]]) assert(dialog.handleKey({keyCode,type,deviceId:7}));
  assert.equal(dialog.ready,true); assert.equal(dialog.swap,true);
  dialog.save(); assert.equal(saves,1); assert.equal(closed,0); assert(dialog.error.includes('保存校准失败'));
  dialog.onSave=()=>true; dialog.save(); assert.equal(closed,1); assert.equal(h.calls.length,0);
  const widget=read('widget/KeyboardLayoutCalibrationDialog');
  assert(widget.includes('this.onClose(); this.controller?.close()'));
  assert(!/sendText|keyText|appendDiagnosticLog/.test(widget), 'text and key contents are never recorded');
});
test('composite-keyboard dialog requires a completed capture and forwards both confirmed devices', () => {
  const h = harness(), ctx = h.context; ctx.KeyType = {Down:0,Up:1};
  vm.runInContext(ts.transpile('class Dialog {' + ['begin','handleKey','prompt','save'].map(n => method('widget/KeyboardLayoutCalibrationDialog',n)).join('\n') + '} exports.Dialog=Dialog;'),ctx);
  let saved;
  const dialog = Object.assign(new ctx.exports.Dialog(), { capture:new ctx.KeyboardLayoutCapture(-1,[7,9],true),
    phase:'idle',ready:false,swap:false,composite:false,error:'',onSave:(swap,ids)=>{saved={swap,ids:plain(ids)};return true;},close(){} });
  dialog.begin();
  for (const [keyCode,type,deviceId] of [[2045,0,7],[2045,1,7],[2076,0,9],[2076,1,9]])
    assert(dialog.handleKey({keyCode,type,deviceId}));
  assert.equal(dialog.ready,true); assert.equal(dialog.composite,true); dialog.save();
  assert.deepEqual(saved,{swap:true,ids:[7,9]});
  assert(read('widget/KeyboardLayoutCalibrationDialog').includes('请确认两次按键来自同一把键盘'));
});
test('native key events forward the identified device through the real keyboard mapper', () => {
  const h = harness(), ctx = h.context; ctx.ConnectionStatus={CONNECTED:2}; ctx.isNavigationControlKey=()=>false;
  vm.runInContext(ts.transpile('class Page {'+method('pages/RemotePage','handleNativeKeyInput')+'} exports.InputPage=Page;'),ctx);
  const page = Object.assign(new ctx.exports.InputPage(), {connectionStatus:2,desktopWindowActive:true,
    secondaryHeldKeys:[], mapControlKeyCode:code=>code===2045?18:0,
    mapHarmonyKeyCodeToUsbHidCode:()=>6,mapHarmonyKeyCodeToLetter:()=> 'c'});
  h.S.configureHardwareKeyboardLayout(false,[{deviceId:7,swap:true,calibrated:true},{deviceId:9,swap:false,calibrated:false}]); h.clear();
  page.handleNativeKeyInput({source:1,deviceId:7,keyCode:2045,action:0,modifierValid:false,capsLockValid:false});
  page.handleNativeKeyInput({source:1,deviceId:7,keyCode:2019,action:0,modifierValid:true,modifierMask:4,capsLockValid:false});
  assert(h.keys().some(k=>k[0]===91&&k[1]===0));
  assert.equal(h.calls.find(c=>c[0]==='sendPhysicalKeyEvent')[3],8);
  assert(h.logs.every(entry=>!entry.join(' ').includes('2045') && !entry.join(' ').includes('deviceId')));
});
test('UI has an independent input-settings entrance and blocks all remote routes during calibration', () => {
  const source=read('pages/RemotePage'), settings=method('pages/RemotePage','buildKeyboardSettingsOptions');
  assert(source.includes("case 'keyboardSettings': this.openKeyboardSettings()"));
  assert(source.includes("case 'mouseSettings': this.openMouseSettings()"));
  assert(settings.indexOf("'键盘模式'") < settings.indexOf("'键盘布局'"));
  assert(settings.indexOf("'键盘布局'") < settings.indexOf("'自定义键盘映射：已开启'"));
  assert(settings.includes("this.keyboardLayoutMode === 'apple'"));
  assert(settings.includes('this.keyboardLayoutState.count > 0'), 'multiple devices may start explicit calibration');
  for (const name of ['handleNativeKeyInput','handleRemoteKey','handleNativeMouseInput','syncHardwareKeyState',
    'handleRemoteTouch','handleRemoteMouse','handleRemoteClickFallback','handleRemoteAxis','handleRemoteHover']) {
    assert(method('pages/RemotePage',name).includes('this.showKeyboardCalibration'),name);
  }
  assert(source.includes('控 → 输入 → 键盘设置'));
  assert(method('pages/RemotePage','aboutToDisappear').includes('configureHardwareKeyboardLayout(false)'));
});
function pageHarness(h) {
  const ctx=h.context; ctx.ConnectionStatus={CONNECTED:2};
  vm.runInContext(ts.transpile('class Page {'+['setKeyboardLayoutMode','openKeyboardLayoutCalibration','openKeyboardSettings',
    'openMouseSettings','closeInputSettings'].map(n=>method('pages/RemotePage',n)).join('\n')+'} exports.LayoutPage=Page;'),ctx);
  return Object.assign(new ctx.exports.LayoutPage(),{
    peerPreferences:new ctx.RemotePeerPreferences('server','peer'),connectionStatus:2,remotePageVisible:true,
    keyboardLayoutMode:'auto',keyboardLayoutService:h.service,showKeyboardPanel:false,showKeyboardSettings:false,
    showMouseSettings:false,showKeyboardCalibration:false,showFileToast(){},setControlMenu(){},
    releaseRemoteNavigationKeys(){},releaseVirtualModifiers(){},releaseHeldMouseButtons(){},stopEdgeAutoPan(){},
    closeRemoteKeyboard(){this.showKeyboardPanel=false;},hardwareModifierTrackingActive:true,
  });
}
test('page saves a layout mode only after successful scoped persistence and rolls back failures', async () => {
  const h=harness(), page=pageHarness(h); h.service.start('auto'); await tick();
  page.setKeyboardLayoutMode('apple'); assert.equal(page.keyboardLayoutMode,'apple');
  h.failWrite(true); page.setKeyboardLayoutMode('system');
  assert.equal(page.keyboardLayoutMode,'apple'); assert.equal(page.peerPreferences.get('keyboard-layout-mode'),'apple');
  h.failWrite(false); page.remotePageVisible=false; page.setKeyboardLayoutMode('system');
  assert.equal(page.keyboardLayoutMode,'apple'); page.remotePageVisible=true; page.connectionStatus=3;
  page.setKeyboardLayoutMode('system'); assert.equal(page.keyboardLayoutMode,'apple');
});
test('page calibration rejects stale inventories and stale peers, while cancellation restores the parent', async () => {
  const h=harness(), page=pageHarness(h), overlays=[];
  h.context.KeyboardLayoutCalibrationDialog=options=>{overlays.push(options);return options;};
  h.context.CustomDialogController=class{constructor(options){this.options=options;}open(){}};
  h.service.start('apple'); await tick(); page.keyboardLayoutMode='apple'; page.showKeyboardSettings=true;
  page.openKeyboardLayoutCalibration(); assert.equal(page.showKeyboardCalibration,true);
  assert.equal(page.showKeyboardSettings,false); const dialog=overlays[0], originalPeer=page.peerPreferences;
  page.peerPreferences=new h.context.RemotePeerPreferences('server','other'); assert.equal(dialog.onSave(true),false);
  page.peerPreferences=originalPeer; page.remotePageVisible=false; assert.equal(dialog.onSave(true),false);
  page.remotePageVisible=true; h.change(); await tick(); assert.equal(dialog.onSave(true),false);
  page.keyboardCalibrationDialog.options.cancel(); assert.equal(page.showKeyboardCalibration,false);
  assert.equal(page.showKeyboardSettings,true); assert.equal(h.disk.size,0);
  page.openKeyboardLayoutCalibration(); assert(overlays[1].onSave(true)); overlays[1].onClose();
  assert.equal(page.showKeyboardSettings,true); assert.equal(page.showKeyboardCalibration,false);
});
test('page opens multi-keyboard calibration and saves only the explicitly captured devices', async () => {
  const h=harness(), page=pageHarness(h), overlays=[];
  h.devices([keyboard(7,'first'),keyboard(9,'second'),keyboard(11,'third')]);
  h.context.KeyboardLayoutCalibrationDialog=options=>{overlays.push(options);return options;};
  h.context.CustomDialogController=class{constructor(options){this.options=options;}open(){}};
  h.service.start('apple'); await tick(); page.keyboardLayoutMode='apple'; page.openKeyboardLayoutCalibration();
  assert.equal(page.showKeyboardCalibration,true); assert.deepEqual(plain(overlays[0].deviceIds),[7,9,11]);
  assert.equal(overlays[0].onSave(true,[7,99]),false);
  assert.equal(overlays[0].onSave(true,[7,9]),true);
  assert.deepEqual(h.bindingStates.at(-1).map(b=>b.swap),[true,true,false]);
});
test('modal open failures restore input, and opening settings balances held keys before capture', async () => {
  const h=harness(), page=pageHarness(h);
  h.service.start('apple'); await tick(); page.keyboardLayoutMode='apple';
  h.context.CustomDialogController=class{constructor(){throw Error('window unavailable');}};
  page.openKeyboardLayoutCalibration(); assert.equal(page.showKeyboardCalibration,false);
  assert.equal(page.showKeyboardSettings,true);
  h.S.sendHardwareControlKey(18,0,2045); h.clear(); page.showKeyboardPanel=true; page.openMouseSettings();
  assert.equal(page.showKeyboardPanel,false); assert.equal(page.showMouseSettings,true);
  assert(h.keys().some(k=>k[0]===18&&k[1]===1));
  h.clear(); page.closeInputSettings();
  assert.equal(page.showMouseSettings,false); assert.equal(page.hardwareModifierTrackingActive,false);
  assert.equal(h.calls[0][0],'takeNativeInputEvents','discard buffered calibration keys before resuming remote input');
});
(async () => {
  let passed=0;
  for (const [name, run] of tests) {
    try { await run(); passed++; console.log('PASS '+name); }
    catch(error) { console.error('FAIL '+name); throw error; }
  }
  console.log('TOTAL='+passed+' FAILED=0 (production layout logic; real Mac-keyboard acceptance pending)');
})().catch(error=>{ console.error(error); process.exitCode=1; });
