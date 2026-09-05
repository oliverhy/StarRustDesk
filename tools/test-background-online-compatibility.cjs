// Deterministic tests of actual ArkTS bodies; no Hvigor, device, or network needed.
// SDK contract checked locally in @ohos.resourceschedule.backgroundTaskManager.d.ts:
// request API since 21, video submode 10 under mode 6 since 22; start/update may
// throw 9800005 even after isModeSupported; notification task ID is optional.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const serviceSource = read('entry/src/main/ets/service/RemoteSessionBackgroundTask.ets')
  .replace(/^import .*\r?\n/gm, '').replace('export class ', 'class ');
const pageSource = read('entry/src/main/ets/pages/ConnectionPage.ets');
function compile(source) {
  const result = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal((result.diagnostics || []).length, 0, 'transpile diagnostics');
  return result.outputText;
}
const serviceJs = compile(serviceSource + '\nglobalThis.Task = RemoteSessionBackgroundTask;');
const pageStart = pageSource.indexOf('  refreshSavedConnectionOnlineStates(');
const pageEnd = pageSource.indexOf('  applySavedConnection(', pageStart);
assert(pageStart >= 0 && pageEnd > pageStart);
const pageJs = compile(`class Page { ${pageSource.slice(pageStart, pageEnd)} } globalThis.Page = Page;`);
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const error = code => ({ code, message: `test error ${code}` });
function fixture(api = 26) {
  let now = 1000, timerId = 0;
  const timers = new Map(), logs = [], calls = [], probes = [], listeners = new Map();
  const config = { probe: () => true, run: async () => ({ continuousTaskId: 7 }) };
  function kind(request) {
    return Array.isArray(request) ? 'legacy' : request.backgroundTaskSubmodes[0] === 10 ? 'video' : 'normal';
  }
  const bg = {
    BackgroundTaskMode: { MODE_MULTI_DEVICE_CONNECTION: 6, MODE_AV_PLAYBACK_AND_RECORD: 12,
      MODE_AUDIO_PLAYBACK: 2, MODE_DATA_TRANSFER: 1 },
    BackgroundTaskSubmode: { SUBMODE_VIDEO_BROADCAST_NORMAL_NOTIFICATION: 10,
      SUBMODE_NORMAL_NOTIFICATION: 2, SUBMODE_AVSESSION_AUDIO_PLAYBACK: 5, SUBMODE_LIVE_VIEW_NOTIFICATION: 3 },
    ContinuousTaskCancelReason: { USER_CANCEL: 1, SYSTEM_CANCEL: 2, USER_CANCEL_REMOVE_NOTIFICATION: 3,
      SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED: 4, SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_USE_AVSESSION: 5,
      SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING: 6 },
    ContinuousTaskRequest: class { isModeSupported() {
      probes.push(kind(this));
      assert.equal(this.backgroundTaskModes.length, this.backgroundTaskSubmodes.length);
      return config.probe(kind(this), this);
    } },
    on: (event, cb) => listeners.set(event, cb), off: event => listeners.delete(event),
    startBackgroundRunning: async (_, request) => {
      calls.push(['start', kind(request), request]); return config.run('start', kind(request), request);
    },
    updateBackgroundRunning: async (_, request) => {
      calls.push(['update', kind(request), request]); return config.run('update', kind(request), request);
    },
    stopBackgroundRunning: async () => { calls.push(['stop']); return config.run('stop'); }
  };
  const context = vm.createContext({ backgroundTaskManager: bg, deviceInfo: { sdkApiVersion: api },
    ConnectionStatus: { CONNECTING: 1, CONNECTED: 2, WAITING_2FA: 4 },
    RemoteAudioSession: { initialize() {}, setActive() {}, shutdown() {} },
    RustDeskNapi: { appendDiagnosticLog: (_, line) => logs.push(line), setBackgroundVideoMode() {} },
    wantAgent: { getWantAgent: async () => ({}), OperationType: { START_ABILITY: 1 },
      WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } }, Date: { now: () => now },
    setTimeout: (fn, delay) => { timers.set(++timerId, { fn, at: now + delay }); return timerId; },
    clearTimeout: id => timers.delete(id)
  });
  vm.runInContext(serviceJs, context);
  const task = context.Task;
  task.initialize({ abilityInfo: { bundleName: 'test', name: 'TestAbility' } });
  task.sessionDesired = true;
  return { task, config, calls, probes, logs, timers,
    emit: (event, info) => listeners.get(event)(info),
    advance: async ms => {
      now += ms;
      for (const [id, timer] of [...timers]) if (timer.at <= now) {
        timers.delete(id); timer.fn();
      }
      await flush();
    }
  };
}
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
for (const api of [21, 22, 26]) for (const audio of [false, true]) for (const transfer of [false, true]) {
  test(`matching modes and update task ID api=${api} audio=${audio} transfer=${transfer}`, async () => {
    const f = fixture(api);
    Object.assign(f.task, { audioPlaybackActive: audio, dataTransferActive: transfer });
    await f.task.startInternal(f.task.context, 'initial');
    await f.task.updateInternal(f.task.context, 'updated');
    assert.equal(f.task.state, 'active');
    const request = f.calls[1][2];
    assert.equal(request.continuousTaskId, 7);
    assert.equal(request.backgroundTaskModes.length, 1 + Number(audio) + Number(transfer));
  });
}
for (const operation of ['start', 'update']) {
  function prepare() {
    const f = fixture();
    if (operation === 'update') Object.assign(f.task, { state: 'active', taskId: 7, currentSignature: 'old' });
    return f;
  }
  const run = f => f.task[`${operation}Internal`](f.task.context, 'new');
  test(`${operation}: runtime video rejection retries normal before legacy and caches rejection`, async () => {
    const f = prepare();
    f.config.run = async (_, kind) => { if (kind === 'video') throw error(9800005); return { continuousTaskId: 7 }; };
    await run(f);
    assert.deepEqual(f.calls.map(c => c[1]), ['video', 'normal']);
    assert.equal(f.task.videoBroadcastRejected, true);
    assert.equal(f.task.currentSignature, 'new');
    assert(f.logs.some(l => l.includes('actual=modes=6;submodes=2')));
    f.calls.length = 0; await run(f);
    assert.deepEqual(f.calls.map(c => c[1]), ['normal']);
  });
  test(`${operation}: runtime normal rejection permits legacy only after both requests`, async () => {
    const f = prepare();
    f.config.run = async (_, kind) => { if (kind !== 'legacy') throw error(9800005); return { continuousTaskId: 7 }; };
    await run(f);
    assert.deepEqual(f.calls.map(c => c[1]), ['video', 'normal', 'legacy']);
    assert.equal(f.task.currentSignature, 'new');
    assert(f.logs.some(l => l.includes('actual=legacy:multiDeviceConnection')));
  });
  test(`${operation}: final failure has backoff and no success log`, async () => {
    const f = prepare(); f.config.run = async () => { throw error(9800005); };
    await run(f);
    assert.equal(f.task.currentSignature, operation === 'start' ? '' : 'old');
    assert.equal(f.timers.size, 1);
    assert(!f.logs.some(l => /keep_alive_(started|updated) /.test(l)));
  });
  for (const code of [201, 401, 9800004]) test(`${operation}: error ${code} is not bypassed`, async () => {
    const f = prepare(); f.config.run = async () => { throw error(code); };
    await run(f); assert.equal(f.calls.length, 1);
    assert.equal(f.timers.size, 1);
  });
  test(`${operation}: cancellation while request resolves never becomes fake success`, async () => {
    const f = prepare();
    f.config.run = async () => {
      f.emit('continuousTaskCancel', { id: 7, reason: 1 });
      return { continuousTaskId: 7 };
    };
    await run(f);
    assert.equal(f.task.state, 'cancelled'); assert.equal(f.task.taskId, -1);
    assert.equal(f.task.userSuppressed, true); assert.equal(f.timers.size, 0);
    assert(!f.logs.some(l => /keep_alive_(started|updated) /.test(l)));
    f.emit('continuousTaskActive', { id: 7 }); assert.equal(f.task.state, 'cancelled');
  });
  test(`${operation}: suspension callback survives successful request completion`, async () => {
    const f = prepare();
    f.config.run = async () => {
      f.emit('continuousTaskSuspend', { continuousTaskId: 7, suspendState: true, suspendReason: 4 });
      return { continuousTaskId: 7 };
    };
    await run(f); assert.equal(f.task.state, 'suspended');
    assert(f.logs.some(l => l.includes('state=suspended requested=new')));
    f.emit('continuousTaskActive', { id: 99 }); assert.equal(f.task.state, 'suspended');
    f.emit('continuousTaskActive', { id: 7 }); assert.equal(f.task.state, 'active');
  });
}
test('probe false or 9800005 tries normal; unrelated probe error stops', async () => {
  for (const mode of ['false', 'mismatch', 'permission']) {
    const f = fixture();
    f.config.probe = kind => {
      if (kind === 'normal') return true;
      if (mode === 'false') return false;
      throw error(mode === 'mismatch' ? 9800005 : 201);
    };
    await f.task.startInternal(f.task.context, 'new');
    assert.deepEqual(f.calls.map(c => c[1]), mode === 'permission' ? [] : ['normal']);
  }
});
test('both probes unsupported use legacy, older API uses legacy without probing', async () => {
  for (const api of [20, 26]) {
    const f = fixture(api); f.config.probe = () => false;
    await f.task.startInternal(f.task.context, 'new');
    assert.deepEqual(f.calls.map(c => c[1]), ['legacy']);
    if (api === 20) assert.equal(f.probes.length, 0);
  }
});
test('failed start retries at 30 seconds without another external status event', async () => {
  const f = fixture(); f.config.run = async () => { throw error(201); };
  f.task.scheduleReconcile(); await flush(); assert.equal(f.calls.length, 1);
  await f.advance(29999); f.task.scheduleReconcile(); await flush(); assert.equal(f.calls.length, 1);
  f.config.run = async () => ({ continuousTaskId: 7 });
  await f.advance(1); assert.equal(f.calls.length, 2); assert.equal(f.task.state, 'active');
  assert.equal(f.timers.size, 0);
});
test('system cancellation retries after backoff; user cancellation waits for a new session', async () => {
  const f = fixture(); await f.task.startInternal(f.task.context, 'new');
  f.emit('continuousTaskCancel', { id: 7, reason: 2 });
  await flush(); assert.equal(f.calls.length, 1);
  await f.advance(30000); assert.equal(f.calls.length, 2);
  f.emit('continuousTaskCancel', { id: 7, reason: 3 });
  f.task.syncForConnectionStatus(2); await f.advance(60000); assert.equal(f.calls.length, 2);
  f.task.syncForConnectionStatus(0); f.task.syncForConnectionStatus(2); await flush();
  assert.equal(f.calls.length, 3);
});
test('failed update retains suspended state and applied signature', async () => {
  const f = fixture(); Object.assign(f.task, { taskId: 7, state: 'suspended', taskSuspended: true, currentSignature: 'old' });
  f.config.run = async () => { throw error(201); };
  await f.task.updateInternal(f.task.context, 'new');
  assert.equal(f.task.state, 'suspended'); assert.equal(f.task.currentSignature, 'old');
});
test('failed stop retains ownership and retries, never logs stopped prematurely', async () => {
  const f = fixture(); await f.task.startInternal(f.task.context, 'new');
  f.config.run = async () => { throw error(9800004); };
  f.task.stop(); await flush();
  assert.equal(f.task.state, 'active'); assert.equal(f.task.taskId, 7);
  assert(!f.logs.includes('remote_session_keep_alive_stopped'));
  f.config.run = async () => ({}); await f.advance(30000);
  assert.equal(f.task.state, 'stopped'); assert.equal(f.task.taskId, -1);
  f.emit('continuousTaskActive', { id: 7 }); assert.equal(f.task.state, 'stopped');
});
function pageFixture(ids = ['123', '192.168.1.2']) {
  let now = 1000, raw = '', queryReturn = 0;
  const queries = [];
  const context = vm.createContext({ Date: { now: () => now },
    RustDeskNapi: { appendDiagnosticLog() {}, queryPeerOnlineStates: (ids, server) => {
      queries.push([Array.from(ids), server]); return queryReturn;
    }, takePeerOnlineStates: () => { const result = raw; raw = ''; return result; } },
    PEER_STATE_QUERY_TIMEOUT_MS: 12000, PEER_STATE_REFRESH_MS: 30000,
    PEER_STATE_CHECKING: 0, PEER_STATE_UNKNOWN: 3, PEER_STATE_ONLINE: 1, PEER_STATE_OFFLINE: 2,
    RustDeskTheme: { SUCCESS: 'green', WARNING: 'amber' }
  });
  vm.runInContext(pageJs, context);
  const page = Object.assign(new context.Page(), { savedConnections: ids.map(remoteId => ({ remoteId })),
    peerOnlineStates: {}, peerOnlineStatesVersion: 0, peerOnlineQueryInFlight: false, customServerHint: 'server' });
  return { page, queries, setNow: value => { now = value; }, setRaw: value => { raw = value; },
    setQueryReturn: value => { queryReturn = value; } };
}
test('IPv4, port, IPv6, mapped and scoped endpoints are not IDs', () => {
  const f = pageFixture();
  for (const endpoint of ['192.168.1.2', '192.168.1.2:21118', '::1', '2001:db8::1',
    '[2001:db8::1]:21118', '::ffff:192.168.1.2', 'fe80::1%wlan0', '[fe80::1%3]:21118']) {
    assert.equal(f.page.isDirectPeerEndpoint(endpoint), true, endpoint);
  }
  for (const id of ['123456789', 'abc', 'abc-123', 'my_peer']) assert.equal(f.page.isDirectPeerEndpoint(id), false, id);
  for (const invalid of ['[::1', '::1]', '192.168.1.2:0', '1.2.3.999', '1.2.3', '[bad]', 'bad:port']) {
    assert.equal(f.page.isDirectPeerEndpoint(invalid), true, `safely exclude malformed endpoint ${invalid}`);
  }
});
test('mixed saved list only queries deduplicated IDs and preserves saved order', () => {
  const f = pageFixture(['123', '192.168.1.2', '[::1]:21118', '123', 'abc']);
  const original = JSON.stringify(f.page.savedConnections);
  f.page.peerOnlineStates['192.168.1.2'] = 2;
  f.page.refreshSavedConnectionOnlineStates(true);
  assert.deepEqual(f.queries, [[['123', 'abc'], 'server']]);
  assert.equal(f.page.peerOnlineStates['192.168.1.2'], 3);
  assert.equal(JSON.stringify(f.page.savedConnections), original);
});
test('IP-only list makes no hbbs call and has helpful unknown text', () => {
  const f = pageFixture(['192.168.1.2', '[::1]:21118']); f.page.refreshSavedConnectionOnlineStates();
  assert.equal(f.queries.length, 0); assert.equal(f.page.peerOnlineQueryInFlight, false);
  assert.equal(f.page.nextPeerOnlineRefreshAt, 31000);
  assert.match(f.page.peerOnlineStateHint('192.168.1.2'), /直连地址.*未知.*连接/);
  f.page.peerOnlineStates['192.168.1.2'] = 2;
  assert.equal(f.page.peerOnlineStateColor('192.168.1.2'), 'amber');
});
test('UI deadline remains unknown; late response applies only saved IDs with booleans', () => {
  const f = pageFixture(['123', 'abc', 'missing', 'invalid', '192.168.1.2']);
  f.page.refreshSavedConnectionOnlineStates(); f.setNow(13000); f.page.pollPeerOnlineStates();
  assert.equal(f.page.peerOnlineQueryInFlight, false); assert.equal(f.page.peerOnlineStates['123'], 3);
  f.setRaw(JSON.stringify({ server: 'server', error: '', peers: [
    { id: '123', online: true }, { id: 'abc', online: false }, { id: '192.168.1.2', online: false },
    { id: 'removed', online: true }, { id: 'invalid', online: 'false' }] }));
  f.page.pollPeerOnlineStates();
  assert.equal(f.page.peerOnlineStates['123'], 1); assert.equal(f.page.peerOnlineStates.abc, 2);
  for (const id of ['192.168.1.2', 'missing', 'invalid']) assert.equal(f.page.peerOnlineStates[id], 3);
  assert.equal(f.page.peerOnlineStates.removed, undefined);
});
test('server mismatch, worker error, malformed data and rejected query never invent offline', () => {
  const f = pageFixture(); f.page.peerOnlineStates['123'] = 1;
  f.setRaw(JSON.stringify({ server: 'old', error: '', peers: [{ id: '123', online: false }] }));
  f.page.pollPeerOnlineStates(); assert.equal(f.page.peerOnlineStates['123'], 1);
  assert.equal(f.page.nextPeerOnlineRefreshAt, 0);
  for (const raw of ['{bad', JSON.stringify({ server: 'server', error: 'deadline', peers: [] })]) {
    f.setRaw(raw); f.page.pollPeerOnlineStates(); assert.equal(f.page.peerOnlineStates['123'], 3);
  }
  f.setQueryReturn(-3); f.page.refreshSavedConnectionOnlineStates();
  assert.equal(f.page.peerOnlineStates['123'], 3); assert.equal(f.page.peerOnlineQueryInFlight, false);
  assert.match(f.page.peerOnlineStateHint('123'), /未知.*尝试连接/);
});
(async () => {
  for (const [name, fn] of tests) { await fn(); console.log(`PASS ${name}`); }
  console.log(`${tests.length} background/online compatibility checks passed`);
})().catch(err => { console.error(err); process.exitCode = 1; });
