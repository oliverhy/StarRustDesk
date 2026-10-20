import { readableInputHeight } from '../theme/ReadableLayout'
import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { RustDeskNapi } from '../service/RustDeskNapi'
import { ServerConfigModel } from '../model/ServerConfigModel'
import { CloudSyncService } from '../service/CloudSyncService'
import { promptAction } from '@kit.ArkUI'
import { scanBarcode, scanCore } from '@kit.ScanKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { OperationDiagnostic } from '../service/OperationDiagnostic'

@CustomDialog
export struct ServerConfigDialog {
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @State idServer: string = ''
  @State relayServer: string = ''
  @State apiServer: string = ''
  @State serverKey: string = ''
  @State errorMsg: string = ''
  @State isTesting: boolean = false
  @State testResult: string = ''
  controller?: CustomDialogController
  @State scanning: boolean = false
  @State showQr: boolean = false
  private alive: boolean = true
  private scanGeneration: number = 0

  aboutToDisappear(): void { this.alive = false; this.scanGeneration++ }

  async scanConfig(): Promise<void> {
    if (this.scanning) return
    this.scanning = true
    const generation = ++this.scanGeneration
    const trace = new OperationDiagnostic('server-config', 'qr_scan')
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as common.UIAbilityContext,
        { scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false })
      if (!this.alive || generation !== this.scanGeneration) { trace.end('stale'); return }
      trace.event('decode')
      const config = ServerConfigModel.decode(result.originalValue)
      if (!config.isValid()) { trace.end('rejected'); this.errorMsg = '二维码不是有效的 RustDesk 服务器配置'; return }
      this.idServer = config.idServer
      this.relayServer = config.relayServer
      this.apiServer = config.apiServer
      this.serverKey = config.serverKey
      this.errorMsg = ''
      this.testResult = '✓ 已识别配置，请核对服务器地址后点击确定保存'
      trace.end('ready')
    } catch (error) {
      const code = OperationDiagnostic.errorCode(error as Object)
      trace.end(code === 1000500002 ? 'cancelled' : 'failed', { code: code })
      if (this.alive && generation === this.scanGeneration && (error as BusinessError).code !== 1000500002) this.errorMsg = '无法扫码，请使用导入或检查设备是否支持扫码'
    } finally { if (this.alive && generation === this.scanGeneration) this.scanning = false }
  }

  aboutToAppear(): void {
    this.alive = true
    this.scanning = false
    this.idServer = RustDeskNapi.getOption('custom-rendezvous-server')
    this.relayServer = RustDeskNapi.getOption('relay-server')
    this.apiServer = RustDeskNapi.getOption('api-server')
    this.serverKey = RustDeskNapi.getOption('key')
  }

  build() {
    Scroll() {
    Column({ space: 12 }) {
      Button(translate(this.scanning ? '扫描中' : '扫码导入服务器配置', this.uiLanguage)).constraintSize({ minHeight: 32 }).fontSize(13)
        .enabled(!this.scanning).onClick(() => { this.scanConfig() })
      .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons))
      Button(translate(this.showQr ? '收起配置二维码' : '显示配置二维码', this.uiLanguage)).constraintSize({ minHeight: 32 }).fontSize(13)
        .enabled(this.idServer.trim().length > 0).onClick(() => { this.showQr = !this.showQr })
      .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons))
      if (this.showQr) {
        QRCode(new ServerConfigModel(this.idServer, this.relayServer, this.apiServer, this.serverKey).toQrPayload())
          .width(180).height(180).color(Color.Black).backgroundColor(Color.White)
        Text(translate('包含当前填写的服务器地址与公钥，不含连接密码。请仅向可信设备展示。', this.uiLanguage))
          .fontSize(11).fontColor(this.isDarkMode ? '#D6DCE7' : '#52627A')
      }
      if (this.errorMsg) { Text(translate(this.errorMsg, this.uiLanguage)).fontSize(12).fontColor(RustDeskTheme.ERROR).width('100%') }
      Row({ space: 8 }) {
        Text(translate('ID/Relay Server', this.uiLanguage))
          .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        Button(translate('导入', this.uiLanguage))
          .constraintSize({ minHeight: 30 })
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.importServerConfigFromClipboard()
          })
        .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 8, ButtonType.Capsule))

        Button(translate('导出', this.uiLanguage))
          .constraintSize({ minHeight: 30 })
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.exportServerConfigToClipboard()
          })
        .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
      }
      .width('100%')

      Text(translate('为连接指定自建的 ID、Relay 与 API 服务', this.uiLanguage))
        .fontSize(13)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
        .margin({ bottom: 4 })

      this.buildField(translate('ID Server', this.uiLanguage), this.idServer, (v: string) => { this.idServer = v })
      this.buildField(translate('Relay Server', this.uiLanguage), this.relayServer, (v: string) => { this.relayServer = v })
      this.buildField(translate('API Server', this.uiLanguage), this.apiServer, (v: string) => { this.apiServer = v })
      this.buildField(translate('Key', this.uiLanguage), this.serverKey, (v: string) => { this.serverKey = v })

      Text(translate('IPv6 可输入裸地址，指定端口时请使用 [IPv6]:端口，例如 [2001:db8::1]:21116', this.uiLanguage))
        .fontSize(11)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      if (this.testResult.length > 0) {
        Row() {
          Circle()
            .width(8)
            .height(8)
            .fill(this.testResult.startsWith('✓') || this.testResult === translate('Server connected successfully', this.uiLanguage) ? RustDeskTheme.SUCCESS : RustDeskTheme.ERROR)
          Text(translate(this.testResult, this.uiLanguage))
            .fontSize(12)
            .fontColor(this.testResult.startsWith('✓') || this.testResult === translate('Server connected successfully', this.uiLanguage) ? RustDeskTheme.SUCCESS : RustDeskTheme.ERROR)
            .margin({ left: 4 })
        }
        .width('100%')
      }

      if (this.isTesting) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
          Text(translate('Testing connection...', this.uiLanguage))
            .fontSize(12)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .margin({ left: 6 })
        }
        .width('100%')
      }

      Text(translate('导出配置与 RustDesk 官方格式兼容，并包含服务器 Key，请勿发送给不可信的人。', this.uiLanguage))
        .fontSize(11)
        .fontColor('#B7791F')
        .width('100%')

      Row({ space: 12 }) {
        Button(translate('Cancel', this.uiLanguage))
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
          .layoutWeight(1)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close()
            }
          })
        .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 6, ButtonType.Capsule))

        Button(translate('Test Connection', this.uiLanguage))
          .fontColor(Color.White)
          .backgroundColor('#248A68')
          .borderRadius(6)
          .layoutWeight(1)
          .enabled(!this.isTesting)
          .onClick(() => {
            this.testConnection()
          })
        .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 6, ButtonType.Capsule))

        Button(translate('OK', this.uiLanguage))
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
          .layoutWeight(1)
          .enabled(!this.isTesting)
          .onClick(() => {
            this.saveConfig()
          })
        .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 6, ButtonType.Capsule))
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .padding(24)
    .width('100%')
    }
    .width('90%').constraintSize({ maxWidth: 650, maxHeight: '90%' })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.BORDER_DARK : '#E4EAF3' })
    .borderRadius(8)
    .shadow({ radius: 24, color: '#26345A84', offsetX: 0, offsetY: 8 })
  }

  testConnection(): void {
    if (this.idServer.length === 0) {
      this.testResult = translate('Please enter ID server address', this.uiLanguage)
      return
    }
    this.isTesting = true
    this.testResult = ''
    let result: string = RustDeskNapi.testIfValidServer(this.idServer)
    this.isTesting = false
    if (result.length === 0) {
      this.testResult = translate('Server connected successfully', this.uiLanguage)
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
      promptAction.showToast({ message: translate('请先填写 ID 服务器地址', this.uiLanguage) })
      return
    }
    const result: number = await RustDeskNapi.setClipboardTextAsync(config.encode())
    if (result === 0) {
      RustDeskNapi.appendDiagnosticLog('server-config', 'official_compatible_config_exported')
      promptAction.showToast({ message: translate('服务器配置已导出到剪贴板', this.uiLanguage) })
    } else {
      promptAction.showToast({ message: translate('导出失败，请重试', this.uiLanguage) })
    }
  }

  async importServerConfigFromClipboard(): Promise<void> {
    const source: string = await RustDeskNapi.getClipboardTextAsync()
    if (source.trim().length === 0) {
      promptAction.showToast({ message: translate('剪贴板为空，请先复制服务器配置', this.uiLanguage) })
      return
    }
    const config: ServerConfigModel = ServerConfigModel.decode(source)
    if (!config.isValid()) {
      promptAction.showToast({ message: translate('服务器配置无效', this.uiLanguage) })
      return
    }
    this.idServer = config.idServer
    this.relayServer = config.relayServer
    this.apiServer = config.apiServer
    this.serverKey = config.serverKey
    this.applyConfig(this.idServer, this.relayServer, this.apiServer, this.serverKey)
    RustDeskNapi.appendDiagnosticLog('server-config', 'official_compatible_config_imported')
    promptAction.showToast({ message: translate('服务器配置已导入并生效', this.uiLanguage) })
  }

  @Builder
  buildField(label: string, value: string, onChange: (v: string) => void) {
    Column() {
      Text(translate(label, this.uiLanguage))
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
      TextInput({ placeholder: translate(label, this.uiLanguage), text: value })
        .height(readableInputHeight(44, this.uiFontScale, 18))
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
