'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r/g, '');
const context = { exports: {}, Math, Number, JSON, Map, Array, Object, Observed: value => value };
for (const file of ['GamepadMapping', 'GameScreenControls', 'GameScreenRenderKey']) {
  const source = read(`entry/src/main/ets/model/${file}.ets`).replace(/^import .*\n/gm, '');
  vm.runInNewContext(ts.transpile(source), context);
  Object.assign(context, context.exports);
}
const pageSource = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = pageSource.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return pageSource.slice(start, pageSource.indexOf('\n  }', start) + 4);
};
const logs = [], toasts = [], values = new Map();
Object.assign(context, { ConnectionStatus: { CONNECTED: 2 },
  RustDeskNapi: { appendDiagnosticLog: (...args) => logs.push(args) } });
const names = ['screenGameClone', 'prepareDefaultGameScreenLayout', 'syncGameScreenKeys', 'screenGameSelectedKey', 'beginGameScreenEdit',
  'finishGameScreenEdit', 'loadDefaultGameScreenKeys', 'addGameScreenKey', 'toggleGameScreenControls',
  'handleGlassMenuAction'];
vm.runInNewContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} exports.Page=Page;'), context);
const empty = { version:1, active:0, profiles:[{name:'Existing empty',keys:[]},
  {name:'Second',keys:[]},{name:'Third',keys:[]}] };
values.set('game-screen-controls-v1', JSON.stringify(empty));
let releases = 0, starts = 0, stops = 0, menuCloses = 0;
const page = Object.assign(new context.exports.Page(), {
  gameScreenConfig: context.decodeScreenGameConfig(values.get('game-screen-controls-v1')),
  gameScreenKeys: [], gameScreenKeysProfile: -1, gameScreenDefaultLayoutPending: false,
  qualityViewportWidth: 1024, qualityViewportHeight: 600, gameScreenEnabled: false, gameScreenEditing: false,
  gameScreenSelected: -1, physicalGamepadEnabled: false, virtualGamepadEnabled: false,
  remotePageVisible: true, connectionStatus: 2, controlMenu: 'input', controlMenuClosing: false,
  peerPreferences: { get: key => values.get(key) || '', set: (key, value) => { values.set(key, value); return true; }, flush: () => true },
  gamepadMapper: { releaseAll: () => { releases++; } },
  refreshGameScreenAvoidance: () => {},
  startGamepadPolling: () => { starts++; }, stopGamepadPolling: () => { stops++; },
  showFileToast: message => toasts.push(message),
  setGamepadEnabled: (kind, enabled) => { assert.equal(kind, 'virtual'); page.virtualGamepadEnabled = enabled; },
  setControlMenu: category => { assert.equal(category, ''); menuCloses++; page.controlMenu = category; }
});
page.syncGameScreenKeys();
page.toggleGameScreenControls(true);
assert.match(toasts.at(-1), /没有屏幕按键/);
page.beginGameScreenEdit();
page.loadDefaultGameScreenKeys();
assert.equal(page.gameScreenKeys.length, 7, 'preset appears immediately in the editor');
page.finishGameScreenEdit(false);
assert.equal(page.gameScreenKeys.length, 0, 'cancel restores the saved empty layout');
assert.equal(JSON.parse(values.get('game-screen-controls-v1')).profiles[0].keys.length, 0);
page.beginGameScreenEdit();
page.loadDefaultGameScreenKeys();
page.addGameScreenKey();
assert.equal(page.gameScreenKeys.length, 8);
assert.equal(page.gameScreenSelected, 8);
page.finishGameScreenEdit(true);
assert.equal(JSON.parse(values.get('game-screen-controls-v1')).profiles[0].keys.length, 8);
assert.equal(values.get('game-screen-enabled'), '1');
page.beginGameScreenEdit();
const before = JSON.stringify(page.gameScreenConfig);
page.loadDefaultGameScreenKeys();
assert.equal(JSON.stringify(page.gameScreenConfig), before, 'preset never replaces existing custom buttons');
page.finishGameScreenEdit(false);
page.gameScreenConfig = context.defaultScreenGameConfig();
page.gameScreenDefaultLayoutPending = true;
page.prepareDefaultGameScreenLayout();
assert.equal(page.gameScreenDefaultLayoutPending, false);
const preset = page.gameScreenConfig.profiles[0].keys;
assert((preset[3].x - preset[1].x) * (page.qualityViewportWidth - preset[1].size) < 125,
  'fresh layout adapts to a wide tablet without spreading the direction keys');
const unchanged = JSON.stringify(page.gameScreenConfig);
page.qualityViewportWidth = 500;
page.prepareDefaultGameScreenLayout();
assert.equal(JSON.stringify(page.gameScreenConfig), unchanged, 'ordinary resize never moves a configured layout');
page.gameScreenDefaultLayoutPending = true;
page.qualityViewportWidth = 0;
page.qualityViewportHeight = 0;
page.beginGameScreenEdit();
page.finishGameScreenEdit(true);
const savedBeforeResize = JSON.stringify(page.gameScreenConfig);
page.qualityViewportWidth = 1024;
page.qualityViewportHeight = 600;
page.prepareDefaultGameScreenLayout();
assert.equal(page.gameScreenDefaultLayoutPending, false);
assert.equal(JSON.stringify(page.gameScreenConfig), savedBeforeResize,
  'saving before viewport measurement prevents a later resize replacing the saved layout');
page.handleGlassMenuAction('virtualGamepad');
assert.equal(page.virtualGamepadEnabled, true);
assert.equal(menuCloses, 1, 'enabling the virtual pad closes the input menu so it becomes visible');
page.controlMenu = 'input';
page.handleGlassMenuAction('virtualGamepad');
assert.equal(page.virtualGamepadEnabled, false);
assert.equal(menuCloses, 1, 'disabling does not force the menu closed');
assert(releases > 0 && starts > 0 && stops >= 0);
assert(logs.some(entry => String(entry[1]).includes('screen_preset_loaded')));
assert(logs.every(entry => !/password|token|Existing empty/.test(entry.join(' '))));
assert(pageSource.includes("this.virtualGamepadEnabled ? '隐藏虚拟手柄' : '显示虚拟手柄'"));
assert(pageSource.includes("Button(translate('加载默认按键'"));
console.log('PASS game screen preset, saved-layout preservation, edit/cancel/save, empty warning and visible virtual-pad entry');
