import { connection, socket } from '@kit.NetworkKit'
import { LanDiscoveryPeer, LanDiscoveryProtocol } from '../model/LanDiscoveryProtocol'
import { RemoteSessionBackgroundTask } from './RemoteSessionBackgroundTask'
import { RustDeskNapi } from './RustDeskNapi'

interface LocalLanInterface {
  address: string
  prefix: number
  network: connection.NetHandle
}

export interface LanScanResult {
  status: string
  peers: LanDiscoveryPeer[]
}

// Only listens for responses to our own short-lived query. We never advertise
// this app as a controllable host or persist the unauthenticated replies.
export class LanDiscoveryService {
  private generation: number = 0
  private sockets: socket.UDPSocket[] = []
  private networkSignature: string = ''

  private log(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('lan-discovery', message) } catch (_error) {}
  }

  cancel(): void {
    this.generation++
    this.networkSignature = ''
    const old: socket.UDPSocket[] = this.sockets
    this.sockets = []
    if (old.length > 0) this.log('scan_cancelled')
    old.forEach((item: socket.UDPSocket) => { try { item.close().catch(() => {}) } catch (_error) {} })
  }

  private async interfaces(): Promise<LocalLanInterface[]> {
    const networks: connection.NetHandle[] = await connection.getAllNets()
    const result: LocalLanInterface[] = []
    for (const network of networks.slice(0, 16)) {
      try {
        const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(network)
        const types: connection.NetBearType[] = capabilities.bearerTypes
        if (types.includes(connection.NetBearType.BEARER_VPN) ||
          types.includes(connection.NetBearType.BEARER_CELLULAR) ||
          (!types.includes(connection.NetBearType.BEARER_WIFI) &&
            !types.includes(connection.NetBearType.BEARER_ETHERNET))) continue
        const props: connection.ConnectionProperties = await connection.getConnectionProperties(network)
        for (const link of props.linkAddresses) {
          const ip: number | undefined = LanDiscoveryProtocol.ipv4(link.address.address)
          const prefix: number = link.prefixLength
          if (ip === undefined || (ip >>> 24) === 0 || (ip >>> 24) === 127 || (ip >>> 24) >= 224 ||
            !Number.isInteger(prefix) || prefix < 1 || prefix > 30) continue
          if (!result.some((v: LocalLanInterface) => v.network.netId === network.netId && v.address === link.address.address)) {
            result.push({ address: link.address.address, prefix: prefix, network: network })
          }
          if (result.length >= 8) return result
        }
      } catch (_error) { /* a network may disappear while enumerating */ }
    }
    return result
  }

  private signature(items: LocalLanInterface[]): string {
    // In memory only: never write network addresses or identifiers to logs.
    return items.map((v: LocalLanInterface) => `${v.network.netId}/${v.address}/${v.prefix}`).sort().join('|')
  }

  async isCurrentNetwork(): Promise<boolean> {
    if (this.networkSignature.length === 0 || RemoteSessionBackgroundTask.isAppBackground()) return false
    try { return this.signature(await this.interfaces()) === this.networkSignature } catch (_error) { return false }
  }

  async scan(onPeers: (peers: LanDiscoveryPeer[]) => void): Promise<LanScanResult> {
    this.cancel()
    const ticket: number = this.generation
    const peers: LanDiscoveryPeer[] = []
    let received: number = 0
    let rejected: number = 0
    let sent: number = 0
    this.log('scan_start protocol=rustdesk_udp')
    try {
      if (RemoteSessionBackgroundTask.isAppBackground()) return { status: 'cancelled', peers: [] }
      const interfaces: LocalLanInterface[] = await this.interfaces()
      if (ticket !== this.generation) return { status: 'cancelled', peers: [] }
      if (interfaces.length === 0) {
        this.log('scan_no_local_network')
        return { status: 'no_network', peers: [] }
      }
      this.networkSignature = this.signature(interfaces)
      for (const iface of interfaces) {
        if (ticket !== this.generation || RemoteSessionBackgroundTask.isAppBackground()) break
        const udp: socket.UDPSocket = socket.constructUDPSocketInstance()
        this.sockets.push(udp)
        let phase: string = 'socket_bind'
        try {
          udp.on('message', (info: socket.SocketMessageInfo) => {
            if (ticket !== this.generation || RemoteSessionBackgroundTask.isAppBackground()) return
            received++
            if (received > 512 || info.remoteInfo.family !== 'IPv4' || info.remoteInfo.port !== LanDiscoveryProtocol.PORT ||
              !LanDiscoveryProtocol.isLocalPeer(iface.address, iface.prefix, info.remoteInfo.address)) { rejected++; return }
            const peer: LanDiscoveryPeer | undefined = LanDiscoveryProtocol.parse(info.message, info.remoteInfo.address)
            if (peer === undefined) { rejected++; return }
            if (peers.some((p: LanDiscoveryPeer) => p.id === peer.id && p.address === peer.address)) return
            if (peers.length >= 100) { rejected++; return }
            peers.push(peer)
            onPeers(peers.slice())
          })
          await udp.bind({ address: iface.address, family: 1, port: 0 })
          if (ticket !== this.generation) break
          phase = 'network_bind'
          await iface.network.bindSocket(udp)
          if (ticket !== this.generation) break
          phase = 'enable_broadcast'
          await udp.setExtraOptions({ broadcast: true })
          if (ticket !== this.generation || RemoteSessionBackgroundTask.isAppBackground()) break
          phase = 'send'
          await udp.send({ data: LanDiscoveryProtocol.ping(),
            address: { address: '255.255.255.255', family: 1, port: LanDiscoveryProtocol.PORT } })
          sent++
        } catch (_error) {
          this.log(`scan_interface_error phase=${phase}`)
          try { await udp.close() } catch (_closeError) {}
        }
      }
      if (ticket !== this.generation || RemoteSessionBackgroundTask.isAppBackground()) return { status: 'cancelled', peers: [] }
      if (sent === 0) {
        this.networkSignature = ''
        this.log(`scan_send_failed interfaces=${interfaces.length}`)
        return { status: 'error', peers: [] }
      }
      this.log(`scan_sent interfaces=${sent}`)
      for (let i: number = 0; i < 4; i++) {
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 750) })
        if (ticket !== this.generation || RemoteSessionBackgroundTask.isAppBackground()) return { status: 'cancelled', peers: [] }
        if (!await this.isCurrentNetwork()) {
          this.networkSignature = ''
          this.log('scan_stopped reason=network_changed')
          return { status: 'network_changed', peers: [] }
        }
      }
      this.log(`scan_complete responses=${received} rejected=${rejected} devices=${peers.length}`)
      return { status: 'complete', peers: peers.slice() }
    } catch (_error) {
      if (ticket !== this.generation) return { status: 'cancelled', peers: [] }
      this.networkSignature = ''
      this.log('scan_failed phase=network_or_socket')
      return { status: 'error', peers: [] }
    } finally {
      if (ticket === this.generation) {
        const old: socket.UDPSocket[] = this.sockets
        this.sockets = []
        old.forEach((item: socket.UDPSocket) => { try { item.close().catch(() => {}) } catch (_error) {} })
      }
    }
  }
}
