#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const page = fs.readFileSync(
  path.resolve(__dirname, '..', 'entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');

assert.match(page, /placeholder: '搜索名称或远端 ID'/,
  'Saved connections need a clearly labelled search field');
assert.match(page, /savedConnectionSearchExpanded/,
  'Search must expand from the saved-connections action row');
assert.match(page, /Button\(this\.savedConnectionSearchExpanded \? '收起' : '搜索'\)/,
  'The search toggle must stay in one stable action slot');
assert.match(page, /placeholder: '搜索名称或远端 ID'[\s\S]*?\.layoutWeight\(1\)/,
  'Expanded search must use the free space to the left of fixed actions');
assert.match(page, /Button\('备份'\)\s*\.width\(48\)/,
  'Backup action must keep a fixed width while search expands');
assert.match(page, /Button\('\+ 分组'\)\s*\.width\(56\)/,
  'Group action must keep a fixed width while search expands');
assert.doesNotMatch(page, /Search\(\{ value: this\.savedConnectionSearch[^}]+\}\)\s*\.width\('100%'\)/s,
  'Search must not consume a full standalone row');
assert.match(page, /matchesSavedConnectionSearch\(item\)/,
  'Saved connection rows must be filtered');
assert.match(page, /item\.name\.toLowerCase\(\)\.includes\(query\)/,
  'Search must match device names');
assert.match(page, /compactRemoteId\.includes\(compactQuery\)/,
  'Search must match remote IDs and ignore spaces');
assert.match(page, /Text\('未找到匹配的设备'\)/,
  'Search needs an empty-result state');
assert.match(page, /shouldShowSavedConnectionGroup\(group\.id\)/,
  'Groups without matching devices must be hidden while searching');

console.log('PASS saved connection search and filtered groups');
