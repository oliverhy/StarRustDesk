import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { ServerConfigDialog } from '../widget/ServerConfigDialog'
import {
  RELEASE_NOTES_SHOWN_OPTION,
  RELEASE_NOTES_SHOWN_ID,
  RELEASE_NOTES_VERSION,
  ReleaseNotesDialog,
} from '../widget/ReleaseNotesDialog'
import { RustDeskNapi } from '../service/RustDeskNapi'
import { common } from '@kit.AbilityKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { promptAction } from '@kit.ArkUI'
import { fileIo, picker } from '@kit.CoreFileKit'
import { FileTransferHistoryDialog } from '../widget/FileTransferHistoryDialog'
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask'
import { CloudSyncResult, CloudSyncService } from '../service/CloudSyncService'

const QQ_GROUP_NUMBER: string = '221568948'

interface SettingItem {
  label: string
  value: string
}

@Component
export struct SettingsPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('isDarkModeManual') isDarkModeManual: boolean = false
  @State resolution: string = 'Auto'
  @State frameRate: number = 30
  @State showResolutionPicker: boolean = false
  @State showFrameRatePicker: boolean = false
  @State showLocalCursor: boolean = true
  @State remoteAudioEnabled: boolean = true
  @State diagnosticLogEnabled: boolean = false
  @State diagnosticLogBusy: boolean = false
  @State cloudSyncEnabled: boolean = false
  @State cloudSyncIncludesSecrets: boolean = false
  @State cloudSyncBusy: boolean = false
  @State cloudSyncStatus: string = '未开启'
  private cloudPasswordAction: string = ''
  @State pageWidth: number = 0
  private serverConfigDialogController: CustomDialogController = new CustomDialogController({
    builder: ServerConfigDialog(),
    autoCancel: true,
    customStyle: true,
    cornerRadius: 8,
  })
  private releaseNotesDialogController: CustomDialogController = new CustomDialogController({
    builder: ReleaseNotesDialog({
      onClose: () => {
        RustDeskNapi.setOption(RELEASE_NOTES_SHOWN_OPTION, RELEASE_NOTES_SHOWN_ID)
      },
    }),
    autoCancel: false,
    customStyle: true,
    cornerRadius: 10,
  })
  private fileTransferHistoryDialogController: CustomDialogController = new CustomDialogController({
    builder: FileTransferHistoryDialog(),
    autoCancel: true,
    customStyle: true,
    cornerRadius: 10,
  })
  private cloudPasswordDialogController: CustomDialogController = new CustomDialogController({
    builder: SettingsPasswordDialog({
      title: '云备份密码',
      description: '密码仅保存在本机安全存储中，新设备恢复时需要重新输入。',
      onSave: (password: string) => {
        this.saveCloudPassword(password)
      },
      onCancel: () => {
        this.cloudPasswordAction = ''
        this.cloudPasswordDialogController.close()
      }
    }),
    autoCancel: false,
    customStyle: true,
    cornerRadius: 10,
  })

  aboutToAppear(): void {
    let savedRes: string = RustDeskNapi.getOption('resolution')
    if (savedRes.length > 0) {
      this.resolution = savedRes
    }
    let savedFps: string = RustDeskNapi.getOption('frame-rate')
    if (savedFps.length > 0) {
      this.frameRate = parseInt(savedFps)
    }
    this.showLocalCursor = RustDeskNapi.getOption('show-local-cursor') !== '0'
    this.remoteAudioEnabled = RustDeskNapi.getOption('remote-audio-enabled') !== '0'
    RustDeskNapi.setRemoteAudioEnabled(this.remoteAudioEnabled)
    this.diagnosticLogEnabled = RustDeskNapi.getOption('diagnostic-log-enabled') === '1'
    RustDeskNapi.setDiagnosticLogEnabled(this.diagnosticLogEnabled)
    this.cloudSyncEnabled = CloudSyncService.isEnabled()
    this.cloudSyncIncludesSecrets = CloudSyncService.includesSecrets()
    this.updateCloudSyncStatus()
    if (this.cloudSyncEnabled) {
      this.syncCloudNow(false, true)
    }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text('设置')
            .fontSize(this.pageWidth >= 820 ? 30 : 26)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('连接质量、网络服务与外观')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#B7C0CF' : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(this.pageWidth >= 820 ? 116 : 104)
      .padding({ left: this.pageWidth >= 820 ? 32 : 16, right: this.pageWidth >= 820 ? 32 : 16, top: 24, bottom: 18 })

      Scroll() {
        Column({ space: 16 }) {
          this.buildSectionCard(translate('Account'), [
            { label: translate('Device Name'), value: RustDeskNapi.getDeviceName() },
          ])
          this.buildDisplayCard()
          this.buildInputCard()
          this.buildAudioCard()
          this.buildServerConfigCard()
          this.buildCloudSyncCard()
          this.buildDiagnosticsCard()
          this.buildThemeToggle()
          this.buildAboutCard()
        }
        .width(this.pageWidth >= 820 ? 720 : '100%')
        .padding({
          left: RustDeskTheme.PAGE_PADDING,
          right: RustDeskTheme.PAGE_PADDING,
          top: RustDeskTheme.PAGE_PADDING,
          bottom: 94
        })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.pageWidth = newValue.width as number
    })
  }

  @Builder
  buildDisplayCard() {
    Column() {
      Text(translate('Display'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(translate('Resolution'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(this.resolution)
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        Text('>')
          .fontSize(16)
          .fontColor(RustDeskTheme.DARK_GRAY)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .onClick(() => {
        this.showResolutionPicker = !this.showResolutionPicker
        this.showFrameRatePicker = false
      })

      if (this.showResolutionPicker) {
        Column({ space: 4 }) {
          this.buildOptionItem('Auto', () => { this.selectResolution('Auto') })
          this.buildOptionItem('720p', () => { this.selectResolution('720p') })
          this.buildOptionItem('1080p', () => { this.selectResolution('1080p') })
          this.buildOptionItem('4K', () => { this.selectResolution('4K') })
        }
        .width('100%')
        .padding({ left: 8 })
      }

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)
        .margin({ top: 4, bottom: 4 })

      Row() {
        Text(translate('Frame Rate'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(this.frameRate.toString())
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        Text('>')
          .fontSize(16)
          .fontColor(RustDeskTheme.DARK_GRAY)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .onClick(() => {
        this.showFrameRatePicker = !this.showFrameRatePicker
        this.showResolutionPicker = false
      })

      if (this.showFrameRatePicker) {
        Column({ space: 4 }) {
          this.buildOptionItem('15', () => { this.selectFrameRate(15) })
          this.buildOptionItem('30', () => { this.selectFrameRate(30) })
          this.buildOptionItem('60', () => { this.selectFrameRate(60) })
        }
        .width('100%')
        .padding({ left: 8 })
      }
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  selectResolution(res: string): void {
    this.resolution = res
    this.showResolutionPicker = false
    RustDeskNapi.setOption('resolution', res)
  }

  selectFrameRate(fps: number): void {
    this.frameRate = fps
    this.showFrameRatePicker = false
    RustDeskNapi.setOption('frame-rate', fps.toString())
  }

  @Builder
  buildOptionItem(label: string, onClick: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
      .padding({ top: 6, bottom: 6, left: 8 })
      .width('100%')
      .backgroundColor(label === this.resolution || label === this.frameRate.toString() ?
        (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG) :
        (this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE))
      .border({ width: 1, color: label === this.resolution || label === this.frameRate.toString() ?
        (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER) : Color.Transparent })
      .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      .onClick(() => { onClick() })
  }

  @Builder
  buildSectionCard(title: string, items: SettingItem[]) {
    Column() {
      Text(title)
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      ForEach(items, (item: SettingItem) => {
        Row() {
          Text(item.label)
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          Blank()
          if (item.value.length > 0) {
            Text(item.value)
              .fontSize(RustDeskTheme.FONT_SIZE_BODY)
              .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }, (item: SettingItem) => item.label)
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  @Builder
  buildInputCard() {
    Column({ space: 4 }) {
      Row() {
        Column({ space: 4 }) {
          Text('显示本地鼠标指针')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('仅控制本机连接的物理鼠标指针，远端真实光标始终显示')
            .fontSize(12)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.showLocalCursor })
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.showLocalCursor ?
            (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : Color.White))
          .onChange((isOn: boolean) => {
            this.showLocalCursor = isOn
            RustDeskNapi.setOption('show-local-cursor', isOn ? '1' : '0')
          })
      }
      .width('100%')
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  @Builder
  buildAudioCard() {
    Column({ space: 4 }) {
      Row() {
        Column({ space: 4 }) {
          Text('播放远端声音')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('播放远端设备的系统声音；有真实音频时接入系统播控中心')
            .fontSize(12)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.remoteAudioEnabled })
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.remoteAudioEnabled ?
            (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : Color.White))
          .onChange((isOn: boolean) => {
            this.remoteAudioEnabled = isOn
            RustDeskNapi.setOption('remote-audio-enabled', isOn ? '1' : '0')
            RustDeskNapi.setRemoteAudioEnabled(isOn)
            if (!isOn) {
              RemoteSessionBackgroundTask.setAudioPlaybackActive(false)
            }
          })
      }
      .width('100%')
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  @Builder
  buildCloudSyncCard() {
    Column({ space: 4 }) {
      Text('华为云空间')
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 4 })

      Text('在同一华为账号的设备间备份和恢复已保存连接、分组与服务器地址。')
        .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
        .lineHeight(19)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
        .margin({ bottom: 6 })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text('个人云空间同步')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(this.cloudSyncStatus)
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.cloudSyncEnabled })
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.cloudSyncEnabled ?
            (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : Color.White))
          .onChange((isOn: boolean) => {
            this.setCloudSyncEnabled(isOn)
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text('同步连接密码和服务器密钥')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(this.cloudSyncIncludesSecrets ? '已使用 AES-256-GCM 加密后上传' : '默认不上传敏感信息')
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.cloudSyncIncludesSecrets })
          .enabled(this.cloudSyncEnabled && !this.cloudSyncBusy)
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.cloudSyncIncludesSecrets ?
            (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : Color.White))
          .onChange((isOn: boolean) => {
            this.setCloudSecretsEnabled(isOn)
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .opacity(this.cloudSyncEnabled ? 1 : 0.55)

      if (this.cloudSyncEnabled && this.cloudSyncIncludesSecrets) {
        Row() {
          Text('备份密码仅保存在本机')
            .fontSize(11)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          Blank()
          Text('更换密码')
            .fontSize(12)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
            .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
            .onClick(() => {
              this.cloudPasswordAction = 'enable-secrets'
              this.cloudPasswordDialogController.open()
            })
        }
        .width('100%')
        .padding({ bottom: 8 })
      }

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row({ space: 10 }) {
        Button(this.cloudSyncBusy ? '同步中…' : '立即同步')
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .layoutWeight(1)
          .enabled(this.cloudSyncEnabled && !this.cloudSyncBusy)
          .onClick(() => {
            this.syncCloudNow(false, false)
          })
        Button('从云端恢复')
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .layoutWeight(1)
          .enabled(this.cloudSyncEnabled && !this.cloudSyncBusy)
          .onClick(() => {
            this.confirmCloudRestore()
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 6 })

      Text('还需在系统“设置 > 华为账号 > 云空间”中允许 StarRustDesk 同步。')
        .fontSize(11)
        .lineHeight(17)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW,
      offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  setCloudSyncEnabled(enabled: boolean): void {
    this.cloudSyncEnabled = enabled
    CloudSyncService.setEnabled(enabled)
    if (!enabled) {
      this.cloudSyncStatus = '已关闭'
      return
    }
    this.cloudSyncStatus = '等待首次同步'
    this.syncCloudNow(false, false)
  }

  async setCloudSecretsEnabled(enabled: boolean): Promise<void> {
    if (!enabled) {
      this.cloudSyncIncludesSecrets = false
      CloudSyncService.setIncludesSecrets(false)
      await CloudSyncService.upload(getContext(this) as common.UIAbilityContext)
      this.updateCloudSyncStatus()
      return
    }
    if (await CloudSyncService.hasCloudPassword()) {
      this.cloudSyncIncludesSecrets = true
      CloudSyncService.setIncludesSecrets(true)
      await this.syncCloudNow(false, false)
      return
    }
    this.cloudPasswordAction = 'enable-secrets'
    this.cloudPasswordDialogController.open()
  }

  async saveCloudPassword(password: string): Promise<void> {
    try {
      await CloudSyncService.saveCloudPassword(password)
      this.cloudPasswordDialogController.close()
      let action: string = this.cloudPasswordAction
      this.cloudPasswordAction = ''
      if (action === 'enable-secrets') {
        this.cloudSyncIncludesSecrets = true
        CloudSyncService.setIncludesSecrets(true)
        await this.syncCloudNow(false, false)
      } else if (action === 'restore') {
        await this.syncCloudNow(true, false)
      }
    } catch (_error) {
      promptAction.showToast({ message: '备份密码保存失败' })
    }
  }

  async syncCloudNow(restoreOnly: boolean, quiet: boolean): Promise<void> {
    if (this.cloudSyncBusy || !this.cloudSyncEnabled) {
      return
    }
    this.cloudSyncBusy = true
    this.cloudSyncStatus = restoreOnly ? '正在从云端恢复…' : '正在同步…'
    let result: CloudSyncResult = restoreOnly ?
      await CloudSyncService.restore(getContext(this) as common.UIAbilityContext) :
      await CloudSyncService.syncNow(getContext(this) as common.UIAbilityContext)
    this.cloudSyncBusy = false
    if (result.needsPassword) {
      await CloudSyncService.clearCloudPassword()
      this.cloudPasswordAction = 'restore'
      this.cloudPasswordDialogController.open()
      this.cloudSyncStatus = '需要云备份密码'
      if (!quiet) {
        promptAction.showToast({ message: result.message })
      }
      return
    }
    this.updateCloudSyncStatus()
    this.cloudSyncIncludesSecrets = CloudSyncService.includesSecrets()
    if (!quiet || !result.success) {
      promptAction.showToast({ message: result.message })
    }
  }

  confirmCloudRestore(): void {
    AlertDialog.show({
      title: '从云端恢复',
      message: '云端的连接、分组和服务器配置将覆盖本机对应内容。未加密备份不会覆盖本机已有密码与服务器密钥。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '恢复',
        fontColor: RustDeskTheme.ACCENT,
        action: () => {
          this.syncCloudNow(true, false)
        },
      },
    })
  }

  updateCloudSyncStatus(): void {
    if (!this.cloudSyncEnabled) {
      this.cloudSyncStatus = '未开启'
      return
    }
    let lastTime: number = CloudSyncService.getLastSuccessTime()
    if (lastTime <= 0) {
      this.cloudSyncStatus = '已开启，尚未完成同步'
      return
    }
    let date: Date = new Date(lastTime)
    let pad: (value: number) => string = (value: number): string => value < 10 ? `0${value}` : value.toString()
    this.cloudSyncStatus = `上次同步 ${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())}`
  }

  @Builder
  buildDiagnosticsCard() {
    Column({ space: 4 }) {
      Text('问题诊断')
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 4 })

      Text('诊断默认关闭。开启后记录连接、网络通道、视频编码和解码状态；不会记录密码、验证码、剪贴板内容或密钥。')
        .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
        .lineHeight(19)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
        .margin({ bottom: 6 })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text('诊断日志')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(this.diagnosticLogEnabled ? '正在记录，出现问题后可导出发送给开发者' : '已关闭，不会在后台写入诊断日志')
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.diagnosticLogEnabled })
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.diagnosticLogEnabled ?
            (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : Color.White))
          .onChange((isOn: boolean) => {
            this.setDiagnosticLogEnabled(isOn)
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text(this.diagnosticLogBusy ? '正在导出…' : '导出诊断日志')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('选择保存位置后，可将日志文件发送给开发者排查')
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('导出')
          .fontSize(14)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .enabled(!this.diagnosticLogBusy)
      .opacity(this.diagnosticLogBusy ? 0.6 : 1)
      .onClick(() => {
        this.exportDiagnosticLog()
      })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Text('清除诊断日志')
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? '#FF9A9A' : RustDeskTheme.ERROR)
        Blank()
        Text('>')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FF9A9A' : RustDeskTheme.ERROR)
      }
      .width('100%')
      .padding({ top: 10, bottom: 8 })
      .onClick(() => {
        this.confirmClearDiagnosticLog()
      })
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  setDiagnosticLogEnabled(enabled: boolean): void {
    this.diagnosticLogEnabled = enabled
    RustDeskNapi.setOption('diagnostic-log-enabled', enabled ? '1' : '0')
    RustDeskNapi.setDiagnosticLogEnabled(enabled)
    if (enabled) {
      RustDeskNapi.appendDiagnosticLog('support', 'diagnostic_log_enabled_by_user')
    }
  }

  async exportDiagnosticLog(): Promise<void> {
    if (this.diagnosticLogBusy) {
      return
    }
    this.diagnosticLogBusy = true
    let outputFile: fileIo.File | undefined = undefined
    try {
      RustDeskNapi.appendDiagnosticLog('support', 'user_requested_log_export')
      let content: string = RustDeskNapi.getDiagnosticLog()
      let context = getContext(this) as common.UIAbilityContext
      let documentPicker = new picker.DocumentViewPicker(context)
      let fileName: string = `StarRustDesk-diagnostic-${this.diagnosticTimestamp()}.txt`
      let saveUris: string[] = await documentPicker.save({ newFileNames: [fileName] })
      if (saveUris.length <= 0) {
        return
      }
      outputFile = fileIo.openSync(saveUris[0],
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
      fileIo.writeSync(outputFile.fd, content)
      promptAction.showToast({ message: '诊断日志导出成功' })
      RustDeskNapi.appendDiagnosticLog('support', 'log_export_succeeded')
    } catch (_e) {
      RustDeskNapi.appendDiagnosticLog('support', 'log_export_failed')
      promptAction.showToast({ message: '诊断日志导出失败，请重新选择保存位置' })
    } finally {
      if (outputFile !== undefined) {
        try {
          fileIo.closeSync(outputFile)
        } catch (_e) {
        }
      }
      this.diagnosticLogBusy = false
    }
  }

  diagnosticTimestamp(): string {
    let now: Date = new Date()
    let pad: (value: number) => string = (value: number): string => value < 10 ? `0${value}` : value.toString()
    return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-` +
      `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
  }

  confirmClearDiagnosticLog(): void {
    AlertDialog.show({
      title: '清除诊断日志',
      message: '清除后，当前和上一份诊断日志都无法恢复。确定继续吗？',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '清除',
        fontColor: RustDeskTheme.ERROR,
        action: () => {
          RustDeskNapi.clearDiagnosticLog()
          promptAction.showToast({ message: '诊断日志已清除' })
        },
      },
    })
  }

  @Builder
  buildAboutCard() {
    Column() {
      Text(translate('About'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(translate('Version'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(RELEASE_NOTES_VERSION)
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text('更新日志')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(`查看 v${RELEASE_NOTES_VERSION} 的更新内容`)
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('>')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        this.releaseNotesDialogController.open()
      })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text('文件传输历史')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('查看发送、取回、失败和取消记录')
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('>')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        this.fileTransferHistoryDialogController.open()
      })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text('加入 QQ 群')
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(`群号 ${QQ_GROUP_NUMBER}`)
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('>')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        this.openQQGroup()
      })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Text(translate('APP Filing Number'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text('浙ICP备2026058556号-2A')
          .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
        Text('>')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        this.openFilingWebsite()
      })
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  async openFilingWebsite(): Promise<void> {
    try {
      let context = getContext(this) as common.UIAbilityContext
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: 'https://beian.miit.gov.cn/',
      })
    } catch (_) {
    }
  }

  async openQQGroup(): Promise<void> {
    try {
      let context = getContext(this) as common.UIAbilityContext
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: `mqqapi://card/show_pslcard?src_type=internal&version=1&uin=${QQ_GROUP_NUMBER}&card_type=group&source=qrcode`,
      })
    } catch (_) {
      try {
        let data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, QQ_GROUP_NUMBER)
        await pasteboard.getSystemPasteboard().setData(data)
        promptAction.showToast({ message: `未检测到 QQ，群号 ${QQ_GROUP_NUMBER} 已复制` })
      } catch (_) {
        promptAction.showToast({ message: `请在 QQ 中搜索群号 ${QQ_GROUP_NUMBER}` })
      }
    }
  }

  @Builder
  buildServerConfigCard() {
    Column() {
      Row() {
        Column() {
          Text(translate('ID/Relay Server'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          Text(translate('Configure custom server'))
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Text('>')
          .fontSize(18)
          .fontColor(RustDeskTheme.DARK_GRAY)
      }
      .width('100%')
      .onClick(() => {
        this.serverConfigDialogController.open()
      })
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

  @Builder
  buildThemeToggle() {
    Column() {
      Row() {
        Text(translate('Dark Mode'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.isDarkMode })
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : Color.White)
          .onChange((isOn: boolean) => {
            this.isDarkModeManual = true
            this.isDarkMode = isOn
          })
      }
      .width('100%')
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .width('100%')
  }

}

@CustomDialog
struct SettingsPasswordDialog {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @State password: string = ''
  @State passwordConfirm: string = ''
  title: string = '密码'
  description: string = ''
  onSave: (password: string) => void = (_password: string) => {}
  onCancel: () => void = () => {}
  controller?: CustomDialogController
  @State errorMsg: string = ''

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
      }

      TextInput({ placeholder: translate('Password'), text: this.password })
        .height(40)
        .fontSize(14)
        .type(InputType.Password)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER, radius: 8 })
        .padding({ left: 8, right: 8 })
        .width('100%')
        .onChange((v: string) => {
          this.password = v
          this.errorMsg = ''
        })

      TextInput({ placeholder: translate('Confirm Password'), text: this.passwordConfirm })
        .height(40)
        .fontSize(14)
        .type(InputType.Password)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER, radius: 8 })
        .padding({ left: 8, right: 8 })
        .width('100%')
        .onChange((v: string) => {
          this.passwordConfirm = v
          this.errorMsg = ''
        })

      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 12 }) {
        Button(translate('Cancel'))
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.BG_LIGHT)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            this.password = ''
            this.passwordConfirm = ''
            this.errorMsg = ''
            this.onCancel()
          })

        Button(translate('Save'))
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            if (this.password.length < 8) {
              this.errorMsg = '备份密码至少需要 8 位'
              return
            }
            if (this.password !== this.passwordConfirm) {
              this.errorMsg = translate('Passwords do not match')
              return
            }
            let password: string = this.password
            this.password = ''
            this.passwordConfirm = ''
            this.errorMsg = ''
            this.onSave(password)
          })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .padding(24)
    .width('85%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.BORDER_DARK : '#E4EAF3' })
    .borderRadius(8)
  }
}
