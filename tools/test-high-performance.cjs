'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replace(/\r/g, '');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
const values = new Map(), calls = [], toasts = [], logs = [];
let fail = false, publicServer = false, route = 1;
const context = { exports: {}, ConnectionStatus: { CONNECTED: 2 },
  RustDeskNapi: { setHighPerformance: enabled => { calls.push(['priority', enabled]); return fail ? -1 : 0; },
    setGameFps: fps => { calls.push(['fps', fps]); return 0; }, isUsingPublicServer: () => publicServer,
    appendDiagnosticLog: (...args) => logs.push(args) },
  ConnectionService: { getConnectionRoute: () => route } };
vm.runInNewContext(ts.transpile('class Page {' + ['loadHighPerformancePreference', 'setHighPerformance'].map(method).join('\n') + '} exports.Page = Page;'), context);
const obj = Object.assign(new context.exports.Page(), { fileOnly: false, connectionStatus: 2, highPerformanceEnabled: false,
  gameModeEnabled: false, gameModeAppliedFps: 0, gameModeRetryAfter: 0,
  gameModePolicy: { reset() {}, fps() { return 60; } },
  peerPreferences: { get: k => values.get(k) || '', set: (k, v) => { values.set(k, v); return true; }, flush: () => true },
  showFileToast: text => toasts.push(text) });
obj.loadHighPerformancePreference();
assert.deepEqual(calls.pop(), ['priority', false], 'default remains automatic');
obj.setHighPerformance(true);
assert.equal(obj.highPerformanceEnabled, true);
assert.equal(values.get('high-performance-priority'), '1');
assert.deepEqual(calls.pop(), ['priority', true]);
obj.gameModeEnabled = true;
obj.setHighPerformance(false);
assert.deepEqual(calls.slice(-2), [['priority', false], ['fps', 60]], 'restores the game policy after priority is disabled');
fail = true; obj.setHighPerformance(true); fail = false;
assert.equal(obj.highPerformanceEnabled, false, 'failed live changes do not claim success');
assert.deepEqual(calls.slice(-2), [['priority', true], ['priority', false]], 'failed change is rolled back');
publicServer = true; route = 2; obj.setHighPerformance(true);
assert.equal(toasts.at(-1), '公共中继仍按原有规则限制码率和帧率');
assert(page.includes('this.highPerformanceEnabled || this.connectionStatus !== ConnectionStatus.CONNECTED'), 'game-mode adaptation is paused while priority is active');
assert(page.includes('if (this.gameModeEnabled && !this.highPerformanceEnabled)'),
  'game FPS target must not be shown when performance priority overrides it');
for (const value of ['请求帧率', '实际帧率', '请求码率比例', '画面接收速率', '远端目标码率']) assert(page.includes(value));
assert(logs.every(entry => !entry.join(' ').includes('password')));
console.log('PASS high-performance opt-in, per-peer persistence, public-relay notice, rollback and requested/observed UI');
