#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const source = fs.readFileSync(path.resolve(__dirname,
  '../entry/src/main/ets/pages/RemotePage.ets'), 'utf8').replace(/\r\n/g, '\n');

function method(name) {
  const start = source.indexOf(`\n  ${name}(`);
  assert(start >= 0, `${name} not found`);
  const end = source.indexOf('\n  }', start) + 4;
  return source.slice(start, end);
}

const context = vm.createContext({});
const classSource = `class Mapping {${method('mapAsciiToUsbHidCode')}${method('mapHarmonyKeyCodeToUsbHidCode')}${method('mapControlKeyCode')}${method('isModifierControlCode')}};globalThis.Mapping=Mapping;`;
vm.runInContext(ts.transpile(classSource), context);
const mapping = new context.Mapping();

assert.equal(mapping.mapHarmonyKeyCodeToUsbHidCode(2033), 0x14, 'Harmony Q must become USB HID Q');
assert.equal(mapping.mapHarmonyKeyCodeToUsbHidCode(2039), 0x1A, 'Harmony W must become USB HID W');
assert.equal(mapping.mapHarmonyKeyCodeToUsbHidCode(2017), 0x04, 'Harmony A must become USB HID A');
assert.equal(mapping.mapHarmonyKeyCodeToUsbHidCode(2001), 0x1E, 'Harmony 1 must become USB HID 1');
assert.equal(mapping.mapHarmonyKeyCodeToUsbHidCode(2000), 0x27, 'Harmony 0 must become USB HID 0');
assert.equal(mapping.mapHarmonyKeyCodeToUsbHidCode(2043), 0x36, 'Harmony comma must become USB HID comma');
assert.equal(mapping.mapAsciiToUsbHidCode('q'), 0x14);
assert.equal(mapping.mapAsciiToUsbHidCode('W'), 0x1A);

assert.equal(mapping.mapControlKeyCode(2045), 18, 'left Alt remains Alt');
assert.equal(mapping.mapControlKeyCode(2046), 165, 'right Alt becomes RAlt');
assert.equal(mapping.mapControlKeyCode(2047), 16, 'left Shift remains Shift');
assert.equal(mapping.mapControlKeyCode(2048), 161, 'right Shift becomes RShift');
assert.equal(mapping.mapControlKeyCode(2072), 17, 'left Ctrl remains Control');
assert.equal(mapping.mapControlKeyCode(2073), 163, 'right Ctrl becomes RControl');
assert.equal(mapping.mapControlKeyCode(2076), 91, 'left Meta remains Meta');
assert.equal(mapping.mapControlKeyCode(2077), 92, 'right Meta becomes RWin');
assert.equal(mapping.mapControlKeyCode(2090), 112, 'Harmony F1 must become F1');
assert.equal(mapping.mapControlKeyCode(2092), 114, 'Harmony F3 must become F3');
assert.equal(mapping.mapControlKeyCode(2101), 123, 'Harmony F12 must become F12');
for (const key of [16, 161, 17, 163, 18, 165, 91, 92]) {
  assert.equal(mapping.isModifierControlCode(key), true, `${key} must be handled as a modifier`);
}

console.log('PASS HarmonyOS physical keys, function keys and side-specific modifiers follow RustDesk mappings');
