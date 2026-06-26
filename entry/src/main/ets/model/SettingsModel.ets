export enum ColorQuality {
  LOW = 0,
  MEDIUM = 1,
  HIGH = 2,
}

export class SettingsModel {
  resolution: string = 'Auto'
  frameRate: number = 30
  colorQuality: ColorQuality = ColorQuality.MEDIUM
  relayServer: string = ''
  relayPort: string = '21116'
  language: string = 'en'
  isDarkMode: boolean = false
  microphoneEnabled: boolean = true
  speakerEnabled: boolean = true
  trustedDevices: string[] = []
}
