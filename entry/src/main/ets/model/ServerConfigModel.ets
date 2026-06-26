import { util } from '@kit.ArkTS'

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
    let config: ServerConfigModel = new ServerConfigModel()
    config.idServer = options['custom-rendezvous-server'] ?? ''
    config.relayServer = options['relay-server'] ?? ''
    config.apiServer = options['api-server'] ?? ''
    config.serverKey = options['key'] ?? ''
    return config
  }

  static decode(encoded: string): ServerConfigModel {
    try {
      let reversed: string = ''
      for (let i: number = encoded.length - 1; i >= 0; i--) {
        reversed += encoded[i]
      }
      let decodedStr: string = ''
      try {
        let src: util.Base64Helper = new util.Base64Helper()
        let buf: Uint8Array = src.decodeSync(reversed)
        decodedStr = ''
        for (let i: number = 0; i < buf.length; i++) {
          decodedStr += String.fromCharCode(buf[i])
        }
      } catch (_e) {
        decodedStr = encoded
      }
      let json: Record<string, string> = JSON.parse(decodedStr) as Record<string, string>
      return new ServerConfigModel(json['host'], json['relay'], json['api'], json['key'])
    } catch (_e) {
      return new ServerConfigModel()
    }
  }

  encode(): string {
    let config: Record<string, string> = {
      'host': this.idServer.trim(),
      'relay': this.relayServer.trim(),
      'api': this.apiServer.trim(),
      'key': this.serverKey.trim(),
    }
    let jsonStr: string = JSON.stringify(config)
    let encoder: util.TextEncoder = new util.TextEncoder()
    let buf: Uint8Array = encoder.encodeInto(jsonStr)
    let src: util.Base64Helper = new util.Base64Helper()
    let b64: string = src.encodeToStringSync(buf)
    let reversed: string = ''
    for (let i: number = b64.length - 1; i >= 0; i--) {
      reversed += b64[i]
    }
    return reversed
  }

  isValid(): boolean {
    return this.idServer.length > 0
  }
}
