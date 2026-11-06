'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const compile = source => ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

class Base64Helper {
  encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64url'); }
  decodeSync(value) {
    if (!/^[A-Za-z0-9_-]*={0,2}$/.test(value) || value.length % 4 !== 0) throw Error('bad encoding');
    return Uint8Array.from(Buffer.from(value, 'base64url'));
  }
}
class ArkTextEncoder { encodeInto(value) { return Uint8Array.from(Buffer.from(value, 'utf8')); } }
class ArkTextDecoder { decodeToString(value) { return Buffer.from(value).toString('utf8'); } }

const modelSource = read('entry/src/main/ets/model/ServerConfigModel.ets')
  .replace(/^import .*$/m, '').replace('export class', 'class') + '\nglobalThis.Model = ServerConfigModel;';
const modelContext = vm.createContext({
  util: { Base64Helper, Type: { BASIC_URL_SAFE: 1 }, TextEncoder: ArkTextEncoder, TextDecoder: ArkTextDecoder },
  Uint8Array, decodeURIComponent
});
vm.runInContext(compile(modelSource), modelContext);
const Model = modelContext.Model;
const expected = { host: 'id.example.invalid:21116', relay: 'relay.example.invalid:21117',
  api: 'https://api.example.invalid:21114', key: 'FAKE+PUBLIC/KEY=' };
const json = JSON.stringify(expected);
// Flutter's encoder uses Base64URL with padding, followed by character reversal.
const officialPadded = Buffer.from(json).toString('base64').replace(/\+/g, '-').replace(/\//g, '_')
  .split('').reverse().join('');
const officialUnpadded = officialPadded.replace(/^=+/, '');
function checkConfig(value) {
  const actual = Model.decode(value);
  assert.equal(actual.isValidImport(), true);
  assert.equal(actual.idServer, expected.host);
  assert.equal(actual.relayServer, expected.relay);
  assert.equal(actual.apiServer, expected.api);
  assert.equal(actual.serverKey, expected.key);
}

let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }

async function main() {
  await test('official clipboard, QR, JSON, old QR and explicit links', () => {
    for (const sample of [officialPadded, officialUnpadded, json, 'config=' + json,
      'config=' + officialPadded, 'config=' + officialUnpadded,
      'rustdesk://config/' + encodeURIComponent(officialPadded)]) checkConfig(sample);
    const oldQr = new Model(expected.host, expected.relay, expected.api, expected.key).toQrPayload();
    checkConfig(oldQr);
  });

  await test('official deployment filenames remove exe and duplicate suffixes before parsing', () => {
    const samples = [
      ['rustdesk-host=id.example.invalid.exe', 'id.example.invalid', '', ''],
      ['rustdesk-host=id.example.invalid,key=TESTKEY.exe', 'id.example.invalid', '', 'TESTKEY'],
      ['rustdesk-host=id.example.invalid,key=TESTKEY,relay=relay.example.invalid.exe',
        'id.example.invalid', 'relay.example.invalid', 'TESTKEY'],
      ['rustdesk-host=id.example.invalid,key=TESTKEY (1).exe.exe', 'id.example.invalid', '', 'TESTKEY'],
      ['rustdesk-host=id.example.invalid,key=TESTKEY,.exe', 'id.example.invalid', '', 'TESTKEY']
    ];
    for (const [sample, host, relay, key] of samples) {
      const config = Model.decode(sample);
      assert.equal(config.isValidImport(), true);
      assert.equal(config.idServer, host);
      assert.equal(config.relayServer, relay);
      assert.equal(config.serverKey, key);
    }
    checkConfig('rustdesk-licensed-' + officialUnpadded + '(1).exe');
  });

  await test('malformed or unsafe input is rejected', () => {
    const badJson = JSON.stringify({ host: expected.host, relay: {} });
    const badToken = Buffer.from(badJson).toString('base64url').split('').reverse().join('');
    for (const sample of ['', 'config=', 'config=null', 'config={"host":42}',
      'config={"host":"id example.invalid"}', 'config={"host":"a","key":{}}',
      'config=' + badToken, 'rustdesk://config/%ZZ', 'x'.repeat(16385)]) {
      assert.equal(Model.decode(sample).isValidImport(), false, 'must reject invalid sample');
    }
  });

  await test('clipboard distinguishes text, empty data and system failure', async () => {
    let records = [];
    let readError;
    const pasteboard = { getSystemPasteboard: () => ({ getData: async () => {
      if (readError) throw readError;
      return { getRecordCount: () => records.length, getRecord: i => records[i] };
    } }) };
    const mocks = { 'libentry.so': { default: {} }, '@kit.BasicServicesKit': { pasteboard, deviceInfo: {} },
      '../widget/ReleaseNotesDialog': {} };
    const module = { exports: {} };
    const sandbox = { module, exports: module.exports, require: name => {
      if (!(name in mocks)) throw Error('unexpected import: ' + name);
      return mocks[name];
    } };
    vm.runInNewContext(compile(read('entry/src/main/ets/service/RustDeskNapi.ets')), sandbox);
    const napi = module.exports.RustDeskNapi;
    records = [{ plainText: undefined, htmlText: undefined, toPlainText: () => '' },
      { plainText: officialPadded, htmlText: '', toPlainText: () => '' }];
    let result = await napi.getClipboardTextForImportAsync();
    assert.equal(result.failed, false);
    assert.equal(result.text, officialPadded);
    records = [];
    result = await napi.getClipboardTextForImportAsync();
    assert.equal(result.failed, false);
    assert.equal(result.text, '');
    readError = { code: 201, message: 'PRIVATE_ERROR_CONTENT' };
    result = await napi.getClipboardTextForImportAsync();
    assert.equal(result.failed, true);
    assert.equal(result.code, 201);
    assert.equal(result.text, '');
  });

  await test('import applies only valid data and ignores stale requests', async () => {
    const dialog = read('entry/src/main/ets/widget/ServerConfigDialog.ets');
    assert.match(dialog, /PasteButton\(\{ text: PasteDescription\.PASTE/);
    assert.match(dialog, /result === PasteButtonOnClickResult\.SUCCESS/);
    assert.doesNotMatch(dialog, /Button\(translate\('导入'/);
    const start = dialog.indexOf('  async importServerConfigFromClipboard(): Promise<void> {');
    const end = dialog.indexOf('\n  @Builder', start);
    assert.ok(start >= 0 && end > start);
    const method = dialog.slice(start, end);
    let nextRead = async () => ({ text: officialPadded, failed: false, code: 0 });
    const logs = [], toasts = [], applications = [];
    class Trace {
      constructor(scope, action) { logs.push(scope + ':' + action); }
      event(step, fields = {}) { logs.push(step + ':' + JSON.stringify(fields)); }
      end(step, fields = {}) { logs.push(step + ':' + JSON.stringify(fields)); }
      fail() { logs.push('failed'); }
    }
    const sandbox = {
      ServerConfigModel: Model, OperationDiagnostic: Trace,
      RustDeskNapi: { getClipboardTextForImportAsync: () => nextRead(),
        appendDiagnosticLog: (_scope, event) => logs.push(event) },
      promptAction: { showToast: value => toasts.push(value.message) },
      translate: value => value
    };
    vm.runInNewContext(compile('class Harness {\n' + method + '\n}\nglobalThis.Harness = Harness;'), sandbox);
    const make = () => Object.assign(new sandbox.Harness(), {
      importing: false, scanning: false, importGeneration: 0, alive: true, uiLanguage: 'zh-Hans',
      applyConfig: (...values) => applications.push(values)
    });
    let h = make();
    await h.importServerConfigFromClipboard();
    assert.equal(applications.length, 1);
    assert.deepEqual(applications[0], [expected.host, expected.relay, expected.api, expected.key]);
    assert.equal(h.importing, false);
    for (const result of [{ text: '', failed: false, code: 0 },
      { text: 'config=garbage', failed: false, code: 0 }, { text: '', failed: true, code: 201 }]) {
      nextRead = async () => result;
      h = make();
      await h.importServerConfigFromClipboard();
      assert.equal(applications.length, 1, 'invalid or unreadable data must not change options');
    }
    let resolveRead;
    nextRead = () => new Promise(resolve => { resolveRead = resolve; });
    h = make();
    const pending = h.importServerConfigFromClipboard();
    h.alive = false;
    h.importGeneration++;
    resolveRead({ text: officialPadded, failed: false, code: 0 });
    await pending;
    assert.equal(applications.length, 1, 'closed dialog must not apply a delayed result');
    const output = logs.join('\n');
    assert.ok(!output.includes(expected.host) && !output.includes(expected.key) && !output.includes(officialPadded));
    assert.ok(toasts.includes('无法读取剪贴板，请检查系统权限后重试'));
  });
  console.log(`${passed} server-config import regression groups passed`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
