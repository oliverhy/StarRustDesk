import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { RustDeskNapi } from '../service/RustDeskNapi'
import { ServerConfigModel } from '../model/ServerConfigModel'
import { CloudSyncService } from '../service/CloudSyncService'
import { promptAction } from '@kit.ArkUI'

@CustomDialog
export struct ServerConfigDialog {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @State idServer: string = ''
  @State relayServer: string = ''
  @State apiServer: string = ''
  @State serverKey: string = ''
  @State errorMsg: string = ''
  @State isTesting: boolean = false
  @State testResult: string = ''
  controller?: CustomDialogController

  aboutToAppear(): void {
    this.idServer = RustDeskNapi.getOption('custom-rendezvous-server')
    this.relayServer = RustDeskNapi.getOption('relay-server')
    this.apiServer = RustDeskNapi.getOption('api-server')
    this.serverKey = RustDeskNapi.getOption('key')
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(translate('ID/Relay Server'))
          .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        Button('导入')
          .height(30)
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.importServerConfigFromClipboard()
          })

        Button('导出')
          .height(30)
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.exportServerConfigToClipboard()
          })
      }
      .width('100%')

      Text('为连接指定自建的 ID、Relay 与 API 服务')
        .fontSize(13)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
        .margin({ bottom: 4 })

      this.buildField(translate('ID Server'), this.idServer, (v: string) => { this.idServer = v })
      this.buildField(translate('Relay Server'), this.relayServer, (v: string) => { this.relayServer = v })
      this.buildField(translate('API Server'), this.apiServer, (v: string) => { this.apiServer = v })
      this.buildField(translate('Key'), this.serverKey, (v: string) => { this.serverKey = v })

      Text('IPv6 可输入裸地址，指定端口时请使用 [IPv6]:端口，例如 [2001:db8::1]:21116')
        .fontSize(11)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      if (this.testResult.length > 0) {
        Row() {
          Circle()
            .width(8)
            .height(8)
            .fill(this.testResult.startsWith('✓') || this.testResult === translate('Server connected successfully') ? RustDeskTheme.SUCCESS : RustDeskTheme.ERROR)
          Text(this.testResult)
            .fontSize(12)
            .fontColor(this.testResult.startsWith('✓') || this.testResult === translate('Server connected successfully') ? RustDeskTheme.SUCCESS : RustDeskTheme.ERROR)
            .margin({ left: 4 })
        }
        .width('100%')
      }

      if (this.isTesting) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
          Text(translate('Testing connection...'))
            .fontSize(12)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .margin({ left: 6 })
        }
        .width('100%')
      }

      Text('导出配置与 RustDesk 官方格式兼容，并包含服务器 Key，请勿发送给不可信的人。')
        .fontSize(11)
        .fontColor('#B7791F')
        .width('100%')

      Row({ space: 12 }) {
        Button(translate('Cancel'))
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
          .layoutWeight(1)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close()
            }
          })

        Button(translate('Test Connection'))
          .fontColor(Color.White)
          .backgroundColor('#248A68')
          .borderRadius(6)
          .layoutWeight(1)
          .enabled(!this.isTesting)
          .onClick(() => {
            this.testConnection()
          })

        Button(translate('OK'))
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
          .layoutWeight(1)
          .enabled(!this.isTesting)
          .onClick(() => {
            this.saveConfig()
          })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .padding(24)
    .width('90%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.BORDER_DARK : '#E4EAF3' })
    .borderRadius(8)
    .shadow({ radius: 24, color: '#26345A84', offsetX: 0, offsetY: 8 })
  }

  testConnection(): void {
    if (this.idServer.length === 0) {
      this.testResult = translate('Please enter ID server address')
      return
    }
    this.isTesting = true
    this.testResult = ''
    let result: string = RustDeskNapi.testIfValidServer(this.idServer)
    this.isTesting = false
    if (result.length === 0) {
      this.testResult = translate('Server connected successfully')
    } else {
      this.testResult = '✗ ' + result
    }
  }

  saveConfig(): void {
    const idServer: string = this.idServer.trim()
    const relayServer: string = this.relayServer.trim()
    const apiServer: string = this.apiServer.trim()
    const serverKey: string = this.serverKey.trim()
    this.applyConfig(idServer, relayServer, apiServer, serverKey)
    if (this.controller != undefined) {
      this.controller.close()
    }
  }

  private applyConfig(idServer: string, relayServer: string, apiServer: string, serverKey: string): void {
    RustDeskNapi.setOption('custom-rendezvous-server', idServer.trim())
    RustDeskNapi.setOption('relay-server', relayServer.trim())
    RustDeskNapi.setOption('api-server', apiServer.trim())
    RustDeskNapi.setOption('key', serverKey.trim())
    CloudSyncService.markLocalChanged()
    let version: number = AppStorage.get<number>('serverConfigVersion') ?? 0
    AppStorage.set<number>('serverConfigVersion', version + 1)
    RustDeskNapi.appendDiagnosticLog('server-config',
      `saved custom=${idServer.length > 0 || relayServer.length > 0 ? 1 : 0} ` +
      `relay=${relayServer.length > 0 ? 1 : 0} api=${apiServer.length > 0 ? 1 : 0} ` +
      `key=${serverKey.length > 0 ? 1 : 0}`)
  }

  async exportServerConfigToClipboard(): Promise<void> {
    const config: ServerConfigModel = new ServerConfigModel(
      this.idServer, this.relayServer, this.apiServer, this.serverKey)
    if (!config.isValid()) {
      promptAction.showToast({ message: '请先填写 ID 服务器地址' })
      return
    }
    const result: number = await RustDeskNapi.setClipboardTextAsync(config.encode())
    if (result === 0) {
      RustDeskNapi.appendDiagnosticLog('server-config', 'official_compatible_config_exported')
      promptAction.showToast({ message: '服务器配置已导出到剪贴板' })
    } else {
      promptAction.showToast({ message: '导出失败，请重试' })
    }
  }

  async importServerConfigFromClipboard(): Promise<void> {
    const source: string = await RustDeskNapi.getClipboardTextAsync()
    if (source.trim().length === 0) {
      promptAction.showToast({ message: '剪贴板为空，请先复制服务器配置' })
      return
    }
    const config: ServerConfigModel = ServerConfigModel.decode(source)
    if (!config.isValid()) {
      promptAction.showToast({ message: '服务器配置无效' })
      return
    }
    this.idServer = config.idServer
    this.relayServer = config.relayServer
    this.apiServer = config.apiServer
    this.serverKey = config.serverKey
    this.applyConfig(this.idServer, this.relayServer, this.apiServer, this.serverKey)
    RustDeskNapi.appendDiagnosticLog('server-config', 'official_compatible_config_imported')
    promptAction.showToast({ message: '服务器配置已导入并生效' })
  }

  @Builder
  buildField(label: string, value: string, onChange: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
      TextInput({ placeholder: label, text: value })
        .height(44)
        .fontSize(14)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER, radius: 7 })
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => { onChange(v) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
