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
  .replace(/scanCode: number/g, 'scanCode')
  .replace(/\): string/g, ')');
const KeyboardMapping = Function(`return class KeyboardMapping {\n${method}\n}`)();

const expected = new Map([
  [0x02, '!'], [0x03, '@'], [0x04, '#'], [0x05, '$'], [0x06, '%'],
  [0x07, '^'], [0x08, '&'], [0x09, '*'], [0x0A, '('], [0x0B, ')'],
]);
for (const [scanCode, symbol] of expected) {
  assert.equal(KeyboardMapping.getShiftedNumberSymbol(scanCode), symbol);
}
assert.equal(KeyboardMapping.getShiftedNumberSymbol(0x1E), '');

assert.match(source, /shiftedSymbol\.length > 0 && hasShift && !hasHotkeyModifier/,
  'Shifted-number fallback must not replace Ctrl\/Alt\/Meta shortcuts');
assert.match(source, /RustDeskNapi\.sendText\(shiftedSymbol\)/,
  'Shifted-number fallback must send the resolved symbol');
assert.match(source, /action === 1 && trackedSymbolIndex >= 0/,
  'Key-up must follow the same fallback path as key-down');

console.log('PASS Shift+1..0 map to !@#$%^&*() without intercepting hotkeys');
