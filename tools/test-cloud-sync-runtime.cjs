// Execute the production cloud state machine with simulated SDK/files/timers.
// No cloud account, network request, user data or real filesystem writes.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const crypto = require('node:crypto')
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript')
const root = path.resolve(__dirname, '..')
const source = name => fs.readFileSync(path.join(root, 'entry/src/main/ets', name), 'utf8')
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve() }
function environment(config = {}) {
  const clock = { now: 2000000000000, next: 0, tasks: new Map() }
  const schedule = (fn, delay, interval = 0) => {
    const id = ++clock.next
    clock.tasks.set(id, { fn, at: clock.now + delay, interval })
    return id
  }
  const logs = [], drivers = [], files = new Map(), directories = new Set(['/cloud', '/local']), handles = new Map()
  // Existing-device scenarios have reconciled before. Fresh/reinstalled cases
  // below explicitly remove the baseline; do not model reinstall as deletion.
  const options = new Map(Object.entries({ 'cloud-sync-enabled': '1', 'diagnostic-log-enabled': '1',
    'cloud-sync-baseline-established': '1', ...config.options }))
  const credentials = new Map()
  let fd = 0, uuid = 0, lastSync = clock.now - 10000, cloudWrites = 0, starts = 0
  const operations = []
  const states = { UPLOADING: 0, UPLOAD_FAILED: 1, DOWNLOADING: 2, DOWNLOAD_FAILED: 3, COMPLETED: 4, STOPPED: 5 }
  class FileSync {
    constructor() { this.offCount = 0; drivers.push(this) }
    async getLastSyncTime() {
      if (config.timeError) throw { code: 13600001 }
      if (config.timeHang) return new Promise(() => {})
      return lastSync
    }
    on(_, callback) {
      this.callback = callback
      if (config.listenError) throw { code: 201 }
      if (config.asyncSnapshot) schedule(() => this.emit(config.snapshot ?? 4), 1)
      else this.emit(config.snapshot ?? 4)
    }
    off(_, callback) { assert.equal(callback, this.callback); this.offCount++; this.callback = undefined }
    emit(state, error = 0) { this.callback?.({ state, error }) }
    async start() {
      starts++
      if (config.startError) throw { code: config.startError, message: 'SECRET_RAW_MESSAGE' }
      if (config.startHang) return new Promise(() => {})
      if (!config.manual) {
        schedule(() => this.emit(0), 10)
        schedule(() => { lastSync = clock.now; this.emit(4) }, 20)
      }
    }
  }
  const fail = (operation, p = '') => {
    operations.push({ operation, path: p })
    if (config.cloudError === operation && p.startsWith('/cloud/')) {
      if (config.failOnce) config.cloudError = undefined
      throw { code: config.cloudErrorCode ?? 13900020, message: 'SECRET_PATH' }
    }
    if (config.fileError === operation) throw { code: 13900012, message: 'SECRET_PATH' }
  }
  const fileIo = {
    OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync(p) { return files.has(p) || directories.has(p) },
    listFileSync(p) { fail('list', p); return [...files.keys()].filter(k => k.startsWith(p + '/')).map(k => k.slice(p.length + 1)) },
    mkdirSync(p) { fail('mkdir'); directories.add(p) },
    openSync(p, mode) {
      fail('open', p)
      if (mode && (!files.has(p) || (mode & 4))) files.set(p, Buffer.alloc(0))
      if (!files.has(p)) throw { code: 13900002 }
      const f = { fd: ++fd }; handles.set(fd, p); return f
    },
    statSync(fd) { fail('stat', handles.get(fd)); return { size: files.get(handles.get(fd)).length } },
    readSync(fd, buffer) {
      fail('read', handles.get(fd))
      const bytes = files.get(handles.get(fd)); new Uint8Array(buffer).set(bytes)
      if (config.corruptRead && handles.get(fd).endsWith('.pending')) new Uint8Array(buffer)[5] ^= 1
      return config.shortRead ? bytes.length - 1 : bytes.length
    },
    writeSync(fd, data) { fail('write', handles.get(fd)); const bytes = Buffer.from(data); files.set(handles.get(fd), bytes); return config.shortWrite ? bytes.length - 1 : bytes.length },
    fsyncSync(fd) { fail('fsync', handles.get(fd)) },
    closeSync(file) { const id = typeof file === 'number' ? file : file.fd; fail('close', handles.get(id)); handles.delete(id) },
    renameSync(from, to) {
      fail('rename', to)
      // CloudDisk differs from local files: rename over an existing name is EINVAL.
      if (to.startsWith('/cloud/') && files.has(to)) throw { code: 13900020 }
      files.set(to, files.get(from)); files.delete(from); if (to.startsWith('/cloud/')) cloudWrites++
    },
    unlinkSync(p) { fail('unlink', p); files.delete(p) }
  }
  const sandbox = vm.createContext({ exports: {}, console, Promise, Error, Number, String, JSON, ArrayBuffer, Uint8Array,
    Date: class extends Date { constructor(v) { super(v === undefined ? clock.now : v) } static now() { return clock.now } },
    setTimeout: (fn, delay) => schedule(fn, delay), clearTimeout: id => clock.tasks.delete(id),
    setInterval: (fn, delay) => schedule(fn, delay, delay), clearInterval: id => clock.tasks.delete(id),
    cloudSync: { FileSync, SyncState: states }, fileIo,
    cryptoFramework: { createMd: () => {
      const hash = crypto.createHash('sha256')
      return { update: async ({ data }) => { hash.update(data) }, digest: async () => ({ data: new Uint8Array(hash.digest()) }) }
    } },
    util: { generateRandomUUID: () => config.uuids?.length ? config.uuids.shift() : `00000000-0000-4000-8000-${String(++uuid).padStart(12, '0')}`,
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text) } },
      TextDecoder: { create: () => ({ decodeToString: data => new TextDecoder().decode(data) }) } },
    OperationDiagnostic: { errorCode: e => Number.isFinite(Number(e?.code)) ? Number(e.code) : 0 },
    RustDeskNapi: { getOption: key => options.get(key) ?? '', setOption: (key, value) => {
      if (config.ignoreWriteKey !== key) options.set(key, value)
    },
      appendDiagnosticLog: (_, value) => { if (config.logError) throw new Error('logger'); logs.push(value) } },
    CredentialStore: { load: async id => { if (config.credentialError) throw { code: 201 }; return credentials.has(id) ? credentials.get(id) : config.password ?? 'TEST_PASSWORD' },
      save: async (id, value) => { if (!config.credentialSaveFailure) credentials.set(id, value) }, remove: async id => credentials.delete(id) },
    ConnectionBackupService: {
      createPayload: (groups, connections, includesPasswords, serverConfig) => ({ groups, connections, includesPasswords, serverConfig, exportedAt: new Date(clock.now).toISOString() }),
      createPlainText: JSON.stringify, parsePlainText: JSON.parse, isEncrypted: () => config.encrypted === true,
      encrypt: async payload => JSON.stringify(payload), decrypt: async raw => JSON.parse(raw)
    },
    AppStorage: { get: () => 0, set: () => {} }
  })
  function load(code, label) {
    code = code.replace(/^import[\s\S]*?from\s+['"][^'"]+['"]\s*;?\r?\n/gm, '')
    sandbox.exports = {}
    vm.runInContext(ts.transpileModule(code, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, sandbox, { filename: label })
    Object.assign(sandbox, sandbox.exports)
    return sandbox.exports
  }
  load(source('service/CloudSyncTask.ets'), 'CloudSyncTask.ets')
  load(source('service/CloudSyncSnapshotStore.ets'), 'CloudSyncSnapshotStore.ets')
  load(source('service/CloudSyncService.ets'), 'CloudSyncService.ets')
  const context = { cloudFileDir: config.noCloudDir ? '' : '/cloud', filesDir: '/local' }
  const cloudPath = '/cloud/StarRustDesk/cloud-sync-v1.srdsync'
  async function tick(ms) {
    await flush()
    const end = clock.now + ms
    while (true) {
      const next = [...clock.tasks].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0]
      if (!next) break
      const [id, t] = next
      clock.now = t.at
      if (t.interval) t.at += t.interval
      else clock.tasks.delete(id)
      t.fn(); await flush()
    }
    clock.now = end; await flush()
  }
  function wait() { return sandbox.CloudSyncTask.wait(new sandbox.CloudSyncTrace('sync'), () => config.cancelled === true) }
  const cloudSnapshots = () => [...files.keys()].filter(p => /\/cloud-sync-v2-.*\.srdsync$/.test(p)).sort()
  const latestContent = () => JSON.parse(JSON.parse(files.get(cloudSnapshots().at(-1))).content)
  return { config, clock, logs, drivers, files, options, context, cloudPath, tick, wait, load, sandbox, handles, operations, cloudSnapshots, latestContent,
    service: sandbox.CloudSyncService, setLastSync: v => { lastSync = v }, stats: () => ({ cloudWrites, starts }) }
}

let passed = 0
async function test(name, fn) { await fn(); console.log(`PASS ${name}`); passed++ }
async function confirmLatest(e) {
  const previewTask = e.service.restore(e.context)
  await e.tick(100)
  const result = await previewTask
  if (!result.preview) return result
  const restoreTask = e.service.restore(e.context, result.preview.ticket)
  await e.tick(100)
  return await restoreTask
}
;(async () => {
  await test('start acknowledgement and registration snapshot never report success', async () => {
    for (const asyncSnapshot of [false, true]) {
      const e = environment({ manual: true, asyncSnapshot })
      let settled = false
      const p = e.wait().then(() => { settled = true })
      await e.tick(100)
      e.drivers[0].emit(4)
      await e.tick(1000)
      assert.equal(settled, false)
      e.drivers[0].emit(0); e.drivers[0].emit(4)
      await p
      assert.equal(e.drivers[0].offCount, 1)
      assert.equal(e.clock.tasks.size, 0)
    }
  })
  await test('initial previous-task failure is ignored; fresh failure is actionable', async () => {
    const e = environment({ manual: true, snapshot: 1 })
    const p = e.wait().catch(x => x)
    await e.tick(100)
    e.drivers[0].emit(1, 5)
    assert.equal((await p).code, 22410005)
  })
  await test('fresh last-sync timestamp confirms no-op sync, old timestamp does not', async () => {
    const e = environment({ manual: true })
    let done = false
    const p = e.wait().then(() => { done = true })
    await e.tick(1000); assert.equal(done, false)
    e.setLastSync(e.clock.now)
    await e.tick(1000); await p
  })
  await test('all SDK start errors remain distinct and never expose raw message', async () => {
    const messages = new Set()
    for (const code of [22400001, 22400002, 22400003, 13600001, 13900012, 801, 999999]) {
      const e = environment({ startError: code })
      const result = await e.service.syncNow(e.context)
      assert.equal(result.success, false); assert.equal(result.code, code)
      assert.equal(result.stage, 'preflight')
      assert.ok(!result.message.includes('SECRET'))
      assert.ok(e.logs.some(l => l.includes(`code=${code}`) && l.includes('operation_stage=preflight')))
      assert.ok(e.logs.every(l => !l.includes('SECRET')))
      messages.add(result.message)
    }
    assert.equal(messages.size, 7)
  })
  await test('progress failures distinguish network/Wi-Fi/battery/cloud/local/heat/service', async () => {
    for (let code = 0; code <= 8; code++) {
      const e = environment({ manual: true })
      const p = e.wait().catch(x => x)
      await flush(); e.drivers[0].emit(1, code)
      assert.equal((await p).code, 22410000 + code)
    }
  })
  await test('timeout is pending, preserves success timestamp, removes listeners, ignores late events', async () => {
    const e = environment({ manual: true, options: { 'cloud-sync-last-success-at': '1234' } })
    const p = e.service.syncNow(e.context)
    await e.tick(35000)
    const result = await p
    assert.equal(result.pending, true); assert.equal(result.code, -1001)
    assert.equal(e.options.get('cloud-sync-last-success-at'), '1234')
    assert.equal(e.clock.tasks.size, 0)
    assert.equal(e.drivers[0].offCount, 1)
    e.drivers[0].emit(4); await flush()
    assert.equal(e.service.getLastResult(), result)
  })
  await test('hung baseline/start are bounded; listener registration and logger errors are safe', async () => {
    for (const config of [{ timeHang: true }, { startHang: true }]) {
      const e = environment(config), p = e.wait().catch(x => x)
      await e.tick(35000)
      assert.equal((await p).code, -1001)
      assert.equal(e.clock.tasks.size, 0)
    }
    const e = environment({ listenError: true, logError: true })
    const p = e.wait().catch(x => x)
    assert.equal((await p).code, 201)
    assert.equal(e.drivers[0].offCount, 1)
  })
  await test('sync/background upload coalesce; explicit restore reports busy, not false success', async () => {
    const e = environment(), a = e.service.syncNow(e.context), b = e.service.upload(e.context)
    assert.equal(a, b)
    const busy = await e.service.restore(e.context)
    assert.equal(busy.success, false); assert.equal(busy.pending, true)
    await e.tick(100)
    assert.equal((await a).uploaded, true)
    assert.equal(e.stats().cloudWrites, 1)
    assert.equal(e.stats().starts, 2)
  })
  await test('upload only succeeds after second system completion, not after writing mirror', async () => {
    const e = environment({ manual: true })
    let result
    const p = e.service.upload(e.context).then(r => { result = r })
    await flush(); e.drivers[0].emit(0); e.drivers[0].emit(4); await flush()
    assert.equal(e.stats().cloudWrites, 1)
    assert.equal(e.options.has('cloud-sync-last-success-at'), false)
    assert.equal(result, undefined)
    e.drivers[1].emit(0); e.drivers[1].emit(4)
    await p; assert.equal(result.success, true)
  })
  await test('disable invalidates old completion and never stamps success or restores data', async () => {
    const e = environment({ manual: true }), p = e.service.syncNow(e.context)
    await flush(); e.service.setEnabled(false)
    e.drivers[0].emit(0); e.drivers[0].emit(4)
    const result = await p
    assert.equal(result.code, -1002)
    assert.equal(e.stats().cloudWrites, 0)
    assert.equal(e.options.has('cloud-sync-last-success-at'), false)
    assert.equal(e.service.getLastResult(), undefined)
  })
  await test('failed upload acknowledgement after successful preflight keeps prior success time', async () => {
    const e = environment({ manual: true, options: { 'cloud-sync-last-success-at': '1234' } })
    const p = e.service.upload(e.context)
    await flush()
    e.drivers[0].emit(0); e.drivers[0].emit(4)
    e.config.startError = 22400002
    const result = await p
    assert.equal(result.success, false); assert.equal(result.stage, 'upload_wait')
    assert.equal(result.code, 22400002)
    assert.equal(e.options.get('cloud-sync-last-success-at'), '1234')
    assert.equal(e.options.has('cloud-sync-last-applied-at'), false)
  })
  await test('password prompt resumes the right operation instead of restoring an absent backup', async () => {
    const e = environment({ password: '', options: { 'cloud-sync-include-secrets': '1' } })
    const upload = e.service.upload(e.context)
    await e.tick(100)
    const a = await upload
    assert.equal(a.needsPassword, true); assert.equal(a.passwordAction, 'sync')
    const f = environment({ password: '', encrypted: true })
    f.files.set(f.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(f.clock.now).toISOString() })))
    const restore = f.service.restore(f.context)
    await f.tick(100)
    const b = await restore
    assert.equal(b.needsPassword, true); assert.equal(b.passwordAction, 'restore')
  })
  await test('edits during preflight prevent stale writes; edits during upload remain dirty', async () => {
    const e = environment({ manual: true }), p = e.service.syncNow(e.context)
    await flush(); e.service.markLocalChanged(); e.drivers[0].emit(0); e.drivers[0].emit(4)
    assert.equal((await p).code, -1004); assert.equal(e.stats().cloudWrites, 0)
    const f = environment({ manual: true }), q = f.service.upload(f.context)
    await flush(); f.drivers[0].emit(0); f.drivers[0].emit(4); await flush()
    await f.tick(100); f.service.markLocalChanged()
    const dirty = f.options.get('cloud-sync-local-changed-at')
    f.drivers[1].emit(0); f.drivers[1].emit(4)
    assert.equal((await q).pending, true)
    assert.equal(f.options.get('cloud-sync-local-changed-at'), dirty)
  })
  await test('specific directory/credential/file errors identify exact operation stage', async () => {
    const cases = [ [{ noCloudDir: true }, 'cloud_directory', 22400001], [{ fileError: 'mkdir' }, 'cloud_directory', 13900012],
      [{ credentialError: true, options: { 'cloud-sync-include-secrets': '1' } }, 'credential', 201],
      [{ fileError: 'write' }, 'mirror_write', 13900012] ]
    for (const [config, stage, code] of cases) {
      const e = environment(config), p = e.service.syncNow(e.context)
      await e.tick(100)
      const result = await p
      assert.equal(result.stage, stage); assert.equal(result.code, code)
      assert.ok(!result.message.includes('SECRET'))
      assert.equal(e.stats().cloudWrites, 0)
    }
  })
  await test('cloud restore never misrepresents a local mirror as a cloud backup', async () => {
    const e = environment()
    e.files.set('/local/cloud_backup/cloud-sync-v1.srdsync', Buffer.from('{}'))
    const p = e.service.restore(e.context); await e.tick(100)
    const r = await p
    assert.equal(r.restored, false); assert.equal(r.success, false)
    assert.equal(e.options.has('saved-connections'), false)
  })
  await test('failed atomic write preserves previous data and cleans temporary file', async () => {
    for (const config of [{ shortWrite: true }, { fileError: 'rename' }]) {
      const e = environment(config)
      const original = Buffer.from('ORIGINAL_BACKUP')
      e.files.set(e.cloudPath, original)
      assert.throws(() => e.service.writeText(e.cloudPath, 'NEW_BACKUP'))
      assert.deepEqual(e.files.get(e.cloudPath), original)
      assert.equal(e.files.has(e.cloudPath + '.pending'), false)
    }
  })
  await test('enabling sync does not dirty the backup; removing all connections does not resurrect old cloud rows', async () => {
    const e = environment({ options: { 'cloud-sync-local-changed-at': '2000000000000' } })
    e.service.setEnabled(true)
    assert.equal(e.options.get('cloud-sync-local-changed-at'), '2000000000000')
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(1999999999000).toISOString(), groups: [], connections: [{ id: 'old' }] })))
    const p = e.service.syncNow(e.context); await e.tick(100)
    assert.equal((await p).uploaded, true)
    assert.equal(e.latestContent().connections.length, 0)
  })
  await test('diagnostics default-off and logger failure never changes successful sync', async () => {
    for (const config of [{ options: { 'diagnostic-log-enabled': '0' } }, { logError: true }]) {
      const e = environment(config), p = e.service.syncNow(e.context)
      await e.tick(100)
      assert.equal((await p).success, true); assert.equal(e.logs.length, 0)
    }
  })
  await test('CloudDisk overwrite incompatibility reproduced; repeated new snapshots succeed and retain v1', async () => {
    const e = environment({ options: { 'cloud-sync-local-changed-at': '2000000000000' } })
    const original = Buffer.from(JSON.stringify({ exportedAt: new Date(e.clock.now - 1000).toISOString(), groups: [], connections: [] }))
    e.files.set(e.cloudPath, original)
    assert.throws(() => e.service.writeText(e.cloudPath, 'NEW_BACKUP'), error => error.code === 13900020)
    assert.deepEqual(e.files.get(e.cloudPath), original)
    for (let i = 0; i < 2; i++) {
      e.service.markLocalChanged()
      const p = e.service.syncNow(e.context); await e.tick(100)
      assert.equal((await p).success, true)
    }
    assert.equal(e.cloudSnapshots().length, 2)
    assert.deepEqual(e.files.get(e.cloudPath), original)
    assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
    assert.equal(e.handles.size, 0)
  })
  await test('cloud writer avoids fsync while local mirror still requires it', async () => {
    const e = environment({ cloudError: 'fsync' })
    const p = e.service.syncNow(e.context); await e.tick(100)
    assert.equal((await p).success, true)
    assert.ok(e.operations.some(o => o.operation === 'fsync' && o.path.startsWith('/local/')))
    assert.ok(!e.operations.some(o => o.operation === 'fsync' && o.path.startsWith('/cloud/')))
    const f = environment({ fileError: 'fsync' }), q = f.service.syncNow(f.context)
    await f.tick(100)
    assert.equal((await q).stage, 'mirror_write')
    assert.equal(f.cloudSnapshots().length, 0)
  })
  await test('restores newest complete snapshot on another simulated device, retains legacy support', async () => {
    const writer = environment()
    for (let i = 0; i < 2; i++) {
      writer.options.set('saved-connections', JSON.stringify([{ id: `device${i}`, remoteId: `12345678${i}`, name: '测试', performancePreset: 'balanced', groupId: '' }]))
      writer.service.markLocalChanged()
      const p = writer.service.syncNow(writer.context); await writer.tick(100)
      assert.equal((await p).uploaded, true)
    }
    const reader = environment()
    for (const name of writer.cloudSnapshots()) reader.files.set(name, writer.files.get(name))
    reader.files.set(reader.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(writer.clock.now - 1000).toISOString(), groups: [], connections: [] })))
    reader.files.set('/cloud/StarRustDesk/cloud-sync-v2-9999999999999-00000000-0000-4000-8000-000000000000.srdsync.pending', Buffer.from('PARTIAL'))
    const p = confirmLatest(reader); await reader.tick(100)
    assert.equal((await p).restored, true)
    assert.equal(JSON.parse(reader.options.get('saved-connections'))[0].id, 'device1')
    // A newer valid legacy snapshot is still read, never overwritten in place.
    reader.files.set(reader.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(writer.clock.now + 1000).toISOString(), groups: [], connections: [] })))
    const q = confirmLatest(reader); await reader.tick(100)
    assert.equal((await q).restored, true)
    assert.equal(JSON.parse(reader.options.get('saved-connections')).length, 0)
  })
  await test('damaged newest snapshot blocks restoration instead of resurrecting older data', async () => {
    for (const damage of ['partial', 'checksum', 'time', 'null']) {
      const e = environment(), p = e.service.syncNow(e.context); await e.tick(100); await p
      const name = e.cloudSnapshots()[0], good = e.files.get(name)
      const envelope = JSON.parse(good)
      if (damage === 'checksum') envelope.sha256 = '0'.repeat(64)
      if (damage === 'time') envelope.contentTime++
      e.files.set(name, Buffer.from(damage === 'partial' ? '{' : damage === 'null' ? 'null' : JSON.stringify(envelope)))
      e.files.set(e.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(e.clock.now - 1000).toISOString(), groups: [], connections: [{ id: 'old' }] })))
      e.options.set('saved-connections', 'LOCAL_UNCHANGED')
      const q = e.service.restore(e.context); await e.tick(100)
      const result = await q
      assert.equal(result.success, false); assert.equal(result.code, -1005)
      assert.equal(result.stage, 'cloud_validate')
      assert.equal(e.options.get('saved-connections'), 'LOCAL_UNCHANGED')
      assert.equal(e.cloudSnapshots().length, 1)
    }
  })
  await test('file operation failures retain exact stage/code and do not delete previous snapshots', async () => {
    for (const [operation, stage] of [['open', 'cloud_open'], ['write', 'cloud_write_bytes'], ['close', 'cloud_close'],
      ['stat', 'cloud_verify_stat'], ['read', 'cloud_verify_bytes'], ['rename', 'cloud_publish']]) {
      const e = environment({ cloudError: operation, failOnce: true })
      const trace = new e.sandbox.CloudSyncTrace('upload')
      const original = Buffer.from('OLD_BACKUP')
      e.files.set(e.cloudPath, original)
      const failure = await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', 'SEALED_CONTENT', e.clock.now, trace, () => {}).catch(x => x)
      assert.equal(failure.code, 13900020, operation)
      assert.equal(trace.stage, stage, operation)
      assert.deepEqual(e.files.get(e.cloudPath), original)
      assert.equal(e.cloudSnapshots().length, 0)
      assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
      assert.equal(e.handles.size, 0)
      assert.ok(e.logs.every(l => !l.includes('SEALED_CONTENT') && !l.includes('/cloud/') && !l.includes('SECRET')))
    }
  })
  await test('short write, short read and mismatched readback never publish', async () => {
    for (const config of [{ shortWrite: true }, { shortRead: true }, { corruptRead: true }]) {
      const e = environment(config), trace = new e.sandbox.CloudSyncTrace('upload')
      const failure = await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', 'DATA', e.clock.now, trace, () => {}).catch(x => x)
      assert.equal(failure.code, 13900005)
      assert.equal(e.cloudSnapshots().length, 0)
      assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
    }
  })
  await test('unique naming handles retries, simultaneous writers and publish-time collision without overwrite', async () => {
    const e = environment(), store = e.sandbox.CloudSyncSnapshotStore
    const trace = () => new e.sandbox.CloudSyncTrace('upload')
    await Promise.all([store.publish('/cloud/StarRustDesk', 'A', e.clock.now, trace(), () => {}),
      store.publish('/cloud/StarRustDesk', 'B', e.clock.now, trace(), () => {})])
    assert.equal(e.cloudSnapshots().length, 2)
    const original = e.files.get(e.cloudSnapshots()[0])
    e.config.uuids = ['00000000-0000-4000-8000-000000000001']
    await store.publish('/cloud/StarRustDesk', 'C', e.clock.now, trace(), () => {})
    assert.equal(e.cloudSnapshots().length, 3)
    assert.deepEqual(e.files.get(e.cloudSnapshots()[0]), original)
    const collision = `/cloud/StarRustDesk/cloud-sync-v2-${e.clock.now}-00000000-0000-4000-8000-000000000009.srdsync`
    e.config.uuids = ['00000000-0000-4000-8000-000000000009']
    let checks = 0
    const error = await store.publish('/cloud/StarRustDesk', 'D', e.clock.now, trace(), () => {
      if (++checks === 2) e.files.set(collision, Buffer.from('OTHER_WRITER'))
    }).catch(x => x)
    assert.equal(error.code, 13900015)
    assert.equal(e.files.get(collision).toString(), 'OTHER_WRITER')
    assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
  })
  await test('cleanup errors cannot replace the primary error or failure stage', async () => {
    const e = environment({ cloudError: 'rename', fileError: 'unlink' }), trace = new e.sandbox.CloudSyncTrace('upload')
    const failure = await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', 'DATA', e.clock.now, trace, () => {}).catch(x => x)
    assert.equal(failure.code, 13900020)
    assert.equal(trace.stage, 'cloud_publish')
    assert.ok(e.logs.some(l => l.includes('stage=cleanup_pending') && l.includes('code=13900012')))
    assert.equal(e.cloudSnapshots().length, 0)
    const raw = await e.sandbox.CloudSyncSnapshotStore.readLatest('/cloud/StarRustDesk', e.cloudPath, trace, () => 0)
    assert.equal(raw, undefined)
  })
  await test('settings preserve failed status, reset busy in finally, and ignore disabled completion', async () => {
    const e = environment()
    const settings = source('pages/SettingsPage.ets')
    const method = settings.slice(settings.indexOf('  async syncCloudNow('), settings.indexOf('  confirmCloudRestore('))
    const update = settings.slice(settings.indexOf('  updateCloudSyncStatus():'), settings.indexOf('  @Builder\n  buildDiagnosticsCard()') > 0 ? settings.indexOf('  @Builder\n  buildDiagnosticsCard()') : settings.indexOf('  @Builder\r\n  buildDiagnosticsCard()'))
    const { UI } = e.load(`export class UI { ${method}\n${update}\n}`, 'CloudSettingsMethods')
    e.sandbox.getContext = () => e.context
    e.sandbox.promptAction = { showToast() {} }
    e.sandbox.translate = key => key
    const ui = new UI()
    ui.cloudSyncEnabled = true; ui.cloudSyncBusy = false
    let result = { success: false, message: 'network failure', code: 22400002 }
    e.service.syncNow = async () => result
    await ui.syncCloudNow(false, false)
    assert.equal(ui.cloudSyncStatus, 'network failure'); assert.equal(ui.cloudSyncBusy, false)
    e.service.syncNow = async () => { throw new Error('SECRET') }
    await ui.syncCloudNow(false, false)
    assert.equal(ui.cloudSyncBusy, false); assert.ok(!ui.cloudSyncStatus.includes('SECRET'))
    e.service.syncNow = async () => { ui.cloudSyncEnabled = false; return { success: true } }
    await ui.syncCloudNow(false, false)
    assert.equal(ui.cloudSyncStatus, '未开启'); assert.equal(ui.cloudSyncBusy, false)
  })
  const payload = (time, rows = []) => ({ exportedAt: new Date(time).toISOString(),
    groups: rows.length ? [{ id: 'group', name: 'Test group' }] : [],
    connections: rows.map(id => ({ id, name: 'PRIVATE_NAME', remoteId: '123456789', password: '',
      performancePreset: 'smooth', groupId: 'group' })), includesPasswords: false,
    serverConfig: { idServer: 'PRIVATE_SERVER', relayServer: '', apiServer: '', serverKey: '' } })
  const fresh = extra => environment({ ...extra, options: { 'cloud-sync-baseline-established': '0', ...extra?.options } })
  const complete = async (e, p) => { await e.tick(100); return await p }
  await test('reinstall never publishes empty data, even after password/privacy preference edits', async () => {
    for (const changed of [false, true]) {
      const e = fresh()
      if (changed) e.service.markLocalChanged()
      e.service.setEnabled(true)
      for (const operation of [() => e.service.syncNow(e.context), () => e.service.upload(e.context)]) {
        const result = await complete(e, operation())
        assert.equal(result.success, false); assert.equal(result.pending, true)
        assert.equal(e.cloudSnapshots().length, 0)
        assert.equal(e.options.has('cloud-sync-last-applied-at'), false)
        assert.ok(e.logs.some(l => l.includes('empty_upload_blocked')))
      }
    }
  })
  await test('a late old cloud backup is restored after a protected empty first sync', async () => {
    const e = fresh()
    await complete(e, e.service.syncNow(e.context))
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 10000, ['old-peer']))))
    e.service.markLocalChanged() // Password/privacy edits must not win over the populated backup.
    const result = await complete(e, e.service.syncNow(e.context))
    assert.equal(result.restored, true); assert.equal(result.connectionCount, 1); assert.equal(result.groupCount, 1)
    assert.equal(e.cloudSnapshots().length, 0)
    assert.equal(JSON.parse(e.options.get('saved-connections'))[0].id, 'old-peer')
    assert.ok(result.message.includes('1'))
  })
  await test('existing empty latest backup is not falsely restored on a reinstalled device', async () => {
    const e = fresh()
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000))))
    const result = await complete(e, e.service.syncNow(e.context))
    assert.equal(result.success, false); assert.equal(result.restored, false)
    assert.equal(e.options.has('saved-connections'), false)
    assert.equal(e.options.has('cloud-sync-last-applied-at'), false)
  })
  await test('history preview is read-only, cancel preserves data, explicit older restore survives next sync', async () => {
    const e = fresh()
    const old = JSON.stringify(payload(e.clock.now - 10000, ['old-peer']))
    e.files.set(e.cloudPath, Buffer.from(old))
    const trace = new e.sandbox.CloudSyncTrace('upload')
    await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', JSON.stringify(payload(e.clock.now - 1000)), e.clock.now - 1000, trace, () => {})
    const snapshotCount = e.cloudSnapshots().length
    const history = await complete(e, e.service.listBackups(e.context))
    assert.deepEqual(Array.from(history.backups, b => b.connectionCount), [0, 1])
    let preview = await complete(e, e.service.previewRestore(e.context, 'legacy'))
    assert.equal(preview.preview.connectionCount, 1); assert.equal(e.options.has('saved-connections'), false)
    const paused = await e.service.upload(e.context)
    assert.equal(paused.pending, true); assert.equal(e.cloudSnapshots().length, snapshotCount)
    e.service.cancelRestorePreview()
    const cancelled = await complete(e, e.service.restore(e.context, preview.preview.ticket))
    assert.equal(cancelled.success, false); assert.equal(e.options.has('saved-connections'), false)
    preview = await complete(e, e.service.previewRestore(e.context, 'legacy'))
    const restored = await complete(e, e.service.restore(e.context, preview.preview.ticket))
    assert.equal(restored.restored, true); assert.equal(restored.connectionCount, 1)
    assert.equal(e.files.get(e.cloudPath).toString(), old, 'historical snapshot retained byte-for-byte')
    assert.equal(e.cloudSnapshots().length, snapshotCount)
    assert.ok(e.logs.every(l => !l.includes('PRIVATE_') && !l.includes('old-peer') && !l.includes('/cloud/')))
    assert.ok(e.logs.some(l => l.includes('restore_verified') && l.includes('connections=1')))
    const next = await complete(e, e.service.syncNow(e.context))
    assert.equal(next.uploaded, true)
    assert.equal(e.latestContent().connections.length, 1, 'history restore must not be undone by the empty latest cloud version')
  })
  await test('confirmed empty backup explicitly reports zero; intentional deletion continues to sync', async () => {
    const e = fresh()
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000))))
    const preview = await complete(e, e.service.previewRestore(e.context, 'legacy'))
    assert.equal(preview.preview.connectionCount, 0)
    const restored = await complete(e, e.service.restore(e.context, preview.preview.ticket))
    assert.equal(restored.restored, true); assert.equal(restored.connectionCount, 0)
    assert.ok(restored.message.includes('0'))
    assert.notEqual(restored.message, '已从华为云空间恢复')
    e.service.markLocalChanged()
    const result = await complete(e, e.service.syncNow(e.context))
    assert.equal(result.uploaded, true); assert.equal(e.latestContent().connections.length, 0)
  })
  await test('new local populated backup is allowed, first-sync conflicts require confirmation', async () => {
    const e = fresh()
    e.options.set('saved-connections', JSON.stringify(payload(e.clock.now, ['local']).connections))
    e.service.markLocalChanged()
    assert.equal((await complete(e, e.service.syncNow(e.context))).uploaded, true)
    assert.equal(e.options.get('cloud-sync-baseline-established'), '1')
    const f = fresh()
    const local = JSON.stringify(payload(f.clock.now, ['local']).connections)
    f.options.set('saved-connections', local); f.service.markLocalChanged()
    f.files.set(f.cloudPath, Buffer.from(JSON.stringify(payload(f.clock.now - 1000, ['remote']))))
    const result = await complete(f, f.service.syncNow(f.context))
    assert.equal(result.pending, true); assert.equal(f.options.get('saved-connections'), local)
    assert.equal(f.cloudSnapshots().length, 0)
  })
  await test('encrypted historical preview retains selection through password re-entry without dirtying data', async () => {
    const e = fresh({ encrypted: true, password: '' })
    const sealed = payload(e.clock.now - 1000, ['encrypted-peer']); sealed.includesPasswords = true
    sealed.connections[0].password = 'PRIVATE_PASSWORD'
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(sealed)))
    const history = await complete(e, e.service.listBackups(e.context))
    assert.equal(history.backups[0].encrypted, true); assert.equal(history.backups[0].connectionCount, -1)
    const required = await complete(e, e.service.previewRestore(e.context, 'legacy'))
    assert.equal(required.needsPassword, true); assert.equal(required.passwordAction, 'restore')
    await e.service.saveCloudPassword('TEST_PASSWORD')
    assert.equal(e.options.has('cloud-sync-local-changed-at'), false)
    const preview = await complete(e, e.service.previewRestore(e.context, 'legacy'))
    assert.equal(preview.preview.connectionCount, 1)
    const result = await complete(e, e.service.restore(e.context, preview.preview.ticket))
    assert.equal(result.restored, true)
    assert.ok(e.logs.every(l => !l.includes('PRIVATE_') && !l.includes('TEST_PASSWORD')))
  })
  await test('stale/cancelled previews, modified legacy data and refused writes never report restored', async () => {
    for (const mutation of ['local', 'cloud', 'disable', 'write']) {
      const e = fresh()
      e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000, ['old']))))
      const preview = await complete(e, e.service.previewRestore(e.context, 'legacy'))
      if (mutation === 'local') e.service.markLocalChanged()
      if (mutation === 'cloud') e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now, ['new']))))
      if (mutation === 'disable') e.service.setEnabled(false)
      if (mutation === 'write') e.config.ignoreWriteKey = 'saved-connections'
      const result = await complete(e, e.service.restore(e.context, preview.preview.ticket))
      assert.equal(result.restored, false, mutation); assert.equal(result.success, false, mutation)
      assert.equal(e.options.has('cloud-sync-last-success-at'), false, mutation)
      assert.equal(e.options.has('cloud-sync-last-applied-at'), false, mutation)
      e.service.cancelRestorePreview()
    }
    const e = fresh({ credentialSaveFailure: true, password: '' })
    await assert.rejects(() => e.service.saveCloudPassword('TEST_PASSWORD'))
  })
  await test('history is paginated; corrupt newest stays visible while explicit older selection is allowed', async () => {
    const e = fresh(), trace = new e.sandbox.CloudSyncTrace('history')
    for (let i = 0; i < 31; i++) {
      const time = e.clock.now - 1000 - i
      await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', JSON.stringify(payload(time, ['old'])), time, trace, () => {})
    }
    const latest = e.cloudSnapshots().at(-1)
    e.files.set(latest, Buffer.from('{'))
    const a = await complete(e, e.service.listBackups(e.context))
    assert.equal(a.backups.length, 30); assert.equal(a.hasMore, true)
    assert.equal(a.backups[0].readable, false); assert.equal(a.backups[1].readable, true)
    const b = await complete(e, e.service.listBackups(e.context, a.nextOffset))
    assert.equal(b.backups.length, 1); assert.equal(b.hasMore, false)
    const automatic = await complete(e, e.service.syncNow(e.context))
    assert.equal(automatic.success, false, 'no silent rollback past damaged latest snapshot')
    const preview = await complete(e, e.service.previewRestore(e.context, a.backups[1].id))
    assert.equal(preview.preview.connectionCount, 1)
    e.service.cancelRestorePreview()
    const error = await e.sandbox.CloudSyncSnapshotStore.readSelected('/cloud/StarRustDesk', e.cloudPath, '../outside', trace, () => 1).catch(x => x)
    assert.equal(error.code, -1005)
    assert.equal(e.cloudSnapshots().length, 31)
  })
  await test('malformed local connection/group data never becomes an uploaded empty backup', async () => {
    for (const key of ['saved-connections', 'saved-connection-groups']) {
      const e = environment(); e.options.set(key, '{')
      const result = await complete(e, e.service.syncNow(e.context))
      assert.equal(result.success, false); assert.equal(result.code, -1008)
      assert.equal(e.cloudSnapshots().length, 0)
    }
  })
  await test('late homepage loads cannot erase restored rows or clear them after an old error', async () => {
    for (const rejectOld of [false, true]) {
      const e = fresh()
      const page = source('pages/ConnectionPage.ets')
      const method = page.slice(page.indexOf('  async loadSavedConnections():'), page.indexOf('  persistSavedConnections('))
      const { Page } = e.load(`export class Page { ${method} }`, 'CloudHomepageLoad')
      e.sandbox.PerformanceSettings = { normalize: x => x }
      let resolveOld, reject
      const oldPassword = new Promise((ok, fail) => { resolveOld = ok; reject = fail })
      e.sandbox.CredentialStore.load = id => id === 'old' ? oldPassword : Promise.resolve('')
      const ui = new Page()
      Object.assign(ui, { savedConnectionsLoadGeneration: 0, savedConnectionsVersion: 0, normalizeRemoteId: x => x,
        cloneSavedConnections: x => x, validGroupId: x => x, refreshSavedConnectionOnlineStates() {},
        persistSavedConnections: rows => e.options.set('saved-connections', JSON.stringify(rows)) })
      e.options.set('saved-connections', JSON.stringify(payload(e.clock.now, ['old']).connections))
      const first = ui.loadSavedConnections()
      e.options.set('saved-connections', JSON.stringify(payload(e.clock.now, ['restored']).connections))
      await ui.loadSavedConnections()
      if (rejectOld) reject(new Error('old load failed')); else resolveOld('')
      await first
      assert.equal(ui.savedConnections[0].id, 'restored')
      assert.equal(JSON.parse(e.options.get('saved-connections'))[0].id, 'restored')
    }
  })
  await test('restore UI requires preview ticket and preserves the selected encrypted history ID', async () => {
    const settings = source('pages/SettingsPage.ets')
    assert.ok(settings.includes('this.loadCloudHistory(false)'))
    assert.ok(settings.includes('await this.previewCloudRestore(this.cloudRestoreSnapshotId)'))
    assert.ok(settings.includes('common.UIAbilityContext, this.cloudRestoreTicket)'))
    assert.ok(settings.includes('preview.connectionCount === 0'))
    assert.ok(settings.includes('CloudSyncService.cancelRestorePreview()'))
    assert.ok(settings.includes('!lastResult.success || lastResult.restored'))
  })
  await test('manual restore without confirmation ticket can only preview and never replaces local rows', async () => {
    const e = fresh()
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000, ['old']))))
    const result = await complete(e, e.service.restore(e.context))
    assert.equal(result.preview.connectionCount, 1); assert.equal(result.restored, false)
    assert.equal(e.options.has('saved-connections'), false)
    assert.equal(e.options.has('cloud-sync-last-success-at'), false)
    e.service.cancelRestorePreview()
  })
  await test('diagnostic fields are fixed numeric/boolean metadata; strings, unknown stages and non-finite values are dropped', async () => {
    const e = environment(), trace = new e.sandbox.CloudSyncTrace('sync')
    trace.event('cloud_open')
    trace.detail('result', { connections: 3, groups: 1, success: true, cloudTime: NaN, localRevision: Infinity,
      parentOpId: 'PRIVATE_TICKET', password: 'PRIVATE_PASSWORD', serverAddress: 'PRIVATE_SERVER',
      filename: '/PRIVATE_PATH', raw: 'PRIVATE_BACKUP', encrypted: 'PRIVATE_STRING' })
    trace.detail('PRIVATE_STAGE', { connections: 99 })
    assert.equal(trace.stage, 'cloud_open', 'details must not obscure the failure stage')
    const line = e.logs.find(l => l.includes('stage=result'))
    assert.ok(line.includes('connections=3') && line.includes('groups=1') && line.includes('success=1'))
    assert.ok(line.includes('operation_stage=cloud_open'))
    assert.ok(e.logs.every(l => !/PRIVATE_|NaN|Infinity/.test(l)))
  })
  await test('restore diagnostics identify decision, contents, readback counts, final result and homepage parent operation', async () => {
    const e = fresh()
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000, ['old']))))
    const result = await complete(e, e.service.syncNow(e.context))
    assert.equal(result.restored, true)
    for (const stage of ['request_state', 'inventory', 'selection_latest_v1', 'decision_restore_fresh',
      'backup_summary', 'restore_verify_info', 'restore_verified', 'result']) {
      assert.ok(e.logs.some(l => l.includes(`stage=${stage} `)), stage)
    }
    assert.ok(e.logs.some(l => /expected_connections=1 actual_connections=1/.test(l) && l.includes('verified=1')))
    assert.ok(e.logs.some(l => l.includes('stage=result ') && l.includes('restored=1') && l.includes('needs_password=0')))
    const parent = e.service.getLastRestoreOperationId()
    assert.ok(parent > 0)
    e.service.recordUi('home_reload_complete', { connections: 1, cloudRevision: 1, parentOpId: parent })
    assert.ok(e.logs.some(l => l.includes('stage=home_reload_complete ') && l.includes(`parent_op_id=${parent}`)))
    assert.ok(e.logs.every(l => !l.includes('PRIVATE_') && !l.includes('old') && !l.includes('/cloud/')))
  })
  await test('history diagnostics keep individual file failure codes and system completion evidence', async () => {
    const e = fresh(), trace = new e.sandbox.CloudSyncTrace('upload')
    const time = e.clock.now - 1000
    await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', JSON.stringify(payload(time, ['old'])), time, trace, () => {})
    e.files.set(e.cloudSnapshots()[0], Buffer.from('{'))
    const result = await complete(e, e.service.listBackups(e.context))
    assert.equal(result.success, true); assert.equal(result.backups[0].readable, false)
    assert.ok(e.logs.some(l => l.includes('stage=history_entry_error ') && l.includes('code=-1005')))
    assert.ok(e.logs.some(l => l.includes('stage=snapshot_format_invalid ') && l.includes('verified=0')))
    assert.ok(e.logs.some(l => l.includes('stage=history_page ') && l.includes('page_count=1')))
    assert.ok(e.logs.some(l => l.includes('stage=system_completed_progress ') && l.includes('active_seen=1')))
    assert.ok(e.logs.some(l => l.includes('stage=read_result ') && l.includes('expected_bytes=1') && l.includes('actual_bytes=1')))
  })
  await test('password/decryption failure logs code and password-required outcome, never raw exception or secrets', async () => {
    const e = fresh({ encrypted: true })
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000, ['old']))))
    e.sandbox.ConnectionBackupService.decrypt = async () => { throw { code: 17630001, message: 'PRIVATE_PASSWORD PRIVATE_TOKEN' } }
    const result = await complete(e, e.service.previewRestore(e.context, 'legacy'))
    assert.equal(result.needsPassword, true)
    assert.ok(e.logs.some(l => l.includes('stage=password_or_backup_invalid ') && l.includes('code=17630001')))
    assert.ok(e.logs.some(l => l.includes('stage=result ') && l.includes('needs_password=1')))
    assert.ok(e.logs.every(l => !l.includes('PRIVATE_') && !l.includes('TEST_PASSWORD')))
  })
  await test('diagnostic-off and logger exceptions cannot alter metadata-heavy restore or UI callbacks', async () => {
    for (const config of [{ options: { 'diagnostic-log-enabled': '0' } }, { logError: true }]) {
      const e = fresh(config)
      e.files.set(e.cloudPath, Buffer.from(JSON.stringify(payload(e.clock.now - 1000, ['old']))))
      const result = await complete(e, e.service.syncNow(e.context))
      e.service.recordUi('restore_confirmed', { connections: 1 })
      e.service.recordUi('home_reload_complete', { connections: 1 })
      assert.equal(result.restored, true); assert.equal(e.logs.length, 0)
    }
  })
  await test('joined requests and refused readback writes have actionable operation and mismatch diagnostics', async () => {
    const e = environment()
    const a = e.service.syncNow(e.context), b = e.service.upload(e.context)
    assert.equal(a, b); await complete(e, a)
    assert.ok(e.logs.some(l => l.includes('stage=request_joined ') && /parent_op_id=[1-9]/.test(l)))
    const f = fresh({ ignoreWriteKey: 'saved-connections' })
    f.files.set(f.cloudPath, Buffer.from(JSON.stringify(payload(f.clock.now - 1000, ['old']))))
    const result = await complete(f, f.service.syncNow(f.context))
    assert.equal(result.success, false); assert.equal(result.code, -1008)
    assert.ok(f.logs.some(l => l.includes('stage=restore_verify_info ') && l.includes('expected_connections=1') &&
      l.includes('actual_connections=-1') && l.includes('verified=0')))
  })
  await test('successful restore cleanup is not misreported as a user cancellation', async () => {
    const e = environment(), settings = source('pages/SettingsPage.ets')
    const method = settings.slice(settings.indexOf('  cancelCloudRestore('), settings.indexOf('  async loadCloudHistory('))
    const { Page } = e.load(`export class Page { ${method} }`, 'CloudRestoreCleanup')
    const ui = new Page()
    ui.cloudRestoreTicket = 'PRIVATE_TICKET'; ui.cloudRestoreSnapshotId = 'PRIVATE_SNAPSHOT'
    ui.cancelCloudRestore(false)
    assert.ok(!e.logs.some(l => l.includes('stage=restore_cancelled')))
    ui.cloudRestoreTicket = 'PRIVATE_TICKET'; ui.cancelCloudRestore()
    assert.ok(e.logs.some(l => l.includes('stage=restore_cancelled')))
    assert.ok(e.logs.every(l => !l.includes('PRIVATE_')))
  })
  console.log(`cloud-sync runtime: ${passed} scenario groups passed`)
})().catch(error => { console.error(error); process.exitCode = 1 })
