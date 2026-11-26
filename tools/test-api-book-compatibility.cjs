const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const options = new Map(), cache = new Map();
let sequence = 0, localWrites = 0;
const native = {
  getOption: key => options.get(key) || '',
  setOption: (key, value) => { localWrites++; options.set(key, value); },
  appendDiagnosticLog() {},
  setApiAccountContext() {}
};
function load(name) {
  if (cache.has(name)) return cache.get(name);
  const context = { exports: {}, AppStorage: { get: () => 0, setOrCreate() {} }, require: id => {
    if (id === './RustDeskNapi') return { RustDeskNapi: native };
    if (id === './CloudSyncService') return { CloudSyncService: { markLocalChanged() {} } };
    if (id === './ApiAccountStore') return { ApiAccountStore: {} };
    if (id === '@kit.RemoteCommunicationKit') return { rcp: {} };
    if (id === '@kit.ArkTS') return { url: { URL }, util: {
      generateRandomUUID: () => `test-${++sequence}`,
      TextEncoder: { create: () => ({ encodeInto: value => new TextEncoder().encode(value) }) }
    } };
    if (id.startsWith('./')) return load(id.slice(2));
    throw Error(id);
  } };
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/service', `${name}.ets`), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText, context);
  cache.set(name, context.exports);
  return context.exports;
}
const { RustDeskApiService: Api } = load('RustDeskApiService');
const { ApiBookSync: Sync } = load('ApiBookSync');
const book = { guid: 'test-book', name: 'Test', writable: true, legacy: false };
const peer = (id, name = id) => ({ id, name, platform: '', tags: [] });
const ids = [ '123456789', 'device-name_1', 'device.example', '192.168.1.2', '192.168.1.2:21118',
  '2001:db8::1', '[2001:db8::1]', '[2001:db8::1]:21118', '::1', '::', '::ffff:192.0.2.1',
  '[::ffff:192.0.2.1]:65535', '1:2:3:4:5:6:7:8' ];
for (const id of ids) {
  assert(Api.validPeerId(id), `valid endpoint: ${id}`);
  assert(Sync.syncableId(id), `syncable endpoint: ${id}`);
}
for (const id of ['', 'a'.repeat(65), 'bad id', '256.0.0.1', '192.168.1', '192.168.01.1',
  '[2001:db8::1', '2001:db8::1]', '[192.168.1.1]', '[gggg::1]:21118', '[::1]:0', '[::1]:65536',
  '192.168.1.1:0', '192.168.1.1:65536', '1:::2', '1::2::3', '1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9',
  '1:2:3:4:5:6:7::8', '::ffff:999.1.1.1', '[fe80::1%eth0]', 'https://example.test', 'id/path', 'id?x=y']) {
  assert(!Api.validPeerId(id), `reject invalid endpoint: ${id}`);
}
assert.deepEqual(Array.from(Api.parsePeers(ids.map(id => ({ id }))), p => p.id), ids);

function queued(replies) {
  const api = new Api(); let calls = 0;
  api.request = async route => {
    assert(route.includes(`current=${++calls}&pageSize=100`));
    assert(replies.length, 'unexpected extra pagination request');
    return replies.shift();
  };
  return { api, remaining: () => replies.length, calls: () => calls };
}
async function fetch(replies, strict, count) {
  const q = queued(replies);
  assert.equal((await q.api.peers(book, strict)).length, count);
  assert.equal(q.remaining(), 0);
}
(async () => {
  const partial = () => [ { total: 2, data: [{ id: '123' }] }, { total: 2, data: [{ id: '123' }] } ];
  await fetch(partial(), false, 1); // Browsing remains usable with a non-standard server.
  await assert.rejects(queued(partial()).api.peers(book, true), /分页/);
  await assert.rejects(queued([{ total: 2, data: [{ id: '123' }] }, { total: 2, data: [] }]).api.peers(book, true), /分页/);
  // A server can impose a smaller page size than requested. Do not stop at page * 100.
  await fetch([{ total: 2, data: [{ id: '123' }] }, { total: 2, data: [{ id: '456' }] }], true, 2);
  const whole = Array.from({ length: 150 }, (_, i) => ({ id: String(1000 + i) }));
  await fetch([{ total: 150, data: whole }], true, 150); // Server returns all rows at once.
  await fetch([{ data: whole }, { data: [] }], true, 150); // Legacy response without total.
  await fetch([{ data: [{ id: '123' }] }, { data: [{ id: '456' }] }, { data: [] }], true, 2);
  await assert.rejects(queued([{ data: [{ id: '123' }] }, { data: [{ id: '123' }] }]).api.peers(book, true), /分页/);
  await assert.rejects(queued([{ data: whole }, { data: whole }]).api.peers(book, true), /分页/);
  await fetch([{ total: 0, data: [] }], true, 0);
  await fetch([{ data: [] }], true, 0);
  await assert.rejects(queued([{ total: 0, data: [{ id: '123' }] }]).api.peers(book, true), /分页/);
  await assert.rejects(queued([{ total: 2, data: [{ id: '123' }] }, { total: 1, data: [{ id: '456' }] }]).api.peers(book, true), /分页/);
  for (const total of ['2', -1, 1.5, null]) {
    await assert.rejects(queued([{ total, data: [] }]).api.peers(book, true), /分页/);
  }
  await assert.rejects(queued([{ total: 2, data: [{ id: '123' }, { id: '123' }] }]).api.peers(book, true), /无效|重复/);
  await assert.rejects(queued(Array.from({ length: 50 }, (_, i) => ({ total: 51, data: [{ id: `p${i}` }] }))).api.peers(book, true), /分页限制/);

  // Reproduce the data-loss bug through production preview/apply, not only peers().
  const api = new Api(); api.server = 'https://test.invalid'; api.username = 'test';
  const key = Sync.key(api, book);
  options.set('saved-connections', JSON.stringify([{ remoteId: '123', name: '123' }, { remoteId: '456', name: '456' }]));
  options.set(key, JSON.stringify([peer('123'), peer('456')]));
  const saved = options.get('saved-connections'), baseline = options.get(key);
  api.request = async () => ({ total: 2, data: [{ id: '123' }] });
  const before = localWrites;
  await assert.rejects(Sync.preview(api, book), /分页/);
  assert.equal(localWrites, before, 'partial preview must not write or delete local data');
  api.request = async () => ({ total: 2, data: [{ id: '123' }, { id: '456' }] });
  const plan = await Sync.preview(api, book);
  api.request = async () => ({ total: 2, data: [{ id: '123' }] });
  await assert.rejects(Sync.apply(api, book, plan, false), /分页/);
  assert.equal(localWrites, before, 'partial apply preflight must not write or delete local data');
  assert.equal(options.get('saved-connections'), saved);
  assert.equal(options.get(key), baseline);

  // Exercise both directions with the real service, importer and synchronizer.
  options.clear();
  const ipv4 = '192.168.1.2:21118', ipv6 = '[2001:db8::1]:21118';
  let remote = [{ id: ipv6, alias: 'IPv6 remote', tags: ['home'] }];
  const payloads = [];
  api.request = async (route, method, body) => {
    if (route.startsWith('/api/ab/peers?')) return { total: remote.length, data: remote.map(p => ({ ...p })) };
    payloads.push(body);
    if (route.startsWith('/api/ab/peer/add/') || route.startsWith('/api/ab/peer/update/')) {
      const row = JSON.parse(body); remote = remote.filter(p => p.id !== row.id).concat(row); return {};
    }
    if (method === 'DELETE') { const ids = JSON.parse(body); remote = remote.filter(p => !ids.includes(p.id)); return {}; }
    throw Error(`unexpected route ${route}`);
  };
  options.set('saved-connections', JSON.stringify([{ remoteId: ipv4, name: 'IPv4 local', credentialAlias: 'private-alias', groupId: 'keep' }]));
  let next = await Sync.preview(api, book);
  assert.deepEqual(Array.from(next.changes, c => c.kind).sort(), ['download', 'upload']);
  await Sync.apply(api, book, next, false);
  assert.equal((await Sync.preview(api, book)).changes.length, 0, 'IP sync converges');
  assert.equal(JSON.parse(options.get('saved-connections')).length, 2);
  assert(!payloads.join('').includes('private-alias'), 'credentials stay local');
  remote.find(p => p.id === ipv4).alias = 'renamed remotely';
  await Sync.apply(api, book, await Sync.preview(api, book), false);
  const row = JSON.parse(options.get('saved-connections')).find(p => p.remoteId === ipv4);
  assert.equal(row.name, 'renamed remotely'); assert.equal(row.credentialAlias, 'private-alias'); assert.equal(row.groupId, 'keep');
  let local = JSON.parse(options.get('saved-connections'));
  local.find(p => p.remoteId === ipv6).name = 'renamed locally';
  options.set('saved-connections', JSON.stringify(local));
  await Sync.apply(api, book, await Sync.preview(api, book), true);
  assert.equal(remote.find(p => p.id === ipv6).alias, 'renamed locally');
  remote = remote.filter(p => p.id !== ipv4);
  await Sync.apply(api, book, await Sync.preview(api, book), false);
  assert.equal(JSON.parse(options.get('saved-connections')).length, 1);
  options.set('saved-connections', '[]');
  await Sync.apply(api, book, await Sync.preview(api, book), true);
  assert.equal(remote.length, 0); assert.equal((await Sync.preview(api, book)).changes.length, 0);
  console.log('PASS address-book compatibility: IPv4/IPv6 validation, safe pagination, no partial-list deletion, bidirectional IP convergence and credential preservation');

  // Match the official personal/legacy and shared response shapes. Never
  // reuse another book's credential even when both contain the same peer ID.
  const account = new Api();
  options.set('api-server', 'https://api.example.test');
  options.set('custom-rendezvous-server', 'id.example.test');
  options.set('key', 'fixture-public-key');
  account.configure('https://api.example.test', 'official', false);
  account.token = 'fixture-token';
  account.bindTransport(true);
  const own = { guid: 'personal', legacy: false }, legacy = { guid: '', legacy: true };
  const shared = { guid: 'shared', legacy: false };
  const ownHash = Buffer.alloc(32, 23).toString('base64');
  let personal = { guid: 'personal' };
  let privatePeer = { id: '123', hash: ownHash, password: 'wrong field', note: 'server memo' };
  let sharedPeer = { id: '123', password: ' shared-设备 ', hash: ownHash };
  let profile = { guid: 'shared', rule: 1, info: { password: 'shared-default' } };
  account.request = async (route, method, body) => {
    assert.equal(body, undefined, 'lookup is read-only, even when the API uses POST');
    if (route === '/api/ab/personal') return personal;
    if (route.startsWith('/api/ab/shared/profiles?')) return { data: [profile], total: 1 };
    if (route === '/api/ab') return { data: JSON.stringify({ peers: [privatePeer] }) };
    if (route.endsWith('&ab=personal')) return { total: 1, data: [privatePeer] };
    if (route.endsWith('&ab=shared')) return { total: 1, data: [sharedPeer] };
    throw Error('unexpected address-book API lookup');
  };
  const credential = await account.addressBookCredential(own, '123');
  assert.equal(credential.kind, 1); assert.equal(credential.value, ownHash);
  assert.equal((await account.addressBookCredential(shared, '123')).value, ' shared-设备 ');
  const browse = (await account.browsePeers(own))[0];
  assert.equal(browse.note, 'server memo');
  assert(!('hash' in browse) && !('password' in browse));
  assert(!('note' in (await account.peers(own, true))[0]));
  sharedPeer = { id: '123', hash: ownHash };
  assert.equal((await account.addressBookCredential(shared, '123')).value, 'shared-default');
  sharedPeer = { id: '123', password: 'x'.repeat(512) };
  await assert.rejects(account.addressBookCredential(shared, '123'), /没有可用/);
  sharedPeer = { id: '123', same_server: false };
  await assert.rejects(account.addressBookCredential(shared, '123'), /不属于/);
  privatePeer = { id: '123', hash: 'invalid', password: 'wrong field', note: 'server memo' };
  await assert.rejects(account.addressBookCredential(own, '123'), /没有可用/);
  privatePeer.hash = ownHash;
  personal = {};
  assert.equal((await account.addressBookCredential(legacy, '123')).value, ownHash);
  await assert.rejects(account.addressBookCredential(own, '123'), /权限或网络/);
  await assert.rejects(account.addressBookCredential(legacy, '192.0.2.5'), /设备 ID/);
  options.set('key', 'changed-fixture-key');
  await assert.rejects(account.addressBookCredential(legacy, '123'), /已关联/);
  options.set('key', 'fixture-public-key');
  account.server = 'http://api.example.test';
  await assert.rejects(account.addressBookCredential(legacy, '123'), /HTTPS/);
  console.log('PASS scoped personal/legacy/shared credential lookup and priority; private data never enters browsing/import/sync models');
})().catch(error => { console.error(error); process.exitCode = 1; });
