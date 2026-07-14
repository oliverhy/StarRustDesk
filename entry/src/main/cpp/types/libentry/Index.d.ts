export interface PeerInfo {
  id: string;
  name: string;
  platform: string;
  online: boolean;
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
export const sendClipboardText: (text: string) => number;
export const takeRemoteClipboardText: () => string;
export const requestRemoteDirectory: (path: string) => number;
export const takeRemoteDirectoryResult: () => string;
export const startFileUpload: (path: string, name: string, remoteDirectory: string) => number;
export const getFileTransferStatus: () => string;
export const sendMouseEvent: (x: number, y: number, action: number) => number;
export const sendMouseWheel: (deltaX: number, deltaY: number) => number;
export const getDisplayCount: () => number;
export const getCurrentDisplay: () => number;
export const switchDisplay: (display: number) => number;
export const refreshVideo: () => number;
export const getPeerList: () => PeerInfo[];
export const getConnectionStatus: () => number;
export const getConnectionRoute: () => number;
export const getLastConnectionError: () => string;
export const getDeviceName: () => string;
export const getClipboardText: () => string;
export const setClipboardText: (text: string) => number;
export const setOption: (key: string, value: string) => number;
export const getOption: (key: string) => string;
export const getAllOptions: () => string;
export const testIfValidServer: (server: string) => string;
export const isUsingPublicServer: () => boolean;
export const getVideoFrame: () => VideoFrameInfo;
export const setSurfaceId: (surfaceId: string) => number;
