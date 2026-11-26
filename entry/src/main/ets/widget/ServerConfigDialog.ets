import { readableInputHeight } from '../theme/ReadableLayout'
import { settingsPalette } from '../theme/SettingsSkin'
import { SettingsAction } from './SettingsControls'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { ClipboardImportReadResult, RustDeskNapi } from '../service/RustDeskNapi'
import { ServerConfigModel } from '../model/ServerConfigModel'
import { CloudSyncService } from '../service/CloudSyncService'
import { promptAction } from '@kit.ArkUI'
import { scanBarcode, scanCore } from '@kit.ScanKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { OperationDiagnostic } from '../service/OperationDiagnostic'

interface ServerFieldBuilderParams {
  label: string
  value: string
  onChange: (value: string) => void
}

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
  @State importing: boolean = false
  @State showQr: boolean = false
  private alive: boolean = true
  private scanGeneration: number = 0
  private importGeneration: number = 0

  aboutToDisappear(): void { this.alive = false; this.scanGeneration++; this.importGeneration++ }

  async scanConfig(): Promise<void> {
    if (this.scanning || this.importing) return
    this.scanning = true
    const generation = ++this.scanGeneration
    const trace = new OperationDiagnostic('server-config', 'qr_scan')
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as common.UIAbilityContext,
        { scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false })
      if (!this.alive || generation !== this.scanGeneration) { trace.end('stale'); return }
      trace.event('decode')
      const config = ServerConfigModel.decode(result.originalValue)
      if (!config.isValidImport()) { trace.end('rejected'); this.testResult = ''; this.errorMsg = '二维码不是有效的 RustDesk 服务器配置'; return }
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
    this.importing = false
    this.idServer = RustDeskNapi.getOption('custom-rendezvous-server')
    this.relayServer = RustDeskNapi.getOption('relay-server')
    this.apiServer = RustDeskNapi.getOption('api-server')
    this.serverKey = RustDeskNapi.getOption('key')
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text(translate('ID / 中继服务器', this.uiLanguage)).fontSize(20).fontWeight(700)
          .fontColor(settingsPalette(this.isDarkMode).ink).layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
        SettingsAction({ icon: 'close', accessibleLabel: translate('关闭', this.uiLanguage), tone: 'quiet',
          onAction: () => { this.controller?.close() } })
      }
      .width('100%').padding({ left: 16, right: 10, top: 10, bottom: 8 })
      Divider().strokeWidth(1).color(settingsPalette(this.isDarkMode).hair)
      Scroll() {
        Column({ space: 10 }) {
          Text(translate('为连接指定自建的 ID、Relay 与 API 服务', this.uiLanguage))
            .fontSize(13).fontColor(settingsPalette(this.isDarkMode).muted).width('100%')
          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
            SettingsAction({ label: translate(this.scanning ? '扫描中' : '扫码导入服务器配置', this.uiLanguage),
              icon: 'scan', isEnabled: !this.scanning && !this.importing, onAction: () => { this.scanConfig() } })
              .margin({ right: 6, bottom: 6 })
            SettingsAction({ label: translate(this.showQr ? '收起配置二维码' : '显示配置二维码', this.uiLanguage),
              icon: 'qr', isEnabled: this.idServer.trim().length > 0, onAction: () => { this.showQr = !this.showQr } })
              .margin({ right: 6, bottom: 6 })

            // A normal button cannot grant the native component's one-time clipboard access.
            Row() {
              PasteButton({ text: PasteDescription.PASTE, buttonType: this.roundedRectButtons ?
                ButtonType.Normal : ButtonType.Capsule })
                .fontSize(13)
                .fontColor(settingsPalette(this.isDarkMode).ink)
                .backgroundColor(settingsPalette(this.isDarkMode).pill)
                .borderRadius(this.roundedRectButtons ? 12 : 22)
                .constraintSize({ minHeight: 44 })
                .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
                  if (result === PasteButtonOnClickResult.SUCCESS) {
                    this.importServerConfigFromClipboard()
                  } else {
                    const trace = new OperationDiagnostic('server-config', 'clipboard_import')
                    trace.end('rejected', { kind: 3 })
                    promptAction.showToast({ message: translate('无法读取剪贴板，请检查系统权限后重试', this.uiLanguage) })
                  }
                })
            }
            .margin({ right: 6, bottom: 6 })

            SettingsAction({ label: translate('导出', this.uiLanguage), icon: 'download',
              onAction: () => { this.exportServerConfigToClipboard() } }).margin({ bottom: 6 })
          }
          .width('100%')
          if (this.showQr) {
            Column({ space: 8 }) {
              QRCode(new ServerConfigModel(this.idServer, this.relayServer, this.apiServer, this.serverKey).toQrPayload())
                .width(180).height(180).color(Color.Black).backgroundColor(Color.White)
              Text(translate('包含当前填写的服务器地址与公钥，不含连接密码。请仅向可信设备展示。', this.uiLanguage))
                .fontSize(12).fontColor(settingsPalette(this.isDarkMode).muted).width('100%')
            }
            .width('100%').padding(9).backgroundColor(settingsPalette(this.isDarkMode).app).borderRadius(10)
          }
          if (this.errorMsg) {
            Text(translate(this.errorMsg, this.uiLanguage)).fontSize(12).fontColor(settingsPalette(this.isDarkMode).red)
              .width('100%')
          }
          this.buildField({ label: 'ID Server', value: this.idServer, onChange: (v: string) => { this.idServer = v } })
          this.buildField({ label: 'Relay Server', value: this.relayServer, onChange: (v: string) => { this.relayServer = v } })
          this.buildField({ label: 'API Server', value: this.apiServer, onChange: (v: string) => { this.apiServer = v } })
          this.buildField({ label: 'Key', value: this.serverKey, onChange: (v: string) => { this.serverKey = v } })

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
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 10 })
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)

      Divider().strokeWidth(1).color(settingsPalette(this.isDarkMode).hair)
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
        SettingsAction({ label: translate('Cancel', this.uiLanguage), onAction: () => { this.controller?.close() } })
          .margin({ left: 6, top: 6 })
        SettingsAction({ label: translate('Test Connection', this.uiLanguage),
          isEnabled: !this.isTesting && !this.scanning && !this.importing,
          onAction: () => { this.testConnection() } }).margin({ left: 6, top: 6 })
        SettingsAction({ label: translate('OK', this.uiLanguage), icon: 'check', tone: 'primary',
          isEnabled: !this.isTesting && !this.scanning && !this.importing,
          onAction: () => { this.saveConfig() } }).margin({ left: 6, top: 6 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 4, bottom: 12 })
    }
    .width('92%').height('85%').constraintSize({ maxWidth: 460, maxHeight: 650 })
    .backgroundColor(settingsPalette(this.isDarkMode).surface)
    .border({ width: 1, color: settingsPalette(this.isDarkMode).line })
    .borderRadius(16)
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
    if (this.scanning || this.importing || this.isTesting) return
    const idServer: string = this.idServer.trim()
    const relayServer: string = this.relayServer.trim()
    const apiServer: string = this.apiServer.trim()
    const serverKey: string = this.serverKey.trim()
    if (this.applyConfig(idServer, relayServer, apiServer, serverKey) !== 0) {
      this.testResult = ''
      this.errorMsg = '服务器配置保存失败，原配置未更改，请重试'
      return
    }
    if (this.controller != undefined) {
      this.controller.close()
    }
  }

  private applyConfig(idServer: string, relayServer: string, apiServer: string, serverKey: string): number {
    let result: number = -2
    try {
      result = RustDeskNapi.setServerConfig(idServer.trim(), relayServer.trim(), apiServer.trim(), serverKey.trim())
    } catch (_error) {}
    if (result !== 0) {
      try { RustDeskNapi.appendDiagnosticLog('server-config', `save_failed result=${result}`) } catch (_error) {}
      return result
    }
    // The native transaction is already committed. A nonessential UI/logging
    // failure must not falsely report that the persisted settings were rolled back.
    try { CloudSyncService.markLocalChanged() } catch (_error) {}
    try {
      let version: number = AppStorage.get<number>('serverConfigVersion') ?? 0
      AppStorage.set<number>('serverConfigVersion', version + 1)
    } catch (_error) {}
    try {
      RustDeskNapi.appendDiagnosticLog('server-config',
        `saved custom=${idServer.length > 0 || relayServer.length > 0 ? 1 : 0} ` +
        `relay=${relayServer.length > 0 ? 1 : 0} api=${apiServer.length > 0 ? 1 : 0} ` +
        `key=${serverKey.length > 0 ? 1 : 0}`)
    } catch (_error) {}
    return 0
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
    if (this.importing || this.scanning) return
    this.importing = true
    const generation: number = ++this.importGeneration
    const trace = new OperationDiagnostic('server-config', 'clipboard_import')
    try {
      trace.event('read_local')
      const result: ClipboardImportReadResult = await RustDeskNapi.getClipboardTextForImportAsync()
      if (!this.alive || generation !== this.importGeneration) { trace.end('stale'); return }
      if (result.failed) {
        trace.end('failed', { code: result.code })
        promptAction.showToast({ message: translate('无法读取剪贴板，请检查系统权限后重试', this.uiLanguage) })
        return
      }
      if (result.text.trim().length === 0) {
        trace.end('rejected', { kind: 1 })
        promptAction.showToast({ message: translate('剪贴板为空，请先复制服务器配置', this.uiLanguage) })
        return
      }
      trace.event('decode')
      const config: ServerConfigModel = ServerConfigModel.decode(result.text)
      if (!config.isValidImport()) {
        trace.end('rejected', { kind: 2 })
        promptAction.showToast({ message: translate('服务器配置无效', this.uiLanguage) })
        return
      }
      // Preserve the existing one-tap import behaviour, but never apply an
      // unreadable or invalid configuration to the current network.
      const saved: number = this.applyConfig(config.idServer, config.relayServer, config.apiServer, config.serverKey)
      if (saved !== 0) {
        trace.end('failed', { result: saved })
        this.testResult = ''
        this.errorMsg = '服务器配置保存失败，原配置未更改，请重试'
        promptAction.showToast({ message: translate(this.errorMsg, this.uiLanguage) })
        return
      }
      this.idServer = config.idServer
      this.relayServer = config.relayServer
      this.apiServer = config.apiServer
      this.serverKey = config.serverKey
      this.errorMsg = ''
      this.testResult = ''
      trace.end('completed')
      try { RustDeskNapi.appendDiagnosticLog('server-config', 'official_compatible_config_imported') } catch (_error) {}
      try { promptAction.showToast({ message: translate('服务器配置已导入并生效', this.uiLanguage) }) } catch (_error) {}
    } catch (error) {
      trace.fail(error as Object)
      if (this.alive && generation === this.importGeneration) {
        promptAction.showToast({ message: translate('导入失败，请重试', this.uiLanguage) })
      }
    } finally {
      if (this.alive && generation === this.importGeneration) this.importing = false
    }
  }

  @Builder
  buildField($$: ServerFieldBuilderParams) {
    Column() {
      Text(translate($$.label, this.uiLanguage))
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
      TextInput({ placeholder: translate($$.label, this.uiLanguage), text: $$.value })
        .height(readableInputHeight(44, this.uiFontScale, 18))
        .fontSize(14)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER, radius: 7 })
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => { $$.onChange(v) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
