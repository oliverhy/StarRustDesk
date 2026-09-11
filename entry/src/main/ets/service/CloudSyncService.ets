import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { cloudSync, fileIo } from '@kit.CoreFileKit'
import { CredentialStore } from './CredentialStore'
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
const CLOUD_SYNC_PASSWORD_ID: string = '__cloud_sync_master_password__'
const CLOUD_FOLDER_NAME: string = 'StarRustDesk'
const CLOUD_FILE_NAME: string = 'cloud-sync-v1.srdsync'
const BACKUP_MIRROR_FOLDER: string = 'cloud_backup'

interface SavedConnectionRow {
  id: string
  name: string
  remoteId: string
  credentialAlias: string
  performancePreset: string
  groupId: string
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
}

export class CloudSyncService {
  private static syncing: boolean = false

  static isEnabled(): boolean {
    try {
      return RustDeskNapi.getOption(CLOUD_SYNC_ENABLED_OPTION) === '1'
    } catch (_error) {
      return false
    }
  }

  static setEnabled(enabled: boolean): void {
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_ENABLED_OPTION, enabled ? '1' : '0')
      if (enabled) {
        CloudSyncService.markLocalChanged()
      }
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
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, Date.now().toString())
    } catch (_error) {
    }
  }

  static getLastSuccessTime(): number {
    return CloudSyncService.readTimestamp(CLOUD_SYNC_LAST_SUCCESS_OPTION)
  }

  static async hasCloudPassword(): Promise<boolean> {
    return (await CredentialStore.load(CLOUD_SYNC_PASSWORD_ID)).length >= 8
  }

  static async saveCloudPassword(password: string): Promise<void> {
    if (password.length < 8) {
      throw new Error('备份密码至少需要 8 位')
    }
    await CredentialStore.save(CLOUD_SYNC_PASSWORD_ID, password)
    CloudSyncService.markLocalChanged()
  }

  static async clearCloudPassword(): Promise<void> {
    await CredentialStore.remove(CLOUD_SYNC_PASSWORD_ID)
  }

  static async syncNow(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    if (!CloudSyncService.isEnabled()) {
      return CloudSyncService.result(false, false, false, false, '云同步未开启', 0)
    }
    if (CloudSyncService.syncing) {
      return CloudSyncService.result(true, false, false, false, '云同步正在进行', Date.now())
    }
    CloudSyncService.syncing = true
    try {
      CloudSyncService.ensureFolders(context)
      await CloudSyncService.requestSystemSync()
      let cloudPath: string = CloudSyncService.cloudPath(context)
      if (!fileIo.accessSync(cloudPath)) {
        return await CloudSyncService.upload(context)
      }
      let raw: string = CloudSyncService.readText(cloudPath)
      let cloudTime: number = CloudSyncService.readContentTime(raw)
      if (cloudTime <= 0) {
        return CloudSyncService.result(false, false, false, false,
          '云端备份格式异常，已保留原文件，未进行覆盖', 0)
      }
      let localChanged: number = CloudSyncService.readTimestamp(CLOUD_SYNC_LOCAL_CHANGED_OPTION)
      if (CloudSyncService.localDataIsEmpty() && cloudTime > 0) {
        return await CloudSyncService.applyCloudContent(context, raw)
      }
      if (cloudTime > localChanged) {
        return await CloudSyncService.applyCloudContent(context, raw)
      }
      if (localChanged > cloudTime) {
        return await CloudSyncService.upload(context)
      }
      let syncTime: number = Date.now()
      RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, syncTime.toString())
      return CloudSyncService.result(true, false, false, false, '云端与本机已是最新', syncTime)
    } catch (_error) {
      RustDeskNapi.appendDiagnosticLog('cloud-sync', 'sync_failed')
      return CloudSyncService.result(false, false, false, false,
        '云空间未就绪，请检查华为账号、云空间开关和网络', 0)
    } finally {
      CloudSyncService.syncing = false
    }
  }

  static async upload(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    try {
      CloudSyncService.ensureFolders(context)
      let includesSecrets: boolean = CloudSyncService.includesSecrets()
      let password: string = ''
      if (includesSecrets) {
        password = await CredentialStore.load(CLOUD_SYNC_PASSWORD_ID)
        if (password.length < 8) {
          return CloudSyncService.result(false, false, false, true,
            '请先设置至少 8 位的云备份密码', 0)
        }
      }
      let payload: ConnectionBackupPayload = await CloudSyncService.buildPayload(includesSecrets)
      let content: string = includesSecrets ? await ConnectionBackupService.encrypt(payload, password) :
        ConnectionBackupService.createPlainText(payload)
      CloudSyncService.writeText(CloudSyncService.cloudPath(context), content)
      CloudSyncService.writeText(CloudSyncService.mirrorPath(context), content)
      await CloudSyncService.requestSystemSync()
      let contentTime: number = CloudSyncService.payloadTime(payload)
      let syncTime: number = Date.now()
      RustDeskNapi.setOption(CLOUD_SYNC_LAST_APPLIED_OPTION, contentTime.toString())
      RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, contentTime.toString())
      RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, syncTime.toString())
      RustDeskNapi.appendDiagnosticLog('cloud-sync',
        `upload_succeeded secrets=${includesSecrets ? 1 : 0}`)
      return CloudSyncService.result(true, false, true, false, '已同步到华为云空间', syncTime)
    } catch (_error) {
      RustDeskNapi.appendDiagnosticLog('cloud-sync', 'upload_failed')
      return CloudSyncService.result(false, false, false, false,
        '上传失败，请确认云空间已为本应用开启', 0)
    }
  }

  static async restore(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    try {
      CloudSyncService.ensureFolders(context)
      await CloudSyncService.requestSystemSync()
      let cloudPath: string = CloudSyncService.cloudPath(context)
      let sourcePath: string = fileIo.accessSync(cloudPath) ? cloudPath : CloudSyncService.mirrorPath(context)
      if (!fileIo.accessSync(sourcePath)) {
        return CloudSyncService.result(false, false, false, false, '云端暂无 StarRustDesk 备份', 0)
      }
      return await CloudSyncService.applyCloudContent(context, CloudSyncService.readText(sourcePath))
    } catch (_error) {
      RustDeskNapi.appendDiagnosticLog('cloud-sync', 'restore_failed')
      return CloudSyncService.result(false, false, false, false,
        '恢复失败，请检查云空间或备份密码', 0)
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
      let password: string = includesSecrets ? await CredentialStore.load(row.id) : ''
      connections.push({
        id: row.id,
        name: row.name,
        remoteId: row.remoteId,
        password: password,
        performancePreset: row.performancePreset,
        groupId: row.groupId
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

  private static async applyCloudContent(context: common.UIAbilityContext, raw: string): Promise<CloudSyncResult> {
    let payload: ConnectionBackupPayload
    if (ConnectionBackupService.isEncrypted(raw)) {
      let password: string = await CredentialStore.load(CLOUD_SYNC_PASSWORD_ID)
      if (password.length < 8) {
        return CloudSyncService.result(false, false, false, true,
          '该云备份已加密，请输入备份密码', 0)
      }
      try {
        payload = await ConnectionBackupService.decrypt(raw, password)
      } catch (_error) {
        return CloudSyncService.result(false, false, false, true,
          '备份密码错误或云备份已损坏', 0)
      }
    } else {
      payload = ConnectionBackupService.parsePlainText(raw)
    }

    let oldRows: SavedConnectionRow[] = CloudSyncService.readConnections()
    let newRows: SavedConnectionRow[] = []
    for (let item of payload.connections) {
      let row: SavedConnectionRow = {
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        credentialAlias: item.id,
        performancePreset: item.performancePreset,
        groupId: item.groupId
      }
      newRows.push(row)
      if (payload.includesPasswords) {
        await CredentialStore.save(item.id, item.password)
      } else {
        let old: SavedConnectionRow | undefined = oldRows.find((value: SavedConnectionRow) =>
          value.remoteId === item.remoteId)
        if (old !== undefined && old.id !== item.id) {
          let oldPassword: string = await CredentialStore.load(old.id)
          if (oldPassword.length > 0) {
            await CredentialStore.save(item.id, oldPassword)
          }
        }
      }
    }
    let groupRows: SavedConnectionGroupRow[] = []
    payload.groups.forEach((group: ConnectionBackupGroup) => {
      groupRows.push({ id: group.id, name: group.name, expanded: true })
    })
    RustDeskNapi.setOption('saved-connection-groups', JSON.stringify(groupRows))
    RustDeskNapi.setOption('saved-connections', JSON.stringify(newRows))
    RustDeskNapi.setOption(CLOUD_SYNC_SECRETS_OPTION, payload.includesPasswords ? '1' : '0')
    if (payload.serverConfig !== undefined) {
      RustDeskNapi.setOption('custom-rendezvous-server', payload.serverConfig.idServer)
      RustDeskNapi.setOption('relay-server', payload.serverConfig.relayServer)
      RustDeskNapi.setOption('api-server', payload.serverConfig.apiServer)
      if (payload.includesPasswords) {
        RustDeskNapi.setOption('key', payload.serverConfig.serverKey)
      }
      let serverVersion: number = AppStorage.get<number>('serverConfigVersion') ?? 0
      AppStorage.set<number>('serverConfigVersion', serverVersion + 1)
    }
    let syncTime: number = CloudSyncService.payloadTime(payload)
    if (syncTime <= 0) {
      syncTime = Date.now()
    }
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_APPLIED_OPTION, syncTime.toString())
    RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, syncTime.toString())
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, Date.now().toString())
    let revision: number = AppStorage.get<number>('savedConnectionsCloudRevision') ?? 0
    AppStorage.set<number>('savedConnectionsCloudRevision', revision + 1)
    CloudSyncService.writeText(CloudSyncService.mirrorPath(context), raw)
    RustDeskNapi.appendDiagnosticLog('cloud-sync',
      `restore_succeeded connections=${newRows.length} groups=${groupRows.length} secrets=${payload.includesPasswords ? 1 : 0}`)
    return CloudSyncService.result(true, true, false, false, '已从华为云空间恢复', Date.now())
  }

  private static readConnections(): SavedConnectionRow[] {
    try {
      let raw: string = RustDeskNapi.getOption('saved-connections')
      return raw.length > 0 ? JSON.parse(raw) as SavedConnectionRow[] : []
    } catch (_error) {
      return []
    }
  }

  private static readGroups(): SavedConnectionGroupRow[] {
    try {
      let raw: string = RustDeskNapi.getOption('saved-connection-groups')
      return raw.length > 0 ? JSON.parse(raw) as SavedConnectionGroupRow[] : []
    } catch (_error) {
      return []
    }
  }

  private static localDataIsEmpty(): boolean {
    return CloudSyncService.readConnections().length === 0 && CloudSyncService.readGroups().length === 0
  }

  private static readContentTime(raw: string): number {
    try {
      if (ConnectionBackupService.isEncrypted(raw)) {
        interface EnvelopeTime { exportedAt: string }
        let envelope: EnvelopeTime = JSON.parse(raw) as EnvelopeTime
        return Date.parse(envelope.exportedAt)
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

  private static ensureFolders(context: common.UIAbilityContext): void {
    let cloudFolder: string = `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`
    let mirrorFolder: string = `${context.filesDir}/${BACKUP_MIRROR_FOLDER}`
    if (!fileIo.accessSync(cloudFolder)) {
      fileIo.mkdirSync(cloudFolder, true)
    }
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

  private static readText(path: string): string {
    let file: fileIo.File | undefined = undefined
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
      let size: number = fileIo.statSync(file.fd).size
      if (size <= 0 || size > 10 * 1024 * 1024) {
        throw new Error('云备份文件大小异常')
      }
      let buffer: ArrayBuffer = new ArrayBuffer(size)
      let readSize: number = fileIo.readSync(file.fd, buffer)
      return util.TextDecoder.create('utf-8', { ignoreBOM: true })
        .decodeToString(new Uint8Array(buffer, 0, readSize), { stream: false })
    } finally {
      if (file !== undefined) {
        fileIo.closeSync(file)
      }
    }
  }

  private static writeText(path: string, content: string): void {
    let file: fileIo.File | undefined = undefined
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
      fileIo.writeSync(file.fd, content)
      fileIo.fsyncSync(file.fd)
    } finally {
      if (file !== undefined) {
        fileIo.closeSync(file)
      }
    }
  }

  private static async requestSystemSync(): Promise<void> {
    let fileSync: cloudSync.FileSync = new cloudSync.FileSync()
    await fileSync.start()
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
