export interface Peer {
  id: string
  username: string
  hostname: string
  alias: string
  platform: string
  password: string
  forceAlwaysRelay: boolean
  rdpPort: string
  rdpUsername: string
  loginName: string
  deviceGroupName: string
  note: string
  isOnline: boolean
}

export function createEmptyPeer(): Peer {
  return {
    id: '',
    username: '',
    hostname: '',
    alias: '',
    platform: '',
    password: '',
    forceAlwaysRelay: false,
    rdpPort: '',
    rdpUsername: '',
    loginName: '',
    deviceGroupName: '',
    note: '',
    isOnline: false,
  }
}

export function peerDisplayName(peer: Peer): string {
  if (peer.alias.length > 0) {
    return peer.alias
  }
  if (peer.hostname.length > 0) {
    return peer.hostname
  }
  return peer.id
}
