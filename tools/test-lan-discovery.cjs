'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const dgram = require('node:dgram');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const textDecoder = { create: (_encoding, options) => ({
  decodeToString: bytes => new TextDecoder('utf-8', { fatal: options?.fatal }).decode(bytes)
}) };
function load(file, imports = {}, extra = {}) {
  const code = ts.transpileModule(read(file), { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText;
  const ctx = { exports: {}, Uint8Array, ArrayBuffer, Number, Promise, setTimeout, clearTimeout,
    require: name => {
      if (name === '@kit.ArkTS') return { util: { TextDecoder: textDecoder } };
      if (imports[name]) return imports[name];
      throw new Error(`Unexpected import: ${name}`);
    }, ...extra };
  vm.runInNewContext(code, ctx, { filename: file });
  return ctx.exports;
}
const { LanDiscoveryProtocol: wire } = load('entry/src/main/ets/model/LanDiscoveryProtocol.ets');
const arr = value => Uint8Array.from(value).buffer;
const variable = value => {
  const out = [];
  while (value >= 128) { out.push((value & 127) | 128); value >>>= 7; }
  out.push(value);
  return out;
};
const field = (number, value) => {
  const bytes = [...new TextEncoder().encode(value)];
  return [...variable(number * 8 + 2), ...variable(bytes.length), ...bytes];
};
// Independently constructed from the checked-in official rendezvous.proto.
const pong = (id = 'Remote_123', host = '测试电脑') => {
  const peer = [...field(1, 'pong'), ...field(2, 'ignored-mac'), ...field(3, id),
    ...field(4, 'ignored-user'), ...field(5, host), ...field(6, 'Windows')];
  return arr([...variable(22 * 8 + 2), ...variable(peer.length), ...peer]);
};
async function socketRoundTrip() {
  const server = dgram.createSocket('udp4');
  const client = dgram.createSocket('udp4');
  try {
    await new Promise(resolve => server.bind(0, '127.0.0.1', resolve));
    await new Promise(resolve => client.bind(0, '127.0.0.1', resolve));
    const reply = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('UDP loopback timed out')), 2000);
      server.once('message', (data, remote) => {
        try { assert.deepEqual([...data], [178, 1, 6, 10, 4, 112, 105, 110, 103]); }
        catch (error) { clearTimeout(timer); reject(error); return; }
        server.send(Buffer.from(pong()), remote.port, remote.address);
      });
      client.once('message', data => { clearTimeout(timer); resolve(data); });
    });
    client.send(Buffer.from(wire.ping()), server.address().port, '127.0.0.1');
    const bytes = await reply;
    const peer = wire.parse(Uint8Array.from(bytes).buffer, '192.168.50.8');
    assert.equal(peer.id, 'Remote_123');
    assert.equal(peer.hostname, '测试电脑');
  } finally { client.close(); server.close(); }
}
async function main() {
  assert.deepEqual([...new Uint8Array(wire.ping())], [178, 1, 6, 10, 4, 112, 105, 110, 103]);
  const peer = wire.parse(pong(), '192.168.50.8');
  assert.equal(peer.id, 'Remote_123');
  assert.equal(peer.hostname, '测试电脑');
  assert.equal(peer.platform, 'Windows');
  assert.equal(wire.parse(pong('Custom.ID'), '192.168.50.8').id, 'Custom.ID');
  assert(!('mac' in peer) && !('username' in peer));
  for (const invalid of [pong('10.0.0.1'), pong('123.456'), pong('server:21118'), pong('foo@bar'), pong(''),
    arr([]), arr([0xb2, 1, 255, 127]), arr([0xb2, 1, 2, 10]), arr([0xb2, 1, 6, 10, 4, 112, 105, 110, 103]),
    new Uint8Array(2049).buffer]) assert.equal(wire.parse(invalid, '192.168.50.8'), undefined);
  assert.equal(wire.parse(pong('abc', 'na\u202eme\n'), '192.168.50.8').hostname, 'name');
  let seed = 0x60dafe;
  for (let i = 0; i < 3000; i++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    const random = new Uint8Array(seed % 300);
    for (let j = 0; j < random.length; j++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      random[j] = seed >>> 24;
    }
    assert.doesNotThrow(() => wire.parse(random.buffer, '192.168.50.8'));
  }
  assert.equal(wire.isLocalPeer('192.168.50.7', 24, '192.168.50.8'), true);
  for (const bad of ['192.168.51.8', '192.168.50.7', '192.168.50.255', '127.0.0.1', '224.0.0.1', '1.2.3.999']) {
    assert.equal(wire.isLocalPeer('192.168.50.7', 24, bad), false);
  }
  assert.equal(wire.isLocalPeer('192.168.50.7', 0, '192.168.50.8'), false);
  await socketRoundTrip();

  let activeIp = '192.168.50.7', background = false, socketCount = 0, failBind = false, lastMessage;
  const logs = [], packets = [], updates = [];
  const network = { netId: 100, async bindSocket() {} };
  const connection = {
    NetBearType: { BEARER_WIFI: 1, BEARER_CELLULAR: 0, BEARER_ETHERNET: 3, BEARER_VPN: 4 },
    async getAllNets() { return [network]; },
    async getNetCapabilities() { return { bearerTypes: [1] }; },
    async getConnectionProperties() { return { linkAddresses: [{ address: { address: activeIp }, prefixLength: 24 }] }; }
  };
  const socket = { constructUDPSocketInstance() {
    socketCount++;
    let onMessage;
    return {
      on(_name, callback) { onMessage = callback; lastMessage = callback; },
      async bind(address) { assert.equal(address.address, activeIp); if (failBind) throw Error('no bind'); },
      async setExtraOptions(options) { assert.equal(options.broadcast, true); },
      async send(options) {
        packets.push(options);
        assert.equal(options.address.port, 21119);
        assert.equal(options.address.address, '255.255.255.255');
        for (const [address, message] of [['192.168.50.8', pong()], ['192.168.50.8', pong()],
          ['192.168.51.8', pong()], ['192.168.50.9', pong('9.9.9.9')]]) {
          onMessage({ message, remoteInfo: { family: 'IPv4', port: 21119, address } });
        }
      },
      async close() {}
    };
  } };
  const imports = {
    '@kit.NetworkKit': { connection, socket },
    '../model/LanDiscoveryProtocol': { LanDiscoveryProtocol: wire },
    './RemoteSessionBackgroundTask': { RemoteSessionBackgroundTask: { isAppBackground: () => background } },
    './RustDeskNapi': { RustDeskNapi: { appendDiagnosticLog: (_tag, msg) => logs.push(msg) } }
  };
  const { LanDiscoveryService } = load('entry/src/main/ets/service/LanDiscoveryService.ets', imports,
    { setTimeout: (fn, delay) => setTimeout(fn, Math.max(1, delay / 30)) });
  const service = new LanDiscoveryService();
  const result = await service.scan(peers => updates.push(peers));
  assert.equal(result.status, 'complete');
  assert.equal(result.peers.length, 1);
  assert.equal(updates.length, 1);
  assert.equal(packets.length, 1);
  assert.equal(await service.isCurrentNetwork(), true);
  activeIp = '192.168.51.7';
  assert.equal(await service.isCurrentNetwork(), false);
  activeIp = '192.168.50.7';
  background = true;
  assert.equal(await service.isCurrentNetwork(), false);
  background = false;
  service.cancel();
  assert.equal(await service.isCurrentNetwork(), false);
  let cancelledUpdates = 0;
  const cancelled = service.scan(() => { cancelledUpdates++; });
  await new Promise(resolve => setTimeout(resolve, 5));
  service.cancel();
  const countAtCancel = cancelledUpdates;
  lastMessage({ message: pong('AnotherPeer'), remoteInfo: { family: 'IPv4', port: 21119, address: '192.168.50.10' } });
  assert.equal((await cancelled).status, 'cancelled');
  assert.equal(cancelledUpdates, countAtCancel, 'late datagrams cannot revive a cancelled scan');
  const changed = service.scan(() => {});
  await new Promise(resolve => setTimeout(resolve, 5));
  activeIp = '192.168.51.7';
  const changedResult = await changed;
  assert.equal(changedResult.status, 'network_changed');
  assert.equal(changedResult.peers.length, 0, 'old network results must not survive a network change');
  activeIp = '192.168.50.7';
  failBind = true;
  assert.equal((await service.scan(() => {})).status, 'error');
  failBind = false;
  connection.getNetCapabilities = async () => ({ bearerTypes: [0] });
  const before = socketCount;
  assert.equal((await service.scan(() => {})).status, 'no_network');
  assert.equal(socketCount, before, 'must not broadcast over mobile data');
  connection.getNetCapabilities = async () => ({ bearerTypes: [1, 4] });
  assert.equal((await service.scan(() => {})).status, 'no_network');
  assert(!logs.some(line => /192\.168|Remote_123|ignored|测试电脑/i.test(line)), 'logs must not contain device identity');

  const page = read('entry/src/main/ets/pages/ConnectionPage.ets');
  const begin = page.indexOf('async connectLanPeer(');
  const end = page.indexOf('@Builder', begin);
  const handler = page.slice(begin, end);
  assert.match(handler, /SavedConnectionEditing\.empty\(\)/);
  assert.match(handler, /savedId: ''/);
  assert(!/requestForSavedConnection|connectionPasswordForUse|loadOsPassword/.test(handler));
  assert.match(page, /request\.lanDiscovery === true && !await this\.lanDiscovery\.isCurrentNetwork\(\)/);
  assert.match(page, /this\.pendingConnectionRequest\?\.draft\.remoteId/);
  assert.match(page, /if \(!this\.homeTabActive\) this\.stopLanDiscovery\(\)/);
  assert.match(page, /pendingConnectionRequest\?\.lanDiscovery === true\) this\.closeConnectionPasswordDialog\(\)/);
  assert.match(read('entry/src/main/ets/pages/HomePage.ets'), /onPageHide\(\): void \{ this\.homePageVisible = false/);
  assert.match(read('entry/src/main/rust/src/lib.rs'), /INSECURE_DIRECT_ENDPOINT/);
  console.log('PASS RustDesk discovery wire and real UDP loopback');
  console.log('PASS malformed/spoofed responses, network scope, cancellation and privacy');
  console.log('PASS discovery connection does not reuse stored credentials or bypass direct-IP consent');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
