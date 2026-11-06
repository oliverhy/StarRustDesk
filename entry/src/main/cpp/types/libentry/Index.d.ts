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
  renderedFrames?: number;
  queuedFrames?: number;
  gameEffectiveFps?: number;
  requestedFps?: number;
  requestedBitratePercent?: number;
  generation?: number;
  security?: number;
  codec?: number;
  decoderMode?: number;
  delayMs?: number;
  delaySampleSeq?: number;
  targetBitrateKb?: number;
  dynamicRange?: number;
  colorOutput?: number;
  bitDepth?: number;
}

export const sendChatMessage: (text: string) => number;
export const takeChatMessages: () => string;
export const requestVoiceCall: () => number;
export const getVoiceCallState: () => number;
export const endVoiceCall: () => number;
export const startVoiceCapture: () => number;
export const stopVoiceCapture: () => number;

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
  source?: number;
  timestamp: number;
  modifierMask: number;
  modifierValid: boolean;
  capsLockOn: boolean;
  capsLockValid: boolean;
}

// Exactly one of mouse, key, or reset=true is present. Consume in array order.
// Sequence is process-wide and increasing; coalesced moves can leave gaps.
export interface NativeInputEvent {
  sequence: number;
  mouse?: NativeMouseInputEvent;
  key?: NativeKeyInputEvent;
  // Release all tracked remote keys/buttons and clear local input state first.
  reset?: boolean;
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
export const connect: (peerId: string, password: string, rendezvousServer?: string, relayServer?: string,
  forceRelay?: boolean, allowInsecureFallback?: boolean, fileOnly?: boolean,
  lockAfterDisconnect?: boolean, privacyMode?: boolean, osPassword?: string, insecureReason?: number,
  transportPolicy?: number) => number;
export const disconnect: () => number;
export const setGameMode: (enabled: boolean) => number;
export const setHighPerformance: (enabled: boolean) => number;
export interface GamepadInputEvent {
  kind: number;
  device: number;
  control: number;
  action: number;
  x: number;
  y: number;
}
export const startGamepadMonitor: () => number;
export const stopGamepadMonitor: () => number;
export const takeGamepadEvents: () => GamepadInputEvent[];
export const setGameFps: (fps: number) => number;
export const setPrivacyMode: (enabled: boolean) => number;
export const getPrivacyModeState: () => number;
export const sendKeyEvent: (keyCode: number, action: number, modifierMask?: number) => number;
export const sendPrintableShortcutKey: (keyCode: number, modifierMask: number) => number;
export const sendCtrlAltDel: () => number;
export const canSendCtrlAltDel: () => boolean;
export const sendPhysicalKeyEvent: (hidCode: number, action: number, modifierMask?: number) => number;
export const sendText: (text: string) => number;
export const send2FA: (code: string, trustThisDevice: boolean) => number;
export const getEnableTrustedDevices: () => boolean;
export const sendClipboardText: (text: string) => number;
export const takeRemoteClipboardText: () => string;
export const requestRemoteDirectory: (path: string) => number;
export const takeRemoteDirectoryResult: () => string;
export const startFileUpload: (path: string, name: string, remoteDirectory: string) => number;
export const remoteFileOperation: (kind: number, path: string, name: string) => number;
export const takeFileOperationResult: () => string;
export const cancelFileOperation: () => void;
export const startRecording: (path: string) => number;
export const stopRecording: () => number;
export const getRecordingStatus: () => number;
export const startFileDownloadBatch: (requestsJson: string, localRoot: string) => number;
export const getFileTransferStatus: () => string;
export const cancelFileTransfer: () => number;
export const sendMouseEvent: (x: number, y: number, action: number, modifierMask?: number) => number;
export const sendMouseWheel: (deltaX: number, deltaY: number, modifierMask?: number) => number;
export const sendMobileAction: (action: number) => number;
export const isPeerAndroid: () => boolean;
export const getDisplayCount: () => number;
export const getCurrentDisplay: () => number;
export const getRemoteCursorPosition: () => RemoteCursorPosition;
export const getRemoteCursorData: (lastSequence?: number) => RemoteCursorData;
export const switchDisplay: (display: number) => number;
export const refreshVideo: () => number;
export const setRemoteAudioEnabled: (enabled: boolean) => number;
export const isRemoteAudioActive: () => boolean;
export const setBackgroundVideoMode: (enabled: boolean) => number;
export const fallbackVideoToVp9: () => number;
export const getPeerList: () => PeerInfo[];
export const queryPeerOnlineStates: (peersJson: string, rendezvousServer: string) => number;
export const takePeerOnlineStates: () => string;
export const getConnectionStatus: () => number;
export const getConnectionRoute: () => number;
export const getConnectionTransport: () => number;
export const getLastConnectionError: () => string;
export const getDeviceName: () => string;
export const getClipboardText: () => string;
export const setClipboardText: (text: string) => number;
export const setOption: (key: string, value: string) => number;
export const setApiAccountContext: (json: string) => number;
export const getOption: (key: string) => string;
export const getAllOptions: () => string;
export const testIfValidServer: (server: string) => string;
export const isUsingPublicServer: () => boolean;
export const getVideoFrame: () => VideoFrameInfo;
export const setHdrDisplayFormats: (formats: number) => number;
export const setSurfaceId: (surfaceId: string) => number;
export interface SecondaryDisplayState { display: number; error: number; width: number; height: number; frames: number; token: number; }
export const isSecondaryDisplaySupported: () => boolean;
export const startSecondaryDisplay: (surfaceId: string, display: number) => number;
export const stopSecondaryDisplay: (token?: number) => number;
export const releaseSecondaryButtons: (token: number) => number;
export const getSecondaryDisplayState: () => SecondaryDisplayState;
export const sendSecondaryPointer: (token: number, x: number, y: number, action: number, modifiers: number) => number;
export const setSecondaryKeyboardFocus: (token: number, focused: boolean) => number;
export const queueSecondaryKey: (token: number, code: number, action: number, mask: number, valid: boolean, caps: number) => number;
export const sendSecondaryWheel: (token: number, x: number, y: number, dx: number, dy: number, modifiers: number) => number;
export const prepareSurfaceRebind: () => number;
export const rebindSurface: (surfaceId: string) => number;
// Atomically drains both input kinds. Overflow clears the backlog and returns
// a reset marker before the triggering event. Do not mix with legacy drains.
export const takeNativeInputEvents: () => NativeInputEvent[];
/** @deprecated No cross-device ordering; throws ERR_NATIVE_INPUT_RESET on overflow. */
export const takeNativeMouseEvents: () => NativeMouseInputEvent[];
/** @deprecated No cross-device ordering; throws ERR_NATIVE_INPUT_RESET on overflow. */
export const takeNativeKeyEvents: () => NativeKeyInputEvent[];
export const getHardwareKeyState: () => HardwareKeyState;
