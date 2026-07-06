import { RustDeskNapi } from './RustDeskNapi'
import { ConnectionStatus } from '../model/ConnectionModel'

export class ConnectionService {
  static connect(remoteId: string, password: string, performancePreset: string = 'smooth'): ConnectionStatus {
    let peerId: string = remoteId.trim()
    let rendezvousServer: string = RustDeskNapi.getOption('custom-rendezvous-server').trim()
    let relayServer: string = RustDeskNapi.getOption('relay-server').trim()
    RustDeskNapi.setPerformancePreset(performancePreset)
    let result: number
    if (rendezvousServer.length > 0) {
      result = RustDeskNapi.connectWithServer(peerId, password, rendezvousServer, relayServer)
    } else {
      result = RustDeskNapi.connect(peerId, password)
    }
    return result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED
  }

  static disconnect(): void {
    RustDeskNapi.disconnect()
  }

  static sendKeyEvent(keyCode: number, action: number): void {
    RustDeskNapi.sendKeyEvent(keyCode, action)
  }

  static sendPhysicalKeyEvent(scanCode: number, action: number): void {
    RustDeskNapi.sendPhysicalKeyEvent(scanCode, action)
  }

  static sendText(text: string): void {
    RustDeskNapi.sendText(text)
  }

  static sendMouseEvent(x: number, y: number, action: number): void {
    RustDeskNapi.sendMouseEvent(x, y, action)
  }

  static sendMouseWheel(deltaX: number, deltaY: number): void {
    RustDeskNapi.sendMouseWheel(deltaX, deltaY)
  }

  static getConnectionStatus(): ConnectionStatus {
    let status: number = RustDeskNapi.getConnectionStatus()
    return status as ConnectionStatus
  }

  static getConnectionRoute(): number {
    return RustDeskNapi.getConnectionRoute()
  }

  static getPeerId(): string {
    return RustDeskNapi.getOption('last_connected_peer')
  }

  static getLastConnectionError(): string {
    return RustDeskNapi.getLastConnectionError()
  }
}
