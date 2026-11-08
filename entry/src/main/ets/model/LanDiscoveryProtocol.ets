import { util } from '@kit.ArkTS'

// RustDesk's RendezvousMessage.peer_discovery (field 22) / PeerDiscovery.
// Discovery is unauthenticated; none of these fields proves device identity.
export interface LanDiscoveryPeer {
  id: string
  hostname: string
  platform: string
  address: string
}

class WireValue {
  value: number = 0
  next: number = 0
}

export class LanDiscoveryProtocol {
  static readonly PORT: number = 21119
  static readonly MAX_PACKET: number = 2048

  static ping(): ArrayBuffer {
    return new Uint8Array([0xb2, 0x01, 0x06, 0x0a, 0x04, 0x70, 0x69, 0x6e, 0x67]).buffer
  }

  private static varint(bytes: Uint8Array, start: number, limit: number): WireValue | undefined {
    let value: number = 0
    let multiplier: number = 1
    for (let i: number = 0; i < 5 && start + i < limit; i++) {
      const b: number = bytes[start + i]
      value += (b & 0x7f) * multiplier
      if (value > 0xffffffff) return undefined
      if ((b & 0x80) === 0) {
        const result: WireValue = new WireValue()
        result.value = value
        result.next = start + i + 1
        return result
      }
      multiplier *= 128
    }
    return undefined
  }

  private static skip(bytes: Uint8Array, pos: number, end: number, wire: number): number {
    if (wire === 0) return LanDiscoveryProtocol.varint(bytes, pos, end)?.next ?? -1
    if (wire === 1) return pos + 8 <= end ? pos + 8 : -1
    if (wire === 5) return pos + 4 <= end ? pos + 4 : -1
    if (wire !== 2) return -1
    const length: WireValue | undefined = LanDiscoveryProtocol.varint(bytes, pos, end)
    if (length === undefined || length.value > end - length.next) return -1
    return length.next + length.value
  }

  private static cleanLabel(value: string): string {
    // Strip controls, invisible bidi overrides and line breaks from untrusted names.
    return value.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, '')
      .trim().substring(0, 80)
  }

  static parse(buffer: ArrayBuffer, address: string): LanDiscoveryPeer | undefined {
    if (buffer.byteLength === 0 || buffer.byteLength > LanDiscoveryProtocol.MAX_PACKET) return undefined
    const bytes: Uint8Array = new Uint8Array(buffer)
    let pos: number = 0
    let payloadStart: number = -1
    let payloadEnd: number = -1
    while (pos < bytes.length) {
      const key: WireValue | undefined = LanDiscoveryProtocol.varint(bytes, pos, bytes.length)
      if (key === undefined || key.value === 0) return undefined
      pos = key.next
      const field: number = Math.floor(key.value / 8)
      const wire: number = key.value % 8
      if (field >= 6 && field <= 29 && field !== 22) return undefined
      if (field === 22) {
        if (wire !== 2 || payloadStart !== -1) return undefined
        const length: WireValue | undefined = LanDiscoveryProtocol.varint(bytes, pos, bytes.length)
        if (length === undefined || length.value > bytes.length - length.next) return undefined
        payloadStart = length.next
        payloadEnd = length.next + length.value
        pos = payloadEnd
      } else {
        pos = LanDiscoveryProtocol.skip(bytes, pos, bytes.length, wire)
        if (pos < 0) return undefined
      }
    }
    if (payloadStart < 0) return undefined
    let cmd: string = ''
    let id: string = ''
    let hostname: string = ''
    let platform: string = ''
    pos = payloadStart
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true })
    try {
      while (pos < payloadEnd) {
        const key: WireValue | undefined = LanDiscoveryProtocol.varint(bytes, pos, payloadEnd)
        if (key === undefined || key.value === 0) return undefined
        pos = key.next
        const field: number = Math.floor(key.value / 8)
        const wire: number = key.value % 8
        if ([1, 3, 5, 6].includes(field)) {
          if (wire !== 2) return undefined
          const length: WireValue | undefined = LanDiscoveryProtocol.varint(bytes, pos, payloadEnd)
          if (length === undefined || length.value > 512 || length.value > payloadEnd - length.next) return undefined
          const value: string = decoder.decodeToString(bytes.subarray(length.next, length.next + length.value),
            { stream: false })
          if (field === 1) cmd = value
          if (field === 3) id = value
          if (field === 5) hostname = LanDiscoveryProtocol.cleanLabel(value)
          if (field === 6) platform = LanDiscoveryProtocol.cleanLabel(value)
          pos = length.next + length.value
        } else {
          pos = LanDiscoveryProtocol.skip(bytes, pos, payloadEnd, wire)
          if (pos < 0) return undefined
        }
      }
    } catch (_error) { return undefined }
    // Do not interpret attacker-controlled IDs as direct IP/port endpoints.
    if (cmd !== 'pong' || !/^[A-Za-z0-9_.-]{1,128}$/.test(id) ||
      (id.includes('.') && /^[0-9.]+$/.test(id))) return undefined
    return { id: id, hostname: hostname, platform: platform, address: address }
  }

  static ipv4(value: string): number | undefined {
    const parts: string[] = value.split('.')
    if (parts.length !== 4) return undefined
    let result: number = 0
    for (const part of parts) {
      if (!/^\d{1,3}$/.test(part)) return undefined
      const n: number = Number(part)
      if (n > 255) return undefined
      result = ((result << 8) | n) >>> 0
    }
    return result >>> 0
  }

  static isLocalPeer(local: string, prefix: number, sender: string): boolean {
    const a: number | undefined = LanDiscoveryProtocol.ipv4(local)
    const b: number | undefined = LanDiscoveryProtocol.ipv4(sender)
    if (a === undefined || b === undefined || !Number.isInteger(prefix) || prefix < 1 || prefix > 30) return false
    if ((b >>> 24) === 0 || (b >>> 24) === 127 || (b >>> 24) >= 224 || a === b) return false
    const mask: number = (0xffffffff << (32 - prefix)) >>> 0
    if ((a & mask) !== (b & mask)) return false
    const host: number = (b & (~mask >>> 0)) >>> 0
    return host !== 0 && host !== (~mask >>> 0)
  }
}
