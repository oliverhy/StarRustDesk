export enum ConnectionStatus {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  FAILED = 3,
}

export class ConnectionModel {
  status: ConnectionStatus = ConnectionStatus.DISCONNECTED
  remoteId: string = ''
  password: string = ''
  errorMessage: string = ''
  isOutgoing: boolean = true
  connId: number = -1
  peerId: string = ''
  peerUsername: string = ''

  reset(): void {
    this.status = ConnectionStatus.DISCONNECTED
    this.remoteId = ''
    this.password = ''
    this.errorMessage = ''
    this.isOutgoing = true
    this.connId = -1
    this.peerId = ''
    this.peerUsername = ''
  }
}
