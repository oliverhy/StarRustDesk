const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const source = fs.readFileSync(require('node:path').join(__dirname, '../entry/src/main/ets/service/ConnectionService.ets'), 'utf8');
const methods = source.slice(source.indexOf('  private static recoveryTimer:'), source.indexOf('  static async connect('));
let background = false, revision = 1, pending, delay = 0, restarts = 0, prepared = 0;
const context = vm.createContext({
  ConnectionStatus: { CONNECTED: 2 }, RemoteSessionBackgroundTask: { isAppBackground: () => background },
  AccountSession: { getApi: () => ({ sessionRevision: () => revision, prepareConnection: async () => { prepared++; } }) },
  RustDeskNapi: { appendDiagnosticLog() {} },
  setTimeout: (fn, ms) => { pending = fn; delay = ms; return 1; }, clearTimeout: () => { pending = undefined; }
});
vm.runInContext(ts.transpileModule(`class ConnectionService { ${methods} } globalThis.S = ConnectionService;`,
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText, context);
const S = context.S;
Object.assign(S, { sessionAccountRevision: 1, preparationGeneration: 1, retryPeer: '123', insecureRetryUsed: false,
  authNetworkSnapshot: () => '', releaseModifiers() {}, isDirectAddress: () => false,
  restartConnection: () => restarts++ });
(async () => {
  assert.equal(S.recoverInterruptedSession('远端传输中断'), false, 'no retry before authentication');
  S.observeSession(2);
  for (const error of ['Wrong Password', 'Peer connection closed', 'Peer secure handshake failed']) {
    assert.equal(S.recoverInterruptedSession(error), false);
  }
  S.fileOnly = true; assert.equal(S.recoverInterruptedSession('远端传输中断'), false); S.fileOnly = false;
  S.insecureRetryUsed = true; assert.equal(S.recoverInterruptedSession('远端传输中断'), false); S.insecureRetryUsed = false;
  background = true; assert.equal(S.recoverInterruptedSession('远端传输中断'), false); background = false;
  revision = 2; assert.equal(S.recoverInterruptedSession('远端传输中断'), false); revision = 1;
  assert.equal(S.recoverInterruptedSession('远端传输中断'), true); assert.equal(delay, 1000);
  assert.equal(S.recoverInterruptedSession('远端传输中断'), true); assert.equal(S.recoveryAttempts, 1);
  await pending(); assert.equal(restarts, 1); assert.equal(prepared, 1);
  assert.equal(S.recoverInterruptedSession('远端传输中断'), true); assert.equal(delay, 3000);
  revision = 2; await pending(); assert.equal(restarts, 1, 'account changes cancel an already scheduled retry');
  revision = 1; assert.equal(S.recoverInterruptedSession('远端传输中断'), false, 'max two attempts');
  S.recoveryAttempts = 0; S.recoverInterruptedSession('远端传输中断'); S.cancelRecovery();
  assert.equal(pending, undefined); assert.equal(S.isRecoveryPending(), false);
  console.log('PASS bounded transport recovery: authenticated only, account/network scope, foreground, no insecure downgrade, no manual-close retry');
})().catch(e => { console.error(e); process.exitCode = 1; });
