import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

const PLAIN_BACKUP_FORMAT: string = 'StarRustDeskConnectionBackup'
const ENCRYPTED_BACKUP_FORMAT: string = 'StarRustDeskEncryptedConnectionBackup'
const BACKUP_SCHEMA_VERSION: number = 1
const PBKDF2_ITERATIONS: number = 210000
const BACKUP_AAD: string = 'StarRustDesk|connection-backup|v1'

export interface ConnectionBackupGroup {
  id: string
  name: string
}

export interface ConnectionBackupItem {
  id: string
  name: string
  remoteId: string
  password: string
  performancePreset: string
  groupId: string
}

export interface ConnectionBackupPayload {
  format: string
  schemaVersion: number
  exportedAt: string
  includesPasswords: boolean
  groups: ConnectionBackupGroup[]
  connections: ConnectionBackupItem[]
}

interface EncryptedConnectionBackup {
  format: string
  schemaVersion: number
  exportedAt: string
  kdf: string
  iterations: number
  salt: string
  cipher: string
  iv: string
  ciphertext: string
  tag: string
}

export class ConnectionBackupService {
  private static encoder: util.TextEncoder = new util.TextEncoder()
  private static decoder: util.TextDecoder = new util.TextDecoder('utf-8')
  private static base64: util.Base64Helper = new util.Base64Helper()

  static createPayload(groups: ConnectionBackupGroup[], connections: ConnectionBackupItem[],
    includesPasswords: boolean): ConnectionBackupPayload {
    return {
      format: PLAIN_BACKUP_FORMAT,
      schemaVersion: BACKUP_SCHEMA_VERSION,
      exportedAt: new Date().toISOString(),
      includesPasswords: includesPasswords,
      groups: groups,
      connections: connections
    }
  }

  static createPlainText(payload: ConnectionBackupPayload): string {
    ConnectionBackupService.validatePayload(payload)
    return JSON.stringify(payload, null, 2)
  }

  static isEncrypted(raw: string): boolean {
    try {
      let envelope: EncryptedConnectionBackup = JSON.parse(raw) as EncryptedConnectionBackup
      return envelope.format === ENCRYPTED_BACKUP_FORMAT
    } catch (_error) {
      return false
    }
  }

  static parsePlainText(raw: string): ConnectionBackupPayload {
    let payload: ConnectionBackupPayload = JSON.parse(raw) as ConnectionBackupPayload
    ConnectionBackupService.validatePayload(payload)
    if (payload.includesPasswords) {
      throw new Error('普通备份不得包含连接密码')
    }
    return payload
  }

  static async encrypt(payload: ConnectionBackupPayload, password: string): Promise<string> {
    ConnectionBackupService.validatePayload(payload)
    if (password.length < 8) {
      throw new Error('备份密码至少需要 8 位')
    }

    let random = cryptoFramework.createRandom()
    let salt: Uint8Array = (await random.generateRandom(16)).data
    let iv: Uint8Array = (await random.generateRandom(12)).data
    let keyBytes: Uint8Array = await ConnectionBackupService.deriveKey(password, salt, PBKDF2_ITERATIONS)
    let symKey = await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: keyBytes })
    let params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: ConnectionBackupService.encode(BACKUP_AAD) },
      authTag: { data: new Uint8Array(16) }
    }
    let cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding')
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params)
    let sealed: Uint8Array = (await cipher.doFinal({
      data: ConnectionBackupService.encode(JSON.stringify(payload))
    })).data
    if (sealed.length < 16) {
      throw new Error('加密结果无效')
    }

    let envelope: EncryptedConnectionBackup = {
      format: ENCRYPTED_BACKUP_FORMAT,
      schemaVersion: BACKUP_SCHEMA_VERSION,
      exportedAt: payload.exportedAt,
      kdf: 'PBKDF2|SHA256',
      iterations: PBKDF2_ITERATIONS,
      salt: ConnectionBackupService.base64.encodeToStringSync(salt),
      cipher: 'AES256|GCM|NoPadding',
      iv: ConnectionBackupService.base64.encodeToStringSync(iv),
      ciphertext: ConnectionBackupService.base64.encodeToStringSync(sealed.slice(0, sealed.length - 16)),
      tag: ConnectionBackupService.base64.encodeToStringSync(sealed.slice(sealed.length - 16))
    }
    return JSON.stringify(envelope, null, 2)
  }

  static async decrypt(raw: string, password: string): Promise<ConnectionBackupPayload> {
    let envelope: EncryptedConnectionBackup = JSON.parse(raw) as EncryptedConnectionBackup
    ConnectionBackupService.validateEnvelope(envelope)
    let salt: Uint8Array = ConnectionBackupService.base64.decodeSync(envelope.salt)
    let iv: Uint8Array = ConnectionBackupService.base64.decodeSync(envelope.iv)
    let ciphertext: Uint8Array = ConnectionBackupService.base64.decodeSync(envelope.ciphertext)
    let tag: Uint8Array = ConnectionBackupService.base64.decodeSync(envelope.tag)
    if (salt.length !== 16 || iv.length !== 12 || tag.length !== 16) {
      throw new Error('加密备份参数无效')
    }

    let keyBytes: Uint8Array = await ConnectionBackupService.deriveKey(password, salt, envelope.iterations)
    let symKey = await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: keyBytes })
    let params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: ConnectionBackupService.encode(BACKUP_AAD) },
      authTag: { data: tag }
    }
    let cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding')
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params)
    let clear: Uint8Array = (await cipher.doFinal({ data: ciphertext })).data
    let payload: ConnectionBackupPayload = JSON.parse(
      ConnectionBackupService.decoder.decodeWithStream(clear)) as ConnectionBackupPayload
    ConnectionBackupService.validatePayload(payload)
    if (!payload.includesPasswords) {
      throw new Error('加密备份内容不完整')
    }
    return payload
  }

  private static async deriveKey(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
    let kdf = cryptoFramework.createKdf('PBKDF2|SHA256')
    let params: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: ConnectionBackupService.encode(password),
      salt: salt,
      iterations: iterations,
      keySize: 32
    }
    return (await kdf.generateSecret(params)).data
  }

  private static validateEnvelope(envelope: EncryptedConnectionBackup): void {
    if (envelope.format !== ENCRYPTED_BACKUP_FORMAT ||
      envelope.schemaVersion !== BACKUP_SCHEMA_VERSION ||
      envelope.kdf !== 'PBKDF2|SHA256' ||
      envelope.cipher !== 'AES256|GCM|NoPadding' ||
      envelope.iterations < 100000 || envelope.iterations > 1000000 ||
      envelope.salt.length === 0 || envelope.iv.length === 0 ||
      envelope.ciphertext.length === 0 || envelope.tag.length === 0) {
      throw new Error('不支持的加密备份格式')
    }
  }

  private static validatePayload(payload: ConnectionBackupPayload): void {
    if (payload.format !== PLAIN_BACKUP_FORMAT ||
      payload.schemaVersion !== BACKUP_SCHEMA_VERSION ||
      typeof payload.exportedAt !== 'string' || typeof payload.includesPasswords !== 'boolean' ||
      !Array.isArray(payload.groups) || !Array.isArray(payload.connections)) {
      throw new Error('不支持的连接备份格式')
    }
    if (payload.groups.length > 500 || payload.connections.length > 5000) {
      throw new Error('备份内容数量异常')
    }
    payload.groups.forEach((group: ConnectionBackupGroup) => {
      if (typeof group.id !== 'string' || typeof group.name !== 'string' ||
        group.id.length > 160 || group.name.trim().length === 0 || group.name.length > 100) {
        throw new Error('备份中的分组信息无效')
      }
    })
    payload.connections.forEach((item: ConnectionBackupItem) => {
      if (typeof item.id !== 'string' || typeof item.name !== 'string' ||
        typeof item.remoteId !== 'string' || typeof item.password !== 'string' ||
        typeof item.performancePreset !== 'string' || typeof item.groupId !== 'string' ||
        item.id.length > 200 || item.name.length > 200 || item.remoteId.length > 100 ||
        item.password.length > 1000 || item.performancePreset.length > 50 || item.groupId.length > 160) {
        throw new Error('备份中的连接信息无效')
      }
    })
  }

  private static encode(value: string): Uint8Array {
    return ConnectionBackupService.encoder.encodeInto(value)
  }
}
