#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const read = (relativePath) => fs.readFileSync(path.resolve(__dirname, '..', relativePath), 'utf8');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const service = read('entry/src/main/ets/service/ConnectionService.ets');
const napi = read('entry/src/main/ets/service/RustDeskNapi.ets');
const cpp = read('entry/src/main/cpp/napi_init.cpp');
const header = read('entry/src/main/cpp/core/rustdesk_ffi.h');
const rust = read('entry/src/main/rust/src/lib.rs');

for (const label of ['Ctrl', 'Alt', 'Shift', 'Win/Cmd', 'Fn', '更多', 'Del',
  'Ctrl+Shift+Del', 'Ctrl+Shift+Esc', 'Alt+F4', 'Ctrl+Alt+Del']) {
  assert(page.includes(`'${label}'`), `Missing mobile keyboard helper: ${label}`);
}

assert.match(page, /buildKeyboardShortcutOverlay\(\)/,
  'Keyboard helper overlay must be rendered while the soft keyboard is open');
assert.match(page, /setKeyboardAvoidMode\(KeyboardAvoidMode\.RESIZE\)/,
  'The remote page must resize so the shortcut bar stays above the software keyboard');
assert.match(page, /restoreKeyboardAvoidMode\(\)/,
  'The previous keyboard avoid mode must be restored after closing the panel');
assert.match(page, /keyboardToolsCollapsed/,
  'The shortcut bar must support a compact collapsed state');
assert.match(page, /beginKeyboardToolsDrag\(\)/,
  'The shortcut bar must expose a drag start handler');
assert.match(page, /updateKeyboardToolsDrag\(event\.offsetX, event\.offsetY\)/,
  'The shortcut bar and its compact button must be draggable');
assert.match(page, /Text\('键'\)/,
  'The collapsed shortcut bar must remain available as a small transparent button');
assert.match(page, /this\.keyboardToolsCollapsed = true/,
  'The expanded shortcut bar must provide a collapse action');
assert.match(page, /getKeyboardToolsBaseY\(\): number \{\s*return 8;/,
  'The shortcut bar must start at the top of the resized remote area');
assert.doesNotMatch(page, /padding\(\{ bottom: this\.getKeyboardReservedHeight\(\) \}\)/,
  'The remote picture must not be shortened a second time after keyboard resize');
assert.match(page, /keyboardMainButtonWidth\(54, 46\)/,
  'The phone layout must keep the More button visible');
assert.match(page, /showKeyboardFunctionKeys = !this\.showKeyboardFunctionKeys/,
  'Fn row must be expandable');
assert.match(page, /showKeyboardMoreKeys = !this\.showKeyboardMoreKeys/,
  'More-key row must be expandable');
assert.match(page, /selected \? RustDeskTheme\.ACCENT/,
  'Selected modifiers must use the app accent color');
assert.match(page, /sendPresetShortcut\(46, MODIFIER_MASK_CTRL \| MODIFIER_MASK_SHIFT/,
  'Ctrl+Shift+Del preset must use a modifier snapshot');
for (const label of ['Ctrl+Shift+Esc', 'Ctrl+Shift+Del', 'Alt+F4', 'Ctrl+Alt+Del']) {
  const escaped = label.replace(/[+]/g, '\\+');
  assert.match(page, new RegExp(`buildKeyboardToolButton\\('${escaped}'[\\s\\S]*?\\}, false\\)`),
    `${label} must not refocus the hidden input and reopen the software keyboard`);
}
assert.match(page, /KEYBOARD_CAPTURE_SENTINEL/,
  'The hidden input needs sentinel text so Backspace works when the field appears empty');
assert.match(page, /sendKeyboardTextSegment\(text: string\)/,
  'Committed text must be routed separately from control keys');
assert.match(page, /modifierMask !== 0 && keyCode > 0/,
  'Printable soft-keyboard shortcuts must preserve latched toolbar modifiers');
assert.match(page, /character !== '\\n' && character !== '\\r'/,
  'Newlines from an IME must be converted to remote Enter events');
assert.match(page, /if \(this\.canSendCtrlAltDel\)/,
  'Ctrl+Alt+Del should follow the peer capability reported by RustDesk');

assert.match(service, /RustDeskNapi\.sendKeyEvent\(keyCode, 2, modifierMask\)/,
  'Preset shortcuts must use one press event with explicit modifiers');
assert.match(napi, /static sendCtrlAltDel\(\): number/,
  'ArkTS NAPI facade must expose Ctrl+Alt+Del');
assert.match(cpp, /rust_send_ctrl_alt_del\(\)/,
  'C++ bridge must call the dedicated Rust shortcut API');
assert.match(header, /int rust_send_ctrl_alt_del\(void\);/,
  'Native FFI header must declare the dedicated shortcut API');
assert.match(rust, /ControlKey::CtrlAltDel/,
  'Windows secure attention sequence must use RustDesk ControlKey::CtrlAltDel');
assert.match(rust, /PEER_SAS_ENABLED\.store\(info\.sas_enabled/,
  'Windows shortcut visibility must use the peer SAS capability');

console.log('PASS responsive mobile keyboard helper and dedicated Ctrl+Alt+Del path');
