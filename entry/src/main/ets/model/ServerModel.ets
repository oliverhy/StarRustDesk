export interface ClientInfo {
  id: number
  peerId: string
  peerUsername: string
  isFileTransfer: boolean
  isViewCamera: boolean
  isTerminal: boolean
  isPortForward: boolean
}

export class ServerModel {
  isServiceRunning: boolean = false
  deviceId: string = ''
  deviceName: string = ''
  password: string = ''
  isPasswordEnabled: boolean = false
  isApprovalRequired: boolean = false
  clients: ClientInfo[] = []
  isOnline: boolean = false
}
