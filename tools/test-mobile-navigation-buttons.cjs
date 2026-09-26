#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = p => fs.readFileSync(path.resolve(__dirname, '..', p), 'utf8').replace(/\r\n/g, '\n');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const method = name => {
  const start = page.indexOf(`\n  ${name}(`);
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
const packets = [], logs = [], buttons = [], options = new Map();
const native = {
  sendKeyEvent: (...args) => { packets.push(args); return 0; },
  appendDiagnosticLog: (...args) => logs.push(args),
  getOption: key => options.get(key) || '',
  setOption: (key, value) => options.set(key, value)
};
function Button(label) {
  const state = { label };
  buttons.push(state);
  const chain = new Proxy({}, { get: (_, key) => (...args) => {
    state[key] = args[0];
    return chain;
  } });
  return chain;
}
const context = vm.createContext({ exports: {}, RustDeskNapi: native,
  hilog: { info() {}, warn() {} }, Button,
  ButtonType: { Capsule: 1 }, ButtonShapeModifier: class {},
  LongPressGesture: options => ({ onAction: callback => ({ ...options, callback }) }),
  RustDeskTheme: { FONT_WEIGHT_SEMI_BOLD: 600 }
});
vm.runInContext(compile(read('entry/src/main/ets/service/ConnectionService.ets')
  .replace(/^import .*\n/gm, '')), context);
context.ConnectionService = context.exports.ConnectionService;
const constants = [...page.matchAll(/^const (?:VIRTUAL_MODIFIER_\w+|MODIFIER_MASK_\w+): number = .*;$/gm)]
  .map(m => m[0]).join('\n');
const order = page.match(/const KEYBOARD_MORE_DEFAULT_ORDER: string\[\] = \[[\s\S]*?\];/)[0];
const methods = ['buildKeyboardMoreItem', 'buildKeyboardToolButton', 'keyboardToolSelected',
  'sendVirtualControlKey', 'toggleVirtualModifier', 'isVirtualModifierSelected',
  'setVirtualModifierSelected', 'releaseVirtualModifiers', 'toolbarOrderLabel',
  'openToolbarOrderEditor', 'readToolbarOrder', 'moveToolbarOrderItem', 'saveToolbarOrder']
  .map(method).join('\n');
vm.runInContext(compile(`${constants}\n${order}\nclass Probe {${methods}}\n` +
  'globalThis.Probe = Probe; globalThis.defaults = KEYBOARD_MORE_DEFAULT_ORDER;'), context);
const p = new context.Probe();
let focusRequests = 0;
Object.assign(p, { virtualCtrlSelected: false, virtualShiftSelected: false,
  virtualAltSelected: false, virtualMetaSelected: false, roundedRectButtons: true,
  primaryTextColor: () => '#111111', themeBorderColor: () => '#CCCCCC',
  refocusRemoteKeyboard: () => { focusRequests++; }
});
const directions = [['Left', '←', 37, '← 向左'], ['Up', '↑', 38, '↑ 向上'],
  ['Down', '↓', 40, '↓ 向下'], ['Right', '→', 39, '→ 向右']];
assert.deepEqual(Array.from(context.defaults).slice(0, 4), directions.map(d => d[0]));
for (const vertical of [false, true]) {
  for (const panel of [false, true]) {
    for (let mask = 0; mask < 16; mask++) {
      p.releaseVirtualModifiers();
      for (const [code, bit] of [[17, 1], [16, 2], [18, 4], [91, 8]]) {
        if (mask & bit) p.toggleVirtualModifier(code);
      }
      p.showKeyboardPanel = panel;
      for (const [id, label, code, accessible] of directions) {
        buttons.length = packets.length = 0;
        p.buildKeyboardMoreItem(id, vertical);
        assert.equal(buttons.length, 1);
        const button = buttons[0];
        assert.equal(button.label, label);
        assert.equal(button.width, vertical ? 96 : 48);
        assert.equal(button.height, 38);
        assert.equal(button.fontSize, 20);
        assert.equal(button.accessibilityText, accessible);
        assert.equal(button.focusable, false);
        button.onClick(); button.onClick();
        assert.deepEqual(packets, [[code, 2, mask], [code, 2, mask]], `${id}: modifier mask=${mask}`);
        assert.equal(focusRequests, 0, 'Direction buttons must never refocus/open the soft keyboard');
        assert.equal(p.showKeyboardPanel, panel);
        packets.length = 0;
        assert.equal(button.gesture.repeat, false);
        button.gesture.callback();
        assert.equal(p.showToolbarOrderEditor, true);
        assert.equal(p.toolbarOrderEditorKind, 'keyboardMore');
        assert.equal(packets.length, 0, 'Long press only opens the sort editor');
      }
    }
  }
}
p.releaseVirtualModifiers();
packets.length = 0;
buttons[0].onClick();
assert.deepEqual(packets, [[39, 2, 0]], 'Release must clear all latched modifiers');
assert(logs.some(entry => entry[0] === 'input-shortcut' && entry[1] === 'virtual_key=Up code=38'));
console.log('PASS 256 mobile direction cases: orientation, IME visibility, all modifier combinations, clicks and long-press sorting');

// Existing user order must survive the upgrade; new keys are appended only once.
const legacy = Array.from(context.defaults).filter(key => !directions.some(d => d[0] === key)).reverse();
options.set('remote-keyboard-more-order', legacy.join(','));
p.keyboardMoreOrder = p.readToolbarOrder('remote-keyboard-more-order', context.defaults);
assert.deepEqual(Array.from(p.keyboardMoreOrder), [...legacy, ...directions.map(d => d[0])]);
p.moveToolbarOrderItem('keyboardMore', p.keyboardMoreOrder.indexOf('Up'), 0);
const restored = p.readToolbarOrder('remote-keyboard-more-order', context.defaults);
assert.equal(restored[0], 'Up');
assert.deepEqual(Array.from(restored), Array.from(p.keyboardMoreOrder));
assert.equal(new Set(restored).size, context.defaults.length);
assert.equal(options.size, 1, 'Direction ordering must not overwrite other toolbar settings');
console.log('PASS mobile direction order upgrade, reordering and persistence');
