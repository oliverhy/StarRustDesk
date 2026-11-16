import { asset } from '@kit.AssetStoreKit'
import { util } from '@kit.ArkTS'
import { RustDeskNapi } from './RustDeskNapi'

const ALIAS_PREFIX: string = 'starrustdesk.connection.'
export const CREDENTIAL_ALIASES_OPTION: string = 'credential-aliases-v1'

export interface CredentialAliasEntry {
  id: string
  target: string
}

interface CredentialRecord { present: boolean; value: string }
interface CredentialAssetError { code?: number }

export class CredentialStore {
  private static mutations: number = 0
  private static mutationVersion: number = 0
  private static cachedAliasesRaw: string = '\u0000'
  private static cachedAliases: Map<string, string> = new Map<string, string>()

  private static encode(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value)
  }

  private static decode(value: Uint8Array): string {
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(value, { stream: false })
  }

  private static alias(id: string): Uint8Array {
    return CredentialStore.encode(`${ALIAS_PREFIX}${id}`)
  }

  // Cloud restore stages credentials under fresh physical aliases, then makes
  // them visible with the same atomic commit as the restored connection list.
  static parseAliases(raw: string): CredentialAliasEntry[] {
    if (raw.length === 0) return []
    const entries: CredentialAliasEntry[] = JSON.parse(raw) as CredentialAliasEntry[]
    if (!Array.isArray(entries) || entries.length > 10000) throw new Error('Invalid credential alias map')
    const seen: Set<string> = new Set<string>()
    const targets: Set<string> = new Set<string>()
    for (const entry of entries) {
      if (!entry || typeof entry.id !== 'string' || entry.id.length === 0 || entry.id.length > 200 ||
        entry.id === '__cloud_sync_master_password__' ||
        typeof entry.target !== 'string' || !/^srd-cloud-[0-9a-f-]{36}$/i.test(entry.target) ||
        seen.has(entry.id) || targets.has(entry.target)) {
        throw new Error('Invalid credential alias map')
      }
      seen.add(entry.id)
      targets.add(entry.target)
    }
    return entries
  }

  static physicalId(id: string, entries: CredentialAliasEntry[]): string {
    const match = entries.find((item: CredentialAliasEntry) => item.id === id)
    return match === undefined ? id : match.target
  }

  private static currentPhysicalId(id: string): string {
    const raw = RustDeskNapi.getOption(CREDENTIAL_ALIASES_OPTION)
    if (raw !== CredentialStore.cachedAliasesRaw) {
      const entries = CredentialStore.parseAliases(raw)
      const lookup: Map<string, string> = new Map<string, string>()
      entries.forEach((entry: CredentialAliasEntry) => { lookup.set(entry.id, entry.target) })
      CredentialStore.cachedAliases = lookup
      CredentialStore.cachedAliasesRaw = raw
    }
    return CredentialStore.cachedAliases.get(id) ?? id
  }

  // The epoch prevents an asynchronous user credential edit from racing the
  // short, synchronous native compare-and-commit used by cloud restore.
  static stableMutationVersion(): number {
    return CredentialStore.mutations === 0 ? CredentialStore.mutationVersion : -1
  }

  static mutationVersionMatches(version: number): boolean {
    return version >= 0 && CredentialStore.mutations === 0 && version === CredentialStore.mutationVersion
  }

  private static beginMutation(): void { CredentialStore.mutations++; CredentialStore.mutationVersion++ }
  private static endMutation(): void { CredentialStore.mutations--; CredentialStore.mutationVersion++ }

  private static attributes(id: string, password: string): asset.AssetMap {
    let attributes: asset.AssetMap = new Map()
    attributes.set(asset.Tag.ALIAS, CredentialStore.alias(id))
    attributes.set(asset.Tag.SECRET, CredentialStore.encode(password))
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER)
    return attributes
  }

  private static async readPhysicalRecord(id: string): Promise<CredentialRecord> {
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, CredentialStore.alias(id))
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      let result: Array<asset.AssetMap> = await asset.query(query)
      if (result.length === 0) return { present: false, value: '' }
      return { present: true, value: CredentialStore.decode(result[0].get(asset.Tag.SECRET) as Uint8Array) }
    } catch (error) {
      // Missing is distinct from a system/permission failure. Never interpret
      // an unreadable existing password as an empty password during restore.
      if ((error as CredentialAssetError).code === 24000002) return { present: false, value: '' }
      throw error as Error
    }
  }

  static async readPhysicalStrict(id: string): Promise<string> {
    return (await CredentialStore.readPhysicalRecord(id)).value
  }

  private static async removePhysical(id: string): Promise<void> {
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, CredentialStore.alias(id))
    await asset.remove(query)
  }

  static async stageRestorePassword(password: string, forbidden: string[] = []): Promise<string> {
    let id = ''
    for (let attempt = 0; attempt < 4; attempt++) {
      const candidate = `srd-cloud-${util.generateRandomUUID(true)}`
      if (/^srd-cloud-[0-9a-f-]{36}$/i.test(candidate) && !forbidden.includes(candidate)) { id = candidate; break }
    }
    if (id.length === 0) throw new Error('Unable to allocate staged credential alias')
    if (password.length === 0) {
      if ((await CredentialStore.readPhysicalRecord(id)).present) throw new Error('Credential alias collision')
      return id
    }
    let created = false
    try {
      // add, never remove/replace: a collision cannot touch existing data.
      await asset.add(CredentialStore.attributes(id, password))
      created = true
      if (await CredentialStore.readPhysicalStrict(id) !== password) throw new Error('Credential verification failed')
      return id
    } catch (error) {
      if (created) { try { await CredentialStore.removePhysical(id) } catch (_e) {} }
      throw error as Error
    }
  }

  static async discardStaged(id: string): Promise<void> {
    if (!/^srd-cloud-[0-9a-f-]{36}$/i.test(id)) return
    try { await CredentialStore.removePhysical(id) } catch (_e) {}
  }

  static async save(id: string, password: string): Promise<void> {
    CredentialStore.beginMutation()
    try {
      const target = CredentialStore.currentPhysicalId(id)
      try { await CredentialStore.removePhysical(target) } catch (_e) {}
      if (password.length > 0) {
        try { await asset.add(CredentialStore.attributes(target, password)) } catch (_e) {}
      }
    } catch (_e) {
    } finally { CredentialStore.endMutation() }
  }

  static async load(id: string): Promise<string> {
    try { return await CredentialStore.loadStrict(id) }
    catch (_e) { return '' }
  }

  static async loadStrict(id: string): Promise<string> {
    return CredentialStore.readPhysicalStrict(CredentialStore.currentPhysicalId(id))
  }

  static async remove(id: string): Promise<void> {
    CredentialStore.beginMutation()
    try { await CredentialStore.removePhysical(CredentialStore.currentPhysicalId(id)) } catch (_e) {}
    finally { CredentialStore.endMutation() }
  }
}
