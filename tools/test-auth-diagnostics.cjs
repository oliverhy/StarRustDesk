const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const core = fs.readFileSync(path.join(root, 'entry/src/main/rust/src/lib.rs'), 'utf8');
const account = fs.readFileSync(path.join(root, 'entry/src/main/rust/src/api_account.rs'), 'utf8');
const native = fs.readFileSync(path.join(root, 'entry/src/main/cpp/napi_init.cpp'), 'utf8');
const allowlist = native.slice(native.indexOf('static bool IsSafeRustLifecycleEvent'), native.indexOf('static void OnRustEvent'));
for (const prefix of ['rv_diag ', 'game_transport ', 'connection auth config ', 'account auth selection ', 'account rendezvous encryption ',
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
const connection = core.slice(core.indexOf('pub extern "C" fn rust_connect('), core.indexOf('pub extern "C" fn rust_set_performance_preset('));
assert(connection.indexOf('prepare_authenticated_rendezvous(') < connection.indexOf('api_account::attach(&mut req, &account_token)'));
assert(connection.indexOf('!account_token.is_empty() && !rv_conn.is_secured()') < connection.indexOf('api_account::attach(&mut req, &account_token)'));
const preparation = core.slice(core.indexOf('async fn prepare_authenticated_rendezvous('), core.indexOf('async fn prepare_direct_socket_candidates('));
assert(preparation.includes('secure_rendezvous_with_retry('));
assert(preparation.includes('tokio::try_join!(auth_future, socket_future)'));
assert(!core.includes('webrtc offer unavailable: {error}'));
assert(!core.includes('webrtc local endpoint unavailable: {error}'));
assert(core.includes('webrtc offer fallback reconnected elapsed_ms='));
assert(core.includes('webrtc offer fallback failed elapsed_ms='));
assert(core.includes('"timeout" } else { "handshake_failed"'));
assert(core.includes('RendezvousPhase::Punch'));
assert(core.includes('action=ignore_unsupported_trickle'));
assert(core.includes('MAX_IGNORED_PUNCH_ICE'));
assert(core.includes('unknown_fields={}'));
const handshake = core.slice(core.indexOf('enum RendezvousHandshakeContext'), core.indexOf('async fn create_relay('));
for (const stage of ['validate_server_key', 'wait_server_key', 'decode_response', 'validate_exchange',
  'verify_server_signature', 'validate_server_exchange_key', 'send_client_key', 'secure_channel']) {
  assert(handshake.includes(`"${stage}"`), `missing handshake diagnostic stage ${stage}`);
}
for (const reason of ['receive_timeout', 'receive_closed', 'receive_error', 'decode_error',
  'unexpected_message', 'invalid_exchange', 'signature_invalid', 'invalid_peer_key', 'send_timeout', 'send_error']) {
  assert(handshake.includes(`"${reason}"`), `missing handshake failure class ${reason}`);
}
assert(handshake.includes('rv_diag phase=handshake context={} step=decode_response outcome=received kind={}'));
assert(handshake.includes('step=validate_exchange outcome=received unknown_fields={}'));
assert(handshake.includes('step=validate_server_exchange_key outcome=verified signed_params_marker={}'));
assert(handshake.includes('tokio::time::timeout(Duration::from_millis(timeout_ms), conn.next())'));
assert(handshake.includes('action=hedge original_pending=true'));
assert(handshake.includes('outcome=unsecured_channel_blocked token_sent=false'));
assert(handshake.includes('if !error.is_transient()'));
assert(!handshake.includes('token: &str'), 'handshake attempts must not accept an account token');
assert(!handshake.includes('conn.next_timeout('), 'EOF must not be conflated with timeout');
assert(!handshake.includes('format!("{}", error)'));
assert(!handshake.includes('format!("{:?}", error)'));
assert(!handshake.includes('format!("{:?}", message)'));
assert(!handshake.includes('format!("{:?}", bytes)'));
for (const code of [-29, -30, -31, -32, -33]) {
  assert(native.includes(`case ${code}: return`), `missing user-facing handshake message ${code}`);
}
assert(native.includes('case -13: return "ID 服务器拒绝了连接请求"'));
assert(native.includes('text.rfind("punch request sent", 0) == 0'), 'timed punch stages must include attempt details');
for (const phase of ['phase=preparation', 'phase=direct_policy', 'phase=direct_candidates',
  'phase=direct_attempt', 'phase=relay_preconnect', 'phase=handshake_retry']) {
  assert(core.includes(phase), `missing weak-network diagnostic ${phase}`);
}
const observation = core.slice(core.indexOf('fn log_rendezvous_observation('), core.indexOf('async fn next_rendezvous_with_updates('));
for (const field of ['candidate', 'session_key', 'password', 'token', 'other_failure', 'refuse_reason']) {
  assert(!observation.includes(field), `rendezvous diagnostics must not serialize ${field}`);
}
console.log('PASS auth diagnostics cover all refusal paths, config/token metadata, and redact raw server errors');
