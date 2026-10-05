#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const assert = require('node:assert/strict')

const root = path.resolve(__dirname, '..', 'entry/src/main/ets')
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8')
const ability = read('entryability/EntryAbility.ets')
const remote = read('pages/RemotePage.ets')
const home = read('pages/HomePage.ets')
const connection = read('pages/ConnectionPage.ets')
const settings = read('pages/SettingsPage.ets')

assert.match(ability, /onConfigurationUpdate\(newConfig: Configuration\)[\s\S]*?updateFontScale\(newConfig\.fontSizeScale\)/)
for (const page of [remote, home, connection, settings]) {
  assert.match(page, /@StorageLink\('uiFontScale'\) uiFontScale: number = 1/)
}
assert.match(remote, /adaptiveToolbarButtonWidth\(baseWidth: number\)/)
assert.match(remote, /getRemoteToolbarHeight\(\)[\s\S]*?return this\.getRemoteToolbarButtonHeight\(\) \+ 14/)
assert.match(remote, /getKeyboardToolsHeight\(\)[\s\S]*?const rows: number = 1 \+ \(this\.showKeyboardFunctionKeys \? 1 : 0\) \+ \(this\.showKeyboardMoreKeys \? 1 : 0\)/)
assert.match(connection, /Flex\(\{ direction: FlexDirection\.Row, wrap: FlexWrap\.Wrap, alignItems: ItemAlign\.Center \}\)[\s\S]*?savedConnectionSearchExpanded/)
assert.match(home, /\.height\(this\.tabItemHeight\(\) \+ 14\)/)
assert.match(settings, /\.constraintSize\(\{ minHeight: this\.buttonShapeOptionHeight\(\) \}\)/)
for (const page of [remote, home, connection, settings]) {
  assert.doesNotMatch(page, /\.maxFontScale\(1\.3\)/,
    'Adaptive controls must not uniformly cap the system font scale')
}

console.log('PASS large-font layout follows the system scale and allows toolbar rows to grow or wrap')
