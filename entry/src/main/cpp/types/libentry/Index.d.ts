export interface FileTransferProgressInfo {
  status: number;
  fileName: string;
  totalBytes: number;
  transferredBytes: number;
  progress: number;
}

export interface PeerInfo {
  id: string;
  name: string;
  platform: string;
  online: boolean;
}

export interface SessionInfo {
  peerId: string;
  clientAddr: string;
  connectedAt: number;
}

export interface VideoFrameInfo {
  hasFrame: boolean;
  width: number;
  height: number;
  length: number;
  totalFrames?: number;
  totalBytes?: number;
}

export const connect: (peerId: string, password: string, rendezvousServer?: string, relayServer?: string) => number;
export const disconnect: () => number;
export const sendKeyEvent: (keyCode: number, action: number) => number;
export const sendPhysicalKeyEvent: (scanCode: number, action: number) => number;
export const sendText: (text: string) => number;
export const sendMouseEvent: (x: number, y: number, action: number) => number;
export const sendMouseWheel: (deltaX: number, deltaY: number) => number;
export const getDisplayCount: () => number;
export const getCurrentDisplay: () => number;
export const switchDisplay: (display: number) => number;
export const refreshVideo: () => number;
export const startService: () => number;
export const stopService: () => number;
export const getActiveSessions: () => SessionInfo[];
export const getPeerList: () => PeerInfo[];
export const getConnectionStatus: () => number;
export const getConnectionRoute: () => number;
export const getLastConnectionError: () => string;
export const getDeviceId: () => string;
export const getDeviceName: () => string;
export const sendFile: (localPath: string, remotePath: string) => number;
export const receiveFile: (remotePath: string, localPath: string) => number;
export const getFileTransferProgress: () => FileTransferProgressInfo;
export const cancelFileTransfer: () => number;
export const getClipboardText: () => string;
export const setClipboardText: (text: string) => number;
export const setOption: (key: string, value: string) => number;
export const getOption: (key: string) => string;
export const getAllOptions: () => string;
export const testIfValidServer: (server: string) => string;
export const isUsingPublicServer: () => boolean;
export const getVideoFrame: () => VideoFrameInfo;
export const setSurfaceId: (surfaceId: string) => number;
