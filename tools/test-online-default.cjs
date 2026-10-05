'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const source = read('entry/src/main/ets/service/PeerOnlinePreference.ets');
const compiled = ts.transpileModule(source.replace(/^import .*\r?\n/gm, '') +
  '\nglobalThis.Preference = PeerOnlinePreference;', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics || []).length, 0, 'production service transpiles');
const option = 'peer-online-query-enabled';
const marker = 'peer-online-default-on-migrated';
function fixture(initial = {}) {
  const options = new Map(Object.entries(initial));
  const storage = new Map(), writes = [], logs = [];
  const failures = { read: false, write: false, log: false };
  const context = vm.createContext({ exports: {},
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    RustDeskNapi: {
      getOption: key => {
        if (failures.read) throw Error('unavailable');
        return options.get(key) || '';
      },
      setOption: (key, value) => {
        if (failures.write) return -1;
        writes.push([key, value]); options.set(key, value); return 0;
      },
      appendDiagnosticLog: (scope, message) => {
        if (failures.log) throw Error('unavailable');
        logs.push([scope, message]);
      }
      // No network methods: migration is strictly local preference handling.
    }
  });
  const load = () => {
    // A new VM models a cold start rather than relying on static in-memory state.
    const next = vm.createContext({ exports: {}, AppStorage: context.AppStorage, RustDeskNapi: context.RustDeskNapi });
    vm.runInContext(compiled.outputText, next);
    return next.Preference;
  };
  return { options, storage, writes, logs, failures, load };
}
let count = 0;
function test(name, fn) { fn(); count++; console.log('PASS ' + name); }
test('fresh installation enables and persists the default before UI load', () => {
  const f = fixture();
  f.load().initialize();
  assert.equal(f.options.get(option), '1');
  assert.equal(f.options.get(marker), '1');
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
  assert.deepEqual(f.writes.map(w => w[0]), [option, marker]);
});
for (const previous of ['', '0', '1']) {
  test(`old default ${JSON.stringify(previous)} is enabled on first upgrade only`, () => {
    const f = fixture({ [option]: previous, 'custom-rendezvous-server': '[2001:db8::1]:21116' });
    f.load().initialize();
    assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
    assert.equal(f.options.get('custom-rendezvous-server'), '[2001:db8::1]:21116');
    assert.equal(f.writes.length, 2);
    f.load().initialize();
    assert.equal(f.writes.length, 2, 'restarts do not repeat migration or config writes');
  });
}
test('manual disabling persists through relaunch and later app upgrades', () => {
  const f = fixture();
  const p = f.load();
  p.initialize();
  assert.equal(p.setEnabled(false), true);
  const writes = f.writes.length;
  for (let i = 0; i < 3; i++) {
    f.storage.clear();
    f.load().initialize();
    assert.equal(f.storage.get('peerOnlineQueryEnabled'), false);
    assert.equal(f.options.get(option), '0');
    assert.equal(f.writes.length, writes);
  }
  assert(!source.includes('RELEASE_NOTES_BUILD'), 'migration is not reset on each app version');
});
test('manual enabling publishes immediately and persists', () => {
  const f = fixture({ [option]: '0', [marker]: '1' });
  const p = f.load();
  p.initialize();
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), false);
  assert.equal(p.setEnabled(true), true);
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
  f.load().initialize();
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
});
test('explicit choice marks migration even if made before initialization', () => {
  const f = fixture();
  assert.equal(f.load().setEnabled(false), true);
  f.load().initialize();
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), false);
});
test('missing choice after completed migration still uses on default', () => {
  const f = fixture({ [marker]: '1' });
  f.load().initialize();
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
  assert.equal(f.writes.length, 0);
});
test('failed migration write does not mark complete and can retry', () => {
  const f = fixture({ [option]: '0' });
  f.failures.write = true;
  f.load().initialize();
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), false);
  assert.equal(f.options.has(marker), false);
  f.failures.write = false;
  f.load().initialize();
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
});
test('unavailable settings and diagnostic logging cannot crash startup', () => {
  const f = fixture();
  f.failures.read = f.failures.log = true;
  assert.doesNotThrow(() => f.load().initialize());
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), false);
  assert.equal(f.writes.length, 0);
});
test('failed user save leaves the active preference unchanged', () => {
  const f = fixture();
  const p = f.load();
  p.initialize();
  f.failures.write = true;
  assert.equal(p.setEnabled(false), false);
  assert.equal(f.storage.get('peerOnlineQueryEnabled'), true);
  assert.equal(f.options.get(option), '1');
});
test('entry, connection and settings pages share the initialized preference', () => {
  const entry = read('entry/src/main/ets/entryability/EntryAbility.ets');
  const connection = read('entry/src/main/ets/pages/ConnectionPage.ets');
  const settings = read('entry/src/main/ets/pages/SettingsPage.ets');
  assert(entry.indexOf('PeerOnlinePreference.initialize()') < entry.indexOf("windowStage.loadContent('pages/HomePage'"));
  for (const page of [connection, settings]) {
    assert.match(page, /@StorageLink\('peerOnlineQueryEnabled'\)[^\r\n]*peerOnlineQueryEnabled: boolean = true/);
  }
  assert(settings.includes("AppStorage.get<boolean>('peerOnlineQueryEnabled') ?? true"));
  assert(settings.includes('PeerOnlinePreference.setEnabled(isOn)'));
  assert(!settings.includes('默认关闭；开启后定期查询已保存设备，手动连接不受影响'));
  assert.match(connection, /if \(!this\.peerOnlineQueryEnabled \|\| this\.peerOnlineQueryInFlight/);
  assert.match(connection, /if \(this\.peerOnlineQueryEnabled\)/, 'manual off still hides state dots');
  assert.match(source, /appendDiagnosticLog\('online-state', message\)/);
});
console.log(`Online default preference: ${count} checks passed.`);
