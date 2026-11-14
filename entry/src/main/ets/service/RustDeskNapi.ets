import rustdeskNapi from 'libentry.so'
import { pasteboard, deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { RELEASE_NOTES_VERSION, RELEASE_NOTES_BUILD } from '../widget/ReleaseNotesDialog'

export interface RemoteSecurityOptions {
  lockAfterDisconnect: boolean
  privacyMode: boolean
  autoUnlock: boolean
}

export interface ClipboardImportReadResult {
  text: string
  failed: boolean
  code: number
}

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()

export interface PeerInfo {
  id: string
  name: string
  platform: string
  online: boolean
}

export interface VideoFrameInfo {
  hasFrame: boolean
  width: number
  height: number
  length: number
  totalFrames?: number
  totalBytes?: number
  decodedFrames?: number
  renderedFrames?: number
  queuedFrames?: number
  gameEffectiveFps?: number
  requestedFps?: number
  requestedBitratePercent?: number
  generation?: number
  security?: number
  codec?: number
  decoderMode?: number
  delayMs?: number
  delaySampleSeq?: number
  targetBitrateKb?: number
  dynamicRange?: number
  colorOutput?: number
  bitDepth?: number
}

export interface GamepadInputEvent {
  kind: number
  device: number
  control: number
  action: number
  x: number
  y: number
}

export interface RemoteCursorPosition {
  valid: boolean
  embedded: boolean
  x: number
  y: number
  sequence: number
}

export interface RemoteCursorData {
  valid: boolean
  id?: number
  hotx?: number
  hoty?: number
  width?: number
  height?: number
  sequence?: number
  colors?: ArrayBuffer
}

export interface NativeMouseInputEvent {
  x: number
  y: number
  action: number
  button: number
  hover: number
  timestamp: number
  modifierMask: number
  modifierValid: boolean
  surfaceWidth?: number
  surfaceHeight?: number
}

export interface SecondaryDisplayState {
  display: number
  error: number
  width: number
  height: number
  frames: number
  token: number
}

export interface NativeKeyInputEvent {
  keyCode: number
  action: number
  source?: number
  deviceId?: number
  timestamp: number
  modifierMask: number
  modifierValid: boolean
  capsLockOn: boolean
  capsLockValid: boolean
}

// Exactly one of mouse, key, or reset=true is present. Consume in array order.
// Sequence is process-wide and increasing; coalesced moves can leave gaps.
export interface NativeInputEvent {
  sequence: number
  mouse?: NativeMouseInputEvent
  key?: NativeKeyInputEvent
  // Release all tracked remote keys/buttons and clear local input state first.
  reset?: boolean
}

export interface HardwareKeyState {
  valid: boolean
  modifierMask: number
  capsLockOn: boolean
  capsLockValid: boolean
}

export interface RemoteDirectoryEntry {
  name: string
  entryType: number
  size: number
  modifiedTime: number
}

export interface RemoteDirectoryResult {
  path: string
  entries: RemoteDirectoryEntry[]
  error: string
}

export interface FileTransferStatus {
  sessionId: number
  state: string
  transferred: number
  total: number
  error: string
  direction?: string
  completedItems?: number
  totalItems?: number
}

export interface FileDownloadRequest {
  remotePath: string
  localName: string
  isDirectory: boolean
}

export interface PeerOnlineState {
  id: string
  online: boolean
}

export interface PeerOnlineResult {
  peers: PeerOnlineState[]
  error: string
  server: string
}

export class RustDeskNapi {
  static getInputCapabilities(): number {
    return (rustdeskNapi as ESObject).getInputCapabilities()
  }

  static setInputModes(mode: number, relative: boolean): number {
    return (rustdeskNapi as ESObject).setInputModes(mode, relative ? 1 : 0)
  }

  static sendMouseRelative(dx: number, dy: number, modifierMask: number): number {
    return (rustdeskNapi as ESObject).sendMouseRelative(dx, dy, modifierMask)
  }

  static initializeDiagnosticLog(filesDirectory: string): number {
    return (rustdeskNapi as ESObject).initializeDiagnosticLog(filesDirectory)
  }

  static setDiagnosticLogEnabled(enabled: boolean): number {
    return (rustdeskNapi as ESObject).setDiagnosticLogEnabled(enabled)
  }

  static appendDiagnosticLog(component: string, message: string): number {
    return (rustdeskNapi as ESObject).appendDiagnosticLog(component, message)
  }

  static getDiagnosticLog(): string {
    return `app_version=${RELEASE_NOTES_VERSION} version_code=${RELEASE_NOTES_BUILD} ` +
      `sdk=${deviceInfo.sdkApiVersion} device_type=${deviceInfo.deviceType}\n` +
      (rustdeskNapi as ESObject).getDiagnosticLog()
  }

  static clearDiagnosticLog(): number {
    return (rustdeskNapi as ESObject).clearDiagnosticLog()
  }

  static connect(peerId: string, password: string, allowInsecureFallback: boolean = false, fileOnly: boolean = false,
    security: RemoteSecurityOptions = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false },
    osPassword: string = '', insecureReason: number = 0, transportPolicy: number = 0): number {
    return rustdeskNapi.connect(peerId, password, '', '', false, allowInsecureFallback, fileOnly,
      security.lockAfterDisconnect, security.privacyMode, security.autoUnlock ? osPassword : '', insecureReason, transportPolicy)
  }

  static connectWithServer(peerId: string, password: string, rendezvousServer: string, relayServer: string,
    forceRelay: boolean = false, allowInsecureFallback: boolean = false, fileOnly: boolean = false,
    security: RemoteSecurityOptions = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false },
    osPassword: string = '', insecureReason: number = 0, transportPolicy: number = 0): number {
    return rustdeskNapi.connect(peerId, password, rendezvousServer, relayServer, forceRelay, allowInsecureFallback, fileOnly,
      security.lockAfterDisconnect, security.privacyMode, security.autoUnlock ? osPassword : '', insecureReason, transportPolicy)
  }

  static restartVideoDecoder(): number {
    return (rustdeskNapi as ESObject).restartVideoDecoder()
  }

  static setPerformancePreset(preset: string): number {
    return (rustdeskNapi as ESObject).setPerformancePreset(preset)
  }

  static setGameMode(enabled: boolean): number {
    return rustdeskNapi.setGameMode(enabled)
  }

  static setHighPerformance(enabled: boolean): number {
    return rustdeskNapi.setHighPerformance(enabled)
  }

  static startGamepadMonitor(): number { return rustdeskNapi.startGamepadMonitor() }
  static stopGamepadMonitor(): number { return rustdeskNapi.stopGamepadMonitor() }
  static takeGamepadEvents(): GamepadInputEvent[] { return rustdeskNapi.takeGamepadEvents() }

  static setGameFps(fps: number): number {
    return rustdeskNapi.setGameFps(fps)
  }

  static disconnect(): number {
    return rustdeskNapi.disconnect()
  }

  static setPrivacyMode(enabled: boolean): number {
    return rustdeskNapi.setPrivacyMode(enabled)
  }

  static getPrivacyModeState(): number {
    return rustdeskNapi.getPrivacyModeState()
  }

  static sendKeyEvent(keyCode: number, action: number, modifierMask: number = 0): number {
    return rustdeskNapi.sendKeyEvent(keyCode, action, modifierMask)
  }

  static sendPrintableShortcutKey(keyCode: number, modifierMask: number): number {
    return rustdeskNapi.sendPrintableShortcutKey(keyCode, modifierMask)
  }

  static sendCtrlAltDel(): number {
    return (rustdeskNapi as ESObject).sendCtrlAltDel()
  }

  static canSendCtrlAltDel(): boolean {
    return (rustdeskNapi as ESObject).canSendCtrlAltDel()
  }

  static sendPhysicalKeyEvent(hidCode: number, action: number, modifierMask: number = 0): number {
    return (rustdeskNapi as ESObject).sendPhysicalKeyEvent(hidCode, action, modifierMask)
  }

  static sendText(text: string): number {
    return (rustdeskNapi as ESObject).sendText(text)
  }

  static send2FA(code: string, trustThisDevice: boolean): number {
    return (rustdeskNapi as ESObject).send2FA(code, trustThisDevice)
  }

  static getEnableTrustedDevices(): boolean {
    return (rustdeskNapi as ESObject).getEnableTrustedDevices()
  }

  static sendMouseEvent(x: number, y: number, action: number, modifierMask: number = 0): number {
    return rustdeskNapi.sendMouseEvent(x, y, action, modifierMask)
  }

  static sendMouseWheel(deltaX: number, deltaY: number, modifierMask: number = 0): number {
    return (rustdeskNapi as ESObject).sendMouseWheel(deltaX, deltaY, modifierMask)
  }

  static sendMobileAction(action: number): number {
    return (rustdeskNapi as ESObject).sendMobileAction(action)
  }

  static isPeerAndroid(): boolean {
    return (rustdeskNapi as ESObject).isPeerAndroid()
  }

  // Atomic ordered drain. Overflow returns reset before the triggering event.
  // Use exclusively: legacy drains consume from the same queue.
  static takeNativeInputEvents(): NativeInputEvent[] {
    return (rustdeskNapi as ESObject).takeNativeInputEvents() as NativeInputEvent[]
  }

  static setSecondaryKeyboardFocus(token: number, focused: boolean): number {
    return (rustdeskNapi as ESObject).setSecondaryKeyboardFocus(token, focused)
  }

  static queueSecondaryKey(token: number, code: number, action: number, mask: number,
    valid: boolean, caps: number, deviceId: number = -1): number {
    return (rustdeskNapi as ESObject).queueSecondaryKey(token, code, action, mask, valid, caps, deviceId)
  }

  // Deprecated: unordered across devices; throws ERR_NATIVE_INPUT_RESET on overflow.
  static takeNativeMouseEvents(): NativeMouseInputEvent[] {
    return (rustdeskNapi as ESObject).takeNativeMouseEvents() as NativeMouseInputEvent[]
  }

  // Deprecated: unordered across devices; throws ERR_NATIVE_INPUT_RESET on overflow.
  static takeNativeKeyEvents(): NativeKeyInputEvent[] {
    return (rustdeskNapi as ESObject).takeNativeKeyEvents() as NativeKeyInputEvent[]
  }

  static getHardwareKeyState(): HardwareKeyState {
    return (rustdeskNapi as ESObject).getHardwareKeyState() as HardwareKeyState
  }

  static getDisplayCount(): number {
    return (rustdeskNapi as ESObject).getDisplayCount()
  }

  static getCurrentDisplay(): number {
    return (rustdeskNapi as ESObject).getCurrentDisplay()
  }

  static getRemoteCursorPosition(): RemoteCursorPosition {
    return (rustdeskNapi as ESObject).getRemoteCursorPosition() as RemoteCursorPosition
  }

  static getRemoteCursorData(lastSequence: number = -1): RemoteCursorData {
    return (rustdeskNapi as ESObject).getRemoteCursorData(lastSequence) as RemoteCursorData
  }

  static switchDisplay(display: number): number {
    return (rustdeskNapi as ESObject).switchDisplay(display)
  }

  static refreshVideo(): number {
    return (rustdeskNapi as ESObject).refreshVideo()
  }

  static setRemoteAudioEnabled(enabled: boolean): number {
    return (rustdeskNapi as ESObject).setRemoteAudioEnabled(enabled)
  }

  static isRemoteAudioActive(): boolean {
    return (rustdeskNapi as ESObject).isRemoteAudioActive()
  }

  static setBackgroundVideoMode(enabled: boolean): number {
    return (rustdeskNapi as ESObject).setBackgroundVideoMode(enabled)
  }

  static fallbackVideoToVp9(): number {
    return (rustdeskNapi as ESObject).fallbackVideoToVp9()
  }

  static getPeerList(): PeerInfo[] {
    return rustdeskNapi.getPeerList()
  }

  static queryPeerOnlineStates(peerIds: string[], rendezvousServer: string): number {
    return (rustdeskNapi as ESObject).queryPeerOnlineStates(JSON.stringify(peerIds), rendezvousServer)
  }

  static takePeerOnlineStates(): string {
    return (rustdeskNapi as ESObject).takePeerOnlineStates()
  }

  static getConnectionStatus(): number {
    return rustdeskNapi.getConnectionStatus()
  }

  static getConnectionRoute(): number {
    return (rustdeskNapi as ESObject).getConnectionRoute()
  }

  static getConnectionTransport(): number {
    return (rustdeskNapi as ESObject).getConnectionTransport()
  }

  static getLastConnectionError(): string {
    return rustdeskNapi.getLastConnectionError()
  }

  static getDeviceName(): string {
    return rustdeskNapi.getDeviceName()
  }

  static getClipboardText(): string {
    return ''
  }

  static async getClipboardTextAsync(): Promise<string> {
    try {
      let data: pasteboard.PasteData = await systemPasteboard.getData()
      let recordCount: number = data.getRecordCount()
      for (let i: number = 0; i < recordCount; i++) {
        let record: pasteboard.PasteDataRecord = data.getRecord(i)
        let text: string = RustDeskNapi.getPlainTextFromRecord(record)
        if (text.length > 0) {
          return text
        }
      }
    } catch (_e) {
      // clipboard may be empty or no permission
    }
    return ''
  }

  // Import needs to distinguish an empty clipboard from an OS read failure.
  // Keep the existing remote clipboard API's behaviour unchanged.
  static async getClipboardTextForImportAsync(): Promise<ClipboardImportReadResult> {
    try {
      const data: pasteboard.PasteData = await systemPasteboard.getData()
      const recordCount: number = data.getRecordCount()
      for (let i: number = 0; i < recordCount; i++) {
        try {
          const text: string = RustDeskNapi.getPlainTextFromRecord(data.getRecord(i))
          if (text.length > 0) return { text: text, failed: false, code: 0 }
        } catch (_recordError) {
          // A non-text record must not prevent reading a later text record.
        }
      }
      return { text: '', failed: false, code: 0 }
    } catch (error) {
      const code = (error as BusinessError)?.code
      return { text: '', failed: true, code: typeof code === 'number' && Number.isFinite(code) ? code : 0 }
    }
  }

  // The remote synchronizer must distinguish an empty clipboard from a
  // permission/read failure, without logging or persisting clipboard contents.
  static async getClipboardTextForSyncAsync(): Promise<ClipboardImportReadResult> {
    return await RustDeskNapi.getClipboardTextForImportAsync()
  }

  static observeClipboardChanges(callback: () => void): boolean {
    try {
      systemPasteboard.on('update', callback)
      return true
    } catch (_e) {
      return false
    }
  }

  static stopObservingClipboardChanges(callback: () => void): void {
    try { systemPasteboard.off('update', callback) } catch (_e) {}
  }

  private static getPlainTextFromRecord(record: pasteboard.PasteDataRecord): string {
    const plainText: string = record.plainText ?? ''
    if (plainText.length > 0) {
      return plainText
    }
    const htmlText: string = record.htmlText ?? ''
    if (htmlText.length > 0) {
      return RustDeskNapi.htmlToText(htmlText)
    }
    return record.toPlainText() ?? ''
  }

  private static htmlToText(html: string): string {
    return html
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, '\'')
      .trim()
  }

  static setClipboardText(text: string): number {
    try {
      let pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      systemPasteboard.setData(pasteData)
      return 0
    } catch (_e) {
      return -1
    }
  }

  static sendClipboardText(text: string): number {
    return (rustdeskNapi as ESObject).sendClipboardText(text)
  }

  static async setClipboardTextAsync(text: string): Promise<number> {
    try {
      let pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      await systemPasteboard.setData(pasteData)
      return 0
    } catch (_e) {
      return -1
    }
  }

  static requestRemoteDirectory(path: string): number {
    return (rustdeskNapi as ESObject).requestRemoteDirectory(path)
  }

  static remoteFileOperation(kind: number, path: string, name: string): number {
    return rustdeskNapi.remoteFileOperation(kind, path, name)
  }
  static takeFileOperationResult(): string { return rustdeskNapi.takeFileOperationResult() }
  static cancelFileOperation(): void { rustdeskNapi.cancelFileOperation() }
  static startRecording(path: string): number { return rustdeskNapi.startRecording(path) }
  static stopRecording(): number { return rustdeskNapi.stopRecording() }
  static getRecordingStatus(): number { return rustdeskNapi.getRecordingStatus() }

  static takeRemoteDirectoryResult(): string {
    return (rustdeskNapi as ESObject).takeRemoteDirectoryResult()
  }

  static startFileUpload(path: string, name: string, remoteDirectory: string): number {
    return (rustdeskNapi as ESObject).startFileUpload(path, name, remoteDirectory)
  }

  static startFileDownloadBatch(requests: FileDownloadRequest[], localRoot: string): number {
    return (rustdeskNapi as ESObject).startFileDownloadBatch(JSON.stringify(requests), localRoot)
  }

  static getFileTransferStatus(): string {
    return (rustdeskNapi as ESObject).getFileTransferStatus()
  }

  static cancelFileTransfer(): number {
    return (rustdeskNapi as ESObject).cancelFileTransfer()
  }

  static takeRemoteClipboardText(): string {
    return (rustdeskNapi as ESObject).takeRemoteClipboardText()
  }

  static setOption(key: string, value: string): number {
    return rustdeskNapi.setOption(key, value)
  }

  static getOption(key: string): string {
    return rustdeskNapi.getOption(key)
  }

  static getAllOptions(): string {
    return rustdeskNapi.getAllOptions()
  }

  static testIfValidServer(server: string): string {
    return rustdeskNapi.testIfValidServer(server)
  }

  static isUsingPublicServer(): boolean {
    return rustdeskNapi.isUsingPublicServer()
  }

  static getVideoFrame(): VideoFrameInfo {
    return rustdeskNapi.getVideoFrame()
  }

  static setSurfaceId(surfaceId: string): number {
    return rustdeskNapi.setSurfaceId(surfaceId)
  }

  static isSecondaryDisplaySupported(): boolean {
    try { return rustdeskNapi.isSecondaryDisplaySupported(); } catch (_error) { return false; }
  }

  static startSecondaryDisplay(surfaceId: string, display: number): number {
    return rustdeskNapi.startSecondaryDisplay(surfaceId, display)
  }

  static stopSecondaryDisplay(token: number = 0): number { return rustdeskNapi.stopSecondaryDisplay(token) }

  static releaseSecondaryButtons(token: number): number { return rustdeskNapi.releaseSecondaryButtons(token) }

  static getSecondaryDisplayState(): SecondaryDisplayState { return rustdeskNapi.getSecondaryDisplayState() }

  static sendSecondaryPointer(token: number, x: number, y: number, action: number, modifiers: number): number {
    return rustdeskNapi.sendSecondaryPointer(token, x, y, action, modifiers)
  }

  static sendSecondaryWheel(token: number, x: number, y: number, dx: number, dy: number, modifiers: number): number {
    return rustdeskNapi.sendSecondaryWheel(token, x, y, dx, dy, modifiers)
  }

  static setHdrDisplayFormats(formats: number): number {
    return rustdeskNapi.setHdrDisplayFormats(formats)
  }
  static setApiAccountContext(json: string): number {
    return rustdeskNapi.setApiAccountContext(json);
  }

  static prepareSurfaceRebind(): number {
    return rustdeskNapi.prepareSurfaceRebind()
  }

  static rebindSurface(surfaceId: string): number {
    return rustdeskNapi.rebindSurface(surfaceId)
  }
}
