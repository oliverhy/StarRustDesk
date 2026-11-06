'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const read = p => fs.readFileSync(path.join(__dirname, '..', p), 'utf8').replace(/\r\n/g, '\n');
const context = { exports: {} };
vm.runInNewContext(ts.transpile(read('entry/src/main/ets/model/GameTransportHealth.ets')), context);
const Health = context.exports.GameTransportHealth;
let health = new Health();
assert.equal(health.observe(1, 1500, 1000), false);
for (let t = 2000; t < 20000; t += 1000) assert.equal(health.observe(1, 1500, t), false, 'stale sample');
health.reset();
for (let n = 1; n <= 3; n++) assert.equal(health.observe(n, 1500, n * 4000), false);
assert.equal(health.observe(4, 1500, 16000), true, 'four fresh samples spanning 12 seconds');
health.reset();
for (let n = 1; n <= 8; n++) assert.equal(health.observe(n, 1500, n * 500), false, 'short spike');
health.reset();
assert.equal(health.observe(1, 1500, 1000), false);
assert.equal(health.observe(2, 200, 5000), false, 'good sample clears the window');
assert.equal(health.observe(3, 1500, 9000), false);
assert.equal(health.observe(4, 1500, 27000), false, 'long gap clears the window');
assert.equal(health.observe(1, 1500, 28000), false, 'new session sequence clears the window');
health.reset();
assert.equal(health.observe(1, 1500, 1000), false);
assert.equal(health.observe(2, 1500, 5000), false);
assert.equal(health.observe(4, 1500, 9000), false, 'missing samples could contain a good report');
assert.equal(health.observe(5, 1500, 13000), false);
assert.equal(health.observe(6, 1500, 17000), false);
assert.equal(health.observe(7, 1500, 21000), true);

function slice(source, from, to) {
  const a = source.indexOf(from), b = source.indexOf(to, a);
  assert(a >= 0 && b > a, from);
  return source.slice(a, b);
}
const serviceSource = read('entry/src/main/ets/service/ConnectionService.ets');
const pageSource = read('entry/src/main/ets/pages/RemotePage.ets');
const pageMethod = slice(pageSource, '  updateGameTransportHealth(', '  updateGameModePolicy(');
let pageCalls = [], pageClock = 20000;
const pageContext = { Date: { now: () => pageClock }, ConnectionStatus: { CONNECTED: 2, CONNECTING: 1 },
  RemoteSessionBackgroundTask: { isAppBackground: () => false },
  ConnectionService: { getConnectionTransport: () => 2, retryUnstableGameUdp: (_transfer, _security, release) => {
    pageCalls.push('checked'); release(); pageCalls.push('reconnect'); return true;
  } }, RustDeskNapi: { appendDiagnosticLog() {} } };
vm.runInNewContext(ts.transpile(`class Page { ${pageMethod} } globalThis.Page = Page;`), pageContext);
const page = Object.assign(new pageContext.Page(), { gameModeEnabled: true, remotePageVisible: true,
  isLeavingAfterDisconnect: false, disconnectConfirmationVisible: false, connectionStatus: 2,
  desktopWindowActive: true, pipSurfaceOwned: false, transferActive: false, uploadStaging: false,
  fileOperationBusy: false, recordingActive: false, communicationCallActive: false, privacyModeState: 0,
  gameTransportHealth: { observe: () => true, reset() {} },
  gamepadMapper: { releaseAll: () => pageCalls.push('gamepad-release') },
  rememberDisplayForReconnect: () => {},
  releaseHeldMouseButtons: () => pageCalls.push('mouse-release'),
  releaseRemoteNavigationKeys: () => pageCalls.push('navigation-release'), showFileToast() {} });
page.updateGameTransportHealth({ security: 1, delaySampleSeq: 4, delayMs: 1500 });
assert.deepEqual(pageCalls, ['checked', 'gamepad-release', 'mouse-release', 'navigation-release', 'reconnect']);
assert.equal(page.connectionStatus, 1, 'block additional inputs while the new session is connecting');
for (const gate of ['isLeavingAfterDisconnect', 'disconnectConfirmationVisible', 'recordingActive',
  'communicationCallActive', 'uploadStaging']) {
  pageCalls = []; page.connectionStatus = 2; page[gate] = true;
  page.updateGameTransportHealth({ security: 1, delaySampleSeq: 5, delayMs: 1500 });
  assert.equal(pageCalls.length, 0, `${gate} prevents proactive reconnect`);
  page[gate] = false;
}
const methods = slice(serviceSource, '  static observeSession(', '  private static cancelRecovery(') +
  slice(serviceSource, '  static recoverInterruptedSession(', '  static async retryCurrentSession(') +
  slice(serviceSource, '  static disconnect():', '  static canRetryWithoutEncryption()');
let status = 3, route = 0, transport = 2, background = false, currentNetwork = 'network', account = 1;
let attempts = [], logs = [], timer;
const napi = {
  getConnectionStatus: () => status, getConnectionRoute: () => route, getConnectionTransport: () => transport,
  getPrivacyModeState: () => 0,
  appendDiagnosticLog: (component, value) => logs.push([component, value]),
  disconnect: () => {},
  connectWithServer: (...args) => { attempts.push(args); return 0; }
};
const sandbox = {
  RustDeskNapi: napi, ConnectionStatus: { CONNECTING: 1, CONNECTED: 2, FAILED: 3, WAITING_2FA: 4 },
  RemoteSessionBackgroundTask: { stop() {}, syncForConnectionStatus() {}, isAppBackground: () => background },
  AccountSession: { getApi: () => ({ sessionRevision: () => account, prepareConnection: async () => {} }) },
  setTimeout: fn => { timer = fn; return 1; }, clearTimeout: () => {}, Date: { now: () => 20000 }
};
vm.runInNewContext(ts.transpile(`class Subject { ${methods.replaceAll('ConnectionService', 'Subject')} } globalThis.Subject = Subject;`), sandbox);
const Service = sandbox.Subject;
function reset() {
  Object.assign(Service, { retryPeer: 'test-peer', retryPassword: 'test-only-secret', retryRendezvous: 'test-server',
    retryRelay: '', retrySecurity: { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false }, retryOsPassword: '',
    sessionSettings: 'network', sessionAccountRevision: 1, sessionAuthenticated: false, fileOnly: false,
    insecureRetryUsed: false, relayRetryUsed: false, gameTransportEnabled: true, gameTcpFallbackUsed: false,
    gameTransportAttemptPolicy: 1, lastEstablishedTransport: 2, recoveryStopped: false, recoveryPending: false,
    recoveryAwaitingConnected: false, manualRetryPending: false, recoveryStartedAt: -1, recoveryAttempts: 0,
    recoveryEpoch: 0, recoveryTimer: -1, preparationGeneration: 1,
    authNetworkSnapshot: () => currentNetwork, releaseModifiers() {}, recordNetworkSnapshot() {},
    resetTransientInputState() {}, cancelRecovery() {} });
  status = 3; route = 0; transport = 2; background = false; currentNetwork = 'network'; account = 1; attempts = []; logs = [];
}
reset();
assert.match(Service.retryRecoverableConnectionFailure('UDP 直连失败，准备重新协商 TCP'), /TCP 或中继/);
assert.equal(attempts.length, 1);
assert.equal(attempts[0][4], false, 'TCP must be tried before forced relay');
assert.equal(attempts[0][5], false, 'retry cannot approve an insecure connection');
assert.equal(attempts[0][10], 2, 'retry must request a fresh TCP-only negotiation');
assert.equal(Service.retryRecoverableConnectionFailure('UDP 直连失败，准备重新协商 TCP'), '', 'bounded retry');
for (const override of [
  { gameTransportEnabled: false }, { insecureRetryUsed: true }, { fileOnly: true },
  { sessionSettings: 'other' }, { sessionAccountRevision: 2 }, { retryPeer: '192.0.2.5:21118' }
]) {
  reset(); Object.assign(Service, override);
  assert.equal(Service.retryRecoverableConnectionFailure('UDP 直连失败，准备重新协商 TCP'), '');
  assert.equal(attempts.length, 0);
}
reset(); background = true;
assert.equal(Service.retryRecoverableConnectionFailure('UDP 直连失败，准备重新协商 TCP'), '');
reset(); status = 2; route = 1; Service.sessionAuthenticated = true;
let released = 0;
assert.equal(Service.retryUnstableGameUdp(false, 1, () => { released++; }), true);
assert.equal(released, 1, 'held game input is released before reconnect');
assert.equal(attempts[0][5], false);
assert.equal(attempts[0][10], 2);
assert.equal(Service.retryUnstableGameUdp(false, 1, () => { released++; }), false, 'only one live fallback per session');
assert.equal(released, 1);
for (const [overrides, transfer, security] of [
  [{}, true, 1], [{}, false, 2], [{ insecureRetryUsed: true }, false, 1],
  [{ retrySecurity: { lockAfterDisconnect: true, privacyMode: false } }, false, 1],
  [{ retrySecurity: { lockAfterDisconnect: false, privacyMode: true } }, false, 1],
  [{ sessionSettings: 'other' }, false, 1], [{ sessionAccountRevision: 2 }, false, 1]
]) {
  reset(); status = 2; route = 1; Service.sessionAuthenticated = true; Object.assign(Service, overrides);
  assert.equal(Service.retryUnstableGameUdp(transfer, security, () => { released++; }), false, 'protected session must not be interrupted');
  assert.equal(attempts.length, 0);
}
reset(); status = 2; route = 1; Service.sessionAuthenticated = true; transport = 1;
assert.equal(Service.retryUnstableGameUdp(false, 1, () => { released++; }), false, 'TCP is not treated as UDP');
reset(); status = 2; route = 1; Service.sessionAuthenticated = true; background = true;
assert.equal(Service.retryUnstableGameUdp(false, 1, () => { released++; }), false, 'background session must not be interrupted');
reset(); status = 2; route = 1; Service.sessionAuthenticated = true;
assert.equal(Service.retryUnstableGameUdp(false, 1, () => { throw new Error('release failed'); }), false);
assert.equal(attempts.length, 0, 'never reconnect when input release fails');
reset(); status = 2; route = 1; Service.sessionAuthenticated = true;
let manualRelease = 0;
assert.equal(Service.reconnectForGameMode(() => { manualRelease++; }), true);
assert.equal(manualRelease, 1);
assert.equal(attempts[0][5], false, 'manual reconnect never grants insecure fallback');
assert.equal(attempts[0][10], 1, 'manual reconnect negotiates UDP preference');
for (const override of [{ insecureRetryUsed: true }, { retryPeer: '192.0.2.2:21118' },
  { retrySecurity: { lockAfterDisconnect: true, privacyMode: false } },
  { retrySecurity: { lockAfterDisconnect: false, privacyMode: true } }, { sessionAccountRevision: 2 }]) {
  reset(); status = 2; route = 1; Service.sessionAuthenticated = true; Object.assign(Service, override);
  assert.equal(Service.reconnectForGameMode(() => { manualRelease++; }), false);
  assert.equal(attempts.length, 0);
}

let dialog, manualReconnect = 0, releasedInput = 0;
const dialogMethod = slice(pageSource, '  showGameReconnectChoice():', '  updateGameTransportHealth(');
const dialogContext = { translate: text => text, ConnectionStatus: { CONNECTING: 1 },
  ConnectionService: { reconnectForGameMode: callback => { manualReconnect++; callback(); return true; } },
  RustDeskNapi: { appendDiagnosticLog() {} } };
vm.runInNewContext(ts.transpile(`class Page { ${dialogMethod} } globalThis.Page = Page;`), dialogContext);
const dialogPage = Object.assign(new dialogContext.Page(), { uiLanguage: 'zh-Hans', peerPreferences: {},
  remotePageVisible: true, gameModeEnabled: true, isLeavingAfterDisconnect: false, transferActive: false,
  uploadStaging: false, fileOperationBusy: false, recordingActive: false, communicationCallActive: false,
  pipSurfaceOwned: false, privacyModeState: 0, getUIContext: () => ({ showAlertDialog: value => { dialog = value; } }),
  gamepadMapper: { releaseAll: () => { releasedInput++; } }, releaseHeldMouseButtons() { releasedInput++; },
  releaseRemoteNavigationKeys() { releasedInput++; }, rememberDisplayForReconnect() {},
  resetRemoteViewportForSession() {}, showFileToast() {} });
dialogPage.showGameReconnectChoice(); dialog.primaryButton.action();
assert.equal(manualReconnect, 0, 'next connection never disconnects the current session');
dialogPage.showGameReconnectChoice(); dialog.secondaryButton.action();
assert.equal(manualReconnect, 1); assert.equal(releasedInput, 3);
dialogPage.transferActive = true; dialogPage.showGameReconnectChoice(); dialog.secondaryButton.action();
assert.equal(manualReconnect, 1, 'ongoing transfer prevents reconnect');

async function interrupted() {
  reset(); status = 3; Service.sessionAuthenticated = true; Service.lastEstablishedTransport = 2;
  assert.equal(Service.recoverInterruptedSession('远端传输中断'), true);
  assert.equal(Service.gameTransportAttemptPolicy, 2);
  await timer();
  assert.equal(attempts.length, 1);
  assert.equal(attempts[0][5], false);
  assert.equal(attempts[0][10], 2);
  assert(logs.every(row => !row.join(' ').includes('test-only-secret')));
  reset(); status = 3; Service.sessionAuthenticated = true; Service.lastEstablishedTransport = 1;
  assert.equal(Service.recoverInterruptedSession('UDP 直连失败，准备重新协商 TCP'), true);
  assert.equal(Service.gameTransportAttemptPolicy, 2, 'UDP failure during an authenticated recovery must also fall back');
  await timer();
  assert.equal(attempts[0][10], 2);
}
async function initialPreference() {
  const methods = slice(serviceSource, '  static async connect(', '  private static authNetworkSnapshot(')
    .replaceAll('ConnectionService', 'Initial');
  let preference = '1', modes = [], captured = [], disposed = 0;
  const initialContext = {
    RustDeskNapi: {
      appendDiagnosticLog() {}, getOption: name => name === 'custom-rendezvous-server' ? 'test-server' : '',
      setGameMode: value => modes.push(value), setHighPerformance() {}, setPerformancePreset() {},
      connectWithServer: (...args) => { captured.push(args); return 0; },
      connect: (...args) => { captured.push(args); return 0; }
    },
    RemotePeerPreferences: class { constructor(server, peer) { assert.equal(server, 'test-server'); assert.equal(peer, 'test-peer'); }
      get() { return preference; } dispose() { disposed++; } },
    AccountSession: { getApi: () => ({ sessionRevision: () => 1, prepareConnection: async () => {} }) },
    RemoteSessionBackgroundTask: { syncForConnectionStatus() {} },
    ConnectionStatus: { CONNECTING: 1, FAILED: 3 }, Date: { now: () => 1000 }
  };
  vm.runInNewContext(ts.transpile(`class Initial { ${methods} } globalThis.Initial = Initial;`), initialContext);
  const Initial = initialContext.Initial;
  Object.assign(Initial, { preparationGeneration: 0, authNetworkSnapshot: () => 'network', cancelRecovery() {},
    resetTransientInputState() {}, recordNetworkSnapshot() {}, isDirectAddress: () => false });
  const secure = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false };
  await Initial.connect('test-peer', 'test-password', 'smooth', false, secure);
  assert.equal(captured[0][10], 1, 'saved per-peer game mode applies before the first handshake');
  assert.equal(modes[0], true);
  preference = '0';
  await Initial.connect('test-peer', 'test-password', 'smooth', false, secure);
  assert.equal(captured[1][10], 0, 'another peer preference cannot inherit game transport');
  preference = '1';
  await Initial.connect('test-peer', 'test-password', 'smooth', true, secure);
  assert.equal(captured[2][10], 0, 'file-only session keeps existing transport behavior');
  assert.equal(disposed, 3);
}
interrupted().then(initialPreference).then(() => console.log('PASS game transport: per-peer initial policy, fresh-sample hysteresis, TCP renegotiation, protected sessions and bounded secure recovery'))
  .catch(error => { console.error(error); process.exitCode = 1; });
