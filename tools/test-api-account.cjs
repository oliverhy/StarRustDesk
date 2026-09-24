const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const options = new Map();
let stored, sequence = 0, pending = [], calls = [], clearWait, loads = 0;
const vault = {
  load: async () => { loads++; return stored; },
  save: async value => { stored = value; },
  clear: async () => { if (clearWait) await clearWait; stored = undefined; }
};
let transportContext = '';
const diagnostics = [];
const native = { getOption: key => options.get(key) || '', setOption: (key, value) => options.set(key, value), getDeviceName: () => 'test device',
  appendDiagnosticLog: (component, message) => diagnostics.push({ component, message }),
  setApiAccountContext: json => { transportContext = json; return 0; } };
class Request {
  constructor(url, method, headers, content, _cookies, _range, configuration) {
    Object.assign(this, { url, method, headers, content, configuration });
  }
}
const rcp = {
  Request,
  createSession: () => ({
    cancel() {}, close() {},
    async fetch(request) {
      calls.push(request);
      assert.equal(request.configuration.transfer.autoRedirect, false);
      assert.equal(request.configuration.tracing.verbose, false);
      const next = pending.shift();
      assert(next, `unexpected ${request.url}`);
      if (next.path) assert(request.url.endsWith(next.path), request.url);
      if (next.check) await next.check(request);
      const raw = next.raw !== undefined ? next.raw : JSON.stringify(next.body);
      const bytes = new TextEncoder().encode(raw);
      request.configuration.tracing.httpEventsHandler.onDataReceive(bytes.buffer);
      return { statusCode: next.status || 200 };
    }
  })
};
function load(file, extra = {}) {
  const js = ts.transpileModule(read(file), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const context = {
    exports: {}, Uint8Array, ArrayBuffer, AppStorage: { get: () => 0, setOrCreate: () => {} },
    require: name => {
      if (name === '@kit.ArkTS') return { url: { URL }, util: { generateRandomUUID: () => `uuid-${++sequence}`, TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } }, TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder().decode(bytes) }) } } };
      if (name === '@kit.RemoteCommunicationKit') return { rcp };
      if (name === './RustDeskNapi') return { RustDeskNapi: native };
      if (name === './ApiAccountStore') return { ApiAccountStore: vault };
      if (name === './CloudSyncService') return { CloudSyncService: { markLocalChanged: () => {} } };
      if (extra[name]) return extra[name];
      throw Error(name);
    }
  };
  vm.runInNewContext(js, context);
  return context.exports;
}
const exported = load('entry/src/main/ets/service/RustDeskApiService.ets');
const Api = exported.RustDeskApiService;
function respond(body, path, status) { pending.push({ body, path, status }); }
async function login(api, provider = 'official') {
  api.configure('https://example.test/api/', provider, false);
  respond({ type: 'access_token', access_token: 'private-token', user: { name: 'alice' } }, '/api/login');
  assert.equal(await api.login('alice', 'private-password', true), true);
}
(async () => {
  assert.equal(Api.normalizeServer('https://example.test/api/', false), 'https://example.test');
  for (const bad of ['http://example.test', 'https://user:pass@example.test', 'https://example.test?q=1', 'file:///tmp/x']) {
    assert.throws(() => Api.normalizeServer(bad, false));
  }
  assert.equal(Api.normalizeServer('http://192.168.1.2:21114/', true), 'http://192.168.1.2:21114');
  const anonymous = new Api();
  options.set('custom-rendezvous-server', '[2001:db8::1]:21116');
  const loadsBeforeSkip = loads;
  await anonymous.prepareConnection();
  assert.equal(loads, loadsBeforeSkip, 'custom IPv6 ID server without API/account skips secure-store restoration');
  options.set('api-session-disabled', '0');
  await anonymous.prepareConnection();
  assert.equal(loads, loadsBeforeSkip + 1, 'remembered account still restores when the API field is empty');
  options.delete('api-session-disabled');
  options.set('api-server', 'https://pro.test');
  await anonymous.prepareConnection();
  assert.equal(loads, loadsBeforeSkip + 2, 'explicit API keeps account preparation enabled');
  options.delete('api-server');
  options.delete('custom-rendezvous-server');
  options.set('relay-server', 'relay.test');
  await anonymous.prepareConnection();
  assert.equal(loads, loadsBeforeSkip + 3, 'relay alone does not identify an anonymous custom ID network');
  options.delete('relay-server');
  const api = new Api(); await login(api);
  assert.equal(diagnostics.length, 0, 'account diagnostics disabled by default');
  options.set('diagnostic-log-enabled', '1');
  options.set('custom-rendezvous-server', '[2001:db8::1]:21116');
  options.delete('api-server');
  const beforeActivePreparation = diagnostics.length;
  await api.prepareConnection();
  assert(diagnostics.slice(beforeActivePreparation).some(event => event.message.includes('prepare_complete')),
    'active account still prepares even when the API field was cleared');
  options.delete('custom-rendezvous-server');
  options.set('api-server', 'https://example.test');
  assert.equal(stored.token, 'private-token');
  assert(!JSON.stringify([...options]).includes('private-token'));
  assert(!JSON.stringify(stored).includes('private-password'));
  respond({ guid: 'personal' }, '/api/ab/personal');
  respond({ total: 0, data: [{ guid: 'team', name: 'Team', rule: 1 }] }, '/api/ab/shared/profiles?current=1&pageSize=100');
  const books = await api.books(); assert.equal(books.length, 2);
  const rows = Array.from({ length: 100 }, (_, i) => ({ id: String(100000000 + i), alias: `PC ${i}` }));
  respond({ total: 101, data: rows }); respond({ total: 101, data: [{ id: '200000000', alias: '中文电脑', password: 'secret', hash: 'secret-hash' }] });
  const peers = await api.peers(books[1]); assert.equal(peers.length, 101);
  assert.equal(peers[100].name, '中文电脑'); assert(!JSON.stringify(peers).includes('secret'));
  assert(calls.at(-1).url.includes('current=2'));
  assert.equal(calls.at(-1).headers.Authorization, 'Bearer private-token');
  const third = new Api(); await login(third, 'thirdParty');
  respond({}, '/api/ab/personal', 404); respond({}, undefined, 404);
  const legacy = await third.books(); assert.equal(legacy[0].legacy, true);
  respond({ data: JSON.stringify({ peers: [{ id: '123456789', alias: '第三方', tags: ['home'] }] }) });
  assert.equal((await third.peers(legacy[0]))[0].name, '第三方');
  respond({}); await assert.rejects(third.peers(legacy[0], true), /明确/);
  respond({ data: JSON.stringify({ peers: [{ id: 'bad id' }] }) });
  await assert.rejects(third.peers(legacy[0], true), /无效|重复/);
  respond({ data: [{ id: 'bad id' }] });
  await assert.rejects(api.peers({ guid: 'personal', legacy: false }, true), /无效|重复/);
  const writableBook = { guid: 'personal', legacy: false, writable: true };
  respond({}, '/api/ab/peer/add/personal');
  await api.writePeer(writableBook, { id: '123', name: 'renamed', tags: ['work'], platform: '' }, true);
  assert.deepEqual(JSON.parse(calls.at(-1).content), { id: '123', alias: 'renamed', tags: ['work'] });
  assert.equal(calls.at(-1).method, 'POST');
  respond({}, '/api/ab/peer/personal'); await api.deletePeer(writableBook, '123');
  assert.equal(calls.at(-1).method, 'DELETE'); assert.deepEqual(JSON.parse(calls.at(-1).content), ['123']);
  await assert.rejects(api.deletePeer({ ...writableBook, writable: false }, '123'), /只读/);
  const legacyData = JSON.stringify({ peers: [{ id: '123', alias: 'old', hash: 'existing-hash' }], tags: ['work'], custom: 7 });
  respond({ data: legacyData }); respond({ data: legacyData }); respond({});
  await third.writePeer(legacy[0], { id: '123', name: 'new', tags: ['work'], platform: '' }, false);
  const savedLegacy = JSON.parse(JSON.parse(calls.at(-1).content).data);
  assert.equal(savedLegacy.custom, 7); assert.equal(savedLegacy.peers[0].hash, 'existing-hash');
  assert.equal(savedLegacy.peers[0].alias, 'new');
  respond({ data: [] }); await assert.rejects(third.deletePeer(legacy[0], '123'), /格式不兼容/);
  const auth = new Api(); auth.configure('https://two.test', 'official', false);
  respond({ type: 'tfa_check', secret: 'challenge-secret', user: { name: 'alice' } });
  assert.equal(await auth.login('alice', 'password', false), false);
  pending.push({ body: { type: 'access_token', access_token: 'otp-token' }, check: request => {
    const body = JSON.parse(request.content); assert.equal(body.tfaCode, '123456');
    assert.equal(body.type, 'email_code'); assert.equal(body.secret, 'challenge-secret'); assert.equal(body.password, undefined);
  } });
  assert.equal(await auth.verify('123456'), true);
  assert.equal(stored, undefined);
  respond({}, undefined, 302); await assert.rejects(auth.books(), /跳转/);
  respond({}, undefined, 401); await assert.rejects(api.books(), /过期/); assert.equal(api.isLoggedIn(), false);
  await login(api);
  pending.push({ raw: 'x'.repeat(2 * 1024 * 1024 + 1) }); await assert.rejects(api.books(), /安全/);
  respond({ total: 2, data: [{ id: '123' }] }); respond({ total: 2, data: [{ id: '123' }] });
  await assert.rejects(api.peers({ guid: 'broken', legacy: false }), /分页/);
  let release; clearWait = new Promise(resolve => { release = resolve; });
  const before = calls.length; const canceled = api.login('alice', 'password', false); api.cancel(); release();
  await assert.rejects(canceled, /取消/); clearWait = undefined; assert.equal(calls.length, before);
  const Import = load('entry/src/main/ets/service/ApiAddressBookImport.ets', { './RustDeskApiService': exported }).ApiAddressBookImport;
  options.set('saved-connections', JSON.stringify([{ id: 'old', remoteId: '123', name: 'keep', credentialAlias: 'old' }]));
  assert.equal(Import.importSelected({ name: 'Team' }, [{ id: '123', name: 'overwrite' }, { id: '456', name: 'new' }]), 1);
  const savedRows = JSON.parse(options.get('saved-connections')); assert.equal(savedRows[0].name, 'keep'); assert.equal(savedRows[0].credentialAlias, 'old');
  options.set('saved-connections', 'invalid');
  assert.throws(() => Import.importSelected({ name: 'Team' }, [{ id: '999' }]));
  assert.equal(options.get('saved-connections'), 'invalid');
  // Account transport is opt-in and only restored for the same API/network.
  const pro = new Api(); pro.configure('https://pro.test', 'official', false);
  await assert.rejects(pro.login('alice', 'password', false, true), /公钥/);
  options.set('custom-rendezvous-server', 'id.pro.test'); options.set('key', 'public-key');
  respond({ type: 'access_token', access_token: 'pro-token' });
  await pro.login('alice', 'password', true, true);
  assert.equal(JSON.parse(transportContext).token, 'pro-token');
  assert.equal(JSON.parse(transportContext).rendezvous, 'id.pro.test');
  assert.equal(stored.boundRendezvous, 'id.pro.test');
  const restored = new Api(); respond({ name: 'alice' });
  assert.equal(await restored.restore(), true);
  options.set('api-server', 'https://another.test');
  assert.equal(await new Api().restore(), false);
  options.set('api-server', 'https://pro.test');
  options.set('custom-rendezvous-server', 'other-id.test');
  const changedNetwork = new Api(); respond({ name: 'alice' });
  assert.equal(await changedNetwork.restore(), true);
  assert.equal(transportContext, ''); assert.match(changedNetwork.warning, /配置已改变/);
  respond({}); await pro.logout();
  assert.equal(transportContext, ''); assert.equal(stored, undefined);
  options.delete('api-server'); options.delete('custom-rendezvous-server'); options.delete('key');
  assert.equal(Api.defaultServer(), 'https://admin.rustdesk.com');
  options.set('custom-rendezvous-server', '[2001:db8::1]:21116');
  assert.equal(Api.defaultServer(), 'http://[2001:db8::1]:21114');
  options.delete('custom-rendezvous-server');
  const publicApi = new Api(); publicApi.configure(Api.defaultServer(), 'official', false);
  respond({ type: 'access_token', access_token: 'official-token', user: { name: 'alice' } });
  await publicApi.login('alice', 'pw', true);
  assert.equal(JSON.parse(transportContext).rendezvous, '@public');
  assert.equal(JSON.parse(transportContext).key, '', 'native layer resolves pinned built-in public key');
  const publicSaved = { ...stored };
  options.set('api-server', Api.PUBLIC_API + '/api/');
  const networkFailure = new Api(); respond({}, undefined, 503);
  await assert.rejects(networkFailure.prepareConnection(), /恢复/);
  assert.equal(stored.token, 'official-token', 'transient API outage must not erase remembered credential');
  assert.equal(transportContext, '');
  respond({ name: 'alice' }); await networkFailure.prepareConnection();
  assert.equal(JSON.parse(transportContext).token, 'official-token');
  stored = { server: 'https://book.test', provider: 'official', token: 'book-token', username: 'alice',
    allowHttp: false, boundRendezvous: '', boundKey: '' };
  options.set('api-server', 'https://book.test'); respond({}, undefined, 503);
  await new Api().prepareConnection();
  assert.equal(stored.token, 'book-token', 'address-book-only outage retains account and does not block anonymous control');
  options.set('api-server', Api.PUBLIC_API);
  options.set('custom-rendezvous-server', 'other.test');
  await networkFailure.prepareConnection(); assert.equal(transportContext, '', 'public token never follows custom network');
  options.delete('custom-rendezvous-server');
  stored = { ...publicSaved, boundRendezvous: '' };
  respond({ name: 'alice' }); await new Api().prepareConnection();
  assert.equal(JSON.parse(transportContext).rendezvous, '@public', 'old official sessions acquire safe public binding');
  const expired = new Api(); respond({}, undefined, 401);
  await assert.rejects(expired.prepareConnection(), /恢复/); assert.equal(stored, undefined);
  const web = new Api(); web.configure(Api.PUBLIC_API, 'official', false);
  respond(['oidc/github', 'common-oidc/[{"name":"company"}]', 'oidc/github']);
  const webOptions = await web.loginOptions(); assert.equal(webOptions.length, 2);
  await assert.rejects(web.startWebLogin('unlisted', false, false), /刷新/);
  respond({ code: 'one-time-secret', url: 'https://identity.example.test/auth' }, '/api/oidc/auth');
  assert.equal(await web.startWebLogin('github', true, false), 'https://identity.example.test/auth');
  const oidcBody = JSON.parse(calls.at(-1).content);
  assert.equal(oidcBody.apiDomain, Api.PUBLIC_API); assert.equal(oidcBody.op, 'github');
  assert.equal(calls.at(-1).headers.Authorization, undefined);
  respond({ error: 'No authed oidc is found' }); assert.equal(await web.pollWebLogin(), false);
  assert(calls.at(-1).url.includes('/api/oidc/auth-query?code=one-time-secret'));
  assert.equal(calls.at(-1).headers.Authorization, undefined);
  respond({ type: 'access_token', access_token: 'web-token', user: { name: 'web-user' } });
  assert.equal(await web.pollWebLogin(), true); assert.equal(stored.token, 'web-token');
  assert.equal(JSON.parse(transportContext).token, 'web-token');
  respond({ code: 's', url: 'http://identity.example.test/' });
  await assert.rejects(web.startWebLogin('github', false, false), /HTTPS/);
  respond({ code: 's', url: 'https://identity.example.test/' });
  await web.startWebLogin('github', false, false);
  let releasePoll; const waitPoll = new Promise(resolve => { releasePoll = resolve; });
  pending.push({ body: { type: 'access_token', access_token: 'late-secret' }, check: async () => waitPoll });
  const late = web.pollWebLogin(); web.cancel(); releasePoll();
  await assert.rejects(late, /取消/); assert.equal(transportContext, ''); assert.equal(stored, undefined);
  respond({ code: 's', url: 'https://identity.example.test/' });
  await web.startWebLogin('github', false, false); web.oidcDeadline = 0;
  await assert.rejects(web.pollWebLogin(), /超时/);
  // Exercise unsampled pending polls, failed HTTP/transport/JSON and hostile raw text.
  respond({ code: 'private-poll-code', url: 'https://identity.example.test/private-url' });
  await web.startWebLogin('github', false, false);
  const beforePolling = diagnostics.length;
  for (let i = 0; i < 16; i++) { respond({}); assert.equal(await web.pollWebLogin(), false); }
  const pollLog = diagnostics.slice(beforePolling).map(v => v.message).join('\n');
  assert.equal((pollLog.match(/request_start/g) || []).length, 2, 'pending polling sampled first and every 15 attempts');
  respond({}, undefined, 503); await assert.rejects(web.pollWebLogin());
  pending.push({ check: () => { throw Object.assign(Error('sensitive-network-secret'), { code: 2300006 }); } }); await assert.rejects(web.pollWebLogin());
  pending.push({ check: () => { throw Object.assign(Error('sensitive-network-secret'), { code: 'sensitive-error-code' }); } }); await assert.rejects(web.pollWebLogin());
  pending.push({ check: () => { throw null; } }); await assert.rejects(web.pollWebLogin(), /网络请求失败/);
  pending.push({ raw: 'sensitive-invalid-json' }); await assert.rejects(web.pollWebLogin());
  respond({ error: 'sensitive-server-refusal' }); await assert.rejects(web.pollWebLogin());
  const log = diagnostics.map(v => v.message).join('\n');
  for (const event of ['restore_start', 'restore_complete', 'restore_failed', 'restore_skip reason=api_changed',
    'prepare_bypass', 'prepare_failed', 'transport_auth_ready mode=public', 'transport_auth_skipped mode=public',
    'credential_invalidated', 'login_challenge', 'web_pending', 'web_complete', 'web_timeout',
    'phase=cancelled', 'phase=response_limit', 'phase=transport', 'phase=response_format', 'phase=server_result', 'http=503', 'error_code=2300006']) {
    assert(log.includes(event), `missing diagnostic ${event}`);
  }
  for (const secret of ['private-token', 'private-password', 'official-token', 'book-token', 'challenge-secret',
    'one-time-secret', 'late-secret', 'web-token', 'web-user', 'alice', '123456', 'identity.example.test',
    'private-poll-code', 'private-url', 'sensitive-network-secret', 'sensitive-error-code', 'sensitive-invalid-json', 'sensitive-server-refusal', 'Bearer ', 'https://']) {
    assert(!log.includes(secret), `sensitive diagnostic content: ${secret}`);
  }
  options.set('diagnostic-log-enabled', '0');
  const disabledCount = diagnostics.length; web.cancel(); await web.restore();
  assert.equal(diagnostics.length, disabledCount, 'disabling diagnostics takes effect immediately');
  console.log('PASS staged diagnostics, request correlation, polling throttle, failure classification, redaction and diagnostic switch');
  console.log('PASS public API defaults/binding, restore failure/retry/expiry, old session migration, SSO polling/cancel/timeout and safe browser URLs');
  const storage = read('entry/src/main/ets/service/ApiAccountStore.ets');
  assert(storage.includes('asset.SyncType.NEVER'));
  assert(storage.includes("getOption('api-session-disabled') === '1'"));
  const assets = new Map(); let removalFails = false;
  const asset = {
    Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, SYNC_TYPE: 5 },
    ReturnType: { ALL: 1 }, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, SyncType: { NEVER: 0 },
    add: async attrs => { assert(attrs.get(2).length <= 1024); assets.set(new TextDecoder().decode(attrs.get(1)), attrs); },
    query: async query => { const found = assets.get(new TextDecoder().decode(query.get(1))); return found ? [found] : []; },
    remove: async query => { if (removalFails) throw Error('storage locked'); assets.delete(new TextDecoder().decode(query.get(1))); }
  };
  const Store = load('entry/src/main/ets/service/ApiAccountStore.ets', { '@kit.AssetStoreKit': { asset } }).ApiAccountStore;
  const longSession = { server: 'https://pro.test', username: '中文账号', provider: 'official', token: 'long-token'.repeat(800), allowHttp: false };
  await Store.save(longSession); assert.equal((await Store.load()).token, longSession.token);
  assert(assets.size > 2);
  removalFails = true; await Store.clear(); assert.equal(await Store.load(), undefined);
  removalFails = false;
  const saving = Store.save(longSession); const clearing = Store.clear();
  await Promise.all([saving, clearing]); assert.equal(await Store.load(), undefined);
  assert.equal(pending.length, 0);
  console.log('PASS official/third-party API login, 2FA, legacy/shared/pagination, HTTPS, redirects, tokens, cancellation and safe import');
})().catch(error => { console.error(error); process.exitCode = 1; });
