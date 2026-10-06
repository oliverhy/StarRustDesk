import { ButtonShapeModifier } from '../theme/ButtonShapeModifier'
﻿import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { LanguageService } from '../utils/LanguageService'
import { ServerConfigDialog } from '../widget/ServerConfigDialog'
import { ApiAccountDialog } from '../widget/ApiAccountDialog'
import {
  RELEASE_NOTES_SHOWN_OPTION,
  RELEASE_NOTES_SHOWN_ID,
  RELEASE_NOTES_VERSION,
  ReleaseNotesDialog,
} from '../widget/ReleaseNotesDialog'
import { RustDeskNapi } from '../service/RustDeskNapi'
import { SystemFaultDiagnostic } from '../service/SystemFaultDiagnostic'
import { common } from '@kit.AbilityKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { promptAction } from '@kit.ArkUI'
import { fileIo, picker } from '@kit.CoreFileKit'
import { FileTransferHistoryDialog } from '../widget/FileTransferHistoryDialog'
import { RecordingDialog } from '../widget/RecordingDialog'
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask'
import { CloudSyncResult, CloudSyncService } from '../service/CloudSyncService'
import { PeerOnlinePreference } from '../service/PeerOnlinePreference'
import { ThemePreference } from '../service/ThemePreference'

const QQ_GROUP_NUMBER: string = '221568948'

interface SettingItem {
  label: string
  value: string
}

@Component
export struct SettingsPage {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('uiLanguagePreference') uiLanguagePreference: string = 'system'
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('isDarkModeManual') isDarkModeManual: boolean = false
  @State themePreferenceBusy: boolean = false
  @StorageLink('peerOnlineQueryEnabled') peerOnlineQueryEnabled: boolean = true
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
  private apiAccountDialogController: CustomDialogController = new CustomDialogController({
    builder: ApiAccountDialog(),
    autoCancel: false,
    customStyle: true,
  })
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
  private recordingDialogController: CustomDialogController = new CustomDialogController({
    builder: RecordingDialog(), customStyle: true,
  })
  private cloudPasswordDialogController: CustomDialogController = new CustomDialogController({
    builder: SettingsPasswordDialog({
      title: translate('云备份密码', this.uiLanguage),
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
    this.peerOnlineQueryEnabled = AppStorage.get<boolean>('peerOnlineQueryEnabled') ?? true
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
          Text(translate('设置', this.uiLanguage))
            .fontSize(this.pageWidth >= 820 ? 30 : 26)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('连接质量、网络服务与外观', this.uiLanguage))
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
          this.buildLanguageCard()
          this.buildButtonShapeCard()
          this.buildSectionCard(translate('Account', this.uiLanguage), [
            { label: translate('Device Name', this.uiLanguage), value: RustDeskNapi.getDeviceName() },
          ])
          this.buildDisplayCard()
          this.buildInputCard()
          this.buildAudioCard()
          this.buildServerConfigCard()
          this.buildApiAccountEntry()
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
  buildLanguageCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(translate('Language', this.uiLanguage))
          .fontSize(17)
          .minFontSize(13)
          .maxFontSize(17)
          .maxLines(1)
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Button() {
          Row({ space: 8 }) {
            Text(this.languagePreferenceLabel())
              .fontSize(14)
              .minFontSize(11)
              .maxFontSize(14)
              .maxLines(2)
              .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
              .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
              .layoutWeight(1)
            Text('▾')
              .fontSize(14)
              .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          }
          .width('100%')
        }
        .id('language-selector')
        .layoutWeight(1.4)
        .constraintSize({ minHeight: this.buttonShapeOptionHeight() })
        .padding({ left: 16, right: 12, top: 10, bottom: 10 })
        .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
        .border({ width: 1,
          color: this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER })
        .accessibilityText(translate('Language', this.uiLanguage) + ': ' + this.languagePreferenceLabel())
        .bindMenu([
          { value: this.languageMenuLabel('system', '跟随系统'),
            action: () => { LanguageService.setPreference('system') } },
          { value: this.languageMenuLabel('zh-Hans', '简体中文'),
            action: () => { LanguageService.setPreference('zh-Hans') } },
          { value: this.languageMenuLabel('zh-Hant', '繁體中文'),
            action: () => { LanguageService.setPreference('zh-Hant') } },
          { value: this.languageMenuLabel('en', 'English'),
            action: () => { LanguageService.setPreference('en') } }
        ], { placement: Placement.BottomRight, enableArrow: true })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
      .width('100%')
      Text(translate('界面语言立即生效，不影响远控连接；系统权限提示在下次启动时应用。', this.uiLanguage))
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
    }
    .padding(16).width('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
  }

  languagePreferenceLabel(): string {
    if (this.uiLanguagePreference === 'zh-Hans') return '简体中文'
    if (this.uiLanguagePreference === 'zh-Hant') return '繁體中文'
    if (this.uiLanguagePreference === 'en') return 'English'
    return translate('跟随系统', this.uiLanguage)
  }

  languageMenuLabel(value: string, label: string): string {
    // Keep language self-names recognizable even when the current UI language changes.
    const text: string = value === 'system' ? translate('跟随系统', this.uiLanguage) : label
    return (this.uiLanguagePreference === value ? '✓ ' : '') + text
  }

  @Builder
  buildApiAccountEntry() {
    Button() {
      Row({ space: 12 }) {
        Column({ space: 5 }) {
          Text(translate('服务器账号', this.uiLanguage))
            .fontSize(17)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? '#F2F6FF' : '#17253D')
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(translate('API 登录与地址簿', this.uiLanguage))
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#C5D5EB' : '#445B78')
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('›')
          .fontSize(28)
          .fontColor(this.isDarkMode ? '#B9D8FF' : '#2763AC')
          .width(24)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 15, bottom: 15 })
    }
    .width('100%')
    .constraintSize({ minHeight: 80 })
    .padding(0)
    .backgroundColor(this.isDarkMode ? '#24364D' : '#EDF4FF')
    .border({ width: 1, color: this.isDarkMode ? '#516B8B' : '#CDDEF4' })
    .accessibilityText(translate('服务器账号，API 登录与地址簿', this.uiLanguage))
    .onClick(() => { this.apiAccountDialogController.open() })
    .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
  }

  @Builder
  buildDisplayCard() {
    Column() {
      Text(translate('Display', this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(translate('Resolution', this.uiLanguage))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(translate(this.resolution, this.uiLanguage))
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
        Text(translate('Frame Rate', this.uiLanguage))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(translate(this.frameRate.toString(), this.uiLanguage))
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
    Text(translate(label, this.uiLanguage))
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
      Text(translate(title, this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      ForEach(items, (item: SettingItem) => {
        Row() {
          Text(translate(item.label, this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          Blank()
          if (item.value.length > 0) {
            Text(translate(item.value, this.uiLanguage))
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
          Text(translate('显示本地鼠标指针', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('仅控制本机连接的物理鼠标指针，远端真实光标始终显示', this.uiLanguage))
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
          Text(translate('播放远端声音', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('播放远端设备的系统声音；有真实音频时接入系统播控中心', this.uiLanguage))
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
      Text(translate('华为云空间', this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 4 })

      Text(translate('在同一华为账号的设备间备份和恢复已保存连接、分组与服务器地址。', this.uiLanguage))
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
          Text(translate('个人云空间同步', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate(this.cloudSyncStatus, this.uiLanguage))
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
          Text(translate('同步连接密码和服务器密钥', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate(this.cloudSyncIncludesSecrets ? '同步时使用 AES-256-GCM 加密敏感信息' : '默认不上传敏感信息', this.uiLanguage))
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
          Text(translate('备份密码仅保存在本机', this.uiLanguage))
            .fontSize(11)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          Blank()
          Text(translate('更换密码', this.uiLanguage))
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
        Button(translate(this.cloudSyncBusy ? '同步中…' : '立即同步', this.uiLanguage))
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .layoutWeight(1)
          .enabled(this.cloudSyncEnabled && !this.cloudSyncBusy)
          .onClick(() => {
            this.syncCloudNow(false, false)
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate('从云端恢复', this.uiLanguage))
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .layoutWeight(1)
          .enabled(this.cloudSyncEnabled && !this.cloudSyncBusy)
          .onClick(() => {
            this.confirmCloudRestore()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width('100%')
      .padding({ top: 10, bottom: 6 })

      Text(translate('还需在系统“设置 > 华为账号 > 云空间”中允许 StarRustDesk 同步。', this.uiLanguage))
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
    try {
      if (!enabled) {
        this.cloudSyncIncludesSecrets = false
        CloudSyncService.setIncludesSecrets(false)
        await this.syncCloudNow(false, false)
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
    } catch (_error) {
      this.cloudSyncStatus = '无法读取本机云备份密码，请稍后重试'
      promptAction.showToast({ message: translate(this.cloudSyncStatus, this.uiLanguage) })
    }
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
      } else if (action === 'sync') {
        await this.syncCloudNow(false, false)
      }
    } catch (_error) {
      promptAction.showToast({ message: translate('备份密码保存失败', this.uiLanguage) })
    }
  }

  async syncCloudNow(restoreOnly: boolean, quiet: boolean): Promise<void> {
    if (this.cloudSyncBusy || !this.cloudSyncEnabled) {
      return
    }
    this.cloudSyncBusy = true
    this.cloudSyncStatus = restoreOnly ? '正在从云端恢复…' : '正在同步…'
    try {
      let result: CloudSyncResult = restoreOnly ?
        await CloudSyncService.restore(getContext(this) as common.UIAbilityContext) :
        await CloudSyncService.syncNow(getContext(this) as common.UIAbilityContext)
      if (!this.cloudSyncEnabled || result.code === -1002) {
        this.updateCloudSyncStatus()
        return
      }
      if (result.needsPassword) {
        this.cloudPasswordAction = result.passwordAction ?? (restoreOnly ? 'restore' : 'sync')
        this.cloudPasswordDialogController.open()
        this.cloudSyncStatus = '需要云备份密码'
        if (!quiet) promptAction.showToast({ message: translate(result.message, this.uiLanguage) })
        return
      }
      if (result.success) this.updateCloudSyncStatus()
      else this.cloudSyncStatus = result.message
      this.cloudSyncIncludesSecrets = CloudSyncService.includesSecrets()
      if (!quiet || !result.success) {
        promptAction.showToast({ message: translate(result.message, this.uiLanguage) })
      }
    } catch (_error) {
      if (this.cloudSyncEnabled) {
        this.cloudSyncStatus = '云同步未完成，请开启诊断日志后重试'
        if (!quiet) promptAction.showToast({ message: translate(this.cloudSyncStatus, this.uiLanguage) })
      }
    } finally {
      this.cloudSyncBusy = false
    }
  }

  confirmCloudRestore(): void {
    AlertDialog.show({
      title: translate('从云端恢复', this.uiLanguage),
      message: translate('云端的连接、分组和服务器配置将覆盖本机对应内容。未加密备份不会覆盖本机已有密码与服务器密钥。', this.uiLanguage),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: translate('取消', this.uiLanguage),
        action: () => {
        },
      },
      secondaryButton: {
        value: translate('恢复', this.uiLanguage),
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
    const lastResult = CloudSyncService.getLastResult()
    if (lastResult !== undefined && !lastResult.success) {
      this.cloudSyncStatus = lastResult.message
      return
    }
    let lastTime: number = CloudSyncService.getLastSuccessTime()
    if (lastTime <= 0) {
      this.cloudSyncStatus = '已开启，尚未完成同步'
      return
    }
    let date: Date = new Date(lastTime)
    let pad: (value: number) => string = (value: number): string => value < 10 ? `0${value}` : value.toString()
    this.cloudSyncStatus = `上次同步 ${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
  }

  @Builder
  buildDiagnosticsCard() {
    Column({ space: 4 }) {
      Text(translate('问题诊断', this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 4 })

      Text(translate('诊断默认关闭。开启后记录连接、网络通道、视频编码和解码状态；不会记录密码、验证码、剪贴板内容或密钥。', this.uiLanguage))
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
          Text(translate('诊断日志', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate(this.diagnosticLogEnabled ? '本地记录运行及系统故障日志，不自动上传；关闭时清除已采集的系统故障记录' : '已关闭，不会在后台写入诊断日志', this.uiLanguage))
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
          Text(translate(this.diagnosticLogBusy ? '正在导出…' : '导出诊断日志', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('包含已采集的崩溃/卡死记录；闪退后请重新打开应用，稍候再导出', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(translate('导出', this.uiLanguage))
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
        Text(translate('清除诊断日志', this.uiLanguage))
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
    SystemFaultDiagnostic.setEnabled(enabled)
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
      content += await SystemFaultDiagnostic.exportText()
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
      promptAction.showToast({ message: translate('诊断日志导出成功', this.uiLanguage) })
      RustDeskNapi.appendDiagnosticLog('support', 'log_export_succeeded')
    } catch (_e) {
      RustDeskNapi.appendDiagnosticLog('support', 'log_export_failed')
      promptAction.showToast({ message: translate('诊断日志导出失败，请重新选择保存位置', this.uiLanguage) })
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
      title: translate('清除诊断日志', this.uiLanguage),
      message: translate('清除后，当前、上一份诊断日志和已采集的系统故障记录都无法恢复。确定继续吗？', this.uiLanguage),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: translate('取消', this.uiLanguage),
        action: () => {
        },
      },
      secondaryButton: {
        value: translate('清除', this.uiLanguage),
        fontColor: RustDeskTheme.ERROR,
        action: () => {
          RustDeskNapi.clearDiagnosticLog()
          SystemFaultDiagnostic.clear()
          promptAction.showToast({ message: translate('诊断日志已清除', this.uiLanguage) })
        },
      },
    })
  }

  @Builder
  buildAboutCard() {
    Column() {
      Text(translate('About', this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(translate('Version', this.uiLanguage))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(translate(RELEASE_NOTES_VERSION, this.uiLanguage))
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
          Text(translate('更新日志', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate(`查看 v${RELEASE_NOTES_VERSION} 的更新内容`, this.uiLanguage))
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
          Text(translate('文件传输历史', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('查看发送、取回、失败和取消记录', this.uiLanguage))
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

      Row() {
        Text(translate('会话录像', this.uiLanguage)).fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Text(translate('查看 / 导出  >', this.uiLanguage)).fontSize(RustDeskTheme.FONT_SIZE_SMALL)
          .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
      }
      .width('100%').padding({ top: 14, bottom: 14 })
      .onClick(() => { this.recordingDialogController.open() })

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Row() {
        Column({ space: 3 }) {
          Text(translate('加入 QQ 群', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate(`群号 ${QQ_GROUP_NUMBER}`, this.uiLanguage))
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
        Text(translate('APP Filing Number', this.uiLanguage))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(translate('浙ICP备2026058556号-2A', this.uiLanguage))
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
        promptAction.showToast({ message: translate(`未检测到 QQ，群号 ${QQ_GROUP_NUMBER} 已复制`, this.uiLanguage) })
      } catch (_) {
        promptAction.showToast({ message: translate(`请在 QQ 中搜索群号 ${QQ_GROUP_NUMBER}`, this.uiLanguage) })
      }
    }
  }

  @Builder
  buildServerConfigCard() {
    Column() {
      Row() {
        Column() {
          Text(translate('ID/Relay Server', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          Text(translate('Configure custom server', this.uiLanguage))
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

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)
        .margin({ top: 12, bottom: 12 })

      Row() {
        Column({ space: 3 }) {
          Text(translate('查询服务器/设备在线状态', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('默认开启；定期查询已保存设备，可手动关闭，手动连接不受影响', this.uiLanguage))
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.peerOnlineQueryEnabled })
          .id('peerOnlineQueryToggle')
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.peerOnlineQueryEnabled ?
            (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : Color.White))
          .onChange((isOn: boolean) => {
            if (PeerOnlinePreference.setEnabled(isOn)) {
              this.peerOnlineQueryEnabled = isOn
            } else {
              promptAction.showToast({ message: translate('保存设置失败，请重试', this.uiLanguage) })
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
  buildButtonShapeCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text(translate('按钮样式', this.uiLanguage))
          .fontSize(16)
          .minFontSize(13)
          .maxFontSize(16)
          .maxLines(1)
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Button() {
          Row({ space: 8 }) {
            Text(this.buttonShapeLabel())
              .fontSize(14)
              .minFontSize(11)
              .maxFontSize(14)
              .maxLines(2)
              .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
              .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
              .layoutWeight(1)
            Text('▾')
              .fontSize(14)
              .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          }
          .width('100%')
        }
        .id('button-shape-selector')
        .layoutWeight(1.4)
        .constraintSize({ minHeight: this.buttonShapeOptionHeight() })
        .padding({ left: 16, right: 12, top: 10, bottom: 10 })
        .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
        .border({ width: 1,
          color: this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER })
        .accessibilityText(translate('按钮样式', this.uiLanguage) + ': ' + this.buttonShapeLabel())
        .bindMenu([
          { value: this.buttonShapeMenuLabel(true), action: () => { this.setButtonShape(true) } },
          { value: this.buttonShapeMenuLabel(false), action: () => { this.setButtonShape(false) } }
        ], { placement: Placement.BottomRight, enableArrow: true })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
      .width('100%')
      Text(translate('应用到连接、设置、远控功能栏和弹窗，立即生效并记住选择', this.uiLanguage))
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
    }
    .padding(16)
    .width('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
  }

  buttonShapeLabel(): string {
    return translate(this.roundedRectButtons ? '圆角长方形' : '经典圆润', this.uiLanguage)
  }

  buttonShapeMenuLabel(rectangular: boolean): string {
    return (this.roundedRectButtons === rectangular ? '✓ ' : '') +
      translate(rectangular ? '圆角长方形' : '经典圆润', this.uiLanguage)
  }

  setButtonShape(rectangular: boolean): void {
    RustDeskNapi.setOption('button-shape', rectangular ? 'rectangle' : 'classic')
    this.roundedRectButtons = rectangular
  }

  buttonShapeOptionHeight(): number {
    return Math.ceil(44 + Math.max(0, this.uiFontScale - 1) * 18)
  }

  async setDarkMode(enabled: boolean): Promise<void> {
    if (this.themePreferenceBusy) return
    this.themePreferenceBusy = true
    try {
      if (!await ThemePreference.setMode(enabled ? 'dark' : 'light')) {
        promptAction.showToast({ message: translate('保存设置失败，请重试', this.uiLanguage) })
      }
    } finally {
      // Re-render the controlled switch from the confirmed persisted state.
      this.themePreferenceBusy = false
    }
  }

  @Builder
  buildThemeToggle() {
    Column() {
      Row() {
        Text(translate('Dark Mode', this.uiLanguage))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.isDarkMode })
          .id('darkModeToggle')
          .enabled(!this.themePreferenceBusy)
          .selectedColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
          .switchPointColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : Color.White)
          .onChange((isOn: boolean) => {
            this.setDarkMode(isOn)
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
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
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
      Text(translate(this.title, this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)

      if (this.description.length > 0) {
        Text(translate(this.description, this.uiLanguage))
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
      }

      TextInput({ placeholder: translate('Password', this.uiLanguage), text: this.password })
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

      TextInput({ placeholder: translate('Confirm Password', this.uiLanguage), text: this.passwordConfirm })
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
        Text(translate(this.errorMsg, this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 12 }) {
        Button(translate('Cancel', this.uiLanguage))
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))

        Button(translate('Save', this.uiLanguage))
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
              this.errorMsg = translate('Passwords do not match', this.uiLanguage)
              return
            }
            let password: string = this.password
            this.password = ''
            this.passwordConfirm = ''
            this.errorMsg = ''
            this.onSave(password)
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
