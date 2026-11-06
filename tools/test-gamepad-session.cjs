'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8').replace(/\r/g, '');
const context = { exports: {}, Math, Number, JSON, Map, Array, Object };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/GamepadMapping.ets')), context);
Object.assign(context, context.exports);
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/GameScreenControls.ets').replace(/^import .*\n/gm, '')), context);
Object.assign(context, context.exports);
context.Observed = value => value;
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/GameScreenRenderKey.ets').replace(/^import .*\n/gm, '')), context);
Object.assign(context, context.exports);
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
};
const names = ['loadGamepadPreferences', 'syncGameScreenKeys', 'gamepadCanForward', 'setGamepadEnabled', 'startGamepadPolling',
  'stopGamepadPolling', 'gamepadVirtualButton', 'gameScreenButton', 'gamepadVirtualAxis', 'sendGamepadTarget', 'moveGamepadPointer'];
const timers = new Map(), calls = [], values = new Map(), logs = [], toasts = [];
let nextTimer = 0, now = 1000, background = false, startResult = 0, pending = [];
Object.assign(context, {
  ConnectionStatus: { CONNECTED: 2 }, Date: { now: () => now },
  RemoteSessionBackgroundTask: { isAppBackground: () => background },
  setTimeout: fn => { const id = ++nextTimer; timers.set(id, fn); return id; },
  clearTimeout: id => timers.delete(id),
  RustDeskNapi: { startGamepadMonitor: () => { calls.push(['start']); return startResult; },
    stopGamepadMonitor: () => { calls.push(['stop']); }, takeGamepadEvents: () => { const out = pending; pending = []; return out; },
    appendDiagnosticLog: (...args) => logs.push(args) },
  ConnectionService: { sendPhysicalKeyEvent: (key, action) => calls.push(['key', key, action]),
    sendKeyEvent: (key, action, identity) => calls.push(['modifier', key, action, identity]),
    sendMouseEvent: (x, y, action) => calls.push(['mouse', x, y, action]) }
});
vm.runInNewContext(ts.transpile('class Page {' + names.map(method).join('\n') + '} exports.Page = Page;'), context);
const pageObj = Object.assign(new context.exports.Page(), { remotePageVisible: true, fileOnly: false, connectionStatus: 2,
  desktopWindowActive: true, pipSurfaceOwned: false, controlMenu: '', displaySwitchActive: false, showKeyboardPanel: false,
  showGestureHelp: false, showRemoteFileBrowser: false, showCommunicationPanel: false, showToolbarOrderEditor: false,
  showMobileActions: false, disconnectConfirmationVisible: false, showGamepadMappingDialog: false, showKeyboardMappingDialog: false,
  showKeyboardCalibration: false, showKeyboardSettings: false, showMouseSettings: false, showOrientationDialog: false,
  physicalGamepadEnabled: false, virtualGamepadEnabled: false, gameScreenKeys: [], gamepadNativeStarted: false, gamepadRetryAt: 0,
  gamepadTimer: -1, gamepadGeneration: 0, remoteWidth: 1920, remoteHeight: 1080, lastAbsX: 10, lastAbsY: 20,
  relativeMouseEnabled: false, ensurePointerInitialized() {}, updatePointerFromDelta: (x, y) => ({ x, y }),
  peerPreferences: { get: key => values.get(key) || '', set: (key, value) => { values.set(key, value); return true; }, flush: () => true },
  showFileToast: value => toasts.push(value)
});
const fire = () => { const [id, fn] = timers.entries().next().value; timers.delete(id); now += 16; fn(); };
pageObj.loadGamepadPreferences();
assert.equal(pageObj.physicalGamepadEnabled, false); assert.equal(pageObj.virtualGamepadEnabled, false);
assert.equal(timers.size, 0, 'nothing monitors input by default');
pageObj.setGamepadEnabled('physical', true);
pending = [{ kind: 0, device: 1, control: 2301, action: 0, x: 0, y: 0 }];
fire();
assert.deepEqual(calls.slice(-2), [['start'], ['key', 44, 0]]);
background = true; fire();
assert.deepEqual(calls.slice(-2), [['key', 44, 1], ['stop']], 'background releases before stopping monitor');
pending = [{ kind: 0, device: 1, control: 2302, action: 0, x: 0, y: 0 }];
fire();
assert(!calls.some(call => call[0] === 'key' && call[1] === 6 && call[2] === 0), 'no background forwarding');
background = false; pending = []; fire();
pageObj.setGamepadEnabled('virtual', true);
pageObj.gamepadVirtualButton(2301, true);
assert.deepEqual(calls.at(-1), ['key', 44, 0]);
pageObj.controlMenu = 'input'; fire();
assert(calls.some(call => call[0] === 'key' && call[1] === 44 && call[2] === 1), 'opening a menu releases virtual input');
pageObj.controlMenu = ''; fire();
pending = [{ kind: 3, device: 0, control: 0, action: 0, x: 0, y: 0 },
  { kind: 0, device: 1, control: 2302, action: 0, x: 0, y: 0 }];
fire();
assert(!calls.some(call => call[0] === 'key' && call[1] === 6 && call[2] === 0), 'a reset discards the rest of the batch');
pageObj.stopGamepadPolling();
assert.equal(timers.size, 0);
pageObj.physicalGamepadEnabled = false; pageObj.virtualGamepadEnabled = false;
pageObj.gameModeEnabled = true; pageObj.gameScreenEnabled = true; pageObj.gameScreenEditing = false;
pageObj.startGamepadPolling();
pageObj.gameScreenButton(1, 'k:26', true);
assert.deepEqual(calls.at(-1), ['key', 26, 0], 'screen control sends a standard key event');
background = true; fire();
assert.deepEqual(calls.at(-1), ['key', 26, 1], 'screen control releases when app backgrounds');
background = false; pageObj.gameScreenEditing = true;
const beforeEdit = calls.length;
pageObj.gameScreenButton(1, 'k:26', true);
assert.equal(calls.length, beforeEdit, 'layout editing cannot press remote keys');
pageObj.stopGamepadPolling();
assert(page.includes('event.keySource === KeySource.JOYSTICK'));
assert(page.includes('event.source === 4'));
assert(logs.every(entry => !entry.join(' ').includes('password')));
console.log('PASS gamepad session gating, foreground release, virtual input, device resets and joystick deduplication');
