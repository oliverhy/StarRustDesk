'use strict';
// Branding changes must never rename storage/crypto namespaces. All fixtures are
// synthetic and in memory: no device, real password, cloud account or network.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const app = JSON.parse(read('AppScope/app.json5')).app;
assert.equal(app.bundleName, 'com.yinhe.starrustdesk');
assert.equal(app.cloudFileSyncEnabled, true);
assert.equal(app.icon, '$media:starrustdesk_app_icon_1024');
assert.equal(app.label, '$string:app_name');
for (const locale of ['base', 'en', 'zh_CN', 'zh_Hant']) {
  const name = locale === 'zh_Hant' ? '芝麻遠控' : '芝麻远控';
  const appStrings = JSON.parse(read(`AppScope/resources/${locale}/element/string.json`)).string;
  const moduleStrings = JSON.parse(read(`entry/src/main/resources/${locale}/element/string.json`)).string;
  assert.equal(appStrings.find(s => s.name === 'app_name').value, name);
  for (const key of ['app_name', 'EntryAbility_label']) assert.equal(moduleStrings.find(s => s.name === key).value, name);
  assert(moduleStrings.find(s => s.name === 'module_desc').value.startsWith(name));
}
const service = 'entry/src/main/ets/service/';
for (const [file, tokens] of [
  ['CloudSyncService.ets', ["CLOUD_FOLDER_NAME: string = 'StarRustDesk'", 'cloud-sync-v1.srdsync']],
  ['CloudSyncSnapshotStore.ets', ["SNAPSHOT_FORMAT: string = 'StarRustDeskCloudSnapshot'", 'cloud-sync-v2-', '.srdsync']],
  ['ConnectionBackupService.ets', ["'StarRustDeskConnectionBackup'", "'StarRustDeskEncryptedConnectionBackup'", "'StarRustDesk|connection-backup|v1'", 'BACKUP_SCHEMA_VERSION: number = 1', 'PBKDF2_ITERATIONS: number = 210000']],
  ['CredentialStore.ets', ["'starrustdesk.connection.'"]],
  ['RemoteSecurityStore.ets', ["'starrustdesk.os-login.'", "'remote-security-options'", "'remote-os-password-server-binding'"]],
  ['ApiAccountStore.ets', ["'starrustdesk.api.account.v1'"]],
  ['ThemePreference.ets', ["'starrustdesk_theme'"]]
]) for (const token of tokens) assert(read(service + file).includes(token), `${file}: preserve ${token}`);
const config = read('entry/src/main/cpp/core/config.cpp');
for (const token of ['SRDCFG1\\n', 'StarRustDesk-local-config-v1:', '0x53, 0x74, 0x61, 0x72, 0x52, 0x75, 0x73, 0x74',
  '0x44, 0x65, 0x73, 0x6b, 0x48, 0x4d, 0x4f, 0x53', '/data/storage/el2/base/haps/entry/files']) assert(config.includes(token), `preserve config identity: ${token}`);
const sign = read('tools/build-formal-app.ps1');
for (const token of ['-keyAlias StarRustDesk2026', 'signing\\StarRustDesk.cer', 'signing\\StarRustDesk.p12',
  'signing\\StarRustDeskRelease.p7b', 'STARRUSTDESK_SIGN_PASSWORD', 'StarRustDesk-default-unsigned.app']) assert(sign.includes(token));
const native = read('entry/src/main/rust/src/lib.rs');
assert.equal((native.match(/my_name: "芝麻远控 HarmonyOS"/g) || []).length, 2, 'both remote/file-transfer login display names');

class Encoder { encodeInto(value) { return new TextEncoder().encode(value); } }
class Decoder {
  decodeWithStream(bytes) { return new TextDecoder().decode(bytes); }
  static create() { return { decodeToString: bytes => new TextDecoder().decode(bytes) }; }
}
const util = { TextEncoder: Encoder, TextDecoder: Decoder, Base64Helper: class {
  encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
  decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
} };
const assetValues = new Map();
const asset = {
  Tag: { ALIAS: 'alias', SECRET: 'secret', RETURN_TYPE: 'return' }, ReturnType: { ALL: 'all' },
  query: async q => {
    const alias = Buffer.from(q.get('alias')).toString();
    const value = assetValues.get(alias);
    return value === undefined ? [] : [new Map([['secret', new Uint8Array(Buffer.from(value))]])];
  },
  add: async () => { throw Error('read-only fixture: unexpected credential write'); },
  remove: async () => { throw Error('read-only fixture: unexpected credential deletion'); }
};
const cryptoFramework = {
  CryptoMode: { ENCRYPT_MODE: 1, DECRYPT_MODE: 2 },
  createRandom: () => ({ generateRandom: async n => ({ data: new Uint8Array(crypto.randomBytes(n)) }) }),
  createKdf: name => {
    assert.equal(name, 'PBKDF2|SHA256');
    return { generateSecret: async p => ({ data: new Uint8Array(crypto.pbkdf2Sync(p.password, p.salt, p.iterations, p.keySize, 'sha256')) }) };
  },
  createSymKeyGenerator: name => { assert.equal(name, 'AES256'); return { convertKey: async b => b.data }; },
  createCipher: name => {
    assert.equal(name, 'AES256|GCM|NoPadding');
    let cipher, encrypt;
    return {
      init: async (mode, key, p) => {
        encrypt = mode === 1;
        cipher = (encrypt ? crypto.createCipheriv : crypto.createDecipheriv)('aes-256-gcm', key, p.iv.data);
        cipher.setAAD(p.aad.data);
        if (!encrypt) cipher.setAuthTag(p.authTag.data);
      },
      doFinal: async ({ data }) => {
        const result = Buffer.concat([cipher.update(data), cipher.final()]);
        return { data: new Uint8Array(encrypt ? Buffer.concat([result, cipher.getAuthTag()]) : result) };
      }
    };
  }
};
function load(name) {
  const exports = {};
  const context = { exports, Uint8Array, require: module => {
    if (module === '@kit.ArkTS') return { util };
    if (module === '@kit.AssetStoreKit') return { asset };
    if (module === '@kit.CryptoArchitectureKit') return { cryptoFramework };
    if (module === './RustDeskNapi') return { RustDeskNapi: { getOption: () => '' } };
    throw Error(module);
  } };
  vm.runInNewContext(ts.transpileModule(read(service + name + '.ets'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, context, { filename: name });
  return exports[name];
}
async function main() {
  const backup = load('ConnectionBackupService');
  const plain = {
    format: 'StarRustDeskConnectionBackup', schemaVersion: 1, exportedAt: '2026-10-27T00:00:00.000Z', includesPasswords: false,
    groups: [{ id: 'old-group', name: '原有分组' }],
    connections: [{ id: 'old-peer', name: '原有连接', remoteId: 'AbC123', password: '', performancePreset: 'smooth', groupId: 'old-group', serverScope: 'private-network' }],
    serverConfig: { idServer: 'example.invalid:21116', relayServer: 'example.invalid:21117', apiServer: '', serverKey: '' }
  };
  const plainResult = backup.parsePlainText(JSON.stringify(plain));
  assert.equal(JSON.stringify(plainResult), JSON.stringify(plain), 'legacy plain backup imports without field/case loss');
  const secrets = structuredClone(plain);
  secrets.includesPasswords = true; secrets.connections[0].password = 'TEST_ONLY_密码'; secrets.serverConfig.serverKey = 'TEST_ONLY_KEY';
  // Independent pre-rename writer, pinned old format/AAD. Do not derive any of
  // these identifiers from the implementation under test.
  const password = 'TEST_ONLY_BackupPassword', salt = Buffer.alloc(16, 7), iv = Buffer.alloc(12, 11);
  const key = crypto.pbkdf2Sync(password, salt, 210000, 32, 'sha256');
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from('StarRustDesk|connection-backup|v1'));
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(secrets)), cipher.final()]);
  const envelope = JSON.stringify({ format: 'StarRustDeskEncryptedConnectionBackup', schemaVersion: 1,
    exportedAt: secrets.exportedAt, kdf: 'PBKDF2|SHA256', iterations: 210000, cipher: 'AES256|GCM|NoPadding',
    salt: salt.toString('base64'), iv: iv.toString('base64'), ciphertext: ciphertext.toString('base64'), tag: cipher.getAuthTag().toString('base64') });
  assert(backup.isEncrypted(envelope));
  assert.equal(JSON.stringify(await backup.decrypt(envelope, password)), JSON.stringify(secrets), 'legacy passwords and relay key survive decryption');
  await assert.rejects(() => backup.decrypt(envelope, 'WRONG_TEST_PASSWORD'));
  const fresh = await backup.encrypt(secrets, password);
  assert.equal(JSON.parse(fresh).format, 'StarRustDeskEncryptedConnectionBackup', 'new export retains old format');
  assert.equal(JSON.stringify(await backup.decrypt(fresh, password)), JSON.stringify(secrets));
  assetValues.set('starrustdesk.connection.old-peer', 'TEST_ONLY_原有密码');
  assert.equal(await load('CredentialStore').load('old-peer'), 'TEST_ONLY_原有密码');
  const session = { server: 'https://example.invalid', provider: 'official', token: 'TEST_ONLY_TOKEN', username: 'fixture', allowHttp: false };
  assetValues.set('starrustdesk.api.account.v1', JSON.stringify({ parts: 1 }));
  assetValues.set('starrustdesk.api.account.v1.part.0', JSON.stringify(session));
  assert.equal(JSON.stringify(await load('ApiAccountStore').load()), JSON.stringify(session));
  console.log('PASS branding: localized public labels, unchanged identity/crypto/storage namespaces, legacy plain/encrypted backups, credential and API session reads');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
