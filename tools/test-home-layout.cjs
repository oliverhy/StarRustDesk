#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const page = fs.readFileSync(
  path.resolve(__dirname, '..', 'entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8')
  .replace(/\r\n/g, '\n');
const homePage = fs.readFileSync(
  path.resolve(__dirname, '..', 'entry/src/main/ets/pages/HomePage.ets'), 'utf8')
  .replace(/\r\n/g, '\n');
const settingsPage = fs.readFileSync(
  path.resolve(__dirname, '..', 'entry/src/main/ets/pages/SettingsPage.ets'), 'utf8')
  .replace(/\r\n/g, '\n');

const between = (start, end) => {
  const a = page.indexOf(start);
  const b = page.indexOf(end, a);
  assert(a >= 0 && b > a, `missing section ${start}`);
  return page.slice(a, b);
};

const build = between('  build() {', '  @Builder\n  buildPageHeader()');
const phone = build.slice(build.indexOf('} else {'));
assert(phone.indexOf('this.buildConnectionForm()') < phone.indexOf('this.buildSavedConnections()'),
  'phone layout must place new connection before saved connections');

const form = between('  buildConnectionForm() {', '  @Builder\n  buildUpdateBanner()');
assert.match(page, /@State connectionFormExpanded: boolean = false/,
  'advanced connection fields should start collapsed');
assert(form.indexOf('this.buildRemoteIdInput()') < form.indexOf('if (this.connectionFormExpanded)'),
  'remote ID/IP must remain visible while advanced options are collapsed');
assert.match(form, /Button\(this\.connectionFormExpanded \? '收起选项⌃' : '更多选项›'\)/,
  'compact form needs a clear advanced-options action');
assert.match(form, /TransitionEffect\.OPACITY[\s\S]*TransitionEffect\.translate\(\{ y: -8 \}\)[\s\S]*duration: 220/,
  'advanced connection fields should animate while expanding and collapsing');
assert.match(page, /placeholder: '远端 ID \/ IP'/,
  'compact form must state that IDs and IP addresses are accepted');

const saved = between('  buildSavedConnections() {', '  @Builder\n  buildConnectionStatusLegend()');
assert.match(saved, /Text\(`\$\{this\.savedConnections\.length\}`\)/,
  'saved connection count should sit beside the title');
assert.match(saved, /this\.buildConnectionStatusLegend\(\)/,
  'compact list needs a status legend');
assert.match(saved, /toggleSavedConnectionsExpanded\(\)[\s\S]*duration: 240/,
  'saved connection section should animate while expanding and collapsing');

const group = between('  buildSavedConnectionGroup(', '  @Builder\n  buildGroupNameDialog()');
assert.match(group, /Button\('连接'\)[\s\S]*CONTROL_SELECTED_BG/,
  'saved rows should use a pale-blue connection button');
assert.match(group, /Button\('⋯'\)[\s\S]*value: '移动到分组'[\s\S]*value: '修改连接'[\s\S]*value: '删除连接'/,
  'compact more menu must retain move, edit and delete');
assert.doesNotMatch(group, /peerOnlineStateHint\(item\.remoteId\)/,
  'saved rows should stay at two text lines');
assert.match(group, /TransitionEffect\.translate\(\{ y: -6 \}\)[\s\S]*duration: 210/,
  'saved connection groups should animate their rows');

assert.match(page, /toggleConnectionGroup\(groupId: string\): void \{[\s\S]*getUIContext\(\)\.animateTo\(\{ duration: 210/,
  'group toggles should drive their transition through animateTo');
assert.match(page, /TransitionEffect\.translate\(\{ x: -8 \}\)[\s\S]*savedConnectionSearchExpanded = !this\.savedConnectionSearchExpanded/,
  'search expansion should animate without shifting the toolbar');

assert.match(homePage, /Stack\(\{ alignContent: Alignment\.TopStart \}\) \{[\s\S]*\.backgroundColor\(Color\.Transparent\)[\s\S]*\.backgroundEffect\(\{[\s\S]*radius: 14,[\s\S]*color: this\.isDarkMode \? '#0C1B2638' : '#04F4F8FF'/,
  'floating home navigation should use a dedicated low-tint background blur layer');
assert.match(homePage, /tabBarWidth[\s\S]*this\.currentTabIndex \* \(\(this\.tabBarWidth - 18\) \/ 2 \+ 6\)[\s\S]*duration: 280/,
  'selected home tab highlight should slide between tabs');
assert.match(homePage, /this\.isDarkMode \? '#2823466F' : '#18DCEBFF'/,
  'sliding home tab highlight should retain the translucent selected color');
assert.doesNotMatch(homePage, /\.padding\(\{ bottom: 78 \}\)/,
  'home pages should render behind the floating navigation surface');
assert.equal((page.match(/\.padding\(\{ bottom: 94 \}\)/g) || []).length, 3,
  'connection scroll areas should preserve a tappable bottom safe space');
assert.match(settingsPage, /bottom: 94/,
  'settings scroll content should preserve a tappable bottom safe space');

console.log('PASS compact reference home layout and preserved actions');
