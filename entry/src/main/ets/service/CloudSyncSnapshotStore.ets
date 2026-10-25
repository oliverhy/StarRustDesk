import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { CloudSyncFailure, CloudSyncTrace } from './CloudSyncTask'

const SNAPSHOT_FORMAT: string = 'StarRustDeskCloudSnapshot'
const MAX_FILE_BYTES: number = 10 * 1024 * 1024
const SNAPSHOT_NAME: RegExp = /^cloud-sync-v2-([0-9]{13,16})-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.srdsync$/

interface CloudSnapshotEnvelope {
  format: string
  schemaVersion: number
  contentTime: number
  sha256: string
  content: string
}

export interface CloudSnapshotReference {
  id: string
  time: number
}

export interface CloudRetentionResult {
  deletedCount: number
  remainingCount: number
  code: number
}

// CloudDisk must not be treated as a local POSIX filesystem: replacing an
// existing name through rename can return EINVAL. Publish immutable snapshots
// under new UUID names. Retention is a separate operation after confirmed sync.
export class CloudSyncSnapshotStore {
  static readonly MAX_BACKUPS: number = 5
  static async readLatest(folder: string, legacyPath: string, trace: CloudSyncTrace,
    readTime: (raw: string) => number): Promise<string | undefined> {
    trace.event('cloud_list')
    const names = fileIo.listFileSync(folder, { recursion: false })
    let newestName = ''
    let newestTime = 0
    let matched = 0
    for (const name of names) {
      const match = SNAPSHOT_NAME.exec(name)
      if (match === null) continue // Ignore pending, unrelated files and subpaths.
      const time = Number(match[1])
      if (!Number.isSafeInteger(time) || time <= 0) continue
      matched++
      if (time > newestTime || (time === newestTime && name > newestName)) {
        newestName = name
        newestTime = time
      }
    }
    const legacyPresent = fileIo.accessSync(legacyPath)
    trace.detail('inventory', { backupCount: matched, ignoredCount: names.length - matched, legacyPresent: legacyPresent })

    let legacy: string | undefined = undefined
    if (legacyPresent) {
      legacy = CloudSyncSnapshotStore.readText(legacyPath, trace, 'cloud_read')
      // A still-used old app may have written a more recent v1 backup.
      if (newestName.length === 0 || readTime(legacy) > newestTime) {
        trace.detail('selection_latest_v1', { cloudTime: readTime(legacy), snapshotVersion: 1 })
        return legacy
      }
    }
    if (newestName.length === 0) return undefined
    trace.detail('selection_latest_v2', { cloudTime: newestTime, snapshotVersion: 2 })
    return CloudSyncSnapshotStore.readSelected(folder, legacyPath, newestName, trace, readTime)
  }

  static listCandidates(folder: string, legacyPath: string, trace: CloudSyncTrace,
    readTime: (raw: string) => number): CloudSnapshotReference[] {
    trace.event('cloud_list')
    const candidates: CloudSnapshotReference[] = []
    const names = fileIo.listFileSync(folder, { recursion: false })
    for (const name of names) {
      const match = SNAPSHOT_NAME.exec(name)
      if (match === null) continue
      const time = Number(match[1])
      if (Number.isSafeInteger(time) && time > 0) candidates.push({ id: name, time: time })
    }
    const legacyPresent = fileIo.accessSync(legacyPath)
    if (legacyPresent) {
      let time = 0
      try { time = readTime(CloudSyncSnapshotStore.readText(legacyPath, trace, 'cloud_read')) }
      catch (_error) {} // Keep an unreadable legacy entry visible; never use it silently.
      candidates.push({ id: 'legacy', time: time })
    }
    trace.detail('inventory', { backupCount: candidates.length, ignoredCount: names.length - candidates.length, legacyPresent: legacyPresent })
    return candidates.sort((a: CloudSnapshotReference, b: CloudSnapshotReference) =>
      b.time - a.time || b.id.localeCompare(a.id))
  }

  static async readSelected(folder: string, legacyPath: string, id: string, trace: CloudSyncTrace,
    readTime: (raw: string) => number): Promise<string> {
    if (id === 'legacy') {
      const content = CloudSyncSnapshotStore.readText(legacyPath, trace, 'cloud_read')
      if (readTime(content) <= 0) throw CloudSyncSnapshotStore.invalidSnapshot()
      return content
    }
    const match = SNAPSHOT_NAME.exec(id)
    // IDs are basenames, not caller-supplied filesystem paths.
    if (match === null || !Number.isSafeInteger(Number(match[1]))) throw CloudSyncSnapshotStore.invalidSnapshot()
    const raw = CloudSyncSnapshotStore.readText(`${folder}/${id}`, trace, 'cloud_read')
    trace.event('cloud_validate')
    let snapshot: CloudSnapshotEnvelope
    try { snapshot = JSON.parse(raw) as CloudSnapshotEnvelope }
    catch (_error) {
      trace.detail('snapshot_format_invalid', { verified: false }, -1005)
      throw CloudSyncSnapshotStore.invalidSnapshot()
    }
    if (snapshot === null || snapshot.format !== SNAPSHOT_FORMAT || snapshot.schemaVersion !== 2 ||
      snapshot.contentTime !== Number(match[1]) || typeof snapshot.content !== 'string' ||
      typeof snapshot.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(snapshot.sha256) ||
      readTime(snapshot.content) !== snapshot.contentTime) {
      trace.detail('snapshot_format_invalid', { verified: false }, -1005)
      throw CloudSyncSnapshotStore.invalidSnapshot()
    }
    if (await CloudSyncSnapshotStore.digest(snapshot.content) !== snapshot.sha256) {
      trace.detail('snapshot_digest_invalid', { verified: false }, -1005)
      throw CloudSyncSnapshotStore.invalidSnapshot()
    }
    trace.detail('snapshot_valid', { cloudTime: snapshot.contentTime, snapshotVersion: 2, verified: true })
    // Never fall back silently to older data if the newest published snapshot
    // is incomplete or corrupt: that could resurrect deleted connections.
    return snapshot.content
  }

  static async publish(folder: string, content: string, contentTime: number, trace: CloudSyncTrace,
    assertCurrent: () => void): Promise<string> {
    trace.event('cloud_digest')
    if (!Number.isSafeInteger(contentTime) || contentTime <= 0 ||
      new util.TextEncoder().encodeInto(content).byteLength > MAX_FILE_BYTES) {
      throw CloudSyncSnapshotStore.invalidSnapshot()
    }
    const envelope: CloudSnapshotEnvelope = {
      format: SNAPSHOT_FORMAT, schemaVersion: 2, contentTime: contentTime,
      sha256: await CloudSyncSnapshotStore.digest(content), content: content
    }
    assertCurrent()
    const serialized = JSON.stringify(envelope)
    const data = new util.TextEncoder().encodeInto(serialized)
    trace.detail('write_size', { expectedBytes: data.byteLength })
    if (data.byteLength > MAX_FILE_BYTES) throw CloudSyncSnapshotStore.invalidSnapshot()
    trace.event('cloud_allocate')
    let target = ''
    let temporary = ''
    for (let attempt = 0; attempt < 8; attempt++) {
      const name = `cloud-sync-v2-${contentTime}-${util.generateRandomUUID(true).toLowerCase()}.srdsync`
      if (!SNAPSHOT_NAME.test(name)) throw CloudSyncSnapshotStore.invalidSnapshot()
      const candidate = `${folder}/${name}`
      if (!fileIo.accessSync(candidate) && !fileIo.accessSync(`${candidate}.pending`)) {
        target = candidate
        temporary = `${candidate}.pending`
        break
      }
    }
    if (target.length === 0) throw new CloudSyncFailure(13900015, 'snapshot_collision', '无法创建独立云快照，原备份已保留，请重试')

    let file: fileIo.File | undefined = undefined
    let created = false
    try {
      trace.event('cloud_open')
      file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY)
      created = true
      trace.event('cloud_write_bytes')
      const written = fileIo.writeSync(file.fd, data.buffer)
      trace.detail('write_result', { expectedBytes: data.byteLength, actualBytes: written, verified: written === data.byteLength })
      if (written !== data.byteLength) throw new CloudSyncFailure(13900005, 'short_write', '云快照未完整写入，原备份已保留')
      trace.event('cloud_close')
      // Do not require disk fsync on the virtual cloud filesystem. Close and
      // read back locally, then let FileSync confirm the upload separately.
      fileIo.closeSync(file)
      file = undefined
      const verified = CloudSyncSnapshotStore.readText(temporary, trace, 'cloud_verify')
      trace.event('cloud_verify_content')
      if (verified !== serialized) throw new CloudSyncFailure(13900005, 'verify_write', '云快照写入校验失败，原备份已保留')
      assertCurrent()
      trace.event('cloud_publish')
      if (fileIo.accessSync(target)) throw new CloudSyncFailure(13900015, 'snapshot_collision', '云快照名称冲突，原备份已保留，请重试')
      fileIo.renameSync(temporary, target) // New name only; never replace v1 or another snapshot.
      created = false
      return target.substring(folder.length + 1)
    } finally {
      if (file !== undefined) CloudSyncSnapshotStore.cleanupClose(file, trace)
      if (created) {
        try {
          if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary)
          trace.event('cleanup_pending')
        } catch (error) { trace.event('cleanup_pending', CloudSyncFailure.from(error as Object).code) }
      }
    }
  }

  static async retainLatest(folder: string, legacyPath: string, trace: CloudSyncTrace,
    readTime: (raw: string) => number, assertCurrent: () => void,
    uploadedSnapshotId: string = ''): Promise<CloudRetentionResult> {
    assertCurrent()
    trace.event('retention_list')
    let candidates = CloudSyncSnapshotStore.listCandidates(folder, legacyPath, trace, readTime)
    const result: CloudRetentionResult = { deletedCount: 0, remainingCount: candidates.length, code: 0 }
    trace.detail('retention_inventory', { backupCount: candidates.length, retentionLimit: CloudSyncSnapshotStore.MAX_BACKUPS })
    if (candidates.length <= CloudSyncSnapshotStore.MAX_BACKUPS) return result
    const retained = candidates.slice(0, CloudSyncSnapshotStore.MAX_BACKUPS)
    // Clock skew or a concurrent writer must not make us delete this operation's
    // newly uploaded snapshot. Retry with a reconciled inventory instead.
    if (uploadedSnapshotId.length > 0 && !retained.some((item: CloudSnapshotReference) => item.id === uploadedSnapshotId)) {
      throw new CloudSyncFailure(-1011, 'retention_changed', '备份版本已变化，已暂停历史清理，请再次同步')
    }
    trace.event('retention_validate')
    for (const item of retained) {
      await CloudSyncSnapshotStore.readSelected(folder, legacyPath, item.id, trace, readTime)
      assertCurrent()
    }
    // Validate every retained snapshot BEFORE the first deletion. Only recognized
    // backup names are candidates; pending files, unrelated files and mirrors stay.
    const obsolete = candidates.slice(CloudSyncSnapshotStore.MAX_BACKUPS).reverse()
    for (const item of obsolete) {
      try {
        assertCurrent()
        const current = CloudSyncSnapshotStore.listCandidates(folder, legacyPath, trace, readTime)
        if (!CloudSyncSnapshotStore.sameInventory(candidates, current)) {
          throw new CloudSyncFailure(-1011, 'retention_changed', '备份版本已变化，已暂停历史清理，请再次同步')
        }
        trace.event('retention_delete')
        fileIo.unlinkSync(item.id === 'legacy' ? legacyPath : `${folder}/${item.id}`)
        result.deletedCount++
        candidates = candidates.filter((candidate: CloudSnapshotReference) => candidate.id !== item.id)
        result.remainingCount = candidates.length
      } catch (error) {
        result.code = CloudSyncFailure.from(error as Object).code || -1011
        trace.detail('retention_failed', { deletedCount: result.deletedCount,
          remainingCount: result.remainingCount, retentionLimit: CloudSyncSnapshotStore.MAX_BACKUPS }, result.code)
        break
      }
    }
    return result
  }

  private static sameInventory(left: CloudSnapshotReference[], right: CloudSnapshotReference[]): boolean {
    return left.length === right.length && left.every((item: CloudSnapshotReference, index: number) =>
      item.id === right[index].id && item.time === right[index].time)
  }

  private static async digest(content: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256')
    await md.update({ data: new util.TextEncoder().encodeInto(content) })
    const result = await md.digest()
    let hex = ''
    for (let i = 0; i < result.data.length; i++) hex += result.data[i].toString(16).padStart(2, '0')
    return hex
  }

  private static readText(path: string, trace: CloudSyncTrace, stage: 'cloud_read' | 'cloud_verify'): string {
    let file: fileIo.File | undefined = undefined
    try {
      trace.event(`${stage}_open`)
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
      trace.event(`${stage}_stat`)
      const size = fileIo.statSync(file.fd).size
      trace.detail('read_size', { expectedBytes: size })
      if (size <= 0 || size > MAX_FILE_BYTES) throw CloudSyncSnapshotStore.invalidSnapshot()
      const data = new ArrayBuffer(size)
      trace.event(`${stage}_bytes`)
      const read = fileIo.readSync(file.fd, data)
      trace.detail('read_result', { expectedBytes: size, actualBytes: read, verified: read === size })
      if (read !== size) {
        throw new CloudSyncFailure(13900005, 'short_read', '云快照未完整读取，请等待下载完成后重试；原备份已保留')
      }
      trace.event(`${stage}_close`)
      fileIo.closeSync(file)
      file = undefined
      return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(new Uint8Array(data), { stream: false })
    } finally {
      if (file !== undefined) CloudSyncSnapshotStore.cleanupClose(file, trace)
    }
  }

  private static cleanupClose(file: fileIo.File, trace: CloudSyncTrace): void {
    try { fileIo.closeSync(file); trace.event('cleanup_close') }
    catch (error) { trace.event('cleanup_close', CloudSyncFailure.from(error as Object).code) }
  }

  private static invalidSnapshot(): CloudSyncFailure {
    return new CloudSyncFailure(-1005, 'invalid_backup', '云备份不完整或校验失败，请稍后重试；已保留全部备份，本机配置未改动')
  }
}
