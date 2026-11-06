import { common } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { InsecureConsentRecord, InsecureConsentScope, INSECURE_CONSENT_DURATION_MS,
  validInsecureConsent } from '../model/InsecureConsent'

// A local-only store: grants are not included in cloud connection backups.
// Only a digest of the scope is persisted, never the peer, server or key.
const STORE_NAME: string = 'starrustdesk_insecure_consent'
const RECORDS_KEY: string = 'grants_v1'
const MAX_RECORDS: number = 64

export class InsecureConsentStore {
  private static queue: Promise<void> = Promise.resolve()
  private static generation: number = 0

  private static async fingerprint(scope: InsecureConsentScope): Promise<string> {
    const material: string = JSON.stringify(['insecure-consent-v1', scope.peer, scope.network, scope.reason])
    const md = cryptoFramework.createMd('SHA256')
    await md.update({ data: new util.TextEncoder().encodeInto(material) })
    const result = await md.digest()
    let hex: string = ''
    for (const byte of result.data) hex += byte.toString(16).padStart(2, '0')
    return hex
  }

  private static records(store: preferences.Preferences, now: number): InsecureConsentRecord[] {
    const raw = store.getSync(RECORDS_KEY, '')
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 16000) return []
    try {
      const decoded = JSON.parse(raw) as InsecureConsentRecord[]
      if (!Array.isArray(decoded) || decoded.length > MAX_RECORDS) return []
      return decoded.filter((record: InsecureConsentRecord) => record !== null &&
        typeof record === 'object' && validInsecureConsent(record, now))
    } catch (_error) { return [] }
  }

  static async has(context: common.UIAbilityContext, scope: InsecureConsentScope): Promise<boolean> {
    const generation: number = InsecureConsentStore.generation
    try {
      await InsecureConsentStore.queue
      const fingerprint = await InsecureConsentStore.fingerprint(scope)
      if (generation !== InsecureConsentStore.generation) return false
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME })
      return InsecureConsentStore.records(store, Date.now()).some(
        (record: InsecureConsentRecord) => record.fingerprint === fingerprint)
    } catch (_error) { return false }
  }

  static async remember(context: common.UIAbilityContext, scope: InsecureConsentScope,
    stillCurrent: () => boolean): Promise<boolean> {
    const generation: number = InsecureConsentStore.generation
    const task: Promise<boolean> = InsecureConsentStore.queue.then(async (): Promise<boolean> => {
      let store: preferences.Preferences | undefined
      let previous: string = ''
      let changed: boolean = false
      try {
        const fingerprint = await InsecureConsentStore.fingerprint(scope)
        if (!stillCurrent() || generation !== InsecureConsentStore.generation) return false
        store = preferences.getPreferencesSync(context, { name: STORE_NAME })
        const old = store.getSync(RECORDS_KEY, '')
        previous = typeof old === 'string' ? old : ''
        const now: number = Date.now()
        const records = InsecureConsentStore.records(store, now)
          .filter((record: InsecureConsentRecord) => record.fingerprint !== fingerprint)
        records.push({ fingerprint: fingerprint, issuedAt: now, expiresAt: now + INSECURE_CONSENT_DURATION_MS })
        store.putSync(RECORDS_KEY, JSON.stringify(records.slice(-MAX_RECORDS)))
        changed = true
        await store.flush()
        if (stillCurrent() && generation === InsecureConsentStore.generation) return true
        // A cancelled or replaced attempt must not gain a lasting grant.
        const remaining = InsecureConsentStore.records(store, Date.now())
          .filter((record: InsecureConsentRecord) => record.fingerprint !== fingerprint)
        store.putSync(RECORDS_KEY, JSON.stringify(remaining))
        await store.flush()
      } catch (_error) {
        // A failed flush must not leave an effective grant in the cached store.
        if (store && changed) {
          try { store.putSync(RECORDS_KEY, previous); await store.flush() } catch (_rollbackError) {}
        }
      }
      return false
    })
    InsecureConsentStore.queue = task.then(() => {}, () => {})
    return task
  }

  static async clear(context: common.UIAbilityContext): Promise<boolean> {
    InsecureConsentStore.generation++
    const task: Promise<boolean> = InsecureConsentStore.queue.then(async (): Promise<boolean> => {
      try {
        const store = preferences.getPreferencesSync(context, { name: STORE_NAME })
        store.clearSync()
        await store.flush()
        return true
      } catch (_error) { return false }
    })
    InsecureConsentStore.queue = task.then(() => {}, () => {})
    return task
  }
}
