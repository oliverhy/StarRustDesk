'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/pages/RemotePage.ets', 'utf8');
const methods = ['rememberDisplayForReconnect', 'initializeRemoteDisplay'].map(name => {
  const match = source.match(new RegExp(`  ${name}\\(\\): void \\{[\\s\\S]*?\\n  \\}`));
  assert(match, `${name} exists`); return match[0];
});
const logs = [], switches = [], refreshes = [];
let remote = 1, switchResult = 0;
const sandbox = { LOG_DOMAIN: 0, hilog: { error() {} }, RustDeskNapi: {
  getCurrentDisplay: () => remote,
  switchDisplay: display => { switches.push(display); remote = display; return switchResult; },
  refreshVideo: () => { refreshes.push(remote); return 0; },
  appendDiagnosticLog: (scope, message) => logs.push([scope, message]),
} };
vm.runInNewContext(ts.transpile(`class Page { ${methods.join('\n')} } globalThis.Page = Page;`), sandbox);
const create = (count, preferred = -1) => Object.assign(new sandbox.Page(), {
  displayStateInitialized: false, displayRestoreRetryPending: false,
  currentDisplay: 0, displayCount: count, reconnectPreferredDisplay: preferred,
});
const page = create(3);
Object.assign(page, {displayStateInitialized: true, currentDisplay: 2});
page.rememberDisplayForReconnect();
assert.equal(page.reconnectPreferredDisplay, 2);
page.displayStateInitialized = false;
page.currentDisplay = 0;
page.rememberDisplayForReconnect();
assert.equal(page.reconnectPreferredDisplay, 2, 'retry before initialization retains the original display');
page.initializeRemoteDisplay();
assert.equal(page.currentDisplay, 2, 'reconnect restores the selected screen even when peer defaults to screen 2');
assert.deepEqual(switches, [2]); assert.deepEqual(refreshes, [2]);
assert.equal(page.reconnectPreferredDisplay, -1);
page.initializeRemoteDisplay();
assert.deepEqual(switches, [2], 'repeated polling never overwrites the user selection');

remote = 1; switches.length = 0; refreshes.length = 0;
let fresh = create(2); fresh.initializeRemoteDisplay();
assert.equal(fresh.currentDisplay, 1, 'fresh session follows a nonzero remote primary display');
assert.equal(fresh.displayStateInitialized, true);
assert.deepEqual(switches, [], 'do not switch away from the peer login screen');
assert.deepEqual(refreshes, [], 'do not redundantly restart capture on initial sync');
assert.match(logs.at(-1)[1], /source=remote_default reason=fresh_session switch_required=false result=0/);

fresh = create(2, 1); fresh.initializeRemoteDisplay();
assert.deepEqual(switches, [], 'same-screen reconnect needs no switch');
assert.match(logs.at(-1)[1], /source=reconnect reason=previous_selection/);

fresh = create(2, 2); fresh.initializeRemoteDisplay();
assert.equal(fresh.currentDisplay, 1, 'missing previous display falls back to remote default, not index 0');
assert.match(logs.at(-1)[1], /reason=previous_display_unavailable/);

for (const invalid of [-1, 9, NaN, 0.5]) {
  remote = invalid; fresh = create(2); fresh.initializeRemoteDisplay();
  assert.equal(fresh.currentDisplay, 0, 'invalid peer default has a bounded first-screen fallback');
  assert.match(logs.at(-2)[1], /source=first_available reason=remote_default_invalid/);
}

remote = 1; switchResult = -2; switches.length = 0; refreshes.length = 0;
fresh = create(3, 2); fresh.initializeRemoteDisplay();
assert.equal(fresh.displayStateInitialized, false, 'failed restore remains retryable');
assert.equal(fresh.reconnectPreferredDisplay, 2);
assert.deepEqual(refreshes, [], 'do not refresh after a failed switch');
switchResult = 0; fresh.initializeRemoteDisplay();
assert.deepEqual(switches, [2, 2], 'retry despite native selection changing before its queue error');
assert.equal(fresh.currentDisplay, 2); assert.equal(fresh.displayStateInitialized, true);

remote = 0; fresh = create(1, 2); fresh.initializeRemoteDisplay();
assert.equal(fresh.currentDisplay, 0, 'single-screen peer remains supported');
assert.match(source, /this\.initializeRemoteDisplay\(\)/);
assert.match(source, /this\.keyboardComposing = false;\s*this\.rememberDisplayForReconnect\(\);\s*this\.displayStateInitialized = false/,
  'save selection before a failed session clears initialized state, including later manual retry');
assert.match(source, /if \(!started\).*?return; \}\s*this\.rememberDisplayForReconnect\(\)/s);
console.log('PASS reconnect display: peer default, preserved reconnect screen, invalid-display fallback, no duplicate switch, retry after queue failure');
