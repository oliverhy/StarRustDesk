const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const core = fs.readFileSync(path.join(root, 'entry/src/main/rust/src/lib.rs'), 'utf8');
const account = fs.readFileSync(path.join(root, 'entry/src/main/rust/src/api_account.rs'), 'utf8');
const native = fs.readFileSync(path.join(root, 'entry/src/main/cpp/napi_init.cpp'), 'utf8');
const allowlist = native.slice(native.indexOf('static bool IsSafeRustLifecycleEvent'), native.indexOf('static void OnRustEvent'));
for (const prefix of ['rv_diag ', 'connection auth config ', 'account auth selection ', 'account rendezvous encryption ',
  'file account rendezvous encryption ', 'file punch request sent ', 'relay request sent ', 'rendezvous rejected',
  'webrtc offer ', 'rendezvous receive ']) {
  assert(allowlist.includes(`"${prefix}"`), `exported diagnostic log must allow ${prefix}`);
}
for (const source of ['punch', 'relay', 'file_punch', 'file_relay', 'relay_request']) {
  assert(core.includes(`log_rendezvous_refusal("${source}",`), source);
}
assert(core.includes('raw_redacted=true'));
assert(core.includes('key_source={} effective_key_set={}'));
assert(core.includes('!request.punch_hole_request().token.is_empty()'));
assert(core.includes('file punch request sent token_attached={}'));
assert(core.includes('relay request sent attempt={attempt}/3 token_attached={}'));
assert(!core.includes('return Err(response.refuse_reason)'));
assert(!core.includes('return Err(response.other_failure)'));
assert(!core.includes('bail!("relay refused: {}", resp.refuse_reason)'));
assert(account.includes('context=absent token_selected=false'));
assert(account.includes('server_match={server_match} key_match={key_match}'));
assert(core.indexOf('account rendezvous encryption ready') < core.indexOf('api_account::attach(&mut req, &account_token)'));
assert(!core.includes('webrtc offer unavailable: {error}'));
assert(!core.includes('webrtc local endpoint unavailable: {error}'));
assert(core.includes('webrtc offer fallback reconnected elapsed_ms='));
assert(core.includes('webrtc offer fallback failed elapsed_ms='));
assert(core.includes('"timeout" } else { "handshake_failed"'));
assert(core.includes('RendezvousPhase::Punch'));
assert(core.includes('action=ignore_unsupported_trickle'));
assert(core.includes('MAX_IGNORED_PUNCH_ICE'));
assert(core.includes('unknown_fields={}'));
const observation = core.slice(core.indexOf('fn log_rendezvous_observation('), core.indexOf('async fn next_rendezvous_with_updates('));
for (const field of ['candidate', 'session_key', 'password', 'token', 'other_failure', 'refuse_reason']) {
  assert(!observation.includes(field), `rendezvous diagnostics must not serialize ${field}`);
}
console.log('PASS auth diagnostics cover all refusal paths, config/token metadata, and redact raw server errors');
