// Numeric values are part of the ArkTS/native boundary. A grant for one reason
// must never authorize a different reason on a later handshake.
export const INSECURE_SERVER_KEY: number = 1
export const INSECURE_MISSING_SIGNATURE: number = 2
export const INSECURE_DIRECT_ENDPOINT: number = 3
export const INSECURE_CONSENT_DURATION_MS: number = 7 * 24 * 60 * 60 * 1000

export interface InsecureConsentScope {
  peer: string
  network: string
  reason: number
  generation: number
}

export interface InsecureConsentRecord {
  fingerprint: string
  issuedAt: number
  expiresAt: number
}

export function insecureReasonForError(message: string): number {
  if (message === '服务器密钥无效' || message === 'Server key is invalid') return INSECURE_SERVER_KEY
  if (message === '远端身份签名缺失，无法建立加密连接' ||
    message === 'Remote identity signature is missing; an encrypted connection cannot be established') {
    return INSECURE_MISSING_SIGNATURE
  }
  if (message === '直连无法验证远端身份，连接未加密' ||
    message === 'Direct connections cannot verify the remote identity and are unencrypted') return INSECURE_DIRECT_ENDPOINT
  return 0
}

export function validInsecureConsent(record: InsecureConsentRecord, now: number): boolean {
  return typeof record.fingerprint === 'string' && /^[0-9a-f]{64}$/.test(record.fingerprint) &&
    Number.isSafeInteger(record.issuedAt) && Number.isSafeInteger(record.expiresAt) &&
    record.issuedAt > 0 && record.expiresAt - record.issuedAt === INSECURE_CONSENT_DURATION_MS &&
    now >= record.issuedAt && now < record.expiresAt
}
