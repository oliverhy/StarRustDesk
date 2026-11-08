'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r/g, '');
const ctx = { exports: {}, Math, Number, JSON, Array, Object, Observed: value => value };
for (const file of ['GamepadMapping', 'GameScreenControls', 'GameScreenRenderKey', 'VirtualGamepadGeometry', 'GameScreenAvoidance']) {
  vm.runInNewContext(ts.transpile(read(`entry/src/main/ets/model/${file}.ets`).replace(/^import .*\n/gm, '')), ctx);
  Object.assign(ctx, ctx.exports);
}
const source = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const log = [], calls = [], toasts = [], values = new Map();
Object.assign(ctx, { ConnectionStatus: { CONNECTED: 2 },
  RustDeskNapi: { appendDiagnosticLog: (...args) => log.push(args) } });
const methods = ['syncGameScreenKeys', 'refreshGameScreenAvoidance', 'screenGameClone',
  'prepareDefaultGameScreenLayout', 'setGamepadEnabled', 'toggleGameScreenControls',
  'beginGameScreenEdit', 'finishGameScreenEdit', 'gamepadVirtualButton', 'gamepadVirtualAxis'];
vm.runInNewContext(ts.transpile('class Page {' + methods.map(method).join('\n') + '} exports.Page=Page;'), ctx);
const config = ctx.defaultScreenGameConfig();
config.profiles[0].keys = ctx.defaultScreenGameKeys(1024, 600);
const original = JSON.stringify(config);
values.set('game-screen-controls-v1', original);
const page = Object.assign(new ctx.exports.Page(), {
  gameScreenConfig: config, gameScreenKeys: [], gameScreenKeysProfile: -1, gameScreenDefaultLayoutPending: false,
  gameScreenEnabled: false, gameScreenEditing: false, gameScreenSelected: -1, gameModeEnabled: true,
  gameScreenCoexistFits: true, gameScreenCoexistCompact: false, gameScreenAvoidanceLogState: '',
  qualityViewportWidth: 1024, qualityViewportHeight: 600, remotePageVisible: true, connectionStatus: 2,
  fileOnly: false, physicalGamepadEnabled: false, virtualGamepadEnabled: false,
  peerPreferences: { get: key => values.get(key) || '', set: (key, value) => { values.set(key, value); return true; }, flush: () => true },
  gamepadMapper: { releaseAll: () => calls.push(['releaseAll']), releaseDevice: device => calls.push(['releaseDevice', device]),
    button: (...args) => calls.push(['button', ...args]), axis: (...args) => calls.push(['axis', ...args]) },
  startGamepadPolling() {}, stopGamepadPolling() {}, gamepadCanForward: () => true,
  gamepadFloatingControlsPlan: () => ({ fits: true }), showFileToast: text => toasts.push(text)
});
const overlaps = (a, b) => a.x < b.x + b.size + 1.99 && b.x < a.x + a.size + 1.99 &&
  a.y < b.y + b.size + 1.99 && b.y < a.y + a.size + 1.99;
const assertSeparated = () => {
  assert(page.gameScreenCoexistFits);
  for (const key of page.gameScreenKeys) {
    assert(key.renderSize >= 36);
    const rect = { x: key.renderX, y: key.renderY, size: key.renderSize };
    for (const pad of ctx.virtualGamepadRects(page.qualityViewportWidth, page.qualityViewportHeight))
      assert(!overlaps(rect, pad), `screen key ${key.id} overlaps controller ${pad.id}`);
  }
};
page.syncGameScreenKeys();
page.toggleGameScreenControls(true);
assert(page.gameScreenKeys.every(key => key.renderX === -1 && key.renderSize === 0));
page.setGamepadEnabled('virtual', true);
assertSeparated();
const adjusted = JSON.stringify(page.gameScreenKeys.map(key => [key.id, key.renderX, key.renderY, key.renderSize]));
assert(calls.some(call => call[0] === 'releaseDevice' && call[1] === -2), 'moving buttons releases held screen keys');
assert.equal(JSON.stringify(page.gameScreenConfig), original, 'coexistence never rewrites user positions');
assert.equal(values.get('game-screen-controls-v1'), original);
page.setGamepadEnabled('virtual', false);
assert(page.gameScreenKeys.every(key => key.renderX === -1 && key.renderY === -1 && key.renderSize === 0), 'original layout restored');
page.setGamepadEnabled('virtual', true);
assertSeparated();
assert.equal(JSON.stringify(page.gameScreenKeys.map(key => [key.id, key.renderX, key.renderY, key.renderSize])), adjusted);
page.beginGameScreenEdit();
assert(page.gameScreenKeys.every(key => key.renderX === -1 && key.renderSize === 0), 'editor uses saved layout');
page.gameScreenConfig.profiles[0].keys[0].x = 0.5;
page.screenGameClone();
page.finishGameScreenEdit(false);
assert.equal(JSON.stringify(page.gameScreenConfig), original, 'cancel restores the saved layout');
assert.equal(values.get('game-screen-controls-v1'), original);
assertSeparated();
assert.equal(JSON.stringify(page.gameScreenKeys.map(key => [key.id, key.renderX, key.renderY, key.renderSize])), adjusted);
page.qualityViewportWidth = 240; page.qualityViewportHeight = 160;
page.refreshGameScreenAvoidance();
assert.equal(page.gameScreenCoexistFits, false, 'insufficient room hides the controller temporarily');
assert(toasts.some(text => text.includes('虚拟手柄暂时隐藏')));
const before = calls.length;
page.gamepadVirtualButton(2301, true);
assert.equal(calls.length, before, 'hidden controller cannot press remote keys');
page.gamepadVirtualButton(2301, false);
assert.deepEqual(calls.at(-1), ['button', -1, 2301, false], 'releases still propagate');
page.gamepadVirtualAxis(1, 1, 1);
assert.deepEqual(calls.at(-1), ['axis', -1, 1, 0, 0]);
page.qualityViewportWidth = 1024; page.qualityViewportHeight = 600;
page.refreshGameScreenAvoidance();
assertSeparated();
assert.equal(JSON.stringify(page.gameScreenConfig), original);
page.toggleGameScreenControls(false);
assert(page.gameScreenKeys.every(key => key.renderX === -1 && key.renderSize === 0));
assert.equal(page.gameScreenCoexistFits, true);
page.toggleGameScreenControls(true);
assertSeparated();
assert.equal(JSON.stringify(page.gameScreenKeys.map(key => [key.id, key.renderX, key.renderY, key.renderSize])), adjusted,
  'enabling screen buttons after the controller produces the same layout');
assert(log.every(entry => !/password|token/i.test(entry.join(' '))), 'diagnostics contain no credentials');
const overlay = read('entry/src/main/ets/widget/GameScreenOverlay.ets');
assert(overlay.includes('!this.editing && this.item.renderX >= 0'));
assert(overlay.includes('!this.editing && this.item.renderSize > 0'));
console.log('PASS screen/gamepad coexistence: toggle order, saved layout, editing, safe fallback and recovery');
