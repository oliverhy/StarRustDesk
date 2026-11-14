const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = p => fs.readFileSync(path.resolve(__dirname, '..', p), 'utf8').replace(/\r\n/g, '\n');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const service = read('entry/src/main/ets/service/ConnectionService.ets').replace(/^import .*\n/gm, '');
const packets = [], logs = [];
const native = {
  sendPrintableShortcutKey: (code, mask) => { packets.push(['printable', code, mask]); return 0; },
  sendKeyEvent: (code, action, mask) => { packets.push(['control', code, action, mask]); return 0; },
  sendText: text => { packets.push(['text', text]); return 0; },
  appendDiagnosticLog: (...args) => logs.push(args),
};
const context = vm.createContext({ exports: {}, RustDeskNapi: native });
const compile = text => ts.transpileModule(text, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
}).outputText;
vm.runInContext(compile(service), context);
context.ConnectionService = context.exports.ConnectionService;
const method = name => {
  const start = page.indexOf(`\n  ${name}(`);
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
vm.runInContext(compile('class Probe {' + ['sendKeyboardTextSegment',
  'getPrintableShortcutKeyCode'].map(method).join('\n') + '}\nglobalThis.Probe=Probe'), context);
const probe = new context.Probe();
let mask = 0;
probe.getVirtualModifierMask = () => mask;
function send(text, modifiers) {
  packets.length = 0;
  mask = modifiers;
  probe.sendKeyboardTextSegment(text);
  return packets;
}

// Test the production ArkTS route, not a replacement implementation of it.
for (const mods of [1, 3, 4, 6, 8, 10, 15]) {
  for (let code = 65; code <= 90; code++) {
    for (const text of [String.fromCharCode(code), String.fromCharCode(code + 32)]) {
      assert.deepEqual(send(text, mods), [['printable', code, mods]]);
    }
  }
}
console.log('PASS Ctrl/Alt/Cmd and explicit Shift + all letters use dedicated printable key packets');
for (const [text, code] of [['1',49], ['!',49], [';',186], [':',186], ['/',191], ['?',191]]) {
  assert.deepEqual(send(text, 1), [['printable',code,1]]);
  assert.deepEqual(send(text, 3), [['printable',code,3]]);
}
assert.deepEqual(send('q', 2), [['printable',81,2]], 'Explicit Shift remains explicit');
for (const text of ['q','Q','你好','去','hello','🙂','']) {
  assert.deepEqual(send(text, 0), [['text',text]]);
}
for (const text of ['你好','去','hello','🙂']) {
  assert.deepEqual(send(text, 1), [['text',text]], 'IME commit must not be converted to shortcuts');
}
console.log('PASS normal text, uppercase, Chinese IME commits and single-line multi-character text keep their text path');
for (const [code, mods] of [[46,3], [27,3], [115,4], [38,1]]) {
  packets.length = 0;
  context.ConnectionService.sendShortcutKey(code, mods);
  assert.deepEqual(packets, [['control',code,2,mods]], 'Preset control keys must retain their protocol');
}
// Stale physical state is not allowed to append an unselected Shift to soft shortcuts.
context.ConnectionService.heldModifierMask = 2;
context.ConnectionService.hardwareModifierMask = 2;
assert.deepEqual(send('q', 1), [['printable',81,1]]);
console.log('PASS preset controls and stale hardware state do not contaminate soft-keyboard modifiers');

const napi = read('entry/src/main/ets/service/RustDeskNapi.ets');
const cpp = read('entry/src/main/cpp/napi_init.cpp');
const header = read('entry/src/main/cpp/core/rustdesk_ffi.h');
const rust = read('entry/src/main/rust/src/lib.rs');
assert.match(napi, /return rustdeskNapi\.sendPrintableShortcutKey\(keyCode, modifierMask\)/);
assert.match(cpp, /rust_send_printable_shortcut_key\(keyCode, modifierMask\)/);
assert.match(cpp, /"sendPrintableShortcutKey", nullptr, SendPrintableShortcutKey/);
assert.match(header, /int rust_send_printable_shortcut_key\(int key_code, int modifier_mask\)/);
assert.match(rust, /input_compat::printable_shortcut_key\(key_code, modifier_mask\)/);
assert(logs.some(v => v[1].includes('printable_key=redacted modifiers=1 result=0')));
console.log('PASS separate ArkTS/NAPI/Rust route and shortcut-only diagnostic metadata');
