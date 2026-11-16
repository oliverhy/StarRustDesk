'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync(path.resolve('entry/src/main/ets/widget/ServerConfigDialog.ets'), 'utf8');
function part(begin, end) {
  const a = source.indexOf(begin), b = source.indexOf(end, a);
  assert.ok(a >= 0 && b > a);
  return source.slice(a, b);
}
const methods = part('  async scanConfig(): Promise<void> {', '\n  aboutToAppear()') +
  part('  saveConfig(): void {', '\n  async exportServerConfigToClipboard()');
const js = ts.transpileModule('class Harness {\n' + methods + '\n}\nglobalThis.Harness = Harness;', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText;

const old = ['previous.invalid', 'previous-relay.invalid', '', 'previous-key'];
const next = ['new.invalid:21116', '', 'https://new.invalid', 'synthetic-key=='];
let stored = old.slice(), calls = 0, marks = 0, revision = 0, status = 0, scanValue = 'valid';
let scanPromise;
const logs = [];
const context = {
  RustDeskNapi: {
    setServerConfig: (...values) => {
      calls++;
      if (status !== 0) return status;
      stored = values.slice();
      return 0;
    },
    appendDiagnosticLog: (_scope, message) => logs.push(message)
  },
  ServerConfigModel: { decode: (input) => ({ isValidImport: () => input === 'valid',
    idServer: next[0], relayServer: next[1], apiServer: next[2], serverKey: next[3] }) },
  CloudSyncService: { markLocalChanged: () => { marks++; } },
  AppStorage: { get: () => revision, set: (_key, value) => { revision = value; } },
  scanBarcode: { startScanForResult: () => scanPromise || Promise.resolve({ originalValue: scanValue }) },
  scanCore: { ScanType: { QR_CODE: 1 } }, getContext: () => ({}),
  OperationDiagnostic: class {
    static errorCode(error) { return error.code || 0; }
    event(event) { logs.push(event); }
    end(event) { logs.push(event); }
  }
};
vm.runInNewContext(js, context);
function make() {
  return Object.assign(new context.Harness(), {
    idServer: old[0], relayServer: old[1], apiServer: old[2], serverKey: old[3],
    scanning: false, importing: false, isTesting: false, alive: true, scanGeneration: 0,
    testResult: '', errorMsg: '', closed: false,
    controller: { close() { this.owner.closed = true; }, owner: null }
  });
}
async function main() {
  let h = make(); h.controller.owner = h;
  await h.scanConfig();
  assert.equal(h.idServer, next[0]);
  assert.equal(h.serverKey, next[3]);
  assert.match(h.testResult, /点击确定保存/);
  assert.equal(calls, 0, 'QR scanning is a preview until confirmation');
  assert.deepEqual(stored, old);

  status = -2;
  h.saveConfig();
  assert.equal(calls, 1);
  assert.deepEqual(stored, old);
  assert.equal(marks, 0); assert.equal(revision, 0);
  assert.equal(h.closed, false);
  assert.match(h.errorMsg, /原配置未更改/);
  status = 0;
  h.saveConfig();
  assert.equal(calls, 2);
  assert.deepEqual(stored, next);
  assert.equal(marks, 1); assert.equal(revision, 1);
  assert.equal(h.closed, true);

  h = make(); h.controller.owner = h; scanValue = 'invalid';
  await h.scanConfig();
  assert.equal(h.idServer, old[0]);
  assert.equal(calls, 2);
  assert.match(h.errorMsg, /不是有效/);
  h.scanning = true; h.saveConfig();
  assert.equal(calls, 2, 'busy operations cannot overwrite the config');

  h = make(); h.controller.owner = h;
  let resolve;
  scanPromise = new Promise(done => { resolve = done; });
  const pending = h.scanConfig();
  h.alive = false; h.scanGeneration++;
  resolve({ originalValue: 'valid' });
  await pending;
  assert.equal(h.idServer, old[0]);
  assert.equal(calls, 2, 'closed dialog ignores delayed scan');
  scanPromise = undefined;

  h = make(); h.controller.owner = h;
  h.idServer = ''; h.relayServer = ''; h.apiServer = ''; h.serverKey = '';
  h.saveConfig();
  assert.deepEqual(stored, ['', '', '', ''], 'manual clearing remains supported');
  const output = logs.join('\n');
  for (const value of [...old, ...next].filter(Boolean)) assert.ok(!output.includes(value));
  console.log('PASS QR preview, confirm, failure, cancellation, manual clearing and redacted logs');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
