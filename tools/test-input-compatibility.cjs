const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
}}).outputText;
const model = { exports: {} };
vm.runInNewContext(compile(read('entry/src/main/ets/model/InputCompatibility.ets')), model);
const { inputCompatibilityKey, selectedKeyboardMode, selectedCursorMode, shouldSuppressCursor } = model.exports;
assert.notEqual(inputCompatibilityKey('a', '123', 'keyboard'), inputCompatibilityKey('b', '123', 'keyboard'));
assert.notEqual(inputCompatibilityKey('a', '1:23', 'keyboard'), inputCompatibilityKey('a', '12:3', 'keyboard'));
assert.equal(selectedKeyboardMode('oops'), 0);
assert.equal(selectedKeyboardMode('2'), 2);
assert.equal(selectedCursorMode('oops'), 'auto');
assert.equal(shouldSuppressCursor('auto', true), true);
assert.equal(shouldSuppressCursor('auto', false), false);
assert.equal(shouldSuppressCursor('separate', true), false);
assert.equal(shouldSuppressCursor('embedded', false), true);

let capabilities = 3;
const calls = [];
const native = new Proxy({}, { get: (_, name) => (...args) => {
  if (name === 'getInputCapabilities') return capabilities;
  calls.push([name, ...args]);
  return 0;
}});
const sandbox = { exports: {}, RustDeskNapi: native, hilog: { info() {}, warn() {} },
  RemoteSessionBackgroundTask: {}, ConnectionStatus: {}, connection: {}, console };
const source = read('entry/src/main/ets/service/ConnectionService.ets').replace(/^import .*\r?\n/gm, '');
vm.runInNewContext(compile(source), sandbox);
const service = sandbox.exports.ConnectionService;
service.configureInputModes(0, true);
calls.length = 0;
service.sendPhysicalKeyEvent(26, 0); // hardware W
service.sendPhysicalKeyEvent(26, 0, undefined, false, 'gamepad');
service.sendPhysicalKeyEvent(26, 1); // gamepad still holds W
service.sendPhysicalKeyEvent(26, 1, undefined, false, 'gamepad');
assert.deepEqual(calls.filter(c => c[0] === 'sendPhysicalKeyEvent').map(c => c.slice(1, 3)),
  [[26, 0], [26, 1]], 'hardware and gamepad share key ownership');
calls.length = 0;
service.sendPhysicalKeyEvent(26, 0, undefined, false, 'gamepad');
service.sendPhysicalKeyEvent(26, 0); // same W held by both
service.sendPhysicalKeyEvent(26, 1, undefined, false, 'gamepad');
service.sendPhysicalKeyEvent(26, 1);
assert.deepEqual(calls.filter(c => c[0] === 'sendPhysicalKeyEvent').map(c => c.slice(1, 3)),
  [[26, 0], [26, 1]], 'releasing the gamepad must not release a hardware-held key');
calls.length = 0;
service.sendLetterKeyEvent('d', 7, 0, 2);
service.sendLetterKeyEvent('d', 7, 1, 0);
assert.deepEqual(calls.filter(c => c[0] === 'sendPhysicalKeyEvent').map(c => c.slice(1, 3)), [[7, 0], [7, 1]]);
assert.equal(calls.some(c => c[0] === 'sendText'), false, 'KVM shifted letters use legacy HID, not text fallback');
calls.length = 0;
service.sendRelativeMouseDelta(0.4, -0.4);
service.sendRelativeMouseDelta(0.4, -0.4);
assert.equal(calls.length, 0);
service.sendRelativeMouseDelta(0.4, -0.4);
assert.deepEqual(calls[0].slice(0, 3), ['sendMouseRelative', 1, -1]);
service.sendMouseEvent(500, 500, 0);
assert.equal(calls.length, 1, 'No duplicate absolute move in relative mode');
service.sendMouseEvent(500, 500, 1);
assert.deepEqual(calls[1].slice(0, 4), ['sendMouseEvent', 0, 0, 1]);
service.configureInputModes(0, false);
calls.length = 0;
service.sendMouseEvent(500, 400, 0);
assert.deepEqual(calls[0].slice(0, 4), ['sendMouseEvent', 500, 400, 0]);
capabilities = 0;
service.configureInputModes(0, true);
calls.length = 0;
service.sendRelativeMouseDelta(10, 20);
assert.equal(calls.length, 0, 'Unsupported peers cannot receive relative movement');
service.sendPhysicalKeyEvent(0x1e, 0, 2);
assert(calls.some(c => c[0] === 'sendText' && c[1] === '!'), 'Normal auto Shift+1 behavior preserved');
service.sendPhysicalKeyEvent(0x1e, 1, 0);
const page = read('entry/src/main/ets/pages/RemotePage.ets');
assert(page.includes('!this.suppressCompatibilityCursor() && (!this.relativeMouseEnabled || this.hasAuthoritativeRemoteCursor)'));
assert(page.includes('this.relativePointerSampleValid = false'));
assert(page.includes('ConnectionService.sendRelativeMouseDelta(remoteDeltaX * sensitivity, remoteDeltaY * sensitivity)'));
const method = name => {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
const moves = [];
const pointerSandbox = { exports: {}, TOUCHPAD_POINTER_SPEED: 1,
  ConnectionService: { sendRelativeMouseDelta: (x,y) => moves.push([x,y]) } };
vm.runInNewContext(compile('export class Pointer {' + method('updatePointerFromLocal') +
  method('updatePointerFromDelta') + '}'), pointerSandbox);
const p = Object.assign(new pointerSandbox.exports.Pointer(), {
  relativeMouseEnabled: true, relativePointerSampleValid: false,
  remoteWidth: 1000, remoteHeight: 800, lastAbsX: 999, lastAbsY: 799,
  getDisplayWidth: () => 500, getDisplayHeight: () => 400,
  markLocalPointerInput() {}, ensurePointerInitialized() {}
});
p.updatePointerFromLocal(100,100);
assert.equal(moves.length,0,'First physical sample establishes baseline only');
p.updatePointerFromLocal(110,90);
assert.deepEqual(moves.pop(),[20,-20]);
p.relativePointerSampleValid=false;
p.updatePointerFromLocal(300,200);
assert.equal(moves.length,0,'Reentry must not jump');
p.updatePointerFromDelta(20,10);
assert.deepEqual(moves.pop(),[40,20], 'Delta must continue even at predicted screen edge');
p.gameModeEnabled = true; p.gameRelativeSensitivity = 150;
p.updatePointerFromDelta(20,10);
assert.deepEqual(moves.pop(), [60,30], 'game sensitivity applies only to relative deltas');
p.updatePointerFromLocal(310,210);
assert.deepEqual(moves.pop(), [30,30], 'physical relative deltas honor game sensitivity');
p.gameModeEnabled = false;
p.updatePointerFromDelta(20,10);
assert.deepEqual(moves.pop(), [40,20], 'normal mode remains unchanged');
console.log('PASS input compatibility: scoped preferences, KVM keyboard, fractional relative movement, buttons, normal auto path');
