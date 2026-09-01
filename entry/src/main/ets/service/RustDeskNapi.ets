import rustdeskNapi from 'libentry.so'
import { pasteboard } from '@kit.BasicServicesKit';

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
  codec?: number
  decoderMode?: number
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
}

export interface NativeKeyInputEvent {
  keyCode: number
  action: number
  timestamp: number
  modifierMask: number
  modifierValid: boolean
  capsLockOn: boolean
  capsLockValid: boolean
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

export class RustDeskNapi {
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
    return (rustdeskNapi as ESObject).getDiagnosticLog()
  }

  static clearDiagnosticLog(): number {
    return (rustdeskNapi as ESObject).clearDiagnosticLog()
  }

  static connect(peerId: string, password: string): number {
    return rustdeskNapi.connect(peerId, password)
  }

  static connectWithServer(peerId: string, password: string, rendezvousServer: string, relayServer: string): number {
    return rustdeskNapi.connect(peerId, password, rendezvousServer, relayServer)
  }

  static setPerformancePreset(preset: string): number {
    return (rustdeskNapi as ESObject).setPerformancePreset(preset)
  }

  static disconnect(): number {
    return rustdeskNapi.disconnect()
  }

  static sendKeyEvent(keyCode: number, action: number, modifierMask: number = 0): number {
    return rustdeskNapi.sendKeyEvent(keyCode, action, modifierMask)
  }

  static sendPhysicalKeyEvent(scanCode: number, action: number, modifierMask: number = 0): number {
    return (rustdeskNapi as ESObject).sendPhysicalKeyEvent(scanCode, action, modifierMask)
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

  static takeNativeMouseEvents(): NativeMouseInputEvent[] {
    return (rustdeskNapi as ESObject).takeNativeMouseEvents() as NativeMouseInputEvent[]
  }

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

  static getRemoteCursorData(): RemoteCursorData {
    return (rustdeskNapi as ESObject).getRemoteCursorData() as RemoteCursorData
  }

  static switchDisplay(display: number): number {
    return (rustdeskNapi as ESObject).switchDisplay(display)
  }

  static refreshVideo(): number {
    return (rustdeskNapi as ESObject).refreshVideo()
  }

  static fallbackVideoToVp9(): number {
    return (rustdeskNapi as ESObject).fallbackVideoToVp9()
  }

  static getPeerList(): PeerInfo[] {
    return rustdeskNapi.getPeerList()
  }

  static getConnectionStatus(): number {
    return rustdeskNapi.getConnectionStatus()
  }

  static getConnectionRoute(): number {
    return (rustdeskNapi as ESObject).getConnectionRoute()
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

  private static getPlainTextFromRecord(record: pasteboard.PasteDataRecord): string {
    if (record.plainText.length > 0) {
      return record.plainText
    }
    if (record.htmlText.length > 0) {
      return RustDeskNapi.htmlToText(record.htmlText)
    }
    return record.toPlainText()
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

  static requestRemoteDirectory(path: string): number {
    return (rustdeskNapi as ESObject).requestRemoteDirectory(path)
  }

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

  static prepareSurfaceRebind(): number {
    return rustdeskNapi.prepareSurfaceRebind()
  }

  static rebindSurface(surfaceId: string): number {
    return rustdeskNapi.rebindSurface(surfaceId)
  }
}
