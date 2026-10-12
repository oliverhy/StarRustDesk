const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const rust = read('entry/src/main/rust/src/lib.rs');
const page = read('entry/src/main/ets/pages/ConnectionPage.ets');
const remote = read('entry/src/main/ets/pages/RemotePage.ets');
const store = read('entry/src/main/ets/service/RemoteSecurityStore.ets');
const native = read('entry/src/main/cpp/napi_init.cpp');

assert.match(page, /@State lockAfterDisconnect: boolean = false/);
assert.match(page, /@State privacyMode: boolean = false/);
assert.match(page, /@State autoUnlock: boolean = false/);
assert.match(page, /identityChanged && draft\.osPassword\.length === 0/);
assert.match(page, /RemoteSecurityStore\.isCurrentServer\(request\.savedId\)/);
assert.match(store, /asset\.Tag\.SECRET/);
assert.match(store, /asset\.Accessibility\.DEVICE_UNLOCKED/);
assert.match(store, /asset\.SyncType\.NEVER/);
assert.match(store, /currentServer\(\)/);
assert.doesNotMatch(page.slice(page.indexOf('  buildBackupPayload('), page.indexOf('  async saveBackupFile(')),
  /osPassword|RemoteSecurityStore/, 'OS password must not enter connection backup');

assert.match(rust, /lock_after_session_end: if LOCK_AFTER_DISCONNECT\.load/);
assert.match(rust, /misc\.set_toggle_privacy_mode\(TogglePrivacyMode/);
assert.match(rust, /PrivacyModeState\(state\)/);
assert.match(rust, /if !PEER_E2EE\.load\(Ordering::SeqCst\)/);
assert.match(rust, /auto_unlock_skipped e2ee_unavailable/);
assert.match(rust, /password_event\.set_seq\(configured\)/);
assert.match(rust, /remote security: privacy_result state=/);
assert.match(native, /"remote security:"/);
assert.match(native, /os_password_configured=/);
assert.match(remote, /this\.privacyModeState === 2 \? '关闭隐私屏'/);

console.log('PASS remote security: opt-in defaults, local secret, peer binding, E2EE gate, protocol and safe diagnostics');
