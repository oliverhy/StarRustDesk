import { asset } from '@kit.AssetStoreKit'
import { util } from '@kit.ArkTS'
import { RemoteSecurityOptions, RustDeskNapi } from './RustDeskNapi'

const OS_SECRET_PREFIX: string = 'starrustdesk.os-login.'
const OPTIONS_KEY: string = 'remote-security-options'
const BINDING_KEY: string = 'remote-os-password-server-binding'

export class RemoteSecurityStore {
  private static encode(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value)
  }

  private static alias(id: string): Uint8Array {
    return RemoteSecurityStore.encode(`${OS_SECRET_PREFIX}${id}`)
  }

  static options(id: string): RemoteSecurityOptions {
    const defaults: RemoteSecurityOptions = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false }
    if (!id) return defaults
    try {
      const all: Record<string, RemoteSecurityOptions> = JSON.parse(RustDeskNapi.getOption(OPTIONS_KEY)) as
        Record<string, RemoteSecurityOptions>
      const item: RemoteSecurityOptions = all[id]
      if (!item) return defaults
      return {
        lockAfterDisconnect: item.lockAfterDisconnect === true,
        privacyMode: item.privacyMode === true,
        autoUnlock: item.autoUnlock === true
      }
    } catch (_e) {
      return defaults
    }
  }

  static saveOptions(id: string, options: RemoteSecurityOptions): void {
    if (!id) return
    let all: Record<string, RemoteSecurityOptions> = {}
    try {
      all = JSON.parse(RustDeskNapi.getOption(OPTIONS_KEY)) as Record<string, RemoteSecurityOptions>
    } catch (_e) {
    }
    all[id] = options
    RustDeskNapi.setOption(OPTIONS_KEY, JSON.stringify(all))
  }

  static async saveOsPassword(id: string, password: string): Promise<void> {
    await RemoteSecurityStore.removeOsPassword(id)
    if (!password) return
    let attributes: asset.AssetMap = new Map()
    attributes.set(asset.Tag.ALIAS, RemoteSecurityStore.alias(id))
    attributes.set(asset.Tag.SECRET, RemoteSecurityStore.encode(password))
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED)
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER)
    await asset.add(attributes)
    RemoteSecurityStore.bindCurrentServer(id)
  }

  private static currentServer(): string {
    return JSON.stringify([
      RustDeskNapi.getOption('custom-rendezvous-server').trim(),
      RustDeskNapi.getOption('relay-server').trim(),
      RustDeskNapi.getOption('key').trim()
    ])
  }

  private static bindings(): Record<string, string> {
    try {
      return JSON.parse(RustDeskNapi.getOption(BINDING_KEY)) as Record<string, string>
    } catch (_e) {
      return {}
    }
  }

  private static bindCurrentServer(id: string): void {
    let bindings: Record<string, string> = RemoteSecurityStore.bindings()
    bindings[id] = RemoteSecurityStore.currentServer()
    RustDeskNapi.setOption(BINDING_KEY, JSON.stringify(bindings))
  }

  static isCurrentServer(id: string): boolean {
    return RemoteSecurityStore.bindings()[id] === RemoteSecurityStore.currentServer()
  }

  static serverBinding(id: string): string {
    return RemoteSecurityStore.bindings()[id] ?? ''
  }

  // Transaction rollback restores only this connection's previous binding.
  static restoreServerBinding(id: string, value: string): void {
    const original = RemoteSecurityStore.bindings()
    const restored: Record<string, string> = {}
    Object.keys(original).forEach((key: string) => { if (key !== id) restored[key] = original[key] })
    if (value.length > 0) restored[id] = value
    RustDeskNapi.setOption(BINDING_KEY, JSON.stringify(restored))
  }

  static async loadOsPassword(id: string): Promise<string> {
    if (!id) return ''
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, RemoteSecurityStore.alias(id))
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
    try {
      const result: Array<asset.AssetMap> = await asset.query(query)
      if (result.length === 0) return ''
      return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(
        result[0].get(asset.Tag.SECRET) as Uint8Array, { stream: false })
    } catch (_e) {
      return ''
    }
  }

  static async removeOsPassword(id: string): Promise<void> {
    if (!id) return
    let query: asset.AssetMap = new Map()
    query.set(asset.Tag.ALIAS, RemoteSecurityStore.alias(id))
    try {
      await asset.remove(query)
    } catch (_e) {
    }
    let remaining: Record<string, string> = {}
    let bindings: Record<string, string> = RemoteSecurityStore.bindings()
    Object.keys(bindings).forEach((key: string) => {
      if (key !== id) remaining[key] = bindings[key]
    })
    RustDeskNapi.setOption(BINDING_KEY, JSON.stringify(remaining))
  }

  static async remove(id: string): Promise<void> {
    await RemoteSecurityStore.removeOsPassword(id)
    try {
      const all: Record<string, RemoteSecurityOptions> = JSON.parse(RustDeskNapi.getOption(OPTIONS_KEY)) as
        Record<string, RemoteSecurityOptions>
      let remaining: Record<string, RemoteSecurityOptions> = {}
      Object.keys(all).forEach((key: string) => {
        if (key !== id) remaining[key] = all[key]
      })
      RustDeskNapi.setOption(OPTIONS_KEY, JSON.stringify(remaining))
    } catch (_e) {
    }
  }
}
