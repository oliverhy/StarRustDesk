'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const compiled = fs.readFileSync(path.resolve(
  'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/widget/ServerConfigDialog.ts'), 'utf8');
const invocations = compiled.split(/\r?\n/).filter(line => line.includes('this.buildField.bind(this)('));
assert.equal(invocations.length, 4);
const begin = compiled.indexOf('    buildField($$: ServerFieldBuilderParams');
const end = compiled.indexOf('\n    rerender()', begin);
assert.ok(begin >= 0 && end > begin);
const fakeComponent = () => new Proxy({}, { get: () => () => {} });
const callbacks = [], rendered = [], changes = {};
// Keep the input methods explicit so compiled create/onChange can be observed.
const input = new Proxy({}, { get: (_target, key) => key === 'create' ?
  config => rendered.push({ ...config }) : key === 'onChange' ?
  fn => { changes[rendered[rendered.length - 1].placeholder] = fn; } : () => {} });
const context = {
  Column: fakeComponent(), Text: fakeComponent(), TextInput: input,
  HorizontalAlign: { Start: 0 }, RustDeskTheme: new Proxy({}, { get: () => '#000000' }),
  readableInputHeight: () => 44, translate: value => value,
  makeBuilderParameterProxy: (_name, getters) => new Proxy({}, { get: (_target, key) => getters[key]() })
};
const harness = 'class Harness {\n' + compiled.slice(begin, end) + '\n' +
  'emitFields() {\n' + invocations.join('\n') + '\n}\n}\nglobalThis.Harness = Harness;';
vm.runInNewContext(ts.transpileModule(harness, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const h = Object.assign(new context.Harness(), {
  idServer: '', relayServer: '', apiServer: '', serverKey: '', isDarkMode: false,
  uiLanguage: 'zh-Hans', uiFontScale: 1,
  observeComponentCreation2: (cb, component) => { cb(0, true); if (component === input) callbacks.push(cb); }
});
h.emitFields();
assert.equal(callbacks.length, 4);
Object.assign(h, { idServer: 'new.invalid', relayServer: 'relay.invalid', apiServer: 'api.invalid', serverKey: 'synthetic-key' });
callbacks.forEach(cb => cb(0, false));
assert.deepEqual(rendered.slice(-4).map(item => item.text), ['new.invalid', 'relay.invalid', 'api.invalid', 'synthetic-key']);
changes['ID Server']('edited.invalid');
changes.Key('edited-key');
assert.equal(h.idServer, 'edited.invalid');
assert.equal(h.serverKey, 'edited-key');
console.log('PASS compiled builder re-reads all four fields after import and writes manual edits back');
