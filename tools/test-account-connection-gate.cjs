const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const source = fs.readFileSync(require('node:path').join(__dirname, '../entry/src/main/ets/service/ConnectionService.ets'), 'utf8');
const methods = source.slice(source.indexOf('  static async connect('), source.indexOf('  static async recordNetworkSnapshot('));
const password = 'sensitive-password-value';
const options = new Map(); let calls = 0, wait;
const diagnostics = [];
const native = { getOption: k => options.get(k) || '', setPerformancePreset: () => {},
  appendDiagnosticLog: (component, message) => diagnostics.push(message),
  connect: () => { calls++; return 0; }, connectWithServer: () => { calls++; return 0; } };
const context = { RustDeskNapi: native, ConnectionStatus: { CONNECTING: 1, FAILED: 3 },
  RemoteSessionBackgroundTask: { syncForConnectionStatus: () => {} },
  AccountSession: { getApi: () => ({ sessionRevision: () => 1, prepareConnection: async () => { if (wait) await wait; } }) } };
vm.createContext(context);
vm.runInContext(ts.transpileModule(`class ConnectionService { ${methods} }
  globalThis.Service = ConnectionService;`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
const S = context.Service;
S.preparationGeneration = 0; S.resetTransientInputState = () => {}; S.recordNetworkSnapshot = () => {};
S.cancelRecovery = () => {};
S.isDirectAddress = peer => peer.includes(':') || /^(\d+\.){3}\d+$/.test(peer);
(async () => {
  let release; wait = new Promise(resolve => { release = resolve; });
  const first = S.connect('123', password); assert.equal(calls, 0); release(); await first; assert.equal(calls, 1);
  wait = new Promise(resolve => { release = resolve; });
  const canceled = S.connect('123', password); S.cancelPendingConnection(); release();
  await assert.rejects(canceled, /取消/); assert.equal(calls, 1);
  wait = new Promise(resolve => { release = resolve; });
  const changed = S.connect('123', password); options.set('custom-rendezvous-server', 'new.test'); release();
  await assert.rejects(changed, /配置/); assert.equal(calls, 1);
  wait = Promise.reject(Error('auth unavailable')); wait.catch(() => {});
  await assert.rejects(S.connect('123', password), /auth/); assert.equal(calls, 1);
  await S.connect('192.0.2.1', password); assert.equal(calls, 2, 'direct IP does not require account network');
  const log = diagnostics.join('\n');
  for (const event of ['gate_start', 'gate_ready', 'gate_cancelled', 'gate_failed', 'direct_ip=true', 'network_changed=true']) assert(log.includes(event));
  for (const secret of [password, 'new.test', '192.0.2.1', 'auth unavailable']) assert(!log.includes(secret));
  console.log('PASS account restoration gates connection, cancellation/server changes never launch stale sessions, direct IP remains independent');
})().catch(e => { console.error(e); process.exitCode = 1; });
