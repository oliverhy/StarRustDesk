import { util } from '@kit.ArkTS'

interface OfficialServerConfig {
  key: string
  host: string
  api: string
  relay: string
}

export class ServerConfigModel {
  idServer: string = ''
  relayServer: string = ''
  apiServer: string = ''
  serverKey: string = ''

  constructor(idServer?: string, relayServer?: string, apiServer?: string, serverKey?: string) {
    this.idServer = (idServer ?? '').trim()
    this.relayServer = (relayServer ?? '').trim()
    this.apiServer = (apiServer ?? '').trim()
    this.serverKey = (serverKey ?? '').trim()
  }

  static fromOptions(options: Record<string, string>): ServerConfigModel {
    return new ServerConfigModel(
      options['custom-rendezvous-server'] ?? '',
      options['relay-server'] ?? '',
      options['api-server'] ?? '',
      options['key'] ?? '')
  }

  static decode(input: string): ServerConfigModel {
    let source: string = input.trim()
    if (source.length === 0) {
      return new ServerConfigModel()
    }

    if (source.length > 16384) return new ServerConfigModel()
    if (source.startsWith('config=')) {
      // Official QR codes may contain either JSON or the same encoded token
      // used by the clipboard. Older app versions also export JSON here.
      source = source.substring(7).trim()
    } else if (source.toLowerCase().startsWith('rustdesk://config/')) {
      try {
        source = decodeURIComponent(source.substring('rustdesk://config/'.length)).trim()
      } catch (_e) { return new ServerConfigModel() }
    }
    if (source.startsWith('{')) {
      try {
        return ServerConfigModel.fromJson(JSON.parse(source) as OfficialServerConfig)
      } catch (_e) { return new ServerConfigModel() }
    }
    // Strip executable suffixes before extracting host/key/relay values.
    // A Windows duplicate suffix is only removed for executable filenames.
    const isExecutable: boolean = /\.exe(?:\.exe)?$/i.test(source)
    let normalized: string = source
    if (isExecutable) {
      normalized = normalized.replace(/\.exe(?:\.exe)?$/i, '').replace(/(?:\s*\(\d+\))+$/, '')
    }
    const plain: ServerConfigModel = ServerConfigModel.decodePlainConfig(normalized)
    if (plain.isValid()) {
      return plain
    }

    normalized = normalized
      .replace(/-licensed---/g, '--')
      .replace(/-licensed--/g, '--')
      .replace(/-licensed-/g, '--')
    // Try the entire token first: '--' can also occur in Base64URL data.
    let candidates: string[] = [normalized]
    candidates = candidates.concat(normalized.split('--'))
    for (let candidate of candidates) {
      let parts: string[] = candidate.includes('(') ? candidate.split('(') : [candidate]
      for (let part of parts) {
        const decoded: ServerConfigModel = ServerConfigModel.decodeOfficialToken(part.trim())
        if (decoded.isValid()) {
          return decoded
        }
      }
    }
    return new ServerConfigModel()
  }

  private static fromJson(json: OfficialServerConfig): ServerConfigModel {
    if (json === null || typeof json !== 'object' || typeof json.host !== 'string' ||
      (json.key !== undefined && typeof json.key !== 'string') ||
      (json.api !== undefined && typeof json.api !== 'string') ||
      (json.relay !== undefined && typeof json.relay !== 'string')) return new ServerConfigModel()
    return new ServerConfigModel(json.host, json.relay, json.api, json.key)
  }

  private static decodePlainConfig(source: string): ServerConfigModel {
    const lower: string = source.toLowerCase()
    const hostIndex: number = lower.indexOf('host=')
    if (hostIndex < 0) {
      return new ServerConfigModel()
    }
    let idServer: string = ''
    let relayServer: string = ''
    let apiServer: string = ''
    let serverKey: string = ''
    source.substring(hostIndex).split(',').forEach((part: string) => {
      const separator: number = part.indexOf('=')
      if (separator <= 0) return
      const name: string = part.substring(0, separator).trim().toLowerCase()
      const value: string = part.substring(separator + 1).trim()
      if (name === 'host') idServer = value
      if (name === 'relay') relayServer = value
      if (name === 'api') apiServer = value
      if (name === 'key') serverKey = value
    })
    return new ServerConfigModel(idServer, relayServer, apiServer, serverKey)
  }

  private static decodeOfficialToken(encoded: string): ServerConfigModel {
    try {
      let reversed: string = ServerConfigModel.reverse(encoded)
      while (reversed.length % 4 !== 0) {
        reversed += '='
      }
      const helper: util.Base64Helper = new util.Base64Helper()
      const bytes: Uint8Array = helper.decodeSync(reversed, util.Type.BASIC_URL_SAFE)
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8')
      const json: OfficialServerConfig = JSON.parse(decoder.decodeToString(bytes)) as OfficialServerConfig
      return ServerConfigModel.fromJson(json)
    } catch (_error) {
      return new ServerConfigModel()
    }
  }

  encode(): string {
    // Keep the same field names/order and transform used by RustDesk custom_server.rs.
    const config: OfficialServerConfig = {
      key: this.serverKey.trim(),
      host: this.idServer.trim(),
      api: this.apiServer.trim(),
      relay: this.relayServer.trim()
    }
    const encoder: util.TextEncoder = new util.TextEncoder()
    const bytes: Uint8Array = encoder.encodeInto(JSON.stringify(config))
    const helper: util.Base64Helper = new util.Base64Helper()
    const encoded: string = helper.encodeToStringSync(bytes, util.Type.BASIC_URL_SAFE).replace(/=+$/g, '')
    return ServerConfigModel.reverse(encoded)
  }

  private static reverse(value: string): string {
    let result: string = ''
    for (let index: number = value.length - 1; index >= 0; index--) {
      result += value[index]
    }
    return result
  }

  isValid(): boolean {
    return this.idServer.length > 0
  }

  isValidImport(): boolean {
    // Imported addresses and public keys cannot contain embedded whitespace or
    // controls. Do not change validation of manually entered configurations.
    return this.isValid() && !/[\s\x00-\x1f\x7f]/.test(this.idServer) &&
      !/[\s\x00-\x1f\x7f]/.test(this.relayServer) &&
      !/[\s\x00-\x1f\x7f]/.test(this.apiServer) &&
      !/[\s\x00-\x1f\x7f]/.test(this.serverKey)
  }

  toQrPayload(): string {
    const config: OfficialServerConfig = { host: this.idServer, relay: this.relayServer,
      api: this.apiServer, key: this.serverKey }
    return `config=${JSON.stringify(config)}`
  }
}
