'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const load = pathName => fs.readFileSync(path.join(root, 'entry/src/main/ets', pathName + '.ets'), 'utf8').replace(/^import .*\n/gm, '');
const widget = load('widget/RemoteGlassMenu');
const screenMenu = widget.slice(widget.indexOf('  screens() {'), widget.indexOf('  zoomControls() {'));
assert(screenMenu.includes('}.alignItems(VerticalAlign.Top)'), 'screen cards must remain top-aligned when only some have an extension button');
assert(screenMenu.includes('display !== this.state.currentDisplay'), 'the current primary display must not offer an extension button');
const c = { exports: {}, Number, Array, Object, Map, Promise };
vm.runInNewContext(ts.transpile(load('model/RemoteMultiDisplayCapability')), c); Object.assign(c, c.exports);
const evaluate = c.evaluateRemoteMultiDisplay;
const displays = [
  { id: 0, sourceMode: 1, width: 1920, height: 1080 },
  { id: 1, sourceMode: 3, width: 2560, height: 1600 },
  { id: 2, sourceMode: 2, width: 1920, height: 1080 },
  { id: 3, sourceMode: -1, width: 1200, height: 800 }
];
assert.equal(evaluate(false, 0, displays, 2, true, true).reason, 'device_not_pc');
assert.equal(evaluate(true, -1, displays, 2, true, true).reason, 'local_display_unknown');
assert.equal(evaluate(true, 0, displays, 1, true, true).reason, 'remote_single_display');
assert.equal(evaluate(true, 0, displays.filter(d => d.sourceMode !== 3), 2, true, true).reason, 'no_confirmed_extended_display');
assert.equal(evaluate(true, 0, displays, 2, false, true).reason, 'multi_stream_not_ready');
assert.equal(evaluate(true, 0, displays, 2, true, false).available, false);
const ready = evaluate(true, 0, displays, 2, true, true);
assert.equal(ready.available, true); assert.equal(ready.candidates.length, 1); assert.equal(ready.candidates[0].id, 1);
const remotePage = load('pages/RemotePage');
assert(remotePage.includes('result.available && result.candidates.length > 0'),
  'extension UI must use the complete protocol and topology gate');
const events = new Map(), logs = [], pending = [];
c.display = { getDefaultDisplaySync: () => ({ id: 0 }),
  getAllDisplays: () => new Promise((resolve, reject) => pending.push({ resolve, reject })),
  on: (kind, cb) => events.set(kind, cb), off: kind => events.delete(kind) };
let peerSupported = false;
c.RustDeskNapi = { appendDiagnosticLog: (component, msg) => logs.push([component, msg]),
  isSecondaryDisplaySupported: () => peerSupported };
let mainDisplay = 0;
c.RemoteDisplayPolicy = { getMainWindow: () => ({ getWindowProperties: () => ({ displayId: mainDisplay }) }) };
vm.runInNewContext(ts.transpile(load('service/RemoteMultiDisplayMonitor')), c); Object.assign(c, c.exports);
async function run() {
  const m = new c.RemoteMultiDisplayMonitor(); m.start(); assert.equal(events.size, 3);
  m.setRemoteCount(2); assert.equal(pending.length, 2);
  pending[1].resolve(displays); await Promise.resolve();
  assert(logs.at(-1)[1].includes('local_extended=1 remote_displays=2 available=0'));
  const count = logs.length; pending[0].resolve([]); await Promise.resolve();
  assert.equal(logs.length, count, 'stale async results cannot replace newer topology');
  mainDisplay = 1; m.setRemoteCount(2); assert.equal(pending.length, 3);
  pending[2].resolve(displays); await Promise.resolve();
  assert(logs.at(-1)[1].includes('reason=no_confirmed_extended_display local_extended=0'),
    'a window already on the external display must not assign the same display again');
  mainDisplay = 0; peerSupported = true; m.setRemoteCount(2); assert.equal(pending.length, 4);
  pending[3].resolve(displays); await Promise.resolve();
  assert(logs.at(-1)[1].includes('reason=ready local_extended=1 remote_displays=2 available=1'),
    'compatible peers must expose the tested extension');
  peerSupported = false; m.setRemoteCount(2); assert.equal(pending.length, 5);
  pending[4].resolve(displays); await Promise.resolve();
  assert(logs.at(-1)[1].includes('reason=multi_stream_not_ready local_extended=1 remote_displays=2 available=0'),
    'a peer capability change must close the gate even when display count is unchanged');
  events.get('remove')(1); assert.equal(pending.length, 6);
  m.stop(); assert.equal(events.size, 0);
  const stoppedCount = logs.length; pending[5].resolve([]); await Promise.resolve();
  assert.equal(logs.length, stoppedCount, 'stop suppresses pending results');
  assert(logs.every(row => !row[1].includes('1920') && !row[1].includes('2560')), 'diagnostics omit display geometry');
  console.log('PASS PC extend detection, fail-closed backend gate, topology race and listener cleanup');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
