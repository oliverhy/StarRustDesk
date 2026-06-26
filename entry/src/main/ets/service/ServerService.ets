import { RustDeskNapi } from './RustDeskNapi'

export class ServerService {
  static startService(): void {
    RustDeskNapi.startService()
  }

  static stopService(): void {
    RustDeskNapi.stopService()
  }

  static getDeviceId(): string {
    return RustDeskNapi.getDeviceId()
  }

  static getDeviceName(): string {
    return RustDeskNapi.getDeviceName()
  }
}
