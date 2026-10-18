export interface SavedConnectionDraft {
  remoteId: string
  name: string
  groupId: string
  performancePreset: string
  password: string
  passwordMode: string
  lockAfterDisconnect: boolean
  privacyMode: boolean
  autoUnlock: boolean
  osPassword: string
  clearOsPassword: boolean
  hasPassword: boolean
  hasOsPassword: boolean
}

export interface ConnectionEditorGroup { id: string; name: string }
export interface ConnectionEditResult { success: boolean; message: string }

export class SavedConnectionEditing {
  static endpoint(value: string): string {
    // Keep custom IDs and displayed/saved addresses exactly as entered, apart from spacing.
    return value.replace(/[\s\u200B-\u200D\uFEFF]+/g, '')
  }

  static sameEndpoint(left: string, right: string): boolean {
    const a = SavedConnectionEditing.endpoint(left)
    const b = SavedConnectionEditing.endpoint(right)
    if (a === b) return true
    // Native direct connections accept IP literals. Only IPv6 hex letters are case
    // insensitive; other strings are opaque peer IDs, including names with dots.
    const ipv6 = /^(\[[0-9a-fA-F:.]+\](?::\d+)?|[0-9a-fA-F:.]+)$/
    return a.includes(':') && b.includes(':') && ipv6.test(a) && ipv6.test(b) && a.toLowerCase() === b.toLowerCase()
  }

  static network(idServer: string, relayServer: string): string {
    const input = JSON.stringify([idServer.trim().toLowerCase(), relayServer.trim().toLowerCase()])
    // Non-secret namespace, not an authentication/security hash. Never includes keys or API tokens.
    let a = 2166136261
    let b = 5381
    for (let i = 0; i < input.length; i++) {
      a = Math.imul(a ^ input.charCodeAt(i), 16777619) >>> 0
      b = (Math.imul(b, 33) ^ input.charCodeAt(i)) >>> 0
    }
    return `network-v1-${a.toString(16).padStart(8, '0')}${b.toString(16).padStart(8, '0')}`
  }

  static validScope(value: string | undefined): string | undefined {
    return value !== undefined && /^network-v1-[0-9a-f]{16}$/.test(value) ? value : undefined
  }

  static sameNetwork(scope: string | undefined, current: string): boolean {
    // Legacy rows have no provenance. Treat them conservatively as existing, never overwrite them.
    return SavedConnectionEditing.validScope(scope) === undefined || scope === current
  }

  static empty(): SavedConnectionDraft {
    return { remoteId: '', name: '', groupId: '', performancePreset: 'smooth', password: '', passwordMode: 'keep',
      lockAfterDisconnect: false, privacyMode: false, autoUnlock: false, osPassword: '', clearOsPassword: false,
      hasPassword: false, hasOsPassword: false }
  }
}
