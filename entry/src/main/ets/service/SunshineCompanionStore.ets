import { asset } from '@kit.AssetStoreKit'
import { util } from '@kit.ArkTS'

/** Leaves the existing connections, backups and RustDesk secrets untouched. */
export class SunshineCompanionStore {
  static isProfile(value: string): boolean {
    return /^ss1-(\d{1,3}\.){3}\d{1,3}-\d{4,5}-[0-9a-f]{64}-[0-9a-f]{64}$/.test(value)
  }

  private static alias(): Uint8Array {
    return new util.TextEncoder().encodeInto('sesame.sunshine.experimental.companion.v1')
  }

  static async load(): Promise<string> {
    try {
      let query: asset.AssetMap = new Map()
      query.set(asset.Tag.ALIAS, SunshineCompanionStore.alias())
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
      const found = await asset.query(query)
      if (found.length !== 1) return ''
      const value = util.TextDecoder.create('utf-8').decodeToString(found[0].get(asset.Tag.SECRET) as Uint8Array)
      return SunshineCompanionStore.isProfile(value) ? value : ''
    } catch (_e) {
      return ''
    }
  }

  static async save(record: string): Promise<void> {
    let attributes: asset.AssetMap = new Map()
    attributes.set(asset.Tag.ALIAS, SunshineCompanionStore.alias())
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(record))
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED)
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER)
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE)
    await asset.add(attributes)
  }

  static async forget(): Promise<void> {
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, SunshineCompanionStore.alias())
    await asset.remove(query)
  }
}
