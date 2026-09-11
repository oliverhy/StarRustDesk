const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const entry = read('entry/src/main/ets/entryability/EntryAbility.ets');
const serverDialog = read('entry/src/main/ets/widget/ServerConfigDialog.ets');
const serverConfigModel = read('entry/src/main/ets/model/ServerConfigModel.ets');
const connectionPage = read('entry/src/main/ets/pages/ConnectionPage.ets');

let passed = 0;
const test = (name, fn) => {
  fn();
  passed++;
  console.log('PASS ' + name);
};

test('server save publishes a refresh version', () => {
  assert.match(entry, /AppStorage\.setOrCreate\('serverConfigVersion', 0\)/);
  assert.match(serverDialog, /AppStorage\.get<number>\('serverConfigVersion'\)/);
  assert.match(serverDialog, /AppStorage\.set<number>\('serverConfigVersion', version \+ 1\)/);
  assert.match(connectionPage, /@StorageLink\('serverConfigVersion'\) @Watch\('onServerConfigVersionChanged'\)/);
});

test('server config import and export match the official clipboard format', () => {
  assert.match(serverDialog, /importServerConfigFromClipboard\(\)/);
  assert.match(serverDialog, /exportServerConfigToClipboard\(\)/);
  assert.match(serverDialog, /RustDeskNapi\.getClipboardTextAsync\(\)/);
  assert.match(serverDialog, /RustDeskNapi\.setClipboardTextAsync\(config\.encode\(\)\)/);
  assert.match(serverConfigModel, /util\.Type\.BASIC_URL_SAFE/);
  assert.match(serverConfigModel, /replace\(\/=\+\$\/g, ''\)/);
  assert.match(serverConfigModel, /decodePlainConfig/);
  assert.match(serverConfigModel, /key: this\.serverKey\.trim\(\),\s*host: this\.idServer\.trim\(\),\s*api:/);
});

test('official server config token round-trips all four fields', () => {
  const source = serverConfigModel.replace(/^import .*$/m, '').replace('export class', 'class') +
    '\nglobalThis.Model = ServerConfigModel;';
  class Base64Helper {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64url'); }
    decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64url')); }
  }
  class ArkTextEncoder {
    encodeInto(value) { return Uint8Array.from(Buffer.from(value, 'utf8')); }
  }
  class ArkTextDecoder {
    decodeToString(value) { return Buffer.from(value).toString('utf8'); }
  }
  const context = vm.createContext({
    util: { Base64Helper, Type: { BASIC_URL_SAFE: 1 }, TextEncoder: ArkTextEncoder, TextDecoder: ArkTextDecoder },
    Uint8Array
  });
  vm.runInContext(ts.transpileModule(source,
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
  const config = new context.Model('id.example:21116', 'relay.example:21117',
    'https://api.example', 'test-public-key');
  const officialJson = JSON.stringify({
    key: 'test-public-key', host: 'id.example:21116', api: 'https://api.example', relay: 'relay.example:21117'
  });
  const expected = Buffer.from(officialJson).toString('base64url').split('').reverse().join('');
  assert.equal(config.encode(), expected);
  assert.deepEqual(JSON.parse(JSON.stringify(context.Model.decode(expected))), JSON.parse(JSON.stringify(config)));
  const plain = context.Model.decode('rustdesk-host=id.example:21116,key=test-public-key,api=https://api.example,relay=relay.example:21117,.exe');
  assert.equal(plain.idServer, 'id.example:21116');
  assert.equal(plain.relayServer, 'relay.example:21117');
});

test('home network indicator updates from either custom server field', () => {
  assert.match(connectionPage, /let relayServer: string = RustDeskNapi\.getOption\('relay-server'\)\.trim\(\)/);
  assert.match(connectionPage, /this\.isUsingPublicServer = idServer\.length === 0 && relayServer\.length === 0/);
  assert.match(connectionPage, /this\.customServerHint = idServer\.length > 0 \? idServer : relayServer/);
});

test('online status queries still use the rendezvous server', () => {
  assert.match(connectionPage, /this\.peerStateServer = idServer/);
  assert.match(connectionPage, /queryPeerOnlineStates\(peerIds, this\.peerStateServer\)/);
  assert.match(connectionPage, /result\.server !== this\.peerStateServer/);
});

test('missing connection password opens an input dialog', () => {
  assert.match(connectionPage, /@State showConnectionPasswordDialog: boolean = false/);
  assert.match(connectionPage, /TextInput\(\{ placeholder: '连接密码'/);
  assert.match(connectionPage, /Toggle\(\{ type: ToggleType\.Checkbox, isOn: this\.rememberConnectionPassword \}\)/);
  assert.match(connectionPage, /if \(password\.length <= 0\) \{\s*this\.openConnectionPasswordDialog\(\)/);
});

test('remember password is opt-in and saved before connect', () => {
  assert.match(connectionPage, /this\.rememberConnectionPassword = false/);
  assert.match(connectionPage, /if \(remember\) \{\s*await this\.saveCurrentConnection\(\)\s*\}\s*this\.onConnect\(\)/);
});

console.log(`${passed} server/password regression checks passed`);
