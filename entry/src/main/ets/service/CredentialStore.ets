import { asset } from '@kit.AssetStoreKit'
import { util } from '@kit.ArkTS'

const ALIAS_PREFIX: string = 'starrustdesk.connection.'

export class CredentialStore {
  private static encode(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value)
  }

  private static decode(value: Uint8Array): string {
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(value, { stream: false })
  }

  private static alias(id: string): Uint8Array {
    return CredentialStore.encode(`${ALIAS_PREFIX}${id}`)
  }

  static async save(id: string, password: string): Promise<void> {
    await CredentialStore.remove(id)
    if (password.length === 0) return
    let attributes: asset.AssetMap = new Map()
    attributes.set(asset.Tag.ALIAS, CredentialStore.alias(id))
    attributes.set(asset.Tag.SECRET, CredentialStore.encode(password))
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER)
    try {
      await asset.add(attributes)
    } catch (_e) {
    }
  }

  static async load(id: string): Promise<string> {
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, CredentialStore.alias(id))
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      let result: Array<asset.AssetMap> = await asset.query(query)
      if (result.length === 0) return ''
      return CredentialStore.decode(result[0].get(asset.Tag.SECRET) as Uint8Array)
    } catch (_e) {
      return ''
    }
  }

  static async remove(id: string): Promise<void> {
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, CredentialStore.alias(id))
    try {
      await asset.remove(query)
    } catch (_e) {
    }
  }
}
