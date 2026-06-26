import rustdeskNapi from 'libentry.so'
import { pasteboard } from '@kit.BasicServicesKit';

export interface FileTransferProgressInfo {
  status: number
  fileName: string
  totalBytes: number
  transferredBytes: number
  progress: number
}

const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard()

export interface PeerInfo {
  id: string
  name: string
  platform: string
  online: boolean
}

export interface SessionInfo {
  peerId: string
  clientAddr: string
  connectedAt: number
}

export interface VideoFrameInfo {
  hasFrame: boolean
  width: number
  height: number
  length: number
  totalFrames?: number
  totalBytes?: number
}

export class RustDeskNapi {
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

  static sendKeyEvent(keyCode: number, action: number): number {
    return rustdeskNapi.sendKeyEvent(keyCode, action)
  }

  static sendText(text: string): number {
    return (rustdeskNapi as ESObject).sendText(text)
  }

  static sendMouseEvent(x: number, y: number, action: number): number {
    return rustdeskNapi.sendMouseEvent(x, y, action)
  }

  static getDisplayCount(): number {
    return (rustdeskNapi as ESObject).getDisplayCount()
  }

  static getCurrentDisplay(): number {
    return (rustdeskNapi as ESObject).getCurrentDisplay()
  }

  static switchDisplay(display: number): number {
    return (rustdeskNapi as ESObject).switchDisplay(display)
  }

  static refreshVideo(): number {
    return (rustdeskNapi as ESObject).refreshVideo()
  }

  static startService(): number {
    return rustdeskNapi.startService()
  }

  static stopService(): number {
    return rustdeskNapi.stopService()
  }

  static getActiveSessions(): SessionInfo[] {
    return rustdeskNapi.getActiveSessions()
  }

  static getPeerList(): PeerInfo[] {
    return rustdeskNapi.getPeerList()
  }

  static getConnectionStatus(): number {
    return rustdeskNapi.getConnectionStatus()
  }

  static getLastConnectionError(): string {
    return rustdeskNapi.getLastConnectionError()
  }

  static getDeviceId(): string {
    return rustdeskNapi.getDeviceId()
  }

  static getDeviceName(): string {
    return rustdeskNapi.getDeviceName()
  }

  static sendFile(localPath: string, remotePath: string): number {
    return rustdeskNapi.sendFile(localPath, remotePath)
  }

  static receiveFile(remotePath: string, localPath: string): number {
    return rustdeskNapi.receiveFile(remotePath, localPath)
  }

  static getFileTransferProgress(): FileTransferProgressInfo {
    return rustdeskNapi.getFileTransferProgress()
  }

  static cancelFileTransfer(): number {
    return rustdeskNapi.cancelFileTransfer()
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
        let text: string = record.toPlainText()
        if (text.length > 0) {
          return text
        }
      }
    } catch (_e) {
      // clipboard may be empty or no permission
    }
    return ''
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
}
