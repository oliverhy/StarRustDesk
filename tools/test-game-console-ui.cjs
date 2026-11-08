'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'), 'utf8').replace(/\r/g, '');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const names = ['gameConsoleWidth', 'gameConsoleMaxY', 'gameConsoleUseTwoColumns', 'toggleGameConsole',
  'gameConsoleActionLabel', 'gameConsoleActionAccessibility', 'gameConsoleActionIcon',
  'gameConsoleActionSelected', 'handleGameConsoleAction'];
const context = { exports: {}, Date, Math, Curve: { EaseOut: 1 }, $r: value => value };
vm.runInNewContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} exports.Page=Page;'), context);
const calls = [];
const page = Object.assign(new context.exports.Page(), {
  qualityViewportWidth: 1000, qualityViewportHeight: 600, uiFontScale: 1,
  gameConsoleExpanded: true, gameConsoleDragAt: 0, gameScreenEditing: false,
  virtualGamepadEnabled: false, gameScreenEnabled: false, relativeMouseEnabled: false, relativeMouseSupported: true,
  setGamepadEnabled: (kind, value) => { calls.push([kind, value]); page.virtualGamepadEnabled = value; },
  toggleGameScreenControls: value => { calls.push(['screen', value]); page.gameScreenEnabled = value; },
  beginGameScreenEdit: () => calls.push(['edit']),
  setRelativeMouse: value => { calls.push(['relative', value]); page.relativeMouseEnabled = value; },
  getUIContext: () => ({ animateTo: (_options, update) => update() })
});
assert.equal(page.gameConsoleWidth(), 248);
assert.equal(page.gameConsoleMaxY(), 390);
assert.equal(page.gameConsoleUseTwoColumns(), true);
page.qualityViewportWidth = 200;
assert.equal(page.gameConsoleWidth(), 200);
assert.equal(page.gameConsoleUseTwoColumns(), false, 'small screens use readable single-column actions');
page.qualityViewportWidth = 1000;
page.uiFontScale = 1.5;
assert.equal(page.gameConsoleUseTwoColumns(), false, 'large fonts use a single column');
page.uiFontScale = 1;
for (const key of ['virtual', 'screen', 'edit', 'relative']) {
  assert(page.gameConsoleActionLabel(key));
  assert(page.gameConsoleActionIcon(key));
  assert(page.gameConsoleActionAccessibility(key));
}
page.handleGameConsoleAction('virtual');
assert.equal(page.gameConsoleActionSelected('virtual'), true);
assert.equal(page.gameConsoleActionAccessibility('virtual'), '隐藏虚拟手柄');
page.handleGameConsoleAction('screen');
assert.equal(page.gameConsoleActionSelected('screen'), true);
page.handleGameConsoleAction('edit');
page.handleGameConsoleAction('relative');
assert.equal(page.gameConsoleActionSelected('relative'), true);
page.relativeMouseSupported = false;
page.handleGameConsoleAction('relative');
assert.deepEqual(calls, [['virtual', true], ['screen', true], ['edit'], ['relative', true]],
  'all actions retain their handlers; unsupported relative mouse cannot be toggled');
page.toggleGameConsole();
assert.equal(page.gameConsoleExpanded, false);
assert.equal(page.gameConsoleWidth(), 146, 'collapsed header has enough room for the full game label');
assert.equal(page.gameConsoleMaxY(), 556);
page.gameScreenEditing = true;
page.toggleGameConsole();
assert.equal(page.gameConsoleExpanded, false, 'editing cannot accidentally collapse the panel');
assert(source.includes(".id('game-console')") && source.includes(".id('game-console-collapse')"));
assert(source.includes(".id('game-console-mapping')") && source.includes(".backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN"));
assert(source.includes("this.isDarkMode ? '#A61B2638' : '#A6FFFFFF'"), 'console shares the toolbar glass palette');
assert(source.includes("this.gameScreenConfig.profiles[this.gameScreenConfig.active].keys.length === 0"));
console.log('PASS game console layout, readable sizing, glass theme, action wiring and safe editing');
