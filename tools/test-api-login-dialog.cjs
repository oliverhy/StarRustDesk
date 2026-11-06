'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const source = read('entry/src/main/ets/widget/ApiAccountDialog.ets');
const start = source.indexOf('  async pollWebLogin(');
const end = source.indexOf('  async initialize()', start);
assert(start >= 0 && end > start, 'real dialog polling method is available');
const snippet = `class DialogHarness { ${source.slice(start, end)} } globalThis.DialogHarness = DialogHarness;`;
const compiled = ts.transpileModule(snippet, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
const policyStart = source.indexOf('  isOfficialPublic():');
const policyEnd = source.indexOf('  resetLoginOptions():', policyStart);
const initStart = source.indexOf('  async initialize():');
const initEnd = source.indexOf('  showError(', initStart);
assert(policyStart >= 0 && policyEnd > policyStart && initStart >= 0 && initEnd > initStart);
const policyCode = `class PolicyHarness { ${source.slice(policyStart, policyEnd)} ${source.slice(initStart, initEnd)} } globalThis.PolicyHarness = PolicyHarness;`;
const compiledPolicy = ts.transpileModule(policyCode, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
class ApiFailure extends Error {
  constructor(message, kind, retryable) { super(message); this.kind = kind; this.retryable = retryable; }
}
const timers = [];
let customIdServer = '';
const context = { ApiFailure, setTimeout: (fn, delay) => { timers.push({ fn, delay }); return timers.length; },
  RustDeskApiService: { PUBLIC_API: 'https://admin.rustdesk.com' },
  RustDeskNapi: { getOption: () => customIdServer } };
vm.runInNewContext(compiled, context);
vm.runInNewContext(compiledPolicy, context);
const Harness = context.DialogHarness;
const PolicyHarness = context.PolicyHarness;
function makeDialog(results) {
  const dialog = new Harness();
  Object.assign(dialog, { alive: true, webAttempt: 7, webRetryCount: 0, webWaiting: true, busy: true,
    loggedIn: false, message: '', webTimer: -1, challenge: '', stopped: false, errors: [], events: [], refreshed: 0 });
  dialog.api = {
    challenge: '', username: 'test-user',
    async pollWebLogin() { const item = results.shift(); if (item instanceof Error) throw item; return item; },
    recordWebRetry(error, attempt, delay) { dialog.events.push(['retry', error.kind, attempt, delay]); },
    recordWebRecovery(attempt) { dialog.events.push(['recovered', attempt]); }
  };
  dialog.stopWebLogin = () => { dialog.stopped = true; dialog.webAttempt++; dialog.webWaiting = false; };
  dialog.showError = error => dialog.errors.push(error);
  dialog.refreshBooks = async () => { dialog.refreshed++; };
  return dialog;
}
const flush = () => new Promise(resolve => setImmediate(resolve));
async function runTimer(expectedDelay) {
  const timer = timers.shift(); assert(timer, 'expected scheduled poll'); assert.equal(timer.delay, expectedDelay);
  timer.fn(); await flush();
}
(async () => {
  const network = new ApiFailure('private-network-detail', 'network', true);
  const busy = new ApiFailure('private-server-detail', 'server_busy', true);
  const dialog = makeDialog([network, busy, false, true]);
  await dialog.pollWebLogin(7);
  assert.equal(dialog.webRetryCount, 1); assert(!dialog.stopped); assert(!dialog.message.includes('private'));
  await runTimer(1000); assert.equal(dialog.webRetryCount, 2);
  await runTimer(2000); assert.equal(dialog.webRetryCount, 0); assert(!dialog.stopped);
  await runTimer(1000); assert(dialog.loggedIn); assert.equal(dialog.refreshed, 1); assert(!dialog.webWaiting);
  assert.deepEqual(dialog.events, [['retry', 'network', 1, 1000], ['retry', 'server_busy', 2, 2000], ['recovered', 2]]);
  assert.equal(timers.length, 0);

  const fatal = makeDialog([new ApiFailure('permission denied', 'permission_denied', false)]);
  await fatal.pollWebLogin(7); assert(fatal.stopped); assert.equal(fatal.errors.length, 1); assert.equal(timers.length, 0);

  let fail;
  const cancelling = makeDialog([]);
  cancelling.api.pollWebLogin = () => new Promise((_resolve, reject) => { fail = reject; });
  const pending = cancelling.pollWebLogin(7); cancelling.stopWebLogin(); fail(network); await pending;
  assert.equal(timers.length, 0, 'a cancelled in-flight attempt must not restart polling');
  assert.equal(cancelling.errors.length, 0);

  const capped = makeDialog(Array.from({ length: 5 }, () => network));
  for (const delay of [1000, 2000, 4000, 8000, 8000]) {
    await capped.pollWebLogin(7); const timer = timers.shift(); assert.equal(timer.delay, delay);
  }
  const providerButton = read('entry/src/main/ets/widget/ApiOAuthProviderButton.ets');
  assert(providerButton.includes('Button({ type: ButtonType.Normal })'), 'provider controls retain button semantics');
  assert(providerButton.includes('.accessibilityText('), 'provider names are available to assistive technology');
  for (const name of ['google', 'github', 'microsoft', 'gitlab']) {
    assert(providerButton.includes(`app.media.auth_${name}`), `${name} uses a local icon`);
  }
  assert(!providerButton.includes('Image(this.providerName)'), 'untrusted provider content is never loaded as an image');
  assert(source.includes('if (this.alive && !this.loggedIn && !this.message && this.isOfficialPublic()) await this.loadLoginOptions()'));
  assert(source.includes("this.loginOptionsState === 'loading'"));
  assert(source.includes('this.thirdPartyLoginSection()'));
  const policy = new PolicyHarness();
  Object.assign(policy, { server: 'https://admin.rustdesk.com', provider: 'official', loginMode: 'public', alive: true, loggedIn: false,
    busy: false, message: '', optionsLoads: 0, api: { isLoggedIn: () => false, restore: async () => false } });
  policy.loadLoginOptions = async () => { policy.optionsLoads++; };
  policy.showError = error => { policy.message = error.message; };
  assert(policy.isOfficialPublic()); assert(!policy.shouldOfferCustomAuthorization());
  customIdServer = 'synthetic-custom-server'; assert(!policy.shouldOfferCustomAuthorization(), 'public login must not bind tokens to the custom network');
  customIdServer = ''; await policy.initialize(); assert.equal(policy.optionsLoads, 1, 'public provider options load automatically');
  policy.server = 'https://synthetic-custom.test'; policy.loginMode = 'pro'; await policy.initialize();
  assert.equal(policy.optionsLoads, 1, 'custom API is not contacted until explicitly requested');
  policy.api.cancel = () => {};
  policy.resetLoginOptions = () => {};
  policy.proServerDraft = policy.server; policy.thirdPartyServerDraft = 'https://third.test';
  policy.password = 'do-not-carry'; policy.username = 'private-user'; policy.authorizeConnections = true;
  await policy.selectLoginMode('public');
  assert.equal(policy.server, 'https://admin.rustdesk.com'); assert.equal(policy.provider, 'official');
  assert.equal(policy.password, ''); assert.equal(policy.username, ''); assert.equal(policy.authorizeConnections, false);
  assert.equal(policy.optionsLoads, 2);
  await policy.selectLoginMode('thirdParty'); assert.equal(policy.server, 'https://third.test'); assert.equal(policy.provider, 'thirdParty');
  policy.server = 'https://edited-third.test';
  await policy.selectLoginMode('pro'); assert.equal(policy.server, 'https://synthetic-custom.test');
  await policy.selectLoginMode('thirdParty'); assert.equal(policy.server, 'https://edited-third.test');
  policy.busy = true; await policy.selectLoginMode('public'); assert.equal(policy.loginMode, 'thirdParty');
  for (const label of ['官方公共服务器', '自建 Server Pro', '第三方 rustdesk-api']) assert(source.includes(`label: '${label}'`));
  console.log('PASS OIDC retry, recovery, fatal errors, cancellation, bounded delay and provider UI');
})().catch(error => { console.error(error); process.exitCode = 1; });
