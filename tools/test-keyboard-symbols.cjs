#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const sourcePath = path.resolve(__dirname, '../entry/src/main/ets/service/ConnectionService.ets');
const source = fs.readFileSync(sourcePath, 'utf8').replace(/\r\n/g, '\n');

const start = source.indexOf('  private static getShiftedNumberSymbol(');
const end = source.indexOf('\n  }\n', start) + '\n  }\n'.length;
assert(start >= 0 && end > start, 'Production shifted-number helper not found');

const method = source.slice(start, end)
  .replace('private static ', 'static ')
  .replace(/hidCode: number/g, 'hidCode')
  .replace(/\): string/g, ')');
const KeyboardMapping = Function(`return class KeyboardMapping {\n${method}\n}`)();

const expected = new Map([
  [0x1E, '!'], [0x1F, '@'], [0x20, '#'], [0x21, '$'], [0x22, '%'],
  [0x23, '^'], [0x24, '&'], [0x25, '*'], [0x26, '('], [0x27, ')'],
]);
for (const [hidCode, symbol] of expected) {
  assert.equal(KeyboardMapping.getShiftedNumberSymbol(hidCode), symbol);
}
assert.equal(KeyboardMapping.getShiftedNumberSymbol(0x04), '');

assert.match(source, /shiftedSymbol\.length > 0 && hasShift && !hasHotkeyModifier/,
  'Shifted-number fallback must not replace Ctrl\/Alt\/Meta shortcuts');
assert.match(source, /RustDeskNapi\.sendText\(shiftedSymbol\)/,
  'Shifted-number fallback must send the resolved symbol');
assert.match(source, /action === 1 && trackedSymbolIndex >= 0/,
  'Key-up must follow the same fallback path as key-down');

console.log('PASS USB HID Shift+1..0 map to !@#$%^&*() without intercepting hotkeys');
