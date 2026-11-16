import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { CloudSyncFailure, CloudSyncTask, CloudSyncTrace, CloudSyncTraceDetails } from './CloudSyncTask'
import { OperationDiagnostic } from './OperationDiagnostic'
import { CloudSnapshotReference, CloudSyncSnapshotStore } from './CloudSyncSnapshotStore'
import { CREDENTIAL_ALIASES_OPTION, CredentialAliasEntry, CredentialStore } from './CredentialStore'
import {
  ConnectionBackupGroup,
  ConnectionBackupItem,
  ConnectionBackupPayload,
  ConnectionBackupServerConfig,
  ConnectionBackupService
} from './ConnectionBackupService'
import { RustDeskNapi } from './RustDeskNapi'

const CLOUD_SYNC_ENABLED_OPTION: string = 'cloud-sync-enabled'
const CLOUD_SYNC_SECRETS_OPTION: string = 'cloud-sync-include-secrets'
const CLOUD_SYNC_LOCAL_CHANGED_OPTION: string = 'cloud-sync-local-changed-at'
const CLOUD_SYNC_LAST_APPLIED_OPTION: string = 'cloud-sync-last-applied-at'
const CLOUD_SYNC_LAST_SUCCESS_OPTION: string = 'cloud-sync-last-success-at'
const CLOUD_SYNC_BASELINE_OPTION: string = 'cloud-sync-baseline-established'
const CLOUD_SYNC_PASSWORD_ID: string = '__cloud_sync_master_password__'
const CLOUD_FOLDER_NAME: string = 'StarRustDesk'
const CLOUD_FILE_NAME: string = 'cloud-sync-v1.srdsync'
const BACKUP_MIRROR_FOLDER: string = 'cloud_backup'
// Every value in this set is compared and committed under the native config
// lock. Credential assets are staged separately and referenced by the alias map.
const CLOUD_RESTORE_KEYS: string[] = ['saved-connections', 'saved-connection-groups', CREDENTIAL_ALIASES_OPTION,
  'custom-rendezvous-server', 'relay-server', 'api-server', 'key', CLOUD_SYNC_ENABLED_OPTION,
  CLOUD_SYNC_SECRETS_OPTION, CLOUD_SYNC_LAST_APPLIED_OPTION, CLOUD_SYNC_LOCAL_CHANGED_OPTION,
  CLOUD_SYNC_LAST_SUCCESS_OPTION, CLOUD_SYNC_BASELINE_OPTION]

interface SavedConnectionRow {
  id: string
  name: string
  remoteId: string
  credentialAlias: string
  performancePreset: string
  groupId: string
  serverScope?: string
}

interface SavedConnectionGroupRow {
  id: string
  name: string
  expanded: boolean
}

export interface CloudSyncResult {
  success: boolean
  restored: boolean
  uploaded: boolean
  needsPassword: boolean
  message: string
  syncTime: number
  pending?: boolean
  code?: number
  stage?: string
  passwordAction?: 'sync' | 'restore'
  backups?: CloudBackupSummary[]
  nextOffset?: number
  hasMore?: boolean
  preview?: CloudRestorePreview
  connectionCount?: number
  groupCount?: number
  notices?: string[]
}

export interface CloudBackupSummary {
  id: string
  time: number
  encrypted: boolean
  readable: boolean
  connectionCount: number
  groupCount: number
  serverConfigured: boolean
}

export interface CloudRestorePreview {
  ticket: string
  time: number
  connectionCount: number
  groupCount: number
  serverConfigured: boolean
  encrypted: boolean
  serverRestoreMode: string
  serverKeyIncluded: boolean
  serverEmptyFieldsKept: boolean
}

interface ServerRestorePlan {
  mode: string
  keyIncluded: boolean
  emptyFieldsKept: boolean
}

interface PreparedCloudRestore {
  ticket: string
  snapshotId: string
  raw: string
  payload: ConnectionBackupPayload
  epoch: number
  revision: number
  baseline: string[]
  credentialVersion: number
}

type CloudAction = 'sync' | 'upload' | 'restore' | 'history' | 'preview'
interface CloudOperationState { uploadedSnapshotId: string }
export type CloudSyncUiEvent = 'history_open' | 'history_close' | 'restore_confirmed' | 'restore_cancelled' |
  'password_save_requested' | 'password_save_verified' | 'password_save_failed' | 'local_changed' |
  'home_reload_start' | 'home_reload_empty' | 'home_reload_complete' | 'home_reload_stale' | 'home_reload_failed'

export class CloudSyncService {
  private static inFlight: Promise<CloudSyncResult> | undefined = undefined
  private static inFlightAction: string = ''
  private static epoch: number = 0
  private static localRevision: number = 0
  private static lastResult: CloudSyncResult | undefined = undefined
  private static preparedRestore: PreparedCloudRestore | undefined = undefined
  private static inFlightOperationId: number = 0
  private static lastRestoreOperationId: number = 0

  static getLastRestoreOperationId(): number { return CloudSyncService.lastRestoreOperationId }

  static recordUi(stage: CloudSyncUiEvent, details: CloudSyncTraceDetails = {}, error?: Object): void {
    try {
      if (RustDeskNapi.getOption('diagnostic-log-enabled') !== '1') return
      new CloudSyncTrace('ui', false).detail(stage, details, error === undefined ? 0 : OperationDiagnostic.errorCode(error))
    } catch (_error) {} // Diagnostics must never affect saving, restoring or UI refresh.
  }

  private static logLocalState(trace: CloudSyncTrace): void {
    try {
      if (RustDeskNapi.getOption('diagnostic-log-enabled') !== '1') return
      trace.detail('request_state', { enabled: CloudSyncService.isEnabled(), baselineReady: CloudSyncService.hasBaseline(),
        encrypted: CloudSyncService.includesSecrets(), localRevision: CloudSyncService.localRevision,
        localChangedAt: CloudSyncService.readTimestamp(CLOUD_SYNC_LOCAL_CHANGED_OPTION),
        lastAppliedAt: CloudSyncService.readTimestamp(CLOUD_SYNC_LAST_APPLIED_OPTION) })
    } catch (_error) {}
  }

  static isEnabled(): boolean {
    try {
      return RustDeskNapi.getOption(CLOUD_SYNC_ENABLED_OPTION) === '1'
    } catch (_error) {
      return false
    }
  }

  static setEnabled(enabled: boolean): void {
    CloudSyncService.epoch++
    CloudSyncService.cancelRestorePreview()
    CloudSyncService.lastResult = undefined
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_ENABLED_OPTION, enabled ? '1' : '0')
    } catch (_error) {
    }
  }

  static includesSecrets(): boolean {
    try {
      return RustDeskNapi.getOption(CLOUD_SYNC_SECRETS_OPTION) === '1'
    } catch (_error) {
      return false
    }
  }

  static setIncludesSecrets(enabled: boolean): void {
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_SECRETS_OPTION, enabled ? '1' : '0')
      CloudSyncService.markLocalChanged()
    } catch (_error) {
    }
  }

  static markLocalChanged(): void {
    CloudSyncService.localRevision++
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, Date.now().toString())
      CloudSyncService.recordUi('local_changed', { localRevision: CloudSyncService.localRevision,
        localChangedAt: CloudSyncService.readTimestamp(CLOUD_SYNC_LOCAL_CHANGED_OPTION) })
    } catch (_error) {
    }
  }

  static getLastSuccessTime(): number {
    return CloudSyncService.readTimestamp(CLOUD_SYNC_LAST_SUCCESS_OPTION)
  }

  static getLastResult(): CloudSyncResult | undefined { return CloudSyncService.lastResult }

  static async hasCloudPassword(): Promise<boolean> {
    return (await CredentialStore.loadStrict(CLOUD_SYNC_PASSWORD_ID)).length >= 8
  }

  static async saveCloudPassword(password: string): Promise<void> {
    if (password.length < 8) {
      throw new Error('备份密码至少需要 8 位')
    }
    CloudSyncService.recordUi('password_save_requested')
    try {
      await CredentialStore.save(CLOUD_SYNC_PASSWORD_ID, password)
      if (await CredentialStore.loadStrict(CLOUD_SYNC_PASSWORD_ID) !== password) {
        throw new Error('备份密码保存失败')
      }
      CloudSyncService.recordUi('password_save_verified', { verified: true })
    } catch (error) {
      CloudSyncService.recordUi('password_save_failed', { verified: false }, error as Object)
      throw error as Error
    }
    // Supplying the decryption password is not an edit to the connection data.
    // In particular, it must not make a reinstalled empty device "newer".
  }

  static async clearCloudPassword(): Promise<void> {
    await CredentialStore.remove(CLOUD_SYNC_PASSWORD_ID)
  }

  static syncNow(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    return CloudSyncService.run(context, 'sync')
  }

  static upload(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    // Background uploads reconcile first too, so a stale local snapshot cannot
    // overwrite a newer backup from another device.
    return CloudSyncService.run(context, 'upload')
  }

  static restore(context: common.UIAbilityContext, ticket: string = ''): Promise<CloudSyncResult> {
    // Manual restore is always a two-step operation; callers without a
    // confirmation ticket only receive a preview, never replacement writes.
    return ticket.length > 0 ? CloudSyncService.run(context, 'restore', ticket) : CloudSyncService.previewRestore(context)
  }

  static listBackups(context: common.UIAbilityContext, offset: number = 0): Promise<CloudSyncResult> {
    return CloudSyncService.run(context, 'history', Math.max(0, Math.floor(offset)).toString())
  }

  static previewRestore(context: common.UIAbilityContext, snapshotId: string = ''): Promise<CloudSyncResult> {
    return CloudSyncService.run(context, 'preview', snapshotId)
  }

  static cancelRestorePreview(): void { CloudSyncService.preparedRestore = undefined }

  private static run(context: common.UIAbilityContext, action: CloudAction,
    selection: string = ''): Promise<CloudSyncResult> {
    const trace = new CloudSyncTrace(action)
    CloudSyncService.logLocalState(trace)
    if (!CloudSyncService.isEnabled()) {
      trace.detail('request_disabled', { enabled: false, success: false })
      return Promise.resolve(CloudSyncService.result(false, false, false, false, '云同步未开启', 0))
    }
    const actionKey = action === 'sync' || action === 'upload' ? 'sync' : `${action}:${selection}`
    if (CloudSyncService.preparedRestore !== undefined && (action === 'sync' || action === 'upload')) {
      trace.detail('request_waiting_confirmation', { pending: true }, -1006)
      return Promise.resolve(CloudSyncService.paused('正在确认云备份，请先完成或取消恢复'))
    }
    if (CloudSyncService.inFlight !== undefined) {
      if (actionKey !== CloudSyncService.inFlightAction) {
        trace.event('busy')
        const busy = CloudSyncService.result(false, false, false, false, '其他云同步任务正在进行，请完成后再试', 0)
        busy.pending = true
        return Promise.resolve(busy)
      }
      trace.event('coalesced')
      trace.detail('request_joined', { parentOpId: CloudSyncService.inFlightOperationId })
      return CloudSyncService.inFlight
    }
    const epoch = CloudSyncService.epoch
    const revision = CloudSyncService.localRevision
    CloudSyncService.inFlightAction = actionKey
    CloudSyncService.inFlightOperationId = trace.id
    const state: CloudOperationState = { uploadedSnapshotId: '' }
    const operation = CloudSyncService.perform(context, action, selection, trace, epoch, revision, state)
      .then(async (result: CloudSyncResult): Promise<CloudSyncResult> => {
        if (result.success && (action === 'sync' || action === 'upload')) {
          result = await CloudSyncService.enforceBackupLimit(context, result, trace, epoch, revision, state.uploadedSnapshotId)
        }
        trace.detail('result', { success: result.success, restored: result.restored, uploaded: result.uploaded,
          needsPassword: result.needsPassword, pending: result.pending ?? false, connections: result.connectionCount,
          groups: result.groupCount }, result.code ?? 0)
        trace.event(result.success ? 'success' : (result.pending ? 'pending' : 'failed'), result.code ?? 0)
        if (epoch === CloudSyncService.epoch && !['history', 'preview'].includes(action)) CloudSyncService.lastResult = result
        return result
      }).finally(() => {
        CloudSyncService.inFlight = undefined
        CloudSyncService.inFlightAction = ''
        CloudSyncService.inFlightOperationId = 0
      })
    CloudSyncService.inFlight = operation
    return operation
  }

  private static assertCurrent(epoch: number, revision?: number): void {
    if (!CloudSyncService.isEnabled() || epoch !== CloudSyncService.epoch) {
      throw new CloudSyncFailure(-1002, 'cancelled', '云同步设置已改变，本次结果不再应用')
    }
    if (revision !== undefined && revision !== CloudSyncService.localRevision) {
      throw new CloudSyncFailure(-1004, 'local_changed', '本机配置在同步期间已修改，已保留修改，请再次同步')
    }
  }

  private static async waitForSystem(trace: CloudSyncTrace, epoch: number): Promise<void> {
    CloudSyncService.assertCurrent(epoch)
    await CloudSyncTask.wait(trace, () => !CloudSyncService.isEnabled() || epoch !== CloudSyncService.epoch)
    CloudSyncService.assertCurrent(epoch)
  }

  private static async perform(context: common.UIAbilityContext, action: CloudAction, selection: string, trace: CloudSyncTrace,
    epoch: number, revision: number, state: CloudOperationState): Promise<CloudSyncResult> {
    try {
      CloudSyncService.ensureFolders(context, trace)
      trace.event('preflight')
      await CloudSyncService.waitForSystem(trace, epoch)
      CloudSyncService.assertCurrent(epoch, revision)
      if (action === 'history') return await CloudSyncService.readHistory(context, trace, epoch, revision, Number(selection))
      if (action === 'preview') return await CloudSyncService.prepareRestore(context, selection, trace, epoch, revision)
      if (action === 'restore' && selection.length > 0) {
        const prepared = CloudSyncService.preparedRestore
        if (prepared === undefined || prepared.ticket !== selection || prepared.epoch !== epoch || prepared.revision !== revision) {
          trace.detail('preview_expired', { localRevision: revision }, -1004)
          throw new CloudSyncFailure(-1004, 'stale_preview', '恢复预览已过期或本机已修改，请重新选择备份')
        }
        const raw = await CloudSyncSnapshotStore.readSelected(`${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`,
          CloudSyncService.cloudPath(context), prepared.snapshotId, trace, (content: string) => CloudSyncService.readContentTime(content))
        CloudSyncService.assertCurrent(epoch, revision)
        if (CloudSyncService.preparedRestore !== prepared || raw !== prepared.raw) {
          trace.detail('preview_changed', { cloudTime: CloudSyncService.payloadTime(prepared.payload) }, -1004)
          throw new CloudSyncFailure(-1004, 'stale_preview', '备份已更新或恢复已取消，请重新预览')
        }
        const result = await CloudSyncService.applyPayload(context, raw, prepared.payload, trace, epoch, revision, true,
          prepared.baseline, prepared.credentialVersion)
        CloudSyncService.cancelRestorePreview()
        return result
      }
      trace.event('cloud_probe')
      const raw = await CloudSyncSnapshotStore.readLatest(`${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`,
        CloudSyncService.cloudPath(context), trace, (content: string) => CloudSyncService.readContentTime(content))
      CloudSyncService.assertCurrent(epoch, revision)
      if (raw === undefined) {
        trace.detail('decision_no_cloud', { backupCount: 0 })
        if (action === 'restore') return CloudSyncService.result(false, false, false, false, '云端暂无 芝麻远控 备份，本机数据未改动', 0)
        if (!CloudSyncService.hasBaseline() && !CloudSyncService.hasLocalContent()) {
          trace.event('empty_upload_blocked')
          return CloudSyncService.paused('本机暂无数据，已暂停上传空备份；请稍后重试或查看历史备份')
        }
        return await CloudSyncService.uploadSnapshot(context, trace, epoch, revision, state)
      }
      trace.event('cloud_parse')
      let cloudTime: number = CloudSyncService.readContentTime(raw)
      if (cloudTime <= 0) {
        throw new CloudSyncFailure(-1005, 'invalid_backup', '云端备份格式异常，已保留原文件，未进行覆盖')
      }
      let localChanged: number = CloudSyncService.readTimestamp(CLOUD_SYNC_LOCAL_CHANGED_OPTION)
      if (action !== 'restore' && !CloudSyncService.hasBaseline()) {
        if (CloudSyncService.hasLocalContent() && localChanged > 0) {
          trace.detail('decision_initial_conflict', { cloudTime: cloudTime, localChangedAt: localChanged, baselineReady: false })
          return CloudSyncService.paused('首次同步存在本机和云端数据，请从云端恢复确认，避免覆盖')
        }
        trace.detail('decision_restore_fresh', { cloudTime: cloudTime, localChangedAt: localChanged, baselineReady: false })
        return await CloudSyncService.applyCloudContent(context, raw, trace, epoch, revision)
      }
      if (action === 'restore' || cloudTime > localChanged) {
        trace.detail('decision_restore_cloud_newer', { cloudTime: cloudTime, localChangedAt: localChanged })
        return await CloudSyncService.applyCloudContent(context, raw, trace, epoch, revision)
      }
      if (localChanged > cloudTime) {
        trace.detail('decision_upload_local_newer', { cloudTime: cloudTime, localChangedAt: localChanged })
        return await CloudSyncService.uploadSnapshot(context, trace, epoch, revision, state)
      }
      let syncTime: number = Date.now()
      trace.detail('decision_no_change', { cloudTime: cloudTime, localChangedAt: localChanged })
      RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, syncTime.toString())
      return CloudSyncService.result(true, false, false, false, '云端与本机已是最新', syncTime)
    } catch (error) {
      const failure = CloudSyncFailure.from(error as Object)
      if (failure.code === -1010) return CloudSyncService.passwordRequired(failure.message, 'restore')
      const result = CloudSyncService.result(false, false, false, false,
        `${failure.message}（错误码 ${failure.code}）`, 0)
      result.pending = [-1001, -1002, -1003, -1004, -1012].includes(failure.code)
      result.code = failure.code
      result.stage = trace.stage
      return result
    }
  }

  private static hasBaseline(): boolean {
    return RustDeskNapi.getOption(CLOUD_SYNC_BASELINE_OPTION) === '1' ||
      CloudSyncService.readTimestamp(CLOUD_SYNC_LAST_APPLIED_OPTION) > 0
  }

  private static hasLocalContent(): boolean {
    return CloudSyncService.readConnections().length > 0 || CloudSyncService.readGroups().length > 0 ||
      ['custom-rendezvous-server', 'relay-server', 'api-server'].some((key: string) => RustDeskNapi.getOption(key).trim().length > 0)
  }

  private static paused(message: string): CloudSyncResult {
    const result = CloudSyncService.result(false, false, false, false, message, 0)
    result.pending = true
    result.code = -1006
    return result
  }

  private static async readHistory(context: common.UIAbilityContext, trace: CloudSyncTrace,
    epoch: number, revision: number, offset: number): Promise<CloudSyncResult> {
    const folder = `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`
    const candidates = CloudSyncSnapshotStore.listCandidates(folder, CloudSyncService.cloudPath(context), trace,
      (raw: string) => CloudSyncService.readContentTime(raw))
    const backups: CloudBackupSummary[] = []
    const start = Number.isSafeInteger(offset) && offset >= 0 ? offset : 0
    for (const candidate of candidates.slice(start, start + 30)) {
      CloudSyncService.assertCurrent(epoch, revision)
      const summary: CloudBackupSummary = { id: candidate.id, time: candidate.time, encrypted: false,
        readable: false, connectionCount: -1, groupCount: -1, serverConfigured: false }
      try {
        const raw = await CloudSyncSnapshotStore.readSelected(folder, CloudSyncService.cloudPath(context), candidate.id,
          trace, (content: string) => CloudSyncService.readContentTime(content))
        summary.encrypted = ConnectionBackupService.isEncrypted(raw)
        if (!summary.encrypted) {
          const payload = ConnectionBackupService.parsePlainText(raw)
          summary.connectionCount = payload.connections.length
          summary.groupCount = payload.groups.length
          summary.serverConfigured = CloudSyncService.hasServerConfig(payload)
        }
        summary.readable = true
      } catch (error) {
        trace.detail('history_entry_error', { cloudTime: candidate.time, verified: false }, CloudSyncFailure.from(error as Object).code)
        trace.event('history_entry_invalid')
      }
      backups.push(summary)
    }
    CloudSyncService.assertCurrent(epoch, revision)
    const result = CloudSyncService.result(true, false, false, false,
      backups.length > 0 ? '请选择要恢复的云备份' : '云端暂无 芝麻远控 备份，本机数据未改动', 0)
    result.backups = backups
    result.nextOffset = start + backups.length
    result.hasMore = result.nextOffset < candidates.length
    trace.detail('history_page', { offset: start, pageCount: backups.length, backupCount: candidates.length, hasMore: result.hasMore })
    return result
  }

  private static async prepareRestore(context: common.UIAbilityContext, snapshotId: string, trace: CloudSyncTrace,
    epoch: number, revision: number): Promise<CloudSyncResult> {
    CloudSyncService.cancelRestorePreview()
    const folder = `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`
    const candidates = CloudSyncSnapshotStore.listCandidates(folder, CloudSyncService.cloudPath(context), trace,
      (raw: string) => CloudSyncService.readContentTime(raw))
    const id = snapshotId.length > 0 ? snapshotId : (candidates[0]?.id ?? '')
    const selectedIndex = candidates.findIndex((candidate: CloudSnapshotReference) => candidate.id === id)
    trace.detail('selection_history', { selectedIndex: selectedIndex, backupCount: candidates.length,
      cloudTime: selectedIndex >= 0 ? candidates[selectedIndex].time : 0 })
    if (!candidates.some((candidate: CloudSnapshotReference) => candidate.id === id)) {
      return CloudSyncService.result(false, false, false, false, '所选云备份不可用，请刷新列表后重试', 0)
    }
    const raw = await CloudSyncSnapshotStore.readSelected(folder, CloudSyncService.cloudPath(context), id, trace,
      (content: string) => CloudSyncService.readContentTime(content))
    const payload = await CloudSyncService.decodeBackup(raw, trace)
    CloudSyncService.assertCurrent(epoch, revision)
    const credentialVersion = CredentialStore.stableMutationVersion()
    if (credentialVersion < 0) throw new CloudSyncFailure(-1004, 'local_changed', '本机密码正在修改，请稍后重新预览')
    const baseline = CLOUD_RESTORE_KEYS.map((key: string): string => RustDeskNapi.getOption(key))
    const ticket = util.generateRandomUUID(true)
    CloudSyncService.preparedRestore = { ticket: ticket, snapshotId: id, raw: raw, payload: payload, epoch: epoch,
      revision: revision, baseline: baseline, credentialVersion: credentialVersion }
    trace.counts('restore_preview', payload.connections.length, payload.groups.length)
    const result = CloudSyncService.result(true, false, false, false, '请核对备份内容后确认恢复', 0)
    const serverPlan = CloudSyncService.serverRestorePlan(payload,
      baseline[CLOUD_RESTORE_KEYS.indexOf('custom-rendezvous-server')], baseline[CLOUD_RESTORE_KEYS.indexOf('key')],
      baseline[CLOUD_RESTORE_KEYS.indexOf('relay-server')], baseline[CLOUD_RESTORE_KEYS.indexOf('api-server')])
    result.preview = { ticket: ticket, time: CloudSyncService.payloadTime(payload),
      connectionCount: payload.connections.length, groupCount: payload.groups.length,
      serverConfigured: CloudSyncService.hasServerConfig(payload), encrypted: ConnectionBackupService.isEncrypted(raw),
      serverRestoreMode: serverPlan.mode, serverKeyIncluded: serverPlan.keyIncluded,
      serverEmptyFieldsKept: serverPlan.emptyFieldsKept }
    trace.detail('restore_server_plan', { serverConfigured: CloudSyncService.hasServerConfig(payload),
      serverWillRestore: serverPlan.mode === 'restore', serverKeyIncluded: serverPlan.keyIncluded,
      serverKeyConflict: serverPlan.mode === 'preserve_key_conflict', serverEmptyFieldsKept: serverPlan.emptyFieldsKept })
    return result
  }

  private static hasServerConfig(payload: ConnectionBackupPayload): boolean {
    const config = payload.serverConfig
    return config !== undefined && [config.idServer, config.relayServer, config.apiServer].some((value: string) => value.trim().length > 0)
  }

  private static serverRestorePlan(payload: ConnectionBackupPayload, localId: string, localKey: string,
    localRelay: string, localApi: string): ServerRestorePlan {
    const config = payload.serverConfig
    if (config === undefined || !CloudSyncService.hasServerConfig(payload)) {
      return { mode: 'preserve_empty', keyIncluded: false, emptyFieldsKept: true }
    }
    const keyIncluded = payload.includesPasswords && config.serverKey.trim().length > 0
    // A retained local key must never silently become attached to a different
    // ID server when the selected backup did not include that server's key.
    const unknownIdAndDifferentEndpoint = config.idServer.trim().length === 0 && localId.trim().length === 0 &&
      (config.relayServer.trim() !== localRelay.trim() || config.apiServer.trim() !== localApi.trim())
    if (!keyIncluded && localKey.trim().length > 0 &&
      (config.idServer.trim() !== localId.trim() || unknownIdAndDifferentEndpoint)) {
      return { mode: 'preserve_key_conflict', keyIncluded: false, emptyFieldsKept: true }
    }
    const keepsAddress = (config.idServer.trim().length === 0 && localId.trim().length > 0) ||
      (config.relayServer.trim().length === 0 && localRelay.trim().length > 0) ||
      (config.apiServer.trim().length === 0 && localApi.trim().length > 0)
    // Do not splice settings from different/unknown server identities just to
    // retain blank fields. Keep the whole local configuration instead.
    if (keepsAddress && (config.idServer.trim() !== localId.trim() || unknownIdAndDifferentEndpoint)) {
      return { mode: 'preserve_partial_conflict', keyIncluded: keyIncluded, emptyFieldsKept: true }
    }
    return { mode: 'restore', keyIncluded: keyIncluded, emptyFieldsKept: keepsAddress }
  }

  private static async uploadSnapshot(context: common.UIAbilityContext, trace: CloudSyncTrace,
    epoch: number, revision: number, state: CloudOperationState): Promise<CloudSyncResult> {
    let includesSecrets: boolean = CloudSyncService.includesSecrets()
    const credentialVersion = includesSecrets ? CredentialStore.stableMutationVersion() : 0
    if (includesSecrets && credentialVersion < 0) {
      throw new CloudSyncFailure(-1004, 'local_changed', '本机密码正在修改，请稍后再次同步')
    }
    let password: string = ''
    if (includesSecrets) {
      trace.event('credential')
      password = await CredentialStore.loadStrict(CLOUD_SYNC_PASSWORD_ID)
      if (password.length < 8) {
        trace.detail('password_missing', { hasPassword: false }, -1010)
        return CloudSyncService.passwordRequired('请先设置至少 8 位的云备份密码', 'sync')
      }
    }
    trace.event('snapshot')
    let payload: ConnectionBackupPayload = await CloudSyncService.buildPayload(includesSecrets)
    if (includesSecrets && !CredentialStore.mutationVersionMatches(credentialVersion)) {
      throw new CloudSyncFailure(-1004, 'local_changed', '本机密码在备份期间已改变，请再次同步')
    }
    trace.detail('backup_summary', { cloudTime: CloudSyncService.payloadTime(payload), connections: payload.connections.length,
      groups: payload.groups.length, encrypted: includesSecrets, serverConfigured: CloudSyncService.hasServerConfig(payload) })
    trace.event('encrypt')
    let content: string = includesSecrets ? await ConnectionBackupService.encrypt(payload, password) :
      ConnectionBackupService.createPlainText(payload)
    trace.detail('encrypt_complete', { encrypted: includesSecrets })
    CloudSyncService.assertCurrent(epoch, revision)
    if (includesSecrets && !CredentialStore.mutationVersionMatches(credentialVersion)) {
      throw new CloudSyncFailure(-1004, 'local_changed', '本机密码在备份期间已改变，请再次同步')
    }
    trace.event('mirror_write')
    CloudSyncService.writeText(CloudSyncService.mirrorPath(context), content)
    trace.event('cloud_write')
    state.uploadedSnapshotId = await CloudSyncSnapshotStore.publish(`${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`, content,
      CloudSyncService.payloadTime(payload), trace, () => CloudSyncService.assertCurrent(epoch, revision))
    trace.event('upload_wait')
    await CloudSyncService.waitForSystem(trace, epoch)
    let contentTime: number = CloudSyncService.payloadTime(payload)
    let syncTime: number = Date.now()
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_APPLIED_OPTION, contentTime.toString())
    if (revision === CloudSyncService.localRevision) {
      RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, contentTime.toString())
    }
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, syncTime.toString())
    RustDeskNapi.setOption(CLOUD_SYNC_BASELINE_OPTION, '1')
    if (revision !== CloudSyncService.localRevision) {
      const pending = CloudSyncService.result(false, false, true, false, '本次快照已同步，但本机又有新修改待同步，请再次同步', syncTime)
      pending.pending = true
      return pending
    }
    return CloudSyncService.result(true, false, true, false, '已同步到华为云空间', syncTime)
  }

  private static async enforceBackupLimit(context: common.UIAbilityContext, result: CloudSyncResult,
    trace: CloudSyncTrace, epoch: number, revision: number, uploadedSnapshotId: string): Promise<CloudSyncResult> {
    try {
      const folder = `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`
      const legacyPath = CloudSyncService.cloudPath(context)
      const retention = await CloudSyncSnapshotStore.retainLatest(folder, legacyPath, trace,
        (raw: string) => CloudSyncService.readContentTime(raw), () => CloudSyncService.assertCurrent(epoch, revision), uploadedSnapshotId)
      if (retention.deletedCount > 0) {
        trace.event('retention_wait')
        await CloudSyncService.waitForSystem(trace, epoch)
      }
      CloudSyncService.assertCurrent(epoch, revision)
      if (retention.code !== 0) {
        throw new CloudSyncFailure(retention.code, 'retention_incomplete', '历史备份清理尚未完成')
      }
      const current = CloudSyncSnapshotStore.listCandidates(folder, legacyPath, trace,
        (raw: string) => CloudSyncService.readContentTime(raw))
      if (current.length > CloudSyncSnapshotStore.MAX_BACKUPS ||
        (uploadedSnapshotId.length > 0 && !current.some((item: CloudSnapshotReference) => item.id === uploadedSnapshotId))) {
        throw new CloudSyncFailure(-1011, 'retention_changed', '备份版本已变化，历史清理尚未完成')
      }
      trace.detail('retention_verified', { deletedCount: retention.deletedCount, remainingCount: current.length,
        retentionLimit: CloudSyncSnapshotStore.MAX_BACKUPS, verified: true })
      return result
    } catch (error) {
      const failure = CloudSyncFailure.from(error as Object)
      trace.detail('retention_failed', { verified: false, retentionLimit: CloudSyncSnapshotStore.MAX_BACKUPS }, failure.code)
      if (result.restored) {
        // Restore is already committed. A later cloud-history maintenance
        // failure must not claim that restoring local data was rolled back.
        result.pending = true
        result.code = failure.code || -1011
        result.stage = 'retention'
        const notices = result.notices ?? []
        notices.push('恢复已提交，但云端历史备份清理尚未完成')
        result.notices = notices
        return result
      }
      result.success = false
      result.pending = true
      result.code = failure.code || -1011
      result.stage = 'retention'
      result.message = `同步数据已处理，但历史备份清理尚未确认完成，请稍后再次同步（错误码 ${result.code}）`
      return result
    }
  }

  private static async buildPayload(includesSecrets: boolean): Promise<ConnectionBackupPayload> {
    let groups: ConnectionBackupGroup[] = []
    let groupRows: SavedConnectionGroupRow[] = CloudSyncService.readGroups()
    groupRows.forEach((row: SavedConnectionGroupRow) => {
      groups.push({ id: row.id, name: row.name })
    })

    let connections: ConnectionBackupItem[] = []
    let rows: SavedConnectionRow[] = CloudSyncService.readConnections()
    for (let row of rows) {
      let password: string = includesSecrets ? await CredentialStore.loadStrict(row.id) : ''
      connections.push({
        id: row.id,
        name: row.name,
        remoteId: row.remoteId,
        password: password,
        performancePreset: row.performancePreset,
        groupId: row.groupId,
        serverScope: row.serverScope
      })
    }
    let serverConfig: ConnectionBackupServerConfig = {
      idServer: RustDeskNapi.getOption('custom-rendezvous-server'),
      relayServer: RustDeskNapi.getOption('relay-server'),
      apiServer: RustDeskNapi.getOption('api-server'),
      serverKey: includesSecrets ? RustDeskNapi.getOption('key') : ''
    }
    return ConnectionBackupService.createPayload(groups, connections, includesSecrets, serverConfig)
  }

  private static async applyCloudContent(context: common.UIAbilityContext, raw: string, trace: CloudSyncTrace,
    epoch: number, revision: number): Promise<CloudSyncResult> {
    const payload = await CloudSyncService.decodeBackup(raw, trace)
    return CloudSyncService.applyPayload(context, raw, payload, trace, epoch, revision, false)
  }

  private static async decodeBackup(raw: string, trace: CloudSyncTrace): Promise<ConnectionBackupPayload> {
    let payload: ConnectionBackupPayload
    if (ConnectionBackupService.isEncrypted(raw)) {
      trace.detail('encrypted_backup_detected', { encrypted: true })
      trace.event('credential')
      let password: string = await CredentialStore.loadStrict(CLOUD_SYNC_PASSWORD_ID)
      if (password.length < 8) {
        trace.detail('password_missing', { hasPassword: false }, -1010)
        throw new CloudSyncFailure(-1010, 'password_required', '该云备份已加密，请输入备份密码')
      }
      try {
        trace.event('encrypt')
        payload = await ConnectionBackupService.decrypt(raw, password)
        trace.detail('decrypt_complete', { encrypted: true, verified: true, hasPassword: true })
      } catch (error) {
        trace.detail('password_or_backup_invalid', { encrypted: true, verified: false, hasPassword: true }, OperationDiagnostic.errorCode(error as Object))
        throw new CloudSyncFailure(-1010, 'password_required', '备份密码错误或云备份已损坏')
      }
    } else {
      payload = ConnectionBackupService.parsePlainText(raw)
    }
    trace.detail('backup_summary', { cloudTime: CloudSyncService.payloadTime(payload), connections: payload.connections.length,
      groups: payload.groups.length, encrypted: ConnectionBackupService.isEncrypted(raw), serverConfigured: CloudSyncService.hasServerConfig(payload) })
    return payload
  }

  private static async applyPayload(context: common.UIAbilityContext, raw: string, payload: ConnectionBackupPayload,
    trace: CloudSyncTrace, epoch: number, revision: number, confirmed: boolean,
    previewBaseline?: string[], previewCredentialVersion?: number): Promise<CloudSyncResult> {
    CloudSyncService.assertCurrent(epoch, revision)
    if (!confirmed && payload.connections.length === 0 && !CloudSyncService.hasBaseline()) {
      trace.event('empty_restore_blocked')
      return CloudSyncService.paused('最新云备份没有连接，未自动恢复；请查看历史备份')
    }
    const baseline = previewBaseline ?? CLOUD_RESTORE_KEYS.map((key: string): string => RustDeskNapi.getOption(key))
    const credentialVersion = previewCredentialVersion ?? CredentialStore.stableMutationVersion()
    if (!CredentialStore.mutationVersionMatches(credentialVersion)) {
      throw new CloudSyncFailure(-1004, 'local_changed', '本机密码已改变，请重新预览云备份')
    }
    // Fail before touching any credential if local persisted data is malformed.
    const oldRows = CloudSyncService.readConnections()
    CloudSyncService.readGroups()
    const originalAliases = CredentialStore.parseAliases(baseline[CLOUD_RESTORE_KEYS.indexOf(CREDENTIAL_ALIASES_OPTION)])
    let aliases: CredentialAliasEntry[] = originalAliases.slice()
    // A staged physical alias must not equal any old/new logical id,
    // even when that logical id currently has an empty password.
    const forbiddenAliases = originalAliases.map((entry: CredentialAliasEntry): string => entry.target)
      .concat(oldRows.map((row: SavedConnectionRow): string => row.id))
      .concat(payload.connections.map((row: ConnectionBackupItem): string => row.id))
    forbiddenAliases.push(CLOUD_SYNC_PASSWORD_ID)
    let aliasesChanged = false
    const staged: string[] = []
    const ids: Set<string> = new Set<string>()
    let committed = false
    let uncertainCommit = false
    let readbackVerified = false
    let newRows: SavedConnectionRow[] = []
    let groupRows: SavedConnectionGroupRow[] = []
    const plan = CloudSyncService.serverRestorePlan(payload,
      baseline[CLOUD_RESTORE_KEYS.indexOf('custom-rendezvous-server')], baseline[CLOUD_RESTORE_KEYS.indexOf('key')],
      baseline[CLOUD_RESTORE_KEYS.indexOf('relay-server')], baseline[CLOUD_RESTORE_KEYS.indexOf('api-server')])
    trace.detail('restore_server_plan', { serverConfigured: CloudSyncService.hasServerConfig(payload),
      serverWillRestore: plan.mode === 'restore', serverKeyIncluded: plan.keyIncluded,
      serverKeyConflict: plan.mode === 'preserve_key_conflict', serverEmptyFieldsKept: plan.emptyFieldsKept })
    if (plan.mode === 'preserve_key_conflict' || plan.mode === 'preserve_partial_conflict') {
      // Restoring connection passwords under a different, retained server may
      // associate legacy unscoped peer IDs with the wrong network. Fail closed.
      trace.detail('restore_aborted', { stagedCredentials: 0, verified: false }, -1008)
      throw new CloudSyncFailure(-1008, 'server_conflict', '备份服务器与本机不同且配置不完整，请先手动配置对应服务器后再恢复；本机数据未改动')
    }
    try {
      trace.event('restore_prepare')
      payload.groups.forEach((group: ConnectionBackupGroup) => {
        groupRows.push({ id: group.id, name: group.name, expanded: true })
      })
      for (let item of payload.connections) {
        CloudSyncService.assertCurrent(epoch, revision)
        if (!item.id || item.id === CLOUD_SYNC_PASSWORD_ID || !item.remoteId || ids.has(item.id)) {
          throw new CloudSyncFailure(-1008, 'invalid_backup', '备份中的连接标识无效或重复，本机数据未改动')
        }
        ids.add(item.id)
        const sameId = oldRows.find((row: SavedConnectionRow) => row.id === item.id)
        if (sameId !== undefined && (sameId.remoteId !== item.remoteId ||
          (sameId.serverScope !== undefined && item.serverScope !== undefined && sameId.serverScope !== item.serverScope))) {
          throw new CloudSyncFailure(-1008, 'identity_conflict', '备份连接与本机连接标识冲突，本机数据未改动')
        }
        newRows.push({ id: item.id, name: item.name, remoteId: item.remoteId, credentialAlias: item.id,
          performancePreset: item.performancePreset, groupId: item.groupId, serverScope: item.serverScope })
        let targetPassword: string | undefined = undefined
        if (payload.includesPasswords) {
          // Keep a matching existing asset, otherwise stage a new immutable alias.
          const currentPassword = sameId === undefined ? undefined :
            await CredentialStore.readPhysicalStrict(CredentialStore.physicalId(item.id, originalAliases))
          if (currentPassword === undefined || currentPassword !== item.password) targetPassword = item.password
        } else {
          const old = oldRows.find((value: SavedConnectionRow) => value.remoteId === item.remoteId &&
            (value.serverScope === undefined || item.serverScope === undefined || value.serverScope === item.serverScope))
          if (old !== undefined && old.id !== item.id) {
            targetPassword = await CredentialStore.readPhysicalStrict(CredentialStore.physicalId(old.id, originalAliases))
          } else if (old === undefined) {
            // An orphaned asset with a reused id must not leak into a new peer.
            const existing = await CredentialStore.readPhysicalStrict(CredentialStore.physicalId(item.id, originalAliases))
            if (existing.length > 0) targetPassword = ''
          }
        }
        if (targetPassword !== undefined) {
          trace.event('restore_stage_credentials')
          const target = await CredentialStore.stageRestorePassword(targetPassword, forbiddenAliases)
          staged.push(target)
          forbiddenAliases.push(target)
          aliases = aliases.filter((entry: CredentialAliasEntry) => entry.id !== item.id)
          aliases.push({ id: item.id, target: target })
          aliasesChanged = true
        }
      }
      CloudSyncService.assertCurrent(epoch, revision)
      if (!CredentialStore.mutationVersionMatches(credentialVersion)) {
        throw new CloudSyncFailure(-1004, 'local_changed', '本机密码已改变，请重新预览云备份')
      }
      const desired = baseline.slice()
      desired[CLOUD_RESTORE_KEYS.indexOf('saved-connections')] = JSON.stringify(newRows)
      desired[CLOUD_RESTORE_KEYS.indexOf('saved-connection-groups')] = JSON.stringify(groupRows)
      if (aliasesChanged) {
        const aliasJson = JSON.stringify(aliases)
        CredentialStore.parseAliases(aliasJson)
        desired[CLOUD_RESTORE_KEYS.indexOf(CREDENTIAL_ALIASES_OPTION)] = aliasJson
      }
      desired[CLOUD_RESTORE_KEYS.indexOf(CLOUD_SYNC_SECRETS_OPTION)] = payload.includesPasswords ? '1' : '0'
      if (plan.mode === 'restore' && payload.serverConfig !== undefined) {
        if (payload.serverConfig.idServer.trim().length > 0) {
          desired[CLOUD_RESTORE_KEYS.indexOf('custom-rendezvous-server')] = payload.serverConfig.idServer
        }
        if (payload.serverConfig.relayServer.trim().length > 0) {
          desired[CLOUD_RESTORE_KEYS.indexOf('relay-server')] = payload.serverConfig.relayServer
        }
        if (payload.serverConfig.apiServer.trim().length > 0) {
          desired[CLOUD_RESTORE_KEYS.indexOf('api-server')] = payload.serverConfig.apiServer
        }
        if (plan.keyIncluded) desired[CLOUD_RESTORE_KEYS.indexOf('key')] = payload.serverConfig.serverKey
      }
      let syncTime = CloudSyncService.payloadTime(payload)
      if (syncTime <= 0) syncTime = Date.now()
      desired[CLOUD_RESTORE_KEYS.indexOf(CLOUD_SYNC_LAST_APPLIED_OPTION)] = syncTime.toString()
      desired[CLOUD_RESTORE_KEYS.indexOf(CLOUD_SYNC_LOCAL_CHANGED_OPTION)] =
        (confirmed ? Math.max(Date.now(), syncTime + 1) : syncTime).toString()
      desired[CLOUD_RESTORE_KEYS.indexOf(CLOUD_SYNC_LAST_SUCCESS_OPTION)] = Date.now().toString()
      desired[CLOUD_RESTORE_KEYS.indexOf(CLOUD_SYNC_BASELINE_OPTION)] = '1'
      trace.event('restore_commit')
      let commit = -9
      try {
        const nativeResult = RustDeskNapi.commitCloudRestore(CLOUD_RESTORE_KEYS, baseline, desired)
        commit = [0, -1, -2, -3].includes(nativeResult) ? nativeResult : -9
      } catch (_error) {}
      if (commit !== 0) {
        trace.detail('restore_commit_failed', { stagedCredentials: staged.length, verified: false }, commit)
        // A bridge exception can make the return value uncertain even if the
        // native atomic rename completed. Never discard active staged assets.
        if (commit === -9) {
          uncertainCommit = true
          let desiredVisible = false
          let baselineVisible = false
          try {
            desiredVisible = CLOUD_RESTORE_KEYS.every((key: string, index: number): boolean => RustDeskNapi.getOption(key) === desired[index])
            baselineVisible = CLOUD_RESTORE_KEYS.every((key: string, index: number): boolean => RustDeskNapi.getOption(key) === baseline[index])
          } catch (_error) {}
          if (desiredVisible && !baselineVisible) {
            committed = true
            trace.detail('restore_commit_recovered', { verified: true, stagedCredentials: staged.length })
          } else if (!baselineVisible) {
            throw new CloudSyncFailure(-1012, 'restore_uncertain', '恢复结果无法确认，请勿重复恢复并导出诊断日志；原凭据已保留')
          }
        }
        if (!committed) {
          if (commit === -3) throw new CloudSyncFailure(-1004, 'local_changed', '本机数据已改变，请重新预览云备份')
          throw new CloudSyncFailure(-1008, 'restore_commit', '恢复未完成，本机原有数据已保留，请重试')
        }
      }
      committed = true
      trace.event('restore_verify')
      let verified = false
      let actualConnections = -1
      let actualGroups = -1
      try {
        actualConnections = CloudSyncService.arrayCount(RustDeskNapi.getOption('saved-connections'))
        actualGroups = CloudSyncService.arrayCount(RustDeskNapi.getOption('saved-connection-groups'))
        verified = CLOUD_RESTORE_KEYS.every((key: string, index: number): boolean => RustDeskNapi.getOption(key) === desired[index])
      } catch (_error) {}
      readbackVerified = verified
      trace.detail('restore_verify_info', { expectedConnections: newRows.length, actualConnections: actualConnections,
        expectedGroups: groupRows.length, actualGroups: actualGroups, verified: verified,
        stagedCredentials: staged.length, serverWillRestore: plan.mode === 'restore' })
      if (!verified) trace.detail('restore_readback_deferred', { verified: false })
    } catch (error) {
      trace.detail('restore_aborted', { stagedCredentials: staged.length, verified: false }, OperationDiagnostic.errorCode(error as Object))
      if (error instanceof CloudSyncFailure) throw error as CloudSyncFailure
      throw new CloudSyncFailure(-1008, 'restore_stage', '恢复准备失败，本机原有数据已保留，请重试')
    } finally {
      if (!committed && uncertainCommit) {
        trace.detail('restore_discard_deferred', { stagedCredentials: staged.length })
      } else if (!committed) {
        // Preserve staged assets if a bridge error makes the committed alias
        // map unreadable. They are encrypted system assets, never log values.
        try {
          const active = CredentialStore.parseAliases(RustDeskNapi.getOption(CREDENTIAL_ALIASES_OPTION))
          for (const target of staged) {
            if (!active.some((entry: CredentialAliasEntry): boolean => entry.target === target)) {
              await CredentialStore.discardStaged(target)
            }
          }
        } catch (_error) { trace.detail('restore_discard_deferred', { stagedCredentials: staged.length }) }
      }
    }
    // The native commit is the point of success. Ancillary mirror/UI failures
    // cannot be reported as a failed restore after data has already changed.
    let mirrorReady = true
    try { trace.event('mirror_restore_write'); CloudSyncService.writeText(CloudSyncService.mirrorPath(context), raw) }
    catch (error) { mirrorReady = false; trace.detail('restore_mirror_deferred', { verified: false }, OperationDiagnostic.errorCode(error as Object)) }
    let cloudRevision = 0
    if (plan.mode === 'restore') {
      try {
        let serverVersion: number = AppStorage.get<number>('serverConfigVersion') ?? 0
        AppStorage.set<number>('serverConfigVersion', serverVersion + 1)
      } catch (_error) { trace.detail('restore_ui_deferred', { verified: false }) }
    }
    CloudSyncService.lastRestoreOperationId = trace.id
    try {
      cloudRevision = AppStorage.get<number>('savedConnectionsCloudRevision') ?? 0
      AppStorage.set<number>('savedConnectionsCloudRevision', cloudRevision + 1)
    } catch (_error) { trace.detail('restore_ui_deferred', { verified: false }) }
    trace.detail('restore_committed', { connections: newRows.length, groups: groupRows.length,
      cloudRevision: cloudRevision + 1, verified: readbackVerified })
    if (readbackVerified) {
      trace.detail('restore_verified', { connections: newRows.length, groups: groupRows.length, cloudRevision: cloudRevision + 1 })
      trace.counts('restore_verified', newRows.length, groupRows.length)
    }
    const message = newRows.length === 0 ? `已恢复空连接备份（0 个连接、${groupRows.length} 个分组）` :
      `已恢复 ${newRows.length} 个连接、${groupRows.length} 个分组`
    const result = CloudSyncService.result(true, true, false, false, message, Date.now())
    result.connectionCount = newRows.length
    result.groupCount = groupRows.length
    const notices: string[] = []
    if (plan.mode === 'preserve_empty') notices.push('备份无服务器配置，已保留本机设置')
    else {
      if (!plan.keyIncluded) notices.push('备份未包含服务器 Key，已保留本机 Key')
      if (plan.emptyFieldsKept) notices.push('备份为空的服务器地址已保留本机值，需要清空请手动设置')
    }
    if (!mirrorReady) notices.push('恢复已提交，但本机备份副本未更新')
    if (!readbackVerified) notices.push('恢复已提交但读取校验未完成，请勿重复恢复并导出诊断日志')
    result.notices = notices
    return result
  }

  private static readConnections(): SavedConnectionRow[] {
    try {
      let raw: string = RustDeskNapi.getOption('saved-connections')
      const rows: SavedConnectionRow[] = raw.length > 0 ? JSON.parse(raw) as SavedConnectionRow[] : []
      if (!Array.isArray(rows)) throw new Error('invalid')
      return rows
    } catch (_error) {
      throw new CloudSyncFailure(-1008, 'local_data', '本机连接数据无法读取，已暂停同步，避免上传空备份')
    }
  }

  private static arrayCount(raw: string): number {
    try {
      const rows: Object = JSON.parse(raw) as Object
      return Array.isArray(rows) ? (rows as Object[]).length : -1
    } catch (_error) { return -1 }
  }

  private static readGroups(): SavedConnectionGroupRow[] {
    try {
      let raw: string = RustDeskNapi.getOption('saved-connection-groups')
      const rows: SavedConnectionGroupRow[] = raw.length > 0 ? JSON.parse(raw) as SavedConnectionGroupRow[] : []
      if (!Array.isArray(rows)) throw new Error('invalid')
      return rows
    } catch (_error) {
      throw new CloudSyncFailure(-1008, 'local_data', '本机分组数据无法读取，已暂停同步，避免上传空备份')
    }
  }

  private static readContentTime(raw: string): number {
    try {
      if (ConnectionBackupService.isEncrypted(raw)) {
        interface EnvelopeTime { exportedAt: string }
        let envelope: EnvelopeTime = JSON.parse(raw) as EnvelopeTime
        const time = Date.parse(envelope.exportedAt)
        return Number.isFinite(time) ? time : 0
      }
      return CloudSyncService.payloadTime(ConnectionBackupService.parsePlainText(raw))
    } catch (_error) {
      return 0
    }
  }

  private static payloadTime(payload: ConnectionBackupPayload): number {
    let value: number = Date.parse(payload.exportedAt)
    return Number.isNaN(value) ? 0 : value
  }

  private static readTimestamp(option: string): number {
    try {
      let value: number = parseInt(RustDeskNapi.getOption(option))
      return Number.isNaN(value) ? 0 : value
    } catch (_error) {
      return 0
    }
  }

  private static ensureFolders(context: common.UIAbilityContext, trace: CloudSyncTrace): void {
    trace.event('cloud_directory')
    if (!context.cloudFileDir || !context.cloudFileDir.startsWith('/')) {
      throw new CloudSyncFailure(22400001, 'cloud_not_ready', '系统尚未提供云同步目录；若 芝麻远控 专用开关已开启，请稍后重试')
    }
    let cloudFolder: string = `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`
    let mirrorFolder: string = `${context.filesDir}/${BACKUP_MIRROR_FOLDER}`
    if (!fileIo.accessSync(cloudFolder)) {
      fileIo.mkdirSync(cloudFolder, true)
    }
    trace.event('mirror_directory')
    if (!fileIo.accessSync(mirrorFolder)) {
      fileIo.mkdirSync(mirrorFolder, true)
    }
  }

  private static cloudPath(context: common.UIAbilityContext): string {
    return `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}/${CLOUD_FILE_NAME}`
  }

  private static mirrorPath(context: common.UIAbilityContext): string {
    return `${context.filesDir}/${BACKUP_MIRROR_FOLDER}/${CLOUD_FILE_NAME}`
  }

  // Local backup mirror only. Cloud snapshots use CloudSyncSnapshotStore.
  private static writeText(path: string, content: string): void {
    let file: fileIo.File | undefined = undefined
    const temporary = `${path}.pending`
    try {
      file = fileIo.openSync(temporary,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
      const data = new util.TextEncoder().encodeInto(content)
      const written = fileIo.writeSync(file.fd, data.buffer)
      if (written !== data.byteLength) throw new CloudSyncFailure(13900005, 'file_io', '云备份未完整写入，原备份已保留')
      fileIo.fsyncSync(file.fd)
      fileIo.closeSync(file)
      file = undefined
      fileIo.renameSync(temporary, path)
    } finally {
      try {
        if (file !== undefined) fileIo.closeSync(file)
      } finally {
        try { if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary) } catch (_e) {}
      }
    }
  }

  private static passwordRequired(message: string, action: 'sync' | 'restore'): CloudSyncResult {
    const result = CloudSyncService.result(false, false, false, true, message, 0)
    result.passwordAction = action
    return result
  }

  private static result(success: boolean, restored: boolean, uploaded: boolean,
    needsPassword: boolean, message: string, syncTime: number): CloudSyncResult {
    return {
      success: success,
      restored: restored,
      uploaded: uploaded,
      needsPassword: needsPassword,
      message: message,
      syncTime: syncTime
    }
  }
}
