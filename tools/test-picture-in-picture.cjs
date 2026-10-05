'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8').replace(/\r\n/g, '\n');
const compile = source => ts.transpileModule(source.replace(/^import .*\n/gm, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const source = read('entry/src/main/ets/service/RemotePictureInPicture.ets');
const background = read('entry/src/main/ets/service/RemoteSessionBackgroundTask.ets');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const flush = async () => { for (let i = 0; i < 35; i++) await Promise.resolve(); };
const gate = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const states = { ABOUT_TO_START: 1, STARTED: 2, ABOUT_TO_STOP: 3, STOPPED: 4, ABOUT_TO_RESTORE: 5, ERROR: 6 };
function fixture(options = {}) {
  const calls = [], phases = [], errors = [], logs = [], video = [], controllers = [];
  let closed = 0, config;
  const api = { PiPState: states, PiPTemplateType: { VIDEO_LIVE: 3 }, PiPControlType: { VIDEO_PLAY_PAUSE: 0 },
    isPiPEnabled: () => options.supported !== false,
    async create(value) {
      calls.push('create'); config = value;
      if (options.createGate) await options.createGate.promise;
      if (options.createError) throw { code: 801 };
      const listeners = new Map();
      const controller = {
        setAutoStartEnabled: value => calls.push(['auto', value]),
        getPiPSettingSwitch: async () => options.setting !== false,
        setPiPControlEnabled: (...args) => calls.push(['control', ...args]),
        on: (name, cb) => listeners.set(name, cb), off: name => listeners.delete(name),
        emit: state => listeners.get('stateChange')?.(state, 'system'),
        async startPiP() {
          calls.push('start');
          controller.emit(states.ABOUT_TO_START);
          if (options.startGate) await options.startGate.promise;
          if (options.startError) throw { code: 1300013 };
          controller.emit(states.STARTED);
        },
        async stopPiP() {
          calls.push('stop');
          if (options.stopError) throw { code: 1300011 };
          controller.emit(states.ABOUT_TO_STOP);
          if (options.stopGate) await options.stopGate.promise;
          controller.emit(states.STOPPED);
        },
        updateContentSize: (...args) => calls.push(['size', ...args])
      };
      controllers.push(controller);
      return controller;
    }
  };
  const context = vm.createContext({ exports: {}, pictureInPicture: api,
    deviceInfo: { sdkApiVersion: options.api || 22 },
    RemoteSessionBackgroundTask: { setPictureInPictureActive: value => video.push(value) },
    RustDeskNapi: { appendDiagnosticLog: (...args) => logs.push(args), refreshVideo: () => calls.push('refresh') }
  });
  vm.runInContext(compile(source), context);
  const pip = new context.exports.RemotePictureInPicture(phase => phases.push(phase), () => closed++,
    (...args) => errors.push(args));
  return { pip, calls, phases, errors, logs, video, controllers, config: () => config, closed: () => closed,
    start: () => pip.start({ ability: 'test' }, { surface: 'existing' }, 1920, 1080), options };
}
let count = 0;
const test = async (name, fn) => { await fn(); console.log('PASS ' + name); count++; };
(async () => {
  await test('system PiP uses existing surface; no automatic entry and no playback pause', async () => {
    const f = fixture(); await f.start();
    assert.equal(f.config().componentController.surface, 'existing');
    assert.equal(f.config().templateType, 3);
    assert.equal(f.config().contentWidth, 1920);
    assert.equal(f.phases.at(-1), 'active');
    assert(f.calls.some(x => Array.isArray(x) && x[0] === 'auto' && x[1] === false));
    assert(f.calls.some(x => Array.isArray(x) && x[0] === 'control' && x[2] === false));
    assert.equal(f.video.at(-1), true);
    await f.pip.stop();
    assert.equal(f.phases.at(-1), 'idle'); assert.equal(f.closed(), 1); assert.equal(f.video.at(-1), false);
  });
  await test('unsupported and disabled system settings are explicit, not fake success', async () => {
    const f = fixture({ supported: false }); await f.start();
    assert.deepEqual(f.errors, [['unsupported', 801]]); assert.equal(f.calls.length, 0);
    const d = fixture({ setting: false }); await d.start();
    assert.deepEqual(d.errors, [['disabled', 0]]); assert(!d.calls.includes('start'));
    assert.equal(d.video.at(-1), false);
  });
  await test('repeated presses create one controller and old APIs do not call settings', async () => {
    const f = fixture({ api: 12, setting: false });
    await Promise.all([f.start(), f.start(), f.start()]);
    assert.equal(f.calls.filter(x => x === 'create').length, 1);
    assert.equal(f.phases.at(-1), 'active'); await f.pip.stop();
  });
  await test('create failure restores background-video policy and is retryable', async () => {
    const f = fixture({ createError: true }); await f.start();
    assert.equal(f.phases.at(-1), 'idle'); assert.equal(f.video.at(-1), false);
    f.options.createError = false; await f.start(); assert.equal(f.phases.at(-1), 'active');
  });
  await test('dispose during create never starts a stale remote screen', async () => {
    const g = gate(), f = fixture({ createGate: g }); const start = f.start(); await flush();
    const stop = f.pip.dispose(); g.resolve(); await Promise.all([start, stop]);
    assert(!f.calls.includes('start')); assert.equal(f.video.at(-1), false);
    await f.start(); assert.equal(f.calls.filter(x => x === 'create').length, 1);
  });
  await test('dispose during native start stops the late window before any next operation', async () => {
    const g = gate(), f = fixture({ startGate: g }); const start = f.start(); await flush();
    const stop = f.pip.dispose(); g.resolve(); await Promise.all([start, stop]);
    assert.deepEqual(f.calls.filter(x => x === 'start' || x === 'stop'), ['start', 'stop']);
    assert.equal(f.video.at(-1), false); assert(!f.phases.includes('active'));
  });
  await test('system restore/close clears state once; closing is not disconnecting', async () => {
    const f = fixture(); await f.start(); const c = f.controllers[0];
    c.emit(states.ABOUT_TO_RESTORE); assert.equal(f.video.at(-1), true);
    c.emit(states.STOPPED); c.emit(states.STOPPED);
    assert.equal(f.closed(), 1); assert.equal(f.video.at(-1), false);
    assert.doesNotMatch(source, /ConnectionService|disconnect\(/);
    await f.start(); assert.equal(f.controllers.length, 2);
    c.emit(states.STOPPED); assert.equal(f.video.at(-1), true);
  });
  await test('native start/stop errors keep truthful state and permit stop retry', async () => {
    const f = fixture({ startError: true }); await f.start();
    assert.equal(f.phases.at(-1), 'idle'); assert.equal(f.errors[0][0], 'start');
    const s = fixture({ stopError: true }); await s.start(); await s.pip.stop();
    assert.equal(s.phases.at(-1), 'active'); assert.equal(s.video.at(-1), true);
    s.options.stopError = false; await s.pip.stop();
    assert.equal(s.phases.at(-1), 'idle'); assert.equal(s.video.at(-1), false);
  });
  await test('size updates use decoded resolution and reject invalid/unchanged dimensions', async () => {
    const f = fixture(); await f.start();
    f.calls.length = 0;
    for (const size of [[1920, 1080], [0, 100], [NaN, 100], [1080, 1920], [1080, 1920]]) {
      f.pip.updateContentSize(...size);
    }
    assert.deepEqual(f.calls.filter(x => Array.isArray(x) && x[0] === 'size'), [['size', 1080, 1920]]);
  });
  await test('resolution changes during asynchronous start are not lost', async () => {
    const g = gate(), f = fixture({ startGate: g }); const start = f.start(); await flush();
    f.pip.updateContentSize(2560, 1440); g.resolve(); await start;
    assert.deepEqual(f.calls.filter(x => Array.isArray(x) && x[0] === 'size'), [['size', 2560, 1440]]);
  });
  await test('PiP is the only exception to background video suppression; stop resets it', async () => {
    const calls = [], context = vm.createContext({ exports: {}, deviceInfo: {}, backgroundTaskManager: {},
      RustDeskNapi: { setBackgroundVideoMode: value => calls.push(value), appendDiagnosticLog() {} },
      RemoteAudioSession: { setActive() {} }, clearTimeout() {} });
    vm.runInContext(compile(background), context);
    const task = context.exports.RemoteSessionBackgroundTask;
    task.scheduleReconcile = () => {}; task.sessionDesired = true;
    task.setAppBackground(true); assert.equal(calls.at(-1), true);
    task.setPictureInPictureActive(true); assert.equal(calls.at(-1), false);
    assert.equal(task.isAppBackground(), true, 'PiP must not pretend the app is foreground for input/reconnect');
    task.setPictureInPictureActive(false); assert.equal(calls.at(-1), true);
    task.setPictureInPictureActive(true); task.setAppBackground(false); task.setPictureInPictureActive(false);
    assert.equal(calls.at(-1), false);
    task.stop(); assert.equal(task.pictureInPictureActive, false);
  });
  await test('page guards surface ownership, both toolbars, late timers and disconnect cleanup', () => {
    for (const name of ['bindSurfaceIfReady', 'scheduleSurfaceRebindIfSizeChanged', 'rebindSurfaceAfterLayoutChange']) {
      assert.match(page, new RegExp(`${name}\\([^\\n]*\\): void \\{\\n    if \\(this.pipSurfaceOwned\\) return;`));
    }
    const menuModel = read('entry/src/main/ets/model/RemoteControlMenu.ets');
    assert(menuModel.includes("'fullscreen', 'pip', 'orientation'"));
    assert(page.includes('this.buildControlToolbarItem(item, true)'));
    assert(page.includes("'fullscreen', 'pip', 'orientation'"));
    assert(page.includes('this.pictureInPicture?.updateContentSize(frame.width, frame.height)'));
    assert(page.includes('this.pictureInPicture.dispose().finally('));
    assert(page.includes('this.pictureInPicture?.dispose()'));
    assert(page.includes('this.remotePageVisible || this.isLeavingAfterDisconnect || this.pipSurfaceOwned'));
    assert(page.includes(".hitTestBehavior(HitTestMode.Default).zIndex(40)"));
    const viewport = page.slice(page.indexOf('  buildRemoteViewport()'), page.indexOf('  buildErrorView()'));
    assert(!viewport.includes('buildPictureInPicturePlaceholder'), 'return button must not be transformed with the remote desktop');
    for (const name of ['syncHardwareKeyState', 'toggleRemoteKeyboard', 'requestRemoteInputFocus']) {
      assert.match(page, new RegExp(`${name}\\(\\): void \\{\\n    if \\(this.pipSurfaceOwned\\) return;`));
    }
  });
  console.log(`PASS ${count} picture-in-picture scenarios (SDK mocked; device rendering not tested)`);
})().catch(error => { console.error(error); process.exitCode = 1; });
