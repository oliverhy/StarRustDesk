import { readableInputHeight } from '../theme/ReadableLayout'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { settingsPalette } from '../theme/SettingsSkin'
import {
  SETTINGS_DIALOG_CLOSE, SETTINGS_DIALOG_OPEN, SETTINGS_RELEASE, SettingsAction, SettingsCategoryItem, SettingsChoice,
  SettingsIcon, settingsPromptTransition
} from '../widget/SettingsControls'
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
import { curves, promptAction } from '@kit.ArkUI'
import { fileIo, picker } from '@kit.CoreFileKit'
import { FileTransferHistoryDialog } from '../widget/FileTransferHistoryDialog'
import { RecordingDialog } from '../widget/RecordingDialog'
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask'
import { CloudBackupSummary, CloudRestorePreview, CloudSyncResult, CloudSyncService } from '../service/CloudSyncService'
import { CloudBackupHistoryDialog } from '../widget/CloudBackupHistoryDialog'
import { PeerOnlinePreference } from '../service/PeerOnlinePreference'
import { ThemePreference } from '../service/ThemePreference'
import { InsecureConsentStore } from '../service/InsecureConsentStore'

const QQ_GROUP_NUMBER: string = '221568948'
const LANGUAGE_OPTIONS: SettingsChoice[] = [
  { key: 'system', label: '跟随系统' }, { key: 'zh-Hans', label: '简体中文', literal: true },
  { key: 'zh-Hant', label: '繁體中文', literal: true }, { key: 'en', label: 'English', literal: true }
]
const BUTTON_OPTIONS: SettingsChoice[] = [
  { key: 'classic', label: '经典圆润' }, { key: 'rectangle', label: '圆角长方形' }
]
const THEME_OPTIONS: SettingsChoice[] = [
  { key: 'system', label: '跟随系统' }, { key: 'light', label: '浅色' }, { key: 'dark', label: '深色' }
]
const RESOLUTION_OPTIONS: SettingsChoice[] = [
  { key: 'Auto', label: 'Auto' }, { key: '720p', label: '720p' },
  { key: '1080p', label: '1080p' }, { key: '4K', label: '4K' }
]
const FRAME_RATE_OPTIONS: SettingsChoice[] = [
  { key: '15', label: '15 FPS' }, { key: '30', label: '30 FPS' }, { key: '60', label: '60 FPS' }
]
const SETTINGS_IN = curves.cubicBezierCurve(0.19, 0.76, 0.28, 1)
const SETTINGS_OUT = curves.cubicBezierCurve(0.26, 0.57, 0.41, 1)

interface SettingsCategory {
  id: string
  title: string
  description: string
  icon: string
}

interface SettingsRowCopy {
  title: string
  detail?: string
  activeStatus?: boolean
}

interface SettingsSwitchArgs {
  label: string
  checked: boolean
  enabled: boolean
  controlId: string
  onChange: (checked: boolean) => void
}

interface SettingsDetail {
  text: string
}

const SETTINGS_CATEGORIES: SettingsCategory[] = [
  { id: 'home', title: '设置', description: '连接质量、网络服务与外观', icon: 'sliders' },
  { id: 'personal', title: '个性化设置', description: '语言、按钮样式与外观', icon: 'sliders' },
  { id: 'remote', title: '远控体验', description: '分辨率、帧率、鼠标指针与声音', icon: 'screen' },
  { id: 'network', title: '网络与账号', description: 'ID / 中继服务器、在线查询与地址簿', icon: 'server' },
  { id: 'backup', title: '备份与恢复', description: '华为云空间、加密备份与恢复', icon: 'cloud' },
  { id: 'diagnostics', title: '诊断与记录', description: '诊断日志、文件传输历史与会话录像', icon: 'activity' },
]

function settingsCategoryMeta(id: string): SettingsCategory {
  return SETTINGS_CATEGORIES.find((category: SettingsCategory) => category.id === id) ?? SETTINGS_CATEGORIES[0]
}

@Extend(Column)
function settingsCard(dark: boolean, compact: boolean) {
  .width('100%').padding(compact ? 10 : { left: 13, right: 13, top: 12, bottom: 12 })
  .backgroundColor(settingsPalette(dark).surface)
  .border({ width: 1, color: settingsPalette(dark).line }).borderRadius(compact ? 12 : 15)
}

@Component
export struct SettingsPage {
  @StorageLink('sunshineTestAvailable') private sunshineAvailable: boolean = false
  @StorageLink('sunshineTestEnabled') private sunshineEnabled: boolean = false
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('uiLanguagePreference') uiLanguagePreference: string = 'system'
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('themeMode') themeMode: string = 'system'
  @State themePreferenceBusy: boolean = false
  @StorageLink('peerOnlineQueryEnabled') peerOnlineQueryEnabled: boolean = true
  @State resolution: string = 'Auto'
  @State frameRate: number = 30
  @State showLocalCursor: boolean = true
  @State remoteAudioEnabled: boolean = true
  @State diagnosticLogEnabled: boolean = false
  @State diagnosticLogBusy: boolean = false
  @State cloudSyncEnabled: boolean = false
  @State cloudSyncIncludesSecrets: boolean = false
  // The native switch moves immediately; this is only its visual draft until
  // the password flow confirms the persisted preference.
  @State cloudSecretsSwitchOn: boolean = false
  @State cloudSecretsPending: boolean = false
  @State cloudSyncBusy: boolean = false
  @State cloudSyncStatus: string = '未开启'
  private cloudPasswordAction: string = ''
  private cloudSecretsRequestGeneration: number = 0
  @State cloudBackups: CloudBackupSummary[] = []
  @State cloudHistoryHasMore: boolean = false
  private cloudHistoryOffset: number = 0
  private cloudRestoreSnapshotId: string = ''
  private cloudRestoreTicket: string = ''
  private cloudUiGeneration: number = 0
  private cloudHistoryDialogController: CustomDialogController = new CustomDialogController({
    builder: CloudBackupHistoryDialog({
      backups: this.cloudBackups,
      hasMore: this.cloudHistoryHasMore,
      busy: this.cloudSyncBusy,
      onSelect: (id: string) => {
        this.cloudHistoryDialogController.close()
        this.previewCloudRestore(id)
      },
      onMore: () => { this.loadCloudHistory(true) },
      onClose: () => {
        CloudSyncService.recordUi('history_close')
        this.cloudHistoryDialogController.close()
        this.cancelCloudRestore()
      }
    }),
    autoCancel: false,
    customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })
  @Link settingsCategory: string
  @Prop tabBarInset: number = 94
  @State pageWidth: number = 0
  @State pageHeight: number = 0
  private apiAccountDialogController: CustomDialogController = new CustomDialogController({
    builder: ApiAccountDialog(),
    autoCancel: false,
    customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })
  private serverConfigDialogController: CustomDialogController = new CustomDialogController({
    builder: ServerConfigDialog(),
    autoCancel: true,
    customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })
  private releaseNotesDialogController: CustomDialogController = new CustomDialogController({
    builder: ReleaseNotesDialog({
      settingsStyle: true,
      onClose: () => {
        RustDeskNapi.setOption(RELEASE_NOTES_SHOWN_OPTION, RELEASE_NOTES_SHOWN_ID)
      },
    }),
    autoCancel: false,
    customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })
  private fileTransferHistoryDialogController: CustomDialogController = new CustomDialogController({
    builder: FileTransferHistoryDialog({ settingsStyle: true }),
    autoCancel: true,
    customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })
  private recordingDialogController: CustomDialogController = new CustomDialogController({
    builder: RecordingDialog({ settingsStyle: true }), customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })
  private cloudPasswordDialogController: CustomDialogController = new CustomDialogController({
    builder: SettingsPasswordDialog({
      title: translate('云备份密码', this.uiLanguage),
      description: '密码仅保存在本机安全存储中，新设备恢复时需要重新输入。',
      onSave: (password: string) => {
        this.saveCloudPassword(password)
      },
      onCancel: () => {
        this.cancelCloudPassword()
      }
    }),
    autoCancel: false,
    customStyle: true,
    openAnimation: SETTINGS_DIALOG_OPEN, closeAnimation: SETTINGS_DIALOG_CLOSE,
  })

  aboutToAppear(): void {
    this.cloudUiGeneration++
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
    this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
    this.updateCloudSyncStatus()
    if (this.cloudSyncEnabled) {
      this.syncCloudNow(false, true)
    }
  }

  aboutToDisappear(): void {
    this.cloudUiGeneration++
    this.cloudSecretsRequestGeneration++
    this.cloudSecretsPending = false
    this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
    this.cloudSyncBusy = false
    this.cloudHistoryDialogController.close()
    if (this.cloudPasswordAction === 'restore') this.cloudPasswordDialogController.close()
    if (this.cloudPasswordAction === 'enable-secrets') {
      this.cloudPasswordAction = ''
      this.cloudPasswordDialogController.close()
    }
    this.cancelCloudRestore()
  }

  build() {
    Column() {
      this.buildHeader()
      Stack({ alignContent: Alignment.Top }) {
        // The key changes only when entering/leaving a section. This animates
        // the viewport without remounting SettingsPage or resetting its data.
        ForEach([this.settingsCategory], (category: string) => {
          Scroll() {
            Column({ space: this.compact() ? 8 : 10 }) {
              this.buildCategoryContent(category)
            }
            .width('100%')
            .constraintSize({ maxWidth: 720 })
            .padding({
              left: this.compact() ? 8 : 13, right: this.compact() ? 8 : 13, top: this.compact() ? 8 : 13,
              bottom: category === 'home' ? this.tabBarInset : 16
            })
          }
          .width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto)
          .id('settings-page-' + category)
          .transition(this.categoryTransition(category))
        }, (category: string) => category)
      }
      .width('100%').layoutWeight(1).clip(true)
    }
    .width('100%').height('100%')
    .backgroundColor(settingsPalette(this.isDarkMode).app)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.pageWidth = newValue.width as number
      this.pageHeight = newValue.height as number
    })
  }

  private compact(): boolean {
    return this.pageWidth <= 530
  }

  private actionWidth(): number {
    const width = this.pageWidth > 0 ? this.pageWidth : 360
    return Math.min(192, Math.max(94, Math.floor(width * 0.45)))
  }

  private groupedActionWidth(): number {
    const width = this.pageWidth > 0 ? this.pageWidth : 360
    const available = Math.min(width, 720) - (this.compact() ? 38 : 54)
    return Math.min(this.actionWidth(), Math.max(72, Math.floor((available - 14) / 2)))
  }

  private menuHeight(): number {
    return this.pageHeight > 0 ? Math.max(88, Math.min(276, this.pageHeight * 0.62)) : 276
  }

  private openCategory(category: string): void {
    if (category === this.settingsCategory || settingsCategoryMeta(category).id !== category) return
    this.getUIContext().animateTo({ duration: 287, curve: SETTINGS_IN }, () => {
      this.settingsCategory = category
    })
  }

  private categoryTransition(category: string): TransitionEffect {
    const direction = category === 'home' ? -1 : 1
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: direction * 25 })
        .animation({ duration: 287, curve: SETTINGS_RELEASE })
        .combine(TransitionEffect.scale({ x: 0.982, y: 0.982 }))
        .combine(TransitionEffect.opacity(0).animation({ duration: 198, curve: SETTINGS_IN })),
      TransitionEffect.translate({ x: direction * 22 })
        .animation({ duration: 176, curve: SETTINGS_OUT })
        .combine(TransitionEffect.scale({ x: 0.989, y: 0.989 }))
        .combine(TransitionEffect.opacity(0)))
  }

  @Builder
  buildHeader() {
    Column() {
      Row({ space: this.compact() ? 7 : 10 }) {
        if (this.settingsCategory !== 'home') {
          SettingsAction({ icon: 'back', accessibleLabel: translate('返回设置', this.uiLanguage), tone: 'neutral',
            controlId: 'settings-category-back', onAction: () => { this.openCategory('home') } })
        }
        Column({ space: 4 }) {
          Text(translate(settingsCategoryMeta(this.settingsCategory).title, this.uiLanguage))
            .fontSize(24).lineHeight('32fp').fontWeight(700).fontColor(settingsPalette(this.isDarkMode).ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
            .accessibilityLevel('yes')
          Text(translate(settingsCategoryMeta(this.settingsCategory).description, this.uiLanguage))
            .fontSize(13).lineHeight('20fp').fontColor(settingsPalette(this.isDarkMode).muted)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        Row() {
          SettingsIcon({ icon: settingsCategoryMeta(this.settingsCategory).icon, iconSize: 18,
            ink: settingsPalette(this.isDarkMode).subtle })
        }
        .width(35).height(35).justifyContent(FlexAlign.Center)
        .backgroundColor(settingsPalette(this.isDarkMode).pill)
        .border({ width: 1, color: settingsPalette(this.isDarkMode).pillEdge }).borderRadius(12)
        .accessibilityLevel('no')
      }
      .width('100%').constraintSize({ maxWidth: 720 })
      .padding({ left: this.compact() ? 12 : 19, right: this.compact() ? 12 : 19,
        top: this.compact() ? 13 : 19, bottom: this.compact() ? 11 : 15 })
    }
    .width('100%')
    .radialGradient({ center: ['0%', '0%'], radius: '77%',
      colors: [[settingsPalette(this.isDarkMode).sky, 0], [settingsPalette(this.isDarkMode).app, 1]] })
    .border({ width: { bottom: 1 }, color: settingsPalette(this.isDarkMode).line })
  }

  @Builder
  buildCategoryContent(category: string) {
    if (category === 'home') {
      this.buildCategoryGroup('常用设置', ['personal', 'remote', 'network'])
      this.buildCategoryGroup('数据与支持', ['backup', 'diagnostics'])
      this.buildSunshineExperiment()
      this.buildAboutCard()
    } else if (category === 'personal') {
      this.buildLanguageCard()
      this.buildButtonShapeCard()
      this.buildThemeToggle()
    } else if (category === 'remote') {
      this.buildDisplayCard()
      this.buildInputCard()
      this.buildAudioCard()
    } else if (category === 'network') {
      this.buildServerConfigCard()
      this.buildApiAccountEntry()
    } else if (category === 'backup') {
      this.buildCloudSyncCard()
    } else if (category === 'diagnostics') {
      this.buildDiagnosticsCard()
      this.buildRecordsCard()
    }
  }

  @Builder
  buildSunshineExperiment() {
    if (this.sunshineAvailable) {
      Column() {
        Row({ space: 8 }) {
          this.rowCopy({
            title: this.uiLanguage === 'en' ? 'Game streaming experiment' : '游戏串流实验',
            detail: this.uiLanguage === 'en' ? 'Show Sunshine in Connections. Connect to your paired Windows helper.' :
              '开启后在连接页进入游戏串流，连接已配对的 Windows 助手。'
          })
          this.buildSwitch({
            label: this.uiLanguage === 'en' ? 'Game streaming experiment' : '游戏串流实验',
            checked: this.sunshineEnabled,
            enabled: true,
            controlId: 'sunshine-experiment-toggle',
            onChange: (isOn: boolean) => { this.sunshineEnabled = isOn }
          })
        }
        .width('100%')
      }
      .settingsCard(this.isDarkMode, this.compact())
    }
  }

  @Builder
  buildCategoryGroup(title: string, categories: string[]) {
    Column() {
      Text(translate(title, this.uiLanguage))
        .width('100%').padding({ left: 7, right: 7, top: 2, bottom: 6 }).fontSize(12).fontWeight(650)
        .lineHeight('18fp')
        .fontColor(settingsPalette(this.isDarkMode).muted).wordBreak(WordBreak.BREAK_WORD)
      ForEach(categories, (category: string, index: number) => {
        if (index > 0) {
          Divider().color(settingsPalette(this.isDarkMode).hair).strokeWidth(1)
            .margin({ left: this.compact() ? 47 : 56, right: 8 })
        }
        SettingsCategoryItem({
          title: translate(settingsCategoryMeta(category).title, this.uiLanguage),
          description: translate(settingsCategoryMeta(category).description, this.uiLanguage),
          icon: settingsCategoryMeta(category).icon, compact: this.compact(), featured: index === 0,
          itemId: 'settings-category-' + category, onAction: () => { this.openCategory(category) }
        })
      }, (category: string) => category)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: this.compact() ? 7 : 12, right: this.compact() ? 7 : 12,
      top: this.compact() ? 7 : 10, bottom: this.compact() ? 4 : 6 })
    .backgroundColor(settingsPalette(this.isDarkMode).surface)
    .border({ width: 1, color: settingsPalette(this.isDarkMode).line }).borderRadius(this.compact() ? 12 : 15)
  }

  @Builder
  sectionTitle(label: string, icon: string) {
    Row({ space: 8 }) {
      SettingsIcon({ icon: icon, iconSize: 17, ink: settingsPalette(this.isDarkMode).blue })
      Text(label).layoutWeight(1).fontSize(16).lineHeight('24fp').fontWeight(700).fontColor(settingsPalette(this.isDarkMode).ink)
        .wordBreak(WordBreak.BREAK_WORD)
    }
    .width('100%').padding({ bottom: 3 })
  }

  @Builder
  rowCopy($$: SettingsRowCopy) {
    Column({ space: 2 }) {
      Text($$.title).fontSize(14).lineHeight('21fp').fontWeight(650).fontColor(settingsPalette(this.isDarkMode).ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      if ($$.detail) {
        Row({ space: 5 }) {
          if ($$.activeStatus) Circle().width(6).height(6).fill(settingsPalette(this.isDarkMode).green)
          Text($$.detail).layoutWeight(1).fontSize(13).lineHeight('19.5fp').wordBreak(WordBreak.BREAK_WORD)
            .fontColor($$.activeStatus ? settingsPalette(this.isDarkMode).green : settingsPalette(this.isDarkMode).muted)
        }
        .width('100%')
      }
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder
  detailText($$: SettingsDetail) {
    Text($$.text).fontSize(13).lineHeight('19.5fp').fontColor(settingsPalette(this.isDarkMode).muted)
      .width('100%').wordBreak(WordBreak.BREAK_WORD)
  }

  @Builder
  rowDivider() {
    Divider().strokeWidth(1).color(settingsPalette(this.isDarkMode).hair)
  }

  @Builder
  buildSwitch($$: SettingsSwitchArgs) {
    Row() {
      Toggle({ type: ToggleType.Switch, isOn: $$.checked })
        .id($$.controlId).width(40).height(23).responseRegion({ x: -4, y: -10, width: 49, height: 44 })
        .selectedColor(settingsPalette(this.isDarkMode).switchOn)
        .switchPointColor(settingsPalette(this.isDarkMode).thumb)
        .switchStyle({ unselectedColor: settingsPalette(this.isDarkMode).switchOff, pointRadius: 8.5, trackBorderRadius: 12 })
        .enabled($$.enabled).accessibilityText($$.label)
        .onChange((value: boolean) => { $$.onChange(value) })
    }
    .width(49).height(44).justifyContent(FlexAlign.Center)
  }

  @Builder
  buildLanguageCard() {
    Column() {
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('Language', this.uiLanguage),
          detail: translate('界面语言立即生效，不影响远控连接；系统权限提示在下次启动时应用。', this.uiLanguage)
        })
        SettingsAction({
          controlId: 'language-selector', label: this.languagePreferenceLabel(),
          accessibleLabel: translate('Language', this.uiLanguage) + ': ' + this.languagePreferenceLabel(),
          items: LANGUAGE_OPTIONS, selected: this.uiLanguagePreference, maxWidth: this.actionWidth(),
          menuMaxHeight: this.menuHeight(), onSelect: (value: string) => { LanguageService.setPreference(value) }
        })
      }
      .width('100%')
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  languagePreferenceLabel(): string {
    if (this.uiLanguagePreference === 'zh-Hans') return '简体中文'
    if (this.uiLanguagePreference === 'zh-Hant') return '繁體中文'
    if (this.uiLanguagePreference === 'en') return 'English'
    return translate('跟随系统', this.uiLanguage)
  }

  @Builder
  buildApiAccountEntry() {
    Column() {
      Row({ space: 8 }) {
        this.rowCopy({ title: translate('服务器账号', this.uiLanguage), detail: translate('API 登录与地址簿', this.uiLanguage) })
        SettingsAction({ label: translate('登录设置', this.uiLanguage), tone: 'quiet', trailing: 'next',
          maxWidth: this.actionWidth(), onAction: () => { this.apiAccountDialogController.open() } })
      }
      .width('100%')
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  @Builder
  buildDisplayCard() {
    Column() {
      this.sectionTitle(translate('Display', this.uiLanguage), 'screen')
      Row({ space: 8 }) {
        this.rowCopy({ title: translate('Resolution', this.uiLanguage) })
        SettingsAction({
          controlId: 'settings-resolution', label: translate(this.resolution, this.uiLanguage),
          accessibleLabel: translate('Resolution', this.uiLanguage) + ': ' + translate(this.resolution, this.uiLanguage),
          items: RESOLUTION_OPTIONS, selected: this.resolution, maxWidth: this.actionWidth(), menuMaxHeight: this.menuHeight(),
          onSelect: (value: string) => { this.selectResolution(value) }
        })
      }
      .width('100%').padding({ top: 6, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({ title: translate('Frame Rate', this.uiLanguage) })
        SettingsAction({
          controlId: 'settings-frame-rate', label: this.frameRate.toString() + ' FPS',
          accessibleLabel: translate('Frame Rate', this.uiLanguage) + ': ' + this.frameRate.toString() + ' FPS',
          items: FRAME_RATE_OPTIONS, selected: this.frameRate.toString(), maxWidth: this.actionWidth(),
          menuMaxHeight: this.menuHeight(), onSelect: (value: string) => { this.selectFrameRate(parseInt(value)) }
        })
      }
      .width('100%').padding({ top: 9 })
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  selectResolution(res: string): void {
    this.resolution = res
    RustDeskNapi.setOption('resolution', res)
  }

  selectFrameRate(fps: number): void {
    this.frameRate = fps
    RustDeskNapi.setOption('frame-rate', fps.toString())
  }

  @Builder
  buildInputCard() {
    Column() {
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('显示本地鼠标指针', this.uiLanguage),
          detail: translate('仅控制本机连接的物理鼠标指针，远端真实光标始终显示', this.uiLanguage)
        })
        this.buildSwitch({
          label: translate('显示本地鼠标指针', this.uiLanguage),
          checked: this.showLocalCursor,
          enabled: true,
          controlId: 'settings-local-cursor',
          onChange: (isOn: boolean) => {
              this.showLocalCursor = isOn
              RustDeskNapi.setOption('show-local-cursor', isOn ? '1' : '0')
            }
        })
      }
      .width('100%')
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  confirmClearInsecureConsent(): void {
    const palette = settingsPalette(this.isDarkMode)
    AlertDialog.show({
      title: translate('清除未加密连接免提醒', this.uiLanguage),
      message: translate('清除后，本机所有远端将在下次遇到未加密连接时重新提示。不会删除连接、密码或服务器设置。', this.uiLanguage),
      backgroundColor: palette.surface, cornerRadius: 16, transition: settingsPromptTransition(),
      primaryButton: { value: translate('取消', this.uiLanguage), fontColor: palette.ink, backgroundColor: palette.pill,
        action: () => {} },
      secondaryButton: { value: translate('清除', this.uiLanguage), fontColor: palette.red, backgroundColor: palette.redSoft,
        action: () => { this.clearInsecureConsent() } },
    })
  }

  async clearInsecureConsent(): Promise<void> {
    let cleared: boolean = false
    try { cleared = await InsecureConsentStore.clear(getContext(this) as common.UIAbilityContext) } catch (_error) {}
    RustDeskNapi.appendDiagnosticLog('connection-security', `insecure_grants_cleared=${cleared}`)
    promptAction.showToast({ message: translate(cleared ? '免提醒授权已清除' : '清除免提醒授权失败，请重试', this.uiLanguage) })
  }

  @Builder
  buildAudioCard() {
    Column() {
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('播放远端声音', this.uiLanguage),
          detail: translate('播放远端设备的系统声音；有真实音频时接入系统播控中心', this.uiLanguage)
        })
        this.buildSwitch({
          label: translate('播放远端声音', this.uiLanguage),
          checked: this.remoteAudioEnabled,
          enabled: true,
          controlId: 'settings-audio',
          onChange: (isOn: boolean) => {
              this.remoteAudioEnabled = isOn
              RustDeskNapi.setOption('remote-audio-enabled', isOn ? '1' : '0')
              RustDeskNapi.setRemoteAudioEnabled(isOn)
              if (!isOn) RemoteSessionBackgroundTask.setAudioPlaybackActive(false)
            }
        })
      }
      .width('100%')
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  @Builder
  buildCloudSyncCard() {
    Column() {
      this.sectionTitle(translate('华为云空间', this.uiLanguage), 'cloud')
      this.detailText({ text: translate('在同一华为账号的设备间备份和恢复已保存连接、分组与服务器地址。', this.uiLanguage) })
      Divider().strokeWidth(1).color(settingsPalette(this.isDarkMode).hair).margin({ top: 8 })
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('个人云空间同步', this.uiLanguage),
          detail: translate(this.cloudSyncStatus, this.uiLanguage),
          activeStatus: this.cloudSyncEnabled
        })
        this.buildSwitch({
          label: translate('个人云空间同步', this.uiLanguage),
          checked: this.cloudSyncEnabled,
          enabled: true,
          controlId: 'settings-cloud-sync',
          onChange: (isOn: boolean) => { this.setCloudSyncEnabled(isOn) }
        })
      }
      .width('100%').padding({ top: 9, bottom: 9 })
      this.rowDivider()

      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('同步连接密码和服务器密钥', this.uiLanguage),
          detail: translate(this.cloudSyncIncludesSecrets ? '同步时使用 AES-256-GCM 加密敏感信息' : '默认不上传敏感信息',
              this.uiLanguage)
        })
        this.buildSwitch({
          label: translate('同步连接密码和服务器密钥', this.uiLanguage),
          checked: this.cloudSecretsSwitchOn,
          enabled: this.cloudSyncEnabled && !this.cloudSyncBusy && !this.cloudSecretsPending,
          controlId: 'settings-cloud-secrets',
          onChange: (isOn: boolean) => { this.onCloudSecretsSwitchChanged(isOn) }
        })
      }
      .width('100%').padding({ top: 9, bottom: 9 }).opacity(this.cloudSyncEnabled ? 1 : 0.55)

      if (this.cloudSyncEnabled && this.cloudSyncIncludesSecrets) {
        this.rowDivider()
        Row({ space: 8 }) {
          this.rowCopy({ title: translate('备份密码', this.uiLanguage), detail: translate('备份密码仅保存在本机', this.uiLanguage) })
          SettingsAction({ label: translate('更换密码', this.uiLanguage), maxWidth: this.actionWidth(),
            onAction: () => {
              this.cloudPasswordAction = 'enable-secrets'
              this.cloudPasswordDialogController.open()
            } })
        }
        .width('100%').padding({ top: 9, bottom: 9 })
      }

      this.rowDivider()
      Row({ space: 3 }) {
        SettingsAction({ label: translate(this.cloudSyncBusy ? '同步中…' : '立即同步', this.uiLanguage),
          icon: 'sync', tone: 'primary', grouped: true, maxWidth: this.groupedActionWidth(),
          isEnabled: this.cloudSyncEnabled && !this.cloudSyncBusy, onAction: () => { this.syncCloudNow(false, false) } })
        Divider().vertical(true).height(19).strokeWidth(1).color(settingsPalette(this.isDarkMode).pillEdge)
        SettingsAction({ label: translate('从云端恢复', this.uiLanguage), icon: 'restore', grouped: true,
          maxWidth: this.groupedActionWidth(), isEnabled: this.cloudSyncEnabled && !this.cloudSyncBusy,
          onAction: () => { this.confirmCloudRestore() } })
      }
      .padding(2).margin({ top: 9, bottom: 9 }).alignSelf(ItemAlign.Start)
      .backgroundColor(settingsPalette(this.isDarkMode).pill)
      .border({ width: 1, color: settingsPalette(this.isDarkMode).pillEdge })
      .borderRadius(this.roundedRectButtons ? 15 : 26)

      this.detailText({ text: translate('还需在系统“设置 > 华为账号 > 云空间”中允许 芝麻远控 同步。', this.uiLanguage) })
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  setCloudSyncEnabled(enabled: boolean): void {
    this.cloudSyncEnabled = enabled
    CloudSyncService.setEnabled(enabled)
    if (!enabled) {
      this.cloudSecretsRequestGeneration++
      this.cloudSecretsPending = false
      this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
      if (this.cloudPasswordAction === 'enable-secrets') {
        this.cloudPasswordAction = ''
        this.cloudPasswordDialogController.close()
      }
      this.cloudHistoryDialogController.close()
      this.cancelCloudRestore()
      this.cloudSyncStatus = '已关闭'
      return
    }
    this.cloudSyncStatus = '等待首次同步'
    this.syncCloudNow(false, false)
  }

  onCloudSecretsSwitchChanged(isOn: boolean): void {
    // Programmatic rollback may itself cause onChange on some ArkUI versions.
    // Ignore it so cancelling never writes preferences or starts a cloud sync.
    if (isOn === this.cloudSecretsSwitchOn) return
    this.cloudSecretsSwitchOn = isOn
    if (this.cloudSecretsPending) {
      // A second gesture may arrive before the disabled state is rendered.
      // Invalidate the earlier password check rather than enabling later.
      this.cloudSecretsRequestGeneration++
      this.cloudSecretsPending = false
      this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
      return
    }
    this.setCloudSecretsEnabled(isOn)
  }

  cancelCloudPassword(): void {
    const action: string = this.cloudPasswordAction
    this.cloudPasswordAction = ''
    if (action === 'restore') this.cancelCloudRestore()
    if (action === 'enable-secrets') this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
    this.cloudPasswordDialogController.close()
  }

  async setCloudSecretsEnabled(enabled: boolean): Promise<void> {
    if (this.cloudSecretsPending || this.cloudSyncBusy || !this.cloudSyncEnabled ||
      enabled === this.cloudSyncIncludesSecrets) {
      this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
      return
    }
    const requestGeneration: number = ++this.cloudSecretsRequestGeneration
    const uiGeneration: number = this.cloudUiGeneration
    this.cloudSecretsPending = true
    try {
      if (!enabled) {
        this.cloudSyncIncludesSecrets = false
        CloudSyncService.setIncludesSecrets(false)
        await this.syncCloudNow(false, false)
        return
      }
      const hasPassword: boolean = await CloudSyncService.hasCloudPassword()
      if (requestGeneration !== this.cloudSecretsRequestGeneration ||
        uiGeneration !== this.cloudUiGeneration || !this.cloudSyncEnabled) return
      if (hasPassword) {
        this.cloudSyncIncludesSecrets = true
        CloudSyncService.setIncludesSecrets(true)
        await this.syncCloudNow(false, false)
        return
      }
      this.cloudPasswordAction = 'enable-secrets'
      this.cloudPasswordDialogController.open()
    } catch (_error) {
      if (requestGeneration !== this.cloudSecretsRequestGeneration || uiGeneration !== this.cloudUiGeneration) return
      this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
      this.cloudSyncStatus = '无法读取本机云备份密码，请稍后重试'
      promptAction.showToast({ message: translate(this.cloudSyncStatus, this.uiLanguage) })
    } finally {
      if (requestGeneration === this.cloudSecretsRequestGeneration) this.cloudSecretsPending = false
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
        await this.previewCloudRestore(this.cloudRestoreSnapshotId)
      } else if (action === 'sync') {
        await this.syncCloudNow(false, false)
      }
    } catch (_error) {
      promptAction.showToast({ message: translate('备份密码保存失败', this.uiLanguage) })
    }
  }

  async syncCloudNow(restoreOnly: boolean, quiet: boolean): Promise<void> {
    if (restoreOnly && this.cloudRestoreTicket.length === 0) {
      await this.previewCloudRestore(this.cloudRestoreSnapshotId)
      return
    }
    if (this.cloudSyncBusy || !this.cloudSyncEnabled) {
      return
    }
    this.cloudSyncBusy = true
    const generation = this.cloudUiGeneration
    this.cloudSyncStatus = restoreOnly ? '正在从云端恢复…' : '正在同步…'
    try {
      let result: CloudSyncResult = restoreOnly ?
        await CloudSyncService.restore(getContext(this) as common.UIAbilityContext, this.cloudRestoreTicket) :
        await CloudSyncService.syncNow(getContext(this) as common.UIAbilityContext)
      if (generation !== this.cloudUiGeneration) return
      if (!this.cloudSyncEnabled || result.code === -1002) {
        this.updateCloudSyncStatus()
        return
      }
      if (result.needsPassword) {
        if (!restoreOnly) this.cloudRestoreSnapshotId = ''
        this.cloudPasswordAction = result.passwordAction ?? (restoreOnly ? 'restore' : 'sync')
        this.cloudPasswordDialogController.open()
        this.cloudSyncStatus = '需要云备份密码'
        if (!quiet) promptAction.showToast({ message: translate(result.message, this.uiLanguage) })
        return
      }
      const notices: string[] = (result.notices ?? []).map((notice: string): string => translate(notice, this.uiLanguage))
      if (result.success && notices.length > 0) {
        this.cloudSyncStatus = translate(result.message, this.uiLanguage) + '\n' + notices.join('\n')
      } else if (result.success) this.updateCloudSyncStatus()
      else this.cloudSyncStatus = result.message
      this.cloudSyncIncludesSecrets = CloudSyncService.includesSecrets()
      if (this.cloudPasswordAction !== 'enable-secrets' && !this.cloudSecretsPending) {
        this.cloudSecretsSwitchOn = this.cloudSyncIncludesSecrets
      }
      if (!quiet || !result.success) {
        promptAction.showToast({ message: translate(result.message, this.uiLanguage) +
          (notices.length > 0 ? '\n' + notices.join('\n') : '') })
      }
      if (restoreOnly) this.cancelCloudRestore(false)
    } catch (_error) {
      if (generation !== this.cloudUiGeneration) return
      if (restoreOnly) this.cancelCloudRestore(false)
      if (this.cloudSyncEnabled) {
        this.cloudSyncStatus = '云同步未完成，请开启诊断日志后重试'
        if (!quiet) promptAction.showToast({ message: translate(this.cloudSyncStatus, this.uiLanguage) })
      }
    } finally {
      if (generation === this.cloudUiGeneration) this.cloudSyncBusy = false
    }
  }

  confirmCloudRestore(): void {
    CloudSyncService.recordUi('history_open')
    this.loadCloudHistory(false)
  }

  cancelCloudRestore(logCancellation: boolean = true): void {
    if (logCancellation && (this.cloudRestoreTicket.length > 0 || this.cloudRestoreSnapshotId.length > 0)) {
      CloudSyncService.recordUi('restore_cancelled')
    }
    this.cloudRestoreTicket = ''
    this.cloudRestoreSnapshotId = ''
    CloudSyncService.cancelRestorePreview()
  }

  async loadCloudHistory(more: boolean): Promise<void> {
    if (this.cloudSyncBusy || !this.cloudSyncEnabled) return
    this.cloudSyncBusy = true
    const generation = this.cloudUiGeneration
    try {
      const result = await CloudSyncService.listBackups(getContext(this) as common.UIAbilityContext, more ? this.cloudHistoryOffset : 0)
      if (!this.cloudSyncEnabled || generation !== this.cloudUiGeneration) return
      if (!result.success || result.backups === undefined || result.backups.length === 0) {
        this.cloudSyncStatus = result.message
        promptAction.showToast({ message: translate(result.message, this.uiLanguage) })
        return
      }
      const incoming = result.backups
      this.cloudBackups = more ? this.cloudBackups.concat(incoming.filter((item: CloudBackupSummary) =>
        !this.cloudBackups.some((existing: CloudBackupSummary) => existing.id === item.id))) : incoming
      this.cloudHistoryOffset = result.nextOffset ?? 0
      this.cloudHistoryHasMore = result.hasMore ?? false
      if (!more) this.cloudHistoryDialogController.open()
    } catch (_error) {
      if (generation !== this.cloudUiGeneration) return
      promptAction.showToast({ message: translate('无法读取云备份列表，请稍后重试', this.uiLanguage) })
    } finally { if (generation === this.cloudUiGeneration) this.cloudSyncBusy = false }
  }

  async previewCloudRestore(snapshotId: string): Promise<void> {
    if (this.cloudSyncBusy || !this.cloudSyncEnabled) return
    this.cloudRestoreSnapshotId = snapshotId
    this.cloudSyncBusy = true
    const generation = this.cloudUiGeneration
    try {
      const result = await CloudSyncService.previewRestore(getContext(this) as common.UIAbilityContext, snapshotId)
      if (generation !== this.cloudUiGeneration) { CloudSyncService.cancelRestorePreview(); return }
      if (!this.cloudSyncEnabled) { this.cancelCloudRestore(); return }
      if (result.needsPassword) {
        this.cloudPasswordAction = 'restore'
        this.cloudSyncStatus = '需要云备份密码'
        this.cloudPasswordDialogController.open()
        promptAction.showToast({ message: translate(result.message, this.uiLanguage) })
        return
      }
      if (!result.success || result.preview === undefined) {
        this.cloudSyncStatus = result.message
        promptAction.showToast({ message: translate(result.message, this.uiLanguage) })
        this.cancelCloudRestore(false)
        return
      }
      this.cloudRestoreTicket = result.preview.ticket
      this.showCloudRestorePreview(result.preview)
    } catch (_error) {
      if (generation !== this.cloudUiGeneration) return
      this.cancelCloudRestore(false)
      promptAction.showToast({ message: translate('无法预览云备份，请稍后重试', this.uiLanguage) })
    } finally { if (generation === this.cloudUiGeneration) this.cloudSyncBusy = false }
  }

  showCloudRestorePreview(preview: CloudRestorePreview): void {
    let serverDetail: string = ''
    const serverConflict = preview.serverRestoreMode === 'preserve_key_conflict' ||
      preview.serverRestoreMode === 'preserve_partial_conflict'
    if (preview.serverRestoreMode === 'preserve_empty') {
      serverDetail = '备份没有服务器地址，将保留本机服务器配置和 Key。'
    } else if (preview.serverRestoreMode === 'preserve_key_conflict') {
      serverDetail = '备份未包含 Key 且服务器不同，将保留本机服务器配置，避免密钥不匹配。'
    } else if (preview.serverRestoreMode === 'preserve_partial_conflict') {
      serverDetail = '备份服务器信息不完整且服务器不同，将保留本机服务器配置。'
    } else if (preview.serverKeyIncluded) {
      serverDetail = '将恢复备份中的服务器地址和 Key。'
    } else {
      serverDetail = '将恢复服务器地址；备份未包含 Key，保留本机现有 Key。'
    }
    const details = `${new Date(preview.time).toLocaleString()}\n` +
      translate(`${preview.connectionCount} 个连接 · ${preview.groupCount} 个分组`, this.uiLanguage) + '\n' +
      translate(serverDetail, this.uiLanguage) + '\n\n' +
      (serverConflict ? translate('为避免连接使用错误的服务器，请先手动配置备份对应的服务器后再恢复；本机数据不会改动。', this.uiLanguage) + '\n\n' : '') +
      (preview.serverRestoreMode === 'preserve_empty' ?
        translate('备份未记录服务器，请核对恢复后的连接是否属于当前服务器。', this.uiLanguage) + '\n\n' : '') +
      (preview.serverRestoreMode === 'restore' && preview.serverEmptyFieldsKept ?
        translate('备份为空的服务器地址将保留本机值；需要清空时请手动设置。', this.uiLanguage) + '\n\n' : '') +
      (!serverConflict && preview.connectionCount === 0 ? translate('此备份没有连接，恢复后本机连接列表将为空。可取消并选择更早的备份。', this.uiLanguage) + '\n\n' : '') +
      translate(serverConflict ? '本次不会恢复连接、分组或服务器配置。' :
        '云端连接和分组将覆盖本机对应内容；服务器配置按上述说明处理。未加密备份不会覆盖本机已有密码。', this.uiLanguage)
    const palette = settingsPalette(this.isDarkMode)
    AlertDialog.show({
      title: translate('确认恢复此备份', this.uiLanguage),
      message: details,
      autoCancel: false,
      cancel: () => { this.cancelCloudRestore() },
      alignment: DialogAlignment.Center,
      backgroundColor: palette.surface, cornerRadius: 16, transition: settingsPromptTransition(),
      primaryButton: {
        value: translate('取消', this.uiLanguage),
        fontColor: palette.ink, backgroundColor: palette.pill,
        action: () => { this.cancelCloudRestore() },
      },
      secondaryButton: {
        value: translate(serverConflict ? '知道了' : '恢复', this.uiLanguage),
        fontColor: palette.blue, backgroundColor: palette.blueSoft,
        action: () => {
          if (serverConflict) { this.cancelCloudRestore(false); return }
          CloudSyncService.recordUi('restore_confirmed', { cloudTime: preview.time, connections: preview.connectionCount,
            groups: preview.groupCount, encrypted: preview.encrypted, serverConfigured: preview.serverConfigured })
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
    if (lastResult !== undefined && (!lastResult.success || lastResult.restored)) {
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
    Column() {
      this.sectionTitle(translate('问题诊断', this.uiLanguage), 'activity')
      this.detailText({
        text: translate('诊断默认关闭。开启后记录连接、网络通道、视频编码和解码状态；不会记录密码、验证码、剪贴板内容或密钥。',
          this.uiLanguage)
      })
      Divider().strokeWidth(1).color(settingsPalette(this.isDarkMode).hair).margin({ top: 8 })
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('诊断日志', this.uiLanguage),
          detail: translate(this.diagnosticLogEnabled ? '本地记录运行及系统故障日志，不自动上传；关闭时清除已采集的系统故障记录' :
              '已关闭，不会在后台写入诊断日志', this.uiLanguage)
        })
        this.buildSwitch({
          label: translate('诊断日志', this.uiLanguage),
          checked: this.diagnosticLogEnabled,
          enabled: true,
          controlId: 'settings-diagnostics',
          onChange: (isOn: boolean) => { this.setDiagnosticLogEnabled(isOn) }
        })
      }
      .width('100%').padding({ top: 9, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate(this.diagnosticLogBusy ? '正在导出…' : '导出诊断日志', this.uiLanguage),
          detail: translate('包含已采集的崩溃/卡死记录；闪退后请重新打开应用，稍候再导出', this.uiLanguage)
        })
        SettingsAction({ label: translate('导出', this.uiLanguage), icon: 'download', maxWidth: this.actionWidth(),
          isEnabled: !this.diagnosticLogBusy, onAction: () => { this.exportDiagnosticLog() } })
      }
      .width('100%').padding({ top: 9, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('清除诊断日志', this.uiLanguage),
          detail: translate('只清理本机已记录的日志', this.uiLanguage)
        })
        SettingsAction({ label: translate('清除', this.uiLanguage), icon: 'trash', tone: 'warn',
          accessibleLabel: translate('清除诊断日志', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.confirmClearDiagnosticLog() } })
      }
      .width('100%').padding({ top: 9 })
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  @Builder
  buildRecordsCard() {
    Column() {
      this.sectionTitle(translate('使用记录', this.uiLanguage), 'clock')
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('文件传输历史', this.uiLanguage),
          detail: translate('查看发送、取回、失败和取消记录', this.uiLanguage)
        })
        SettingsAction({ label: translate('查看', this.uiLanguage), tone: 'quiet', trailing: 'next',
          accessibleLabel: translate('文件传输历史', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.fileTransferHistoryDialogController.open() } })
      }
      .width('100%').padding({ top: 6, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('会话录像', this.uiLanguage),
          detail: translate('查看或导出已结束的远控会话录像', this.uiLanguage)
        })
        SettingsAction({ label: translate('查看 / 导出', this.uiLanguage), tone: 'quiet', trailing: 'next',
          accessibleLabel: translate('会话录像', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.recordingDialogController.open() } })
      }
      .width('100%').padding({ top: 9 })
    }
    .settingsCard(this.isDarkMode, this.compact())
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
      let fileName: string = `芝麻远控-diagnostic-${this.diagnosticTimestamp()}.txt`
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
    const palette = settingsPalette(this.isDarkMode)
    AlertDialog.show({
      title: translate('清除诊断日志', this.uiLanguage),
      message: translate('清除后，当前、上一份诊断日志和已采集的系统故障记录都无法恢复。确定继续吗？', this.uiLanguage),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      backgroundColor: palette.surface, cornerRadius: 16, transition: settingsPromptTransition(),
      primaryButton: {
        value: translate('取消', this.uiLanguage),
        fontColor: palette.ink, backgroundColor: palette.pill,
        action: () => {
        },
      },
      secondaryButton: {
        value: translate('清除', this.uiLanguage),
        fontColor: palette.red, backgroundColor: palette.redSoft,
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
      this.sectionTitle(translate('关于与反馈', this.uiLanguage), 'info')
      Row({ space: 8 }) {
        this.rowCopy({ title: translate('Version', this.uiLanguage) })
        Text('v' + RELEASE_NOTES_VERSION).fontSize(13).fontColor(settingsPalette(this.isDarkMode).subtle)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor(settingsPalette(this.isDarkMode).pill).borderRadius(9)
      }
      .width('100%').padding({ top: 6, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('更新日志', this.uiLanguage),
          detail: translate(`查看 v${RELEASE_NOTES_VERSION} 的更新内容`, this.uiLanguage)
        })
        SettingsAction({ label: translate('查看', this.uiLanguage), tone: 'quiet', trailing: 'next',
          accessibleLabel: translate('更新日志', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.releaseNotesDialogController.open() } })
      }
      .width('100%').padding({ top: 9, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('加入 QQ 群', this.uiLanguage),
          detail: translate(`群号 ${QQ_GROUP_NUMBER}`, this.uiLanguage)
        })
        SettingsAction({ label: translate('加入', this.uiLanguage), tone: 'quiet', trailing: 'next',
          accessibleLabel: translate('加入 QQ 群', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.openQQGroup() } })
      }
      .width('100%').padding({ top: 9, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('应用备案号', this.uiLanguage),
          detail: translate('浙ICP备2026058556号-2A', this.uiLanguage)
        })
        SettingsAction({ label: translate('查看', this.uiLanguage), tone: 'quiet', trailing: 'next',
          accessibleLabel: translate('应用备案号', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.openFilingWebsite() } })
      }
      .width('100%').padding({ top: 9 })
    }
    .settingsCard(this.isDarkMode, this.compact())
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
      this.sectionTitle(translate('网络服务', this.uiLanguage), 'server')
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('ID / 中继服务器', this.uiLanguage),
          detail: translate('配置自建服务器地址和密钥', this.uiLanguage)
        })
        SettingsAction({ label: translate('配置', this.uiLanguage), tone: 'quiet', trailing: 'next',
          maxWidth: this.actionWidth(), onAction: () => { this.serverConfigDialogController.open() } })
      }
      .width('100%').padding({ top: 6, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('查询服务器/设备在线状态', this.uiLanguage),
          detail: translate('默认开启；定期查询已保存设备，可手动关闭，手动连接不受影响', this.uiLanguage)
        })
        this.buildSwitch({
          label: translate('查询服务器/设备在线状态', this.uiLanguage),
          checked: this.peerOnlineQueryEnabled,
          enabled: true,
          controlId: 'peerOnlineQueryToggle',
          onChange: (isOn: boolean) => {
              if (PeerOnlinePreference.setEnabled(isOn)) {
                this.peerOnlineQueryEnabled = isOn
              } else {
                promptAction.showToast({ message: translate('保存设置失败，请重试', this.uiLanguage) })
              }
            }
        })
      }
      .width('100%').padding({ top: 9, bottom: 9 })
      this.rowDivider()
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('未加密连接免提醒', this.uiLanguage),
          detail: translate('清除本机7天免提醒授权，不影响连接、密码和服务器设置', this.uiLanguage)
        })
        SettingsAction({ label: translate('清除', this.uiLanguage), tone: 'warn', icon: 'trash',
          accessibleLabel: translate('清除未加密连接免提醒', this.uiLanguage), maxWidth: this.actionWidth(),
          onAction: () => { this.confirmClearInsecureConsent() } })
      }
      .width('100%').padding({ top: 9 })
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  @Builder
  buildButtonShapeCard() {
    Column() {
      Row({ space: 8 }) {
        this.rowCopy({
          title: translate('按钮样式', this.uiLanguage),
          detail: translate('应用到连接、设置、远控功能栏和弹窗，立即生效并记住选择', this.uiLanguage)
        })
        SettingsAction({
          controlId: 'button-shape-selector', label: this.buttonShapeLabel(),
          accessibleLabel: translate('按钮样式', this.uiLanguage) + ': ' + this.buttonShapeLabel(),
          items: BUTTON_OPTIONS, selected: this.roundedRectButtons ? 'rectangle' : 'classic',
          maxWidth: this.actionWidth(), menuMaxHeight: this.menuHeight(),
          onSelect: (value: string) => { this.setButtonShape(value === 'rectangle') }
        })
      }
      .width('100%')
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

  buttonShapeLabel(): string {
    return translate(this.roundedRectButtons ? '圆角长方形' : '经典圆润', this.uiLanguage)
  }

  setButtonShape(rectangular: boolean): void {
    RustDeskNapi.setOption('button-shape', rectangular ? 'rectangle' : 'classic')
    this.roundedRectButtons = rectangular
  }

  async setThemeMode(mode: string): Promise<void> {
    if (this.themePreferenceBusy) return
    this.themePreferenceBusy = true
    try {
      if (!await ThemePreference.setMode(mode)) {
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
      Row({ space: 8 }) {
        this.rowCopy({ title: translate('外观', this.uiLanguage), detail: translate('选择界面配色', this.uiLanguage) })
        SettingsAction({
          controlId: 'themeModeSelector',
          label: translate(this.themeMode === 'dark' ? '深色' : this.themeMode === 'light' ? '浅色' : '跟随系统', this.uiLanguage),
          accessibleLabel: translate('外观', this.uiLanguage) + ': ' +
            translate(this.themeMode === 'dark' ? '深色' : this.themeMode === 'light' ? '浅色' : '跟随系统', this.uiLanguage),
          items: THEME_OPTIONS, selected: this.themeMode, isEnabled: !this.themePreferenceBusy,
          maxWidth: this.actionWidth(), menuMaxHeight: this.menuHeight(),
          onSelect: (value: string) => { this.setThemeMode(value) }
        })
      }
      .width('100%')
    }
    .settingsCard(this.isDarkMode, this.compact())
  }

}

@CustomDialog
struct SettingsPasswordDialog {
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @State password: string = ''
  @State passwordConfirm: string = ''
  title: string = '密码'
  description: string = ''
  onSave: (password: string) => void = (_password: string) => {}
  onCancel: () => void = () => {}
  controller?: CustomDialogController
  @State errorMsg: string = ''

  private cancel(): void {
    this.password = ''
    this.passwordConfirm = ''
    this.errorMsg = ''
    this.onCancel()
  }

  private submit(): void {
    if (this.password.length < 8) {
      this.errorMsg = '备份密码至少需要 8 位'
      return
    }
    if (this.password !== this.passwordConfirm) {
      this.errorMsg = translate('Passwords do not match', this.uiLanguage)
      return
    }
    const password = this.password
    this.password = ''
    this.passwordConfirm = ''
    this.errorMsg = ''
    this.onSave(password)
  }

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
        .height(readableInputHeight(40, this.uiFontScale, 18))
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
        .height(readableInputHeight(40, this.uiFontScale, 18))
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

      Row({ space: 8 }) {
        SettingsAction({ label: translate('Cancel', this.uiLanguage), onAction: () => { this.cancel() } })
        SettingsAction({ label: translate('Save', this.uiLanguage), tone: 'primary', icon: 'check',
          onAction: () => { this.submit() } })
      }
      .width('100%').justifyContent(FlexAlign.End).padding({ top: 8 })
    }
    .padding(16)
    .width('85%')
    .constraintSize({ maxWidth: 428 })
    .backgroundColor(settingsPalette(this.isDarkMode).surface)
    .border({ width: 1, color: settingsPalette(this.isDarkMode).line })
    .borderRadius(16)
  }
}
