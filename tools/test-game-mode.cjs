'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = p => fs.readFileSync(path.join(__dirname, '..', p), 'utf8').replace(/\r\n/g, '\n');
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/GameModePolicy.ets')), context);
const Policy = context.exports.GameModePolicy;
const p = new Policy();
assert.equal(p.fps(), 60);
assert.equal(p.observe(4, 1000), 60, 'one burst must not reduce the rate');
assert.equal(p.observe(4, 1250), 60, 'samples are limited to twice per second');
assert.equal(p.observe(4, 1500), 50, 'two persistent backlogs reduce the rate promptly');
assert.equal(p.observe(2, 3000), 50, 'middle queue sizes do not oscillate');
assert.equal(p.observe(-1, 4000), 50, 'an unavailable snapshot never changes the rate');
assert.equal(p.observe(NaN, 5000), 50);
for (let t = 4000; t <= 9500; t += 500) p.observe(0, t);
assert.equal(p.fps(), 55, 'twelve low samples recover slowly');
for (let t = 10000; t <= 15500; t += 500) p.observe(0, t);
assert.equal(p.fps(), 60);
for (let t = 16000; t <= 20500; t += 500) p.observe(100, t);
assert.equal(p.fps(), 20, 'rate cannot fall below the supported floor');
assert.equal(p.observe(100, 100), 20, 'clock rollback resets observations, not preference');
p.reset(); assert.equal(p.fps(), 60);
assert.equal(p.observe(4, 1000), 60);
assert.equal(p.observe(4, 3000), 60, 'a long sampling gap cannot prove continuous congestion');
assert.equal(p.observe(4, 3500), 50);
p.reset();
assert.equal(p.observe(4, 1000), 60);
assert.equal(p.observe(0, 1500), 60, 'a brief burst does not reduce the rate');
assert.equal(p.observe(4, 2000), 60, 'good samples clear the high backlog streak');

const page = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
const calls = [], prefs = new Map(), logs = [], toast = [];
let fail = false, background = false;
const ui = { exports: {}, GameModePolicy: Policy, ConnectionStatus: { CONNECTED: 2 },
  ConnectionService: { setGameTransportEnabled() {} },
  RemoteSessionBackgroundTask: { isAppBackground: () => background },
  RustDeskNapi: {
    setGameMode(value) { calls.push(['mode', value]); return fail ? -2 : 0; },
    setGameFps(value) { calls.push(['fps', value]); return fail ? -2 : 0; },
    appendDiagnosticLog(...args) { logs.push(args); }
  }, Date: { now: () => 1000 } };
vm.runInNewContext(ts.transpile('class Page {' + ['loadGameModePreference', 'setGameMode', 'updateGameModePolicy']
  .map(method).join('\n') + '} exports.Page=Page;'), ui);
const pageObj = Object.assign(new ui.exports.Page(), {
  gameModePolicy: new Policy(), gameTransportHealth: { reset() {} }, peerPreferences: { get: key => prefs.get(key) || '',
    set: (key, value) => { prefs.set(key, value); return true; }, flush: () => true },
  fileOnly: false, connectionStatus: 2, desktopWindowActive: true, pipSurfaceOwned: false,
  gameModeEnabled: false, gameModeAppliedFps: 0, gameModeRetryAfter: 0,
  showFileToast: msg => toast.push(msg), showGameReconnectChoice() {},
  stopGamepadPolling() {}, startGamepadPolling() {}, finishGameScreenEdit() {}, refreshGameScreenAvoidance() {}
});
pageObj.loadGameModePreference();
assert.deepEqual(calls.pop(), ['mode', false], 'unconfigured peers default to off');
pageObj.setGameMode(true);
assert.equal(pageObj.gameModeEnabled, true);
assert.equal(prefs.get('game-mode'), '1');
assert.deepEqual(calls.pop(), ['mode', true]);
pageObj.setGameMode(false);
assert.equal(pageObj.gameModeEnabled, false);
assert.equal(prefs.get('game-mode'), '0');
assert.deepEqual(calls.pop(), ['mode', false]);
fail = true; pageObj.setGameMode(true); fail = false;
assert.equal(pageObj.gameModeEnabled, false, 'failed request does not claim enabled');
assert.equal(prefs.get('game-mode'), '0', 'failed request does not change saved preference');
assert.deepEqual(calls.slice(-2), [['mode', true], ['mode', false]], 'rollback requested');
prefs.set('game-mode', '1'); pageObj.loadGameModePreference();
assert.equal(pageObj.gameModeEnabled, true);
pageObj.gameModeAppliedFps = 0;
background = true; const before = calls.length;
pageObj.updateGameModePolicy({ hasFrame: true, queuedFrames: 0, gameEffectiveFps: 2 });
assert.equal(calls.length, before, 'background sessions do not change game FPS');
background = false;
pageObj.updateGameModePolicy({ hasFrame: true, queuedFrames: -1, gameEffectiveFps: 60 });
assert.equal(calls.length, before, 'unavailable queue snapshot is ignored');
pageObj.updateGameModePolicy({ hasFrame: true, queuedFrames: 0, gameEffectiveFps: 60 });
assert.deepEqual(calls.at(-1), ['fps', 60]);
pageObj.peerPreferences.flush = () => false;
pageObj.setGameMode(false);
assert.equal(pageObj.gameModeEnabled, false, 'save failure does not roll back an accepted live toggle');
assert.equal(toast.at(-1), '游戏模式已切换，但设置未保存');
assert(logs.every(entry => !entry.join(' ').includes('password')));

const widget = read('entry/src/main/ets/widget/RemoteGlassMenu.ets');
assert(widget.includes("key === 'gameMode'"));
assert(read('entry/src/main/ets/model/RemoteControlMenu.ets').includes("['gameMode', 'highPerformance', 'edgePan'"));
assert(page.includes("'gameMode', 'highPerformance', 'edgePan'"));
const menuContext = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/RemoteControlMenu.ets')), menuContext);
assert.deepEqual(Array.from(menuContext.exports.remoteControlCategoryItems('view', ['pan', 'gameMode', 'fullscreen'])),
  ['pan', 'gameMode', 'fullscreen'], 'game mode follows the saved toolbar order');
const orderContext = { exports: {}, RustDeskNapi: { getOption: () => '' } };
vm.runInNewContext(ts.transpile('class Page {' + method('readToolbarOrder') + '} exports.Page=Page;'), orderContext);
const orderPage = Object.assign(new orderContext.exports.Page(), {
  peerPreferences: { get: () => 'pan,fullscreen' }
});
assert.deepEqual(Array.from(orderPage.readToolbarOrder('order', ['gameMode', 'pan', 'fullscreen'])),
  ['pan', 'fullscreen', 'gameMode'], 'an existing custom order is preserved and gains the new action');
assert(widget.includes("case 'gameMode': return this.state.gameMode"));
assert(page.includes("case 'gameMode': this.setGameMode(!this.gameModeEnabled)"));
assert(page.includes('this.gameModeEnabled && this.connectionStatus === ConnectionStatus.CONNECTED'));
assert(page.includes("!RemoteSessionBackgroundTask.isAppBackground() && !this.controlMenu"));
const render = read('entry/src/main/cpp/core/video_render.cpp');
assert(render.includes('std::try_to_lock') && render.includes('pending + queued'));
for (const codec of ['h264_decoder', 'vp9_decoder', 'system_video_decoder',
  'software_vp8_decoder', 'software_vp9_decoder', 'software_av1_decoder']) {
  const source = read('entry/src/main/cpp/core/' + codec + '.h');
  assert(source.includes('queuedFrameCount()') && source.includes('std::try_to_lock'), codec);
}
const rust = read('entry/src/main/rust/src/lib.rs');
assert(rust.includes('GAME_MODE.load(Ordering::SeqCst)') && rust.includes('queue_game_performance_update'));
const bridge = read('entry/src/main/cpp/napi_init.cpp');
assert(bridge.includes('rust_set_game_mode(enabled ? 1 : 0, g_connectionStatus.load() == 2 ? 1 : 0)'));
assert(bridge.includes('rust_set_game_fps(fps, g_connectionStatus.load() == 2 ? 1 : 0)'));
assert(!method('setGameMode').includes('setInputModes'), 'game mode does not alter keyboard/mouse mapping');
console.log('PASS game mode: adaptive hysteresis, bounds, invalid samples, rollback, background, UI wiring and nonblocking queue snapshots');
