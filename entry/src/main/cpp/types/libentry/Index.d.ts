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
  decodedFrames?: number;
  codec?: number;
  decoderMode?: number;
}

export interface RemoteCursorPosition {
  valid: boolean;
  embedded: boolean;
  x: number;
  y: number;
  sequence: number;
}

export interface RemoteCursorData {
  valid: boolean;
  id?: number;
  hotx?: number;
  hoty?: number;
  width?: number;
  height?: number;
  sequence?: number;
  colors?: ArrayBuffer;
}

export interface NativeMouseInputEvent {
  x: number;
  y: number;
  action: number;
  button: number;
  hover: number;
  timestamp: number;
  modifierMask: number;
  modifierValid: boolean;
}

export interface NativeKeyInputEvent {
  keyCode: number;
  action: number;
  timestamp: number;
  modifierMask: number;
  modifierValid: boolean;
  capsLockOn: boolean;
  capsLockValid: boolean;
}

export interface HardwareKeyState {
  valid: boolean;
  modifierMask: number;
  capsLockOn: boolean;
  capsLockValid: boolean;
}

export const initializeDiagnosticLog: (filesDirectory: string) => number;
export const setDiagnosticLogEnabled: (enabled: boolean) => number;
export const appendDiagnosticLog: (component: string, message: string) => number;
export const getDiagnosticLog: () => string;
export const clearDiagnosticLog: () => number;
export const connect: (peerId: string, password: string, rendezvousServer?: string, relayServer?: string) => number;
export const disconnect: () => number;
export const sendKeyEvent: (keyCode: number, action: number, modifierMask?: number) => number;
export const sendPhysicalKeyEvent: (scanCode: number, action: number, modifierMask?: number) => number;
export const sendText: (text: string) => number;
export const send2FA: (code: string, trustThisDevice: boolean) => number;
export const getEnableTrustedDevices: () => boolean;
export const sendClipboardText: (text: string) => number;
export const takeRemoteClipboardText: () => string;
export const requestRemoteDirectory: (path: string) => number;
export const takeRemoteDirectoryResult: () => string;
export const startFileUpload: (path: string, name: string, remoteDirectory: string) => number;
export const startFileDownloadBatch: (requestsJson: string, localRoot: string) => number;
export const getFileTransferStatus: () => string;
export const sendMouseEvent: (x: number, y: number, action: number, modifierMask?: number) => number;
export const sendMouseWheel: (deltaX: number, deltaY: number, modifierMask?: number) => number;
export const getDisplayCount: () => number;
export const getCurrentDisplay: () => number;
export const getRemoteCursorPosition: () => RemoteCursorPosition;
export const getRemoteCursorData: () => RemoteCursorData;
export const switchDisplay: (display: number) => number;
export const refreshVideo: () => number;
export const fallbackVideoToVp9: () => number;
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
export const prepareSurfaceRebind: () => number;
export const rebindSurface: (surfaceId: string) => number;
export const takeNativeMouseEvents: () => NativeMouseInputEvent[];
export const takeNativeKeyEvents: () => NativeKeyInputEvent[];
export const getHardwareKeyState: () => HardwareKeyState;
