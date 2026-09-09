// Execute the production Rust getter with a disconnected/handshaking session.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/rust/src/lib.rs'), 'utf8');
const start = source.indexOf('pub extern "C" fn rust_get_connection_route()');
const end = source.indexOf('\n#[no_mangle]', start);
assert(start >= 0 && end > start);
const getter = source.slice(start, end);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'starrustdesk-route-'));
const input = path.join(temp, 'route.rs');
const executable = path.join(temp, 'route.exe');
fs.writeFileSync(input, `use std::sync::atomic::{AtomicI32, AtomicBool, Ordering};
static CONNECTION_ROUTE: AtomicI32 = AtomicI32::new(0);
static CONNECTION_ACTIVE: AtomicBool = AtomicBool::new(false);
${getter}
fn main() {
    assert_eq!(rust_get_connection_route(), 0);
    CONNECTION_ROUTE.store(1, Ordering::SeqCst);
    assert_eq!(rust_get_connection_route(), 1, "failed direct handshake must retain route");
    CONNECTION_ROUTE.store(2, Ordering::SeqCst);
    assert_eq!(rust_get_connection_route(), 2, "relay must not be mistaken for direct");
    CONNECTION_ACTIVE.store(true, Ordering::SeqCst);
    assert_eq!(rust_get_connection_route(), 2);
    CONNECTION_ACTIVE.store(false, Ordering::SeqCst);
    CONNECTION_ROUTE.store(0, Ordering::SeqCst);
    assert_eq!(rust_get_connection_route(), 0, "disconnect clears route");
}`);
const rustc = process.env.RUSTC || path.join(os.homedir(), '.cargo/bin/rustc.exe');
const compile = spawnSync(rustc, [input, '-o', executable], { encoding: 'utf8' });
assert.equal(compile.status, 0, compile.stderr);
const run = spawnSync(executable, [], { encoding: 'utf8' });
assert.equal(run.status, 0, run.stderr);
console.log('PASS production Rust route getter: idle, failed direct, relay, connected, disconnect');
