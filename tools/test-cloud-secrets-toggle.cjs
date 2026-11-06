'use strict';

// Exercise the actual ArkTS controller methods with in-memory platform mocks.
// No real cloud files, credentials or saved connections are touched.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/SettingsPage.ets'), 'utf8');
function slice(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert(a >= 0 && b > a, `method boundaries: ${start}`);
  return source.slice(a, b);
}

const card = slice('  buildCloudSyncCard() {', '  setCloudSyncEnabled(');
assert.match(card, /Toggle\(\{ type: ToggleType\.Switch, isOn: this\.cloudSecretsSwitchOn \}\)/);
assert.match(card, /\.switchPointColor\(this\.cloudSecretsSwitchOn \?/);
assert.match(card, /this\.onCloudSecretsSwitchChanged\(isOn\)/);
assert.match(source, /onCancel: \(\) => \{\s*this\.cancelCloudPassword\(\)/);

const methods = slice('  setCloudSyncEnabled(', '  async syncCloudNow(') +
  slice('  aboutToDisappear(): void {', '\n  build() {');
const observations = { enabled: true, includes: false, hasPassword: false, readError: false,
  saveError: false, pendingPassword: undefined, preferenceWrites: [], saved: 0, syncs: 0,
  opened: 0, closed: 0, restoredCancelled: 0, toastCount: 0 };
const CloudSyncService = {
  setEnabled: value => { observations.enabled = value; },
  setIncludesSecrets: value => { observations.includes = value; observations.preferenceWrites.push(value); },
  hasCloudPassword: async () => {
    if (observations.pendingPassword) return observations.pendingPassword;
    if (observations.readError) throw new Error('simulated credential read failure');
    return observations.hasPassword;
  },
  saveCloudPassword: async () => {
    if (observations.saveError) throw new Error('simulated credential write failure');
    observations.saved++;
  },
};
const sandbox = vm.createContext({ CloudSyncService, translate: value => value,
  promptAction: { showToast: () => { observations.toastCount++; } }, console });
const js = ts.transpileModule(`class Subject { ${methods} } globalThis.Subject = Subject;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
vm.runInContext(js, sandbox);
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

function reset(options = {}) {
  Object.assign(observations, { enabled: true, includes: false, hasPassword: false, readError: false,
    saveError: false, pendingPassword: undefined, preferenceWrites: [], saved: 0, syncs: 0,
    opened: 0, closed: 0, restoredCancelled: 0, toastCount: 0 }, options);
  return Object.assign(new sandbox.Subject(), {
    cloudSyncEnabled: observations.enabled,
    cloudSyncIncludesSecrets: observations.includes,
    cloudSecretsSwitchOn: observations.includes,
    cloudSecretsPending: false,
    cloudSyncBusy: false,
    cloudSyncStatus: '',
    cloudPasswordAction: '',
    cloudSecretsRequestGeneration: 0,
    cloudUiGeneration: 1,
    cloudPasswordDialogController: {
      open: () => { observations.opened++; },
      close: () => { observations.closed++; },
    },
    cloudHistoryDialogController: { close: () => {} },
    cancelCloudRestore: () => { observations.restoredCancelled++; },
    previewCloudRestore: async () => {},
    syncCloudNow: async () => { observations.syncs++; },
  });
}

let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log(`PASS ${name}`); }

;(async () => {
  await test('cancel restores the off switch without changing preference or uploading', async () => {
    const page = reset();
    for (let attempt = 0; attempt < 2; attempt++) {
      page.onCloudSecretsSwitchChanged(true);
      await flush();
      assert.equal(page.cloudSecretsSwitchOn, true);
      assert.equal(page.cloudSyncIncludesSecrets, false);
      assert.equal(page.cloudPasswordAction, 'enable-secrets');
      page.cancelCloudPassword();
      assert.equal(page.cloudSecretsSwitchOn, false);
      assert.equal(page.cloudSyncIncludesSecrets, false);
      // A framework callback caused by the rollback must not toggle or sync.
      page.onCloudSecretsSwitchChanged(false);
      await flush();
      assert.deepEqual(observations.preferenceWrites, []);
      assert.equal(observations.syncs, 0);
      assert.equal(observations.saved, 0);
    }
    assert.equal(observations.opened, 2);
  });

  await test('read failure restores the switch and does not write or sync', async () => {
    const page = reset({ readError: true });
    page.onCloudSecretsSwitchChanged(true);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, false);
    assert.equal(page.cloudSyncIncludesSecrets, false);
    assert.equal(page.cloudSecretsPending, false);
    page.onCloudSecretsSwitchChanged(false);
    await flush();
    assert.deepEqual(observations.preferenceWrites, []);
    assert.equal(observations.syncs, 0);
    assert.equal(observations.toastCount, 1);
  });

  await test('saving the password enables the preference once', async () => {
    const page = reset();
    page.onCloudSecretsSwitchChanged(true);
    await flush();
    await page.saveCloudPassword('test-only-password');
    assert.equal(page.cloudSecretsSwitchOn, true);
    assert.equal(page.cloudSyncIncludesSecrets, true);
    assert.deepEqual(observations.preferenceWrites, [true]);
    assert.equal(observations.saved, 1);
    assert.equal(observations.syncs, 1);
  });

  await test('existing password enables and disabling reverts normally', async () => {
    const page = reset({ hasPassword: true });
    page.onCloudSecretsSwitchChanged(true);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, true);
    assert.equal(page.cloudSyncIncludesSecrets, true);
    page.onCloudSecretsSwitchChanged(false);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, false);
    assert.equal(page.cloudSyncIncludesSecrets, false);
    assert.deepEqual(observations.preferenceWrites, [true, false]);
    assert.equal(observations.syncs, 2);
  });

  await test('failed password save followed by cancel does not enable or sync', async () => {
    const page = reset({ saveError: true });
    page.onCloudSecretsSwitchChanged(true);
    await flush();
    await page.saveCloudPassword('test-only-password');
    page.cancelCloudPassword();
    page.onCloudSecretsSwitchChanged(false);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, false);
    assert.equal(page.cloudSyncIncludesSecrets, false);
    assert.deepEqual(observations.preferenceWrites, []);
    assert.equal(observations.saved, 0);
    assert.equal(observations.syncs, 0);
  });

  await test('cancelling a restore does not change an existing enabled preference', async () => {
    const page = reset({ includes: true });
    page.cloudPasswordAction = 'restore';
    page.cancelCloudPassword();
    assert.equal(page.cloudSecretsSwitchOn, true);
    assert.equal(page.cloudSyncIncludesSecrets, true);
    assert.equal(observations.restoredCancelled, 1);
    assert.deepEqual(observations.preferenceWrites, []);
    assert.equal(observations.syncs, 0);
  });

  await test('disabling cloud sync invalidates a pending password check', async () => {
    let resolvePassword;
    const pendingPassword = new Promise(resolve => { resolvePassword = resolve; });
    const page = reset({ pendingPassword });
    page.onCloudSecretsSwitchChanged(true);
    assert.equal(page.cloudSecretsPending, true);
    page.setCloudSyncEnabled(false);
    resolvePassword(true);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, false);
    assert.equal(page.cloudSecretsPending, false);
    assert.equal(page.cloudSyncIncludesSecrets, false);
    assert.deepEqual(observations.preferenceWrites, []);
    assert.equal(observations.opened, 0);
    assert.equal(observations.syncs, 0);
  });

  await test('a rapid second gesture cancels a pending password check', async () => {
    let resolvePassword;
    const pendingPassword = new Promise(resolve => { resolvePassword = resolve; });
    const page = reset({ pendingPassword });
    page.onCloudSecretsSwitchChanged(true);
    assert.equal(page.cloudSecretsPending, true);
    page.onCloudSecretsSwitchChanged(false);
    resolvePassword(true);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, false);
    assert.equal(page.cloudSecretsPending, false);
    assert.equal(page.cloudSyncIncludesSecrets, false);
    assert.deepEqual(observations.preferenceWrites, []);
    assert.equal(observations.opened, 0);
    assert.equal(observations.syncs, 0);
  });

  await test('leaving the settings page invalidates a pending password check', async () => {
    let resolvePassword;
    const pendingPassword = new Promise(resolve => { resolvePassword = resolve; });
    const page = reset({ pendingPassword });
    page.onCloudSecretsSwitchChanged(true);
    page.aboutToDisappear();
    resolvePassword(true);
    await flush();
    assert.equal(page.cloudSecretsSwitchOn, false);
    assert.equal(page.cloudSecretsPending, false);
    assert.equal(page.cloudSyncIncludesSecrets, false);
    assert.deepEqual(observations.preferenceWrites, []);
    assert.equal(observations.opened, 0);
    assert.equal(observations.syncs, 0);
  });

  console.log(`${passed} cloud secrets switch checks passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
