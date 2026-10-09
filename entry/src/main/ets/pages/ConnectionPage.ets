import { ButtonShapeModifier } from '../theme/ButtonShapeModifier'
import { common } from '@kit.AbilityKit'
import { promptAction, router } from '@kit.ArkUI'
import { fileIo, picker } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { deviceInfo } from '@kit.BasicServicesKit'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { ConnectionService } from '../service/ConnectionService'
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask'
import { ConnectionStatus } from '../model/ConnectionModel'
import { PerformanceSettings } from '../model/PerformanceSettings'
import { PeerOnlineResult, PeerOnlineState, RemoteSecurityOptions, RustDeskNapi } from '../service/RustDeskNapi'
import { CredentialStore } from '../service/CredentialStore'
import { RemoteSecurityStore } from '../service/RemoteSecurityStore'
import { CloudSyncService } from '../service/CloudSyncService'
import {
  ConnectionBackupGroup,
  ConnectionBackupItem,
  ConnectionBackupPayload,
  ConnectionBackupService
} from '../service/ConnectionBackupService'

interface SavedConnectionInfo {
  id: string
  name: string
  remoteId: string
  password: string
  performancePreset: string
  groupId: string
}

interface SavedConnectionRow {
  id: string
  name: string
  remoteId: string
  credentialAlias: string
  performancePreset: string
  groupId: string
}

interface SavedConnectionGroup {
  id: string
  name: string
  expanded: boolean
}

interface SavedConnectionGroupRow {
  id: string
  name: string
  expanded: boolean
}

interface NormalizedImportData {
  groups: SavedConnectionGroup[]
  connections: SavedConnectionInfo[]
  importedCount: number
}

const PEER_STATE_CHECKING: number = 0
const PEER_STATE_ONLINE: number = 1
const PEER_STATE_OFFLINE: number = 2
const PEER_STATE_UNKNOWN: number = 3
const PEER_STATE_REFRESH_MS: number = 30000
const PEER_STATE_QUERY_TIMEOUT_MS: number = 12000

@Component
export struct ConnectionPage {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @State connectionName: string = ''
  @State remoteId: string = ''
  @State focusedConnectionField: string = ''
  @State password: string = ''
  // Only newly typed text may enter the password TextInput. Saved secrets stay out of it.
  @State passwordEditMode: string = 'keep'
  @State lockAfterDisconnect: boolean = false
  @State privacyMode: boolean = false
  @State autoUnlock: boolean = false
  @State osPasswordDraft: string = ''
  @State hasStoredOsPassword: boolean = false
  @State clearOsPassword: boolean = false
  @State isIdEmpty: boolean = true
  @State isConnecting: boolean = false
  private preparingAccount: boolean = false
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('peerOnlineQueryEnabled') @Watch('onPeerOnlineQuerySettingChanged') peerOnlineQueryEnabled: boolean = true
  @StorageLink('serverConfigVersion') @Watch('onServerConfigVersionChanged') serverConfigVersion: number = 0
  @StorageLink('savedConnectionsCloudRevision') @Watch('onCloudConnectionsChanged')
  savedConnectionsCloudRevision: number = 0
  @State showUpdateBanner: boolean = false
  @State isUsingPublicServer: boolean = true
  @State customServerHint: string = ''
  @State connectionStatusText: string = ''
  @State connectionStatusColor: ResourceColor = Color.Transparent
  @State connectionStatusValue: number = 0
  @State performancePreset: string = 'smooth'
  @State hasOpenedRemotePage: boolean = false
  private pendingFileOnly: boolean = false
  @State pageWidth: number = 0
  @State pageFullHeight: number = 0
  @State tabletEditorVisible: boolean = false
  @State savingConnection: boolean = false
  @State saveTipVisible: boolean = false
  @State saveTipOpacity: number = 1
  @State saveTipOffsetY: number = 0
  private saveTipTimer: number = -1
  private saveTipRemoveTimer: number = -1
  private saveTipGeneration: number = 0
  private savePageActive: boolean = false
  @State savedConnections: SavedConnectionInfo[] = []
  @State selectedConnectionId: string = ''
  @State selectedGroupId: string = ''
  @State savedConnectionsVersion: number = 0
  @State peerOnlineStatesVersion: number = 0
  @State connectionGroups: SavedConnectionGroup[] = []
  @State savedConnectionsExpanded: boolean = true
  @State savedConnectionSort: string = 'id'
  @State savedConnectionSortAscending: boolean = true
  @State savedConnectionSearch: string = ''
  @State savedConnectionSearchExpanded: boolean = false
  @State connectionFormExpanded: boolean = false
  @State ungroupedExpanded: boolean = true
  @State showGroupNameDialog: boolean = false
  @State editingGroupId: string = ''
  @State groupNameDraft: string = ''
  @State groupNameError: string = ''
  @State showRenameConnectionDialog: boolean = false
  @State renamingConnectionId: string = ''
  @State connectionNameDraft: string = ''
  @State connectionNameError: string = ''
  @State assignCreatedGroupToForm: boolean = false
  @State assignCreatedGroupConnectionId: string = ''
  @State showGroupPicker: boolean = false
  @State groupPickerConnectionId: string = ''
  @State groupPickerForForm: boolean = false
  @State showBackupPasswordDialog: boolean = false
  @State showConnectionPasswordDialog: boolean = false
  @State connectionPasswordDraft: string = ''
  @State rememberConnectionPassword: boolean = false
  @State connectionPasswordError: string = ''
  @State backupPasswordMode: string = ''
  @State backupPasswordDraft: string = ''
  @State backupPasswordConfirm: string = ''
  @State backupPasswordError: string = ''
  @State backupBusy: boolean = false
  @State showImportPreviewDialog: boolean = false
  @State importReplaceExisting: boolean = false
  @State importPreviewGroupCount: number = 0
  @State importPreviewConnectionCount: number = 0
  @State importPreviewIncludesPasswords: boolean = false
  private pendingEncryptedBackup: string = ''
  private pendingImportPayload: ConnectionBackupPayload | undefined = undefined
  private statusTimer: number = -1
  @State peerOnlineStates: Record<string, number> = {}
  private peerOnlineQueryInFlight: boolean = false
  private peerOnlineQueryStartedAt: number = 0
  private nextPeerOnlineRefreshAt: number = 0
  private peerStateServer: string = ''

  aboutToAppear(): void {
    this.savePageActive = true
    this.checkServerConfig()
    this.loadConnectionFormState()
    this.loadConnectionGroups()
    this.loadSavedConnectionSort()
    this.loadSavedConnections()
    this.syncConnectionState()
    this.startStatusPolling()
  }

  aboutToDisappear(): void {
    this.savePageActive = false
    this.clearSaveTip()
    if (this.preparingAccount) {
      ConnectionService.cancelPendingConnection()
      this.preparingAccount = false
    }
    if (this.statusTimer !== -1) {
      clearTimeout(this.statusTimer)
      this.statusTimer = -1
    }
  }

  checkServerConfig(): void {
    try {
      let idServer: string = RustDeskNapi.getOption('custom-rendezvous-server').trim()
      let relayServer: string = RustDeskNapi.getOption('relay-server').trim()
      this.isUsingPublicServer = idServer.length === 0 && relayServer.length === 0
      this.customServerHint = idServer.length > 0 ? idServer : relayServer
      this.peerStateServer = idServer
    } catch (error) {
      // Server status is informational and must never prevent app startup.
      this.isUsingPublicServer = true
      this.customServerHint = ''
      this.peerStateServer = ''
    }
  }

  onServerConfigVersionChanged(): void {
    this.checkServerConfig()
    this.markAllPeerStatesUnknown()
    this.nextPeerOnlineRefreshAt = 0
    if (!this.peerOnlineQueryInFlight) {
      this.refreshSavedConnectionOnlineStates(true)
    }
  }

  onPeerOnlineQuerySettingChanged(): void {
    this.markAllPeerStatesUnknown()
    this.nextPeerOnlineRefreshAt = 0
    if (this.peerOnlineQueryEnabled && !this.peerOnlineQueryInFlight) {
      this.refreshSavedConnectionOnlineStates(true)
    }
  }

  onCloudConnectionsChanged(): void {
    this.loadConnectionGroups()
    this.loadSavedConnections()
  }

  startStatusPolling(): void {
    let poll = () => {
      this.pollPeerOnlineStates()
      if (this.peerOnlineQueryEnabled && Date.now() >= this.nextPeerOnlineRefreshAt) {
        this.refreshSavedConnectionOnlineStates()
      }
      let status: ConnectionStatus = this.syncConnectionState()
      if (status === ConnectionStatus.CONNECTED || status === ConnectionStatus.WAITING_2FA) {
        if (!this.hasOpenedRemotePage) {
          this.hasOpenedRemotePage = true
          router.pushUrl({ url: 'pages/RemotePage' })
          return
        }
      }
      this.statusTimer = setTimeout(poll, 1000)
    }
    poll()
  }

  syncConnectionState(): ConnectionStatus {
    if (this.preparingAccount) return ConnectionStatus.CONNECTING
    let status: ConnectionStatus = RustDeskNapi.getConnectionStatus() as ConnectionStatus
    RemoteSessionBackgroundTask.syncForConnectionStatus(status)
    this.connectionStatusValue = status
    if (status === ConnectionStatus.CONNECTING) {
      this.connectionStatusText = translate('Connecting...', this.uiLanguage)
      this.connectionStatusColor = RustDeskTheme.WARNING
      this.isConnecting = true
    } else if (status === ConnectionStatus.CONNECTED) {
      this.connectionStatusText = translate('Connected', this.uiLanguage)
      this.connectionStatusColor = RustDeskTheme.SUCCESS
      this.isConnecting = false
    } else if (status === ConnectionStatus.WAITING_2FA) {
      this.connectionStatusText = '需要二次验证'
      this.connectionStatusColor = RustDeskTheme.WARNING
      this.isConnecting = false
    } else if (status === ConnectionStatus.FAILED) {
      let error: string = ConnectionService.getLastConnectionError()
      this.connectionStatusText = error.length > 0 ? error : translate('Connection failed', this.uiLanguage)
      this.connectionStatusColor = RustDeskTheme.ERROR
      this.isConnecting = false
      this.hasOpenedRemotePage = false
    } else {
      this.connectionStatusText = ''
      this.connectionStatusColor = Color.Transparent
      this.isConnecting = false
      this.hasOpenedRemotePage = false
    }
    return status
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.showUpdateBanner) {
          this.buildUpdateBanner()
        }
        this.buildPageHeader()
        if (this.isWideDeviceLayout()) {
          Column({ space: 14 }) {
            this.buildWideQuickConnect()
            Scroll() {
              Column() {
                this.buildSavedConnections()
              }
              .width('100%')
              .padding({ bottom: 94 })
            }
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.Top)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .layoutWeight(1)
        } else if (this.pageWidth >= 820 && deviceInfo.deviceType !== 'tablet') {
          Row({ space: 18 }) {
            Scroll() {
              Column() {
                this.buildConnectionForm()
              }
              .width('100%')
              .padding({ bottom: 94 })
            }
            .layoutWeight(0.9)
            .height('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)

            Scroll() {
              Column() {
                this.buildSavedConnections()
              }
              .width('100%')
              .padding({ bottom: 94 })
            }
            .layoutWeight(1.3)
            .height('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(VerticalAlign.Top)
        } else {
          Scroll() {
            Column({ space: 14 }) {
              this.buildConnectionForm()
              this.buildSavedConnections()
            }
            .width('100%')
            .padding({ bottom: 94 })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: this.pageWidth >= 820 ? 32 : RustDeskTheme.PAGE_PADDING, right: this.pageWidth >= 820 ? 32 : RustDeskTheme.PAGE_PADDING })
      .alignItems(HorizontalAlign.Center)

      if (this.isWideDeviceLayout() && this.tabletEditorVisible) {
        Row() {
          Column()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#44000000')
            .onClick(() => { this.setTabletEditorVisible(false) })
          Scroll() {
            Column() {
              this.buildConnectionForm()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 20, bottom: 94 })
          }
          .width(Math.min(440, this.pageWidth * 0.48))
          .height('100%')
          .align(Alignment.Top)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .scrollBar(BarState.Auto)
        }
        .width('100%')
        .height('100%')
        .zIndex(8)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 40 }))
          .animation({ duration: 240, curve: Curve.EaseInOut }))
      }

      if (this.saveTipVisible) {
        Text(translate('已保存', this.uiLanguage))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#DCEBFF' : '#215FAE')
          .padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .backgroundColor(this.isDarkMode ? '#EE243448' : '#F2E5F0FF')
          .border({ width: 1, color: this.isDarkMode ? '#557B9BC1' : '#AAC7DFFF' })
          .borderRadius(22)
          .shadow({ radius: 12, color: '#18000000', offsetY: 3 })
          .opacity(this.saveTipOpacity)
          .translate({ y: this.saveTipOffsetY })
          .zIndex(30)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityText(translate('连接已保存', this.uiLanguage))
      }

      if (this.showRenameConnectionDialog || this.showGroupNameDialog || this.showGroupPicker || this.showConnectionPasswordDialog ||
        this.showBackupPasswordDialog || this.showImportPreviewDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeAllDialogs()
          })
          .zIndex(10)

        if (this.showRenameConnectionDialog) {
          this.buildRenameConnectionDialog()
        } else if (this.showGroupNameDialog) {
          this.buildGroupNameDialog()
        } else if (this.showGroupPicker) {
          this.buildGroupPickerDialog()
        } else if (this.showConnectionPasswordDialog) {
          this.buildConnectionPasswordDialog()
        } else if (this.showBackupPasswordDialog) {
          this.buildBackupPasswordDialog()
        } else if (this.showImportPreviewDialog) {
          this.buildImportPreviewDialog()
        }
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // IME resizing must not turn a portrait tablet into the landscape layout.
      const nextWidth: number = newValue.width as number
      const nextHeight: number = newValue.height as number
      this.pageFullHeight = Math.abs(nextWidth - this.pageWidth) > 32 ?
        nextHeight : Math.max(this.pageFullHeight, nextHeight)
      this.pageWidth = newValue.width as number
    })
  }

  isWideDeviceLayout(): boolean {
    if (this.pageWidth < 820) return false
    return deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'pc' ||
      deviceInfo.deviceType === 'desktop' ||
      (deviceInfo.deviceType === 'tablet' && this.pageWidth > this.pageFullHeight)
  }

  savedDeviceCardWidth(): string {
    if (!this.isWideDeviceLayout()) return '100%'
    return this.pageWidth >= 1440 ? '32%' : '49%'
  }

  setTabletEditorVisible(visible: boolean): void {
    if (visible) this.connectionFormExpanded = true
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => {
      this.tabletEditorVisible = visible
    })
  }

  @Builder
  buildWideQuickConnect() {
    Row({ space: 20 }) {
      Text(translate(this.selectedConnectionId.length > 0 ? '编辑连接' : '新建连接', this.uiLanguage))
        .fontSize(20)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      Column() {
        this.buildRemoteIdInput()
      }
      .layoutWeight(1)
      Button(translate('更多选项 ›', this.uiLanguage))
        .height(44)
        .fontSize(14)
        .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
        .backgroundColor(Color.Transparent)
        .onClick(() => { this.setTabletEditorVisible(true) })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
  }

  @Builder
  buildPageHeader() {
    Row() {
      Column({ space: 4 }) {
        Text('StarRustDesk')
          .fontSize(this.pageWidth >= 820 ? 34 : 30)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')
        Text(translate('轻松连接并控制你的远端设备', this.uiLanguage))
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#B7C0CF' : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row({ space: 7 }) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.isUsingPublicServer || this.customServerHint.length > 0 ? RustDeskTheme.SUCCESS : RustDeskTheme.WARNING)
        Text(translate(this.isUsingPublicServer ? '公共网络' : '自建网络', this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
      }
      .height(34)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.isDarkMode ? '#263142' : '#F7FAFF')
      .border({ width: 1, color: this.isDarkMode ? '#364256' : '#DFE7F2' })
      .borderRadius(12)
    }
    .width('100%')
    .height(this.pageWidth >= 820 ? 116 : 112)
    .padding({ top: 28, bottom: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildConnectionForm() {
    Column({ space: 10 }) {
      Row() {
        Text(translate(this.selectedConnectionId.length > 0 ? '编辑连接' : '新建连接', this.uiLanguage))
          .fontSize(20)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Button(translate(this.isWideDeviceLayout() ? '关闭 ×' :
          (this.connectionFormExpanded ? '收起选项⌃' : '更多选项›'), this.uiLanguage))
          .height(34)
          .fontSize(14)
          .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          .backgroundColor(Color.Transparent)
          .padding({ left: 8, right: 4 })
          .onClick(() => {
            if (this.isWideDeviceLayout()) {
              this.setTabletEditorVisible(false)
            } else {
              this.setConnectionFormExpanded(!this.connectionFormExpanded)
            }
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
      .width('100%')
      .height(38)

      this.buildRemoteIdInput()

      if (this.connectionFormExpanded) {
        Column({ space: 10 }) {
          this.buildConnectionNameInput()
          this.buildConnectionGroupSelector()
          this.buildPasswordInput()
          this.buildRemoteSecurityOptions()
          this.buildPerformancePresetSelector()
          this.buildConnectionEditActions()
          if (this.connectionStatusText.length > 0) {
            this.buildConnectionStatus()
          }
          if (!this.isUsingPublicServer && this.customServerHint.length > 0) {
            this.buildCustomServerIndicator()
          }
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -8 }))
          .animation({ duration: 220, curve: Curve.EaseInOut }))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .margin({ bottom: 4 })
  }

  @Builder
  buildUpdateBanner() {
    Row() {
      Text(translate('Download new version', this.uiLanguage))
        .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
        .fontColor(Color.White)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FF4081')
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      router.pushUrl({ url: 'pages/SettingsPage' })
    })
  }

  @Builder
  buildConnectionStatus() {
    Row() {
      Circle()
        .width(8)
        .height(8)
        .fill(this.connectionStatusColor)
      Text(translate(this.connectionStatusText, this.uiLanguage))
        .fontSize(14)
        .fontColor(this.connectionStatusColor)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .margin({ left: 6 })

      if (this.connectionStatusValue === ConnectionStatus.FAILED) {
        Button(translate('Retry', this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          .backgroundColor(Color.Transparent)
          .margin({ left: 12 })
          .onClick(() => {
            this.onConnect()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }

      if (this.connectionStatusValue === ConnectionStatus.CONNECTED) {
        Button(translate('Disconnect', this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .backgroundColor(Color.Transparent)
          .margin({ left: 12 })
          .onClick(() => {
            ConnectionService.disconnect()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
    }
    .width('100%')
    .height(38)
    .padding({ left: 12, right: 8 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
    .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
  }

  @Builder
  buildRemoteIdInput() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.End }) {
          TextInput({ placeholder: translate('远端 ID / IP', this.uiLanguage), text: this.remoteId })
            .type(InputType.Normal)
            .fontSize(20)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.ID_COLOR)
            .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
            .height(50)
            .padding({ left: 12, right: 44 })
            .backgroundColor(Color.Transparent)
            .onFocus(() => { this.focusedConnectionField = 'id' })
            .onBlur(() => { this.focusedConnectionField = '' })
            .onChange((value: string) => {
              let normalized: string = this.normalizeRemoteId(value)
              this.remoteId = normalized
              this.isIdEmpty = normalized.length === 0
            })

          if (!this.isIdEmpty) {
            Button({ type: ButtonType.Circle }) {
              Text('✕')
                .fontSize(14)
                .fontColor(Color.White)
            }
            .width(24)
            .height(24)
            .margin({ right: 10 })
            .backgroundColor(RustDeskTheme.DARK_GRAY)
            .onClick(() => {
              this.remoteId = ''
              this.isIdEmpty = true
            })
            .transition(TransitionEffect.OPACITY)
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Circle))
          }
        }
        .layoutWeight(1)
        .height(50)

        Button() {
          Image($r('app.media.connect_arrow'))
            .width(26)
            .height(26)
            .objectFit(ImageFit.Contain)
        }
        .width(50)
        .height(50)
        .padding(0)
        .borderRadius(12)
        .backgroundColor(RustDeskTheme.ACCENT)
        .onClick(() => {
          this.onConnect()
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
      .padding({ left: 14, right: 6 })
      .height(62)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
      .border({ width: 1, color: this.connectionInputBorder('id') })
      .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      .alignItems(VerticalAlign.Center)
      .shadow({
        radius: 8,
        color: this.isDarkMode ? '#00000030' : '#10345A84',
        offsetX: 0,
        offsetY: 2
      })
    }
    .width('100%')
  }

  @Builder
  buildConnectionNameInput() {
    TextInput({ placeholder: translate('连接名称（可选）', this.uiLanguage), text: this.connectionName })
      .type(InputType.Normal)
      .fontSize(RustDeskTheme.FONT_SIZE_BODY)
      .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
      .border({ width: 1, color: this.connectionInputBorder('name') })
      .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      .onFocus(() => { this.focusedConnectionField = 'name' })
      .onBlur(() => { this.focusedConnectionField = '' })
      .onChange((value: string) => {
        this.connectionName = value
      })
  }

  @Builder
  buildConnectionGroupSelector() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(translate('保存到分组', this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        Text(this.selectedGroupId.length === 0 ? translate('未分组', this.uiLanguage) : this.groupNameForId(this.selectedGroupId))
          .fontSize(14)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(translate('选择', this.uiLanguage))
        .height(32)
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
        .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
        .onClick(() => {
          this.openGroupPickerForForm()
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))

      Button(translate('+ 分组', this.uiLanguage))
        .height(32)
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor(RustDeskTheme.ACCENT)
        .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
        .onClick(() => {
          this.openNewGroupDialog(true)
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 8 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildPasswordInput() {
    Column({ space: 8 }) {
      if (this.passwordEditMode === 'keep' && this.hasSavedConnectionPassword()) {
        Row({ space: 8 }) {
          Text(translate('密码已保存', this.uiLanguage))
            .fontSize(16)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
            .layoutWeight(1)
          Button(translate('更换', this.uiLanguage))
            .fontSize(14)
            .height(36)
            .backgroundColor(this.selectedControlBackground())
            .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
            .onClick(() => { this.startPasswordReplacement() })
          Button(translate('清除', this.uiLanguage))
            .fontSize(14)
            .height(36)
            .backgroundColor(Color.Transparent)
            .fontColor(RustDeskTheme.ERROR)
            .onClick(() => { this.clearSavedPassword() })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 6, bottom: 6 })
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .border({ width: 1, color: this.connectionInputBorder('password') })
        .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      } else if (this.passwordEditMode === 'clear') {
        Row({ space: 8 }) {
          Text(translate('密码待清除，保存后生效', this.uiLanguage))
            .fontSize(14)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .layoutWeight(1)
          Button(translate('撤销', this.uiLanguage))
            .fontSize(14)
            .height(36)
            .backgroundColor(this.selectedControlBackground())
            .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
            .onClick(() => { this.cancelPasswordChange() })
        }
        .width('100%')
      } else {
        TextInput({ placeholder: translate(this.hasSavedConnectionPassword() ? '输入新密码' : 'Password', this.uiLanguage), text: this.password })
      .type(InputType.Password)
      .showPasswordIcon(true)
      .fontSize(RustDeskTheme.FONT_SIZE_BODY)
      .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
      .border({ width: 1, color: this.connectionInputBorder('password') })
      .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      .onFocus(() => { this.focusedConnectionField = 'password' })
      .onBlur(() => { this.focusedConnectionField = '' })
      .onChange((value: string) => {
        this.password = value
        this.passwordEditMode = 'replace'
      })
        if (this.passwordEditMode === 'replace' && this.hasSavedConnectionPassword()) {
          Button(translate('取消更换，保留已保存密码', this.uiLanguage))
            .fontSize(13)
            .height(32)
            .backgroundColor(Color.Transparent)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .onClick(() => { this.cancelPasswordChange() })
        }
      }
    }
    .width('100%')
  }

  @Builder
  buildSavedConnections() {
    Column({ space: 8 }) {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      Row() {
        Button() {
          Image(this.savedConnectionsExpanded ?
            $r('app.media.group_chevron_up') : $r('app.media.group_chevron_down'))
            .width(12)
            .height(12)
            .objectFit(ImageFit.Contain)
        }
          .width(42)
          .height(42)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(21)
          .padding(0)
          .onClick(() => {
            this.toggleSavedConnectionsExpanded()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 21, ButtonType.Capsule))
        Text(translate('已保存连接', this.uiLanguage))
          .fontSize(20)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .maxLines(1)
          .margin({ left: 8 })
        Text(translate(`${this.savedConnections.length}`, this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(9)
          .margin({ left: 8 })
        Blank()
      }
      .width(this.isWideDeviceLayout() ? '35%' : '100%')
      .flexShrink(0)
      .height(Math.ceil(46 + Math.max(0, this.uiFontScale - 1) * 18))

      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        if (this.savedConnectionSearchExpanded) {
          Search({ value: this.savedConnectionSearch, placeholder: translate('搜索名称或远端 ID', this.uiLanguage) })
            .layoutWeight(1)
            .height(this.savedToolbarButtonHeight())
            .textFont({ size: 12 })
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
            .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
            .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
            .margin({ right: 8 })
            .transition(TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ x: -8 }))
              .animation({ duration: 200, curve: Curve.EaseInOut }))
            .onChange((value: string) => {
              this.savedConnectionSearch = value
            })
        } else {
          Button(translate(`排序：${this.savedConnectionSort === 'name' ? '名称' :
            this.savedConnectionSort === 'online' ? '在线' : 'ID'}`, this.uiLanguage))
            .height(this.savedToolbarButtonHeight())
            .fontSize(12)
            .labelStyle({ maxLines: 2, minFontSize: 10, maxFontSize: 12,
              heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST })
            .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.TEXT_SECONDARY)
            .backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 2 })
            .bindMenu([
              { value: translate(`${this.savedConnectionSort === 'id' ? '✓ ' : ''}远端 ID`, this.uiLanguage),
                action: () => { this.setSavedConnectionSort('id') } },
              { value: translate(`${this.savedConnectionSort === 'name' ? '✓ ' : ''}设备名称`, this.uiLanguage),
                action: () => { this.setSavedConnectionSort('name') } },
              { value: translate(`${this.savedConnectionSort === 'online' ? '✓ ' : ''}在线优先`, this.uiLanguage),
                action: () => { this.setSavedConnectionSort('online') } }
            ], { placement: Placement.BottomLeft, enableArrow: true })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
          Button() {
            Text(translate(this.savedConnectionSortAscending ? '▲' : '▼', this.uiLanguage))
              .fontSize(10)
              .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.TEXT_SECONDARY)
          }
            .width(28)
            .height(this.savedToolbarButtonHeight())
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.toggleSavedConnectionSortDirection()
            })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
          if (this.uiFontScale <= 1.3) {
            Blank()
          }
        }
        Button(translate('备份', this.uiLanguage))
          .width(this.savedToolbarButtonWidth(48))
          .height(this.savedToolbarButtonHeight())
          .fontSize(12)
          .labelStyle({ maxLines: 2, minFontSize: 10, maxFontSize: 12,
            heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST })
          .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .padding(0)
          .margin({ left: 8 })
          .bindMenu([
            {
              value: translate('普通导出（不含密码）', this.uiLanguage),
              action: () => {
                this.exportPlainBackup()
              }
            },
            {
              value: translate('加密导出（包含密码）', this.uiLanguage),
              action: () => {
                this.openEncryptedExportDialog()
              }
            },
            {
              value: translate('导入备份', this.uiLanguage),
              action: () => {
                this.selectBackupForImport()
              }
            }
          ], {
            placement: Placement.BottomRight,
            enableArrow: true
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate('+ 分组', this.uiLanguage))
          .width(this.savedToolbarButtonWidth(56))
          .height(this.savedToolbarButtonHeight())
          .fontSize(12)
          .labelStyle({ maxLines: 2, minFontSize: 10, maxFontSize: 12,
            heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST })
          .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .padding(0)
          .margin({ left: 8 })
          .onClick(() => {
            this.openNewGroupDialog()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate(this.savedConnectionSearchExpanded ? '收起' : '搜索', this.uiLanguage))
          .width(this.savedToolbarButtonWidth(48))
          .height(this.savedToolbarButtonHeight())
          .fontSize(12)
          .labelStyle({ maxLines: 2, minFontSize: 10, maxFontSize: 12,
            heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST })
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .padding(0)
          .margin({ left: 8 })
          .enabled(this.savedConnections.length > 0 || this.savedConnectionSearchExpanded)
          .opacity(this.savedConnections.length > 0 || this.savedConnectionSearchExpanded ? 1 : 0.45)
          .onClick(() => {
            if (this.savedConnectionSearchExpanded) {
              this.savedConnectionSearch = ''
            }
            this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
              this.savedConnectionSearchExpanded = !this.savedConnectionSearchExpanded
            })
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width(this.isWideDeviceLayout() ? '65%' : '100%')
      .flexShrink(0)
      .margin({ bottom: 2 })
      }
      .width('100%')

      if (this.savedConnectionsExpanded) {
        Column({ space: 8 }) {
          if (this.savedConnections.length === 0 && this.connectionGroups.length === 0) {
            Column({ space: 8 }) {
              Text(translate('暂无保存的连接', this.uiLanguage))
                .fontSize(15)
                .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_PRIMARY)
              Text(translate('可先创建分组，再保存连接', this.uiLanguage))
                .fontSize(12)
                .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            }
            .width('100%')
            .height(112)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
            .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          } else if (this.filteredSavedConnectionCount() === 0) {
            Column({ space: 6 }) {
              Text(translate('未找到匹配的设备', this.uiLanguage))
                .fontSize(15)
                .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_PRIMARY)
              Text(translate('可按设备名称或远端 ID 搜索', this.uiLanguage))
                .fontSize(12)
                .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            }
            .width('100%')
            .height(88)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
            .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          } else {
            if (this.connectionsForGroup('').length > 0) {
              this.buildSavedConnectionGroup('', '未分组', this.ungroupedExpanded, false)
            }

            ForEach(this.connectionGroups, (group: SavedConnectionGroup) => {
              if (this.shouldShowSavedConnectionGroup(group.id)) {
                this.buildSavedConnectionGroup(group.id, group.name, group.expanded, true)
              }
            }, (group: SavedConnectionGroup) =>
              `${group.id}-${this.savedConnectionsVersion}-${this.savedConnectionSearch}`)
          }
          if (this.peerOnlineQueryEnabled && this.savedConnections.length > 0 &&
            this.filteredSavedConnectionCount() > 0) {
            this.buildConnectionStatusLegend()
          }
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -8 }))
          .animation({ duration: 240, curve: Curve.EaseInOut }))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(RustDeskTheme.HOME_CARD_RADIUS)
    .shadow({ radius: 18, color: this.isDarkMode ? RustDeskTheme.HOME_SHADOW_DARK : RustDeskTheme.HOME_SHADOW, offsetX: 0, offsetY: 5 })
    .margin({ bottom: 8 })
  }

  @Builder
  buildRemoteSecurityOptions() {
    Column({ space: 8 }) {
      Text(translate('远端安全选项（仅对此设备生效）', this.uiLanguage))
        .fontSize(15)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      Row() {
        Text(translate('断开连接后锁定远端', this.uiLanguage))
          .fontSize(14)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.lockAfterDisconnect })
          .onChange((value: boolean) => {
            this.lockAfterDisconnect = value
            if (!value) this.autoUnlock = false
          })
      }.width('100%')
      Row() {
        Text(translate('隐私屏幕（需被控端支持并允许）', this.uiLanguage))
          .fontSize(14)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.privacyMode })
          .onChange((value: boolean) => { this.privacyMode = value })
      }.width('100%')
      Row() {
        Text(translate('自动解锁远端系统（需开启断开锁屏）', this.uiLanguage))
          .fontSize(14)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoUnlock })
          .enabled(this.lockAfterDisconnect)
          .onChange((value: boolean) => { this.autoUnlock = value })
      }.width('100%')
      if (this.autoUnlock) {
        Text(translate('仅在端到端加密连接中发送系统密码；密码与连接密码不同。若远端已解锁，可能输入到当前窗口。', this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        TextInput({ placeholder: translate(this.hasStoredOsPassword && !this.clearOsPassword ?
          '系统密码已安全保存；输入可更换' : '输入远端系统密码', this.uiLanguage), text: this.osPasswordDraft })
          .type(InputType.Password)
          .maxLength(240)
          .showPasswordIcon(false)
          .width('100%')
          .height(44)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .onChange((value: string) => { this.osPasswordDraft = value })
        if (this.hasStoredOsPassword && !this.clearOsPassword) {
          Button(translate('清除已保存的系统密码', this.uiLanguage))
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor(RustDeskTheme.ERROR)
            .onClick(() => {
              this.clearOsPassword = true
              this.hasStoredOsPassword = false
              this.osPasswordDraft = ''
            })
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
    .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
  }

  @Builder
  buildConnectionStatusLegend() {
    Row({ space: 14 }) {
      Row({ space: 5 }) {
        Circle().width(8).height(8).fill(RustDeskTheme.SUCCESS)
        Text(translate('在线', this.uiLanguage))
          .fontSize(11)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      }
      Row({ space: 5 }) {
        Circle().width(8).height(8).fill(this.isDarkMode ? '#697386' : '#A5ADBA')
        Text(translate('离线', this.uiLanguage))
          .fontSize(11)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      }
      Row({ space: 5 }) {
        Circle().width(8).height(8).fill(RustDeskTheme.WARNING)
        Text(translate('待确认', this.uiLanguage))
          .fontSize(11)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      }
    }
    .width('100%')
    .height(28)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  buildGroupFolderIcon() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width(10)
        .height(6)
        .border({ width: 2, color: this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.ACCENT })
        .borderRadius(2)
        .position({ x: 2, y: 1 })
      Row()
        .width(24)
        .height(16)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .border({ width: 2, color: this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.ACCENT })
        .borderRadius(3)
        .position({ x: 0, y: 5 })
    }
    .width(24)
    .height(22)
  }

  @Builder
  buildSavedConnectionGroup(groupId: string, groupName: string, expanded: boolean, canRename: boolean) {
    Column() {
      Row({ space: 6 }) {
        this.buildGroupFolderIcon()
        Text(groupId.length === 0 ? translate('未分组', this.uiLanguage) : groupName)
          .fontSize(14)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(translate(`${this.connectionsForGroup(groupId).length}`, this.uiLanguage))
          .fontSize(11)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.isDarkMode ? '#29364A' : '#E7EEF9')
          .borderRadius(8)
        Blank()
        if (canRename) {
          Button('⋯')
            .width(34)
            .height(28)
            .fontSize(14)
            .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
            .backgroundColor(Color.Transparent)
            .padding(0)
            .bindMenu([{ value: translate('重命名分组', this.uiLanguage), action: () => { this.openRenameGroupDialog(groupId) } }],
              { placement: Placement.BottomRight, enableArrow: true })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
        }
        Button() {
          Image((groupId.length <= 0 ? this.ungroupedExpanded : expanded) ?
            $r('app.media.group_chevron_up') : $r('app.media.group_chevron_down'))
            .width(11)
            .height(11)
            .objectFit(ImageFit.Contain)
        }
          .width(32)
          .height(30)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .onClick(() => {
            this.toggleConnectionGroup(groupId)
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
      .width('100%')
      .height(38)
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)

      if (groupId.length <= 0 ? this.ungroupedExpanded : expanded) {
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.connectionsForGroup(groupId), (item: SavedConnectionInfo) => {
            Row({ space: 8 }) {
            Stack() {
              Column() {
                Text(item.name.length > 0 ? item.name.substring(0, 1).toUpperCase() : 'R')
                  .fontSize(15)
                  .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
                  .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
              }
              .width(36)
              .height(36)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor(this.isDarkMode ? '#26364E' : RustDeskTheme.ACCENT_SOFT)
              .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)

              if (this.peerOnlineQueryEnabled) {
                Row()
                  .width(10)
                  .height(10)
                  .backgroundColor(this.peerOnlineStateColor(item.remoteId))
                  .border({ width: 2, color: this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE })
                  .borderRadius(5)
                  .position({ x: 27, y: 27 })
              }
            }
            .width(38)
            .height(38)

            Column({ space: 3 }) {
              Text(item.name.length > 0 ? item.name : item.remoteId)
                .fontSize(14)
                .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
                .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
                .width('100%')
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .maxLines(1)
              Text(item.remoteId)
                .fontSize(12)
                .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)

            Button(translate('连接', this.uiLanguage))
              .width(68)
              .height(32)
              .fontSize(12)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
              .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
              .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
              .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
              .onClick(() => {
                this.connectSavedConnection(item)
              })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))

            Button('⋯')
              .width(42)
              .height(32)
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
              .backgroundColor(Color.Transparent)
              .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
              .padding(0)
              .bindMenu([
                { value: translate('文件传输（不打开画面）', this.uiLanguage), action: () => {
                  this.applySavedConnection(item)
                  this.onConnect(true)
                } },
                {
                  value: translate('移动到分组', this.uiLanguage),
                  action: () => {
                    this.openGroupPickerForConnection(item.id)
                  }
                },
                {
                  value: translate('重命名', this.uiLanguage),
                  action: () => {
                    this.openRenameConnectionDialog(item.id)
                  }
                },
                {
                  value: translate('修改连接', this.uiLanguage),
                  action: () => {
                    this.editSavedConnection(item)
                  }
                },
                {
                  value: translate('删除连接', this.uiLanguage),
                  action: () => {
                    this.deleteSavedConnection(item.id)
                  }
                }
              ], {
                placement: Placement.BottomRight,
                enableArrow: true
              })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
            }
            .width(this.savedDeviceCardWidth())
            .height(this.isWideDeviceLayout() ? 64 : 58)
            .padding({ left: 8, right: 4 })
            .border({ width: { bottom: 1 }, color: this.isDarkMode ? '#303B4D' : RustDeskTheme.DIVIDER })
          }, (item: SavedConnectionInfo) =>
            `${item.id}-${this.savedConnectionsVersion}-${this.peerOnlineStatesVersion}`)
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: -6 }))
          .animation({ duration: 210, curve: Curve.EaseInOut }))
      }
    }
    .width('100%')
    .margin({ top: 4 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(12)
  }

  @Builder
  buildRenameConnectionDialog() {
    Column({ space: 14 }) {
      Text(translate('重命名连接', this.uiLanguage))
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      TextInput({ placeholder: translate('输入连接名称', this.uiLanguage), text: this.connectionNameDraft })
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .border({ width: 1, color: this.connectionNameError.length > 0 ? RustDeskTheme.ERROR :
          (this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER) })
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.connectionNameDraft = value
          this.connectionNameError = ''
        })

      if (this.connectionNameError.length > 0) {
        Text(translate(this.connectionNameError, this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button(translate('取消', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => { this.closeRenameConnectionDialog() })
          .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate('保存名称', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => { this.saveConnectionName() })
          .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 420 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildGroupNameDialog() {
    Column({ space: 14 }) {
      Text(translate(this.editingGroupId.length > 0 ? '重命名分组' : '新建分组', this.uiLanguage))
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      TextInput({ placeholder: translate('输入分组名称', this.uiLanguage), text: this.groupNameDraft })
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .border({ width: 1, color: this.groupNameError.length > 0 ? RustDeskTheme.ERROR : (this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER) })
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.groupNameDraft = value
          this.groupNameError = ''
        })

      if (this.groupNameError.length > 0) {
        Text(translate(this.groupNameError, this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button(translate('取消', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.closeGroupDialogs()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate(this.editingGroupId.length > 0 ? '保存名称' : '创建', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.saveGroupName()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 420 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildGroupPickerDialog() {
    Column({ space: 12 }) {
      Row() {
        Text(translate(this.groupPickerForForm ? '选择保存分组' : '移动连接到分组', this.uiLanguage))
          .fontSize(19)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Button(translate('关闭', this.uiLanguage))
          .height(30)
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.closeGroupDialogs()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }
      .width('100%')

      Scroll() {
        Column({ space: 7 }) {
          this.buildGroupPickerOption('', '未分组')
          ForEach(this.connectionGroups, (group: SavedConnectionGroup) => {
            this.buildGroupPickerOption(group.id, group.name)
          }, (group: SavedConnectionGroup) => group.id)
        }
        .width('100%')
      }
      .width('100%')
      .height(Math.min(320, 58 + this.connectionGroups.length * 48))

      Button(translate('+ 新建分组', this.uiLanguage))
        .width('100%')
        .height(40)
        .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.ACCENT_SOFT)
        .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
        .onClick(() => {
          this.openNewGroupDialog(this.groupPickerForForm, this.groupPickerForForm ? '' : this.groupPickerConnectionId)
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
    }
    .width(this.pageWidth >= 820 ? 420 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildConnectionPasswordDialog() {
    Column({ space: 12 }) {
      Text(translate('输入连接密码', this.uiLanguage))
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(translate(`请输入远端设备 ${this.remoteId} 的连接密码`, this.uiLanguage))
        .fontSize(13)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      TextInput({ placeholder: translate('连接密码', this.uiLanguage), text: this.connectionPasswordDraft })
        .type(InputType.Password)
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .border({ width: 1, color: this.connectionPasswordError.length > 0 ? RustDeskTheme.ERROR :
          (this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER) })
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.connectionPasswordDraft = value
          this.connectionPasswordError = ''
        })
        .onSubmit(() => {
          this.confirmConnectionPassword()
        })

      Row({ space: 10 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.rememberConnectionPassword })
          .selectedColor(RustDeskTheme.ACCENT)
          .onChange((isOn: boolean) => {
            this.rememberConnectionPassword = isOn
          })
        Column({ space: 2 }) {
          Text(translate(this.selectedConnectionId.length > 0 ? '保存密码到此连接' : '保存密码并保存此连接', this.uiLanguage))
            .fontSize(14)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text(translate('密码将写入系统安全凭据库', this.uiLanguage))
            .fontSize(11)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.connectionPasswordError.length > 0) {
        Text(translate(this.connectionPasswordError, this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button(translate('取消', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.closeConnectionPasswordDialog()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate('连接', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.confirmConnectionPassword()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 420 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildBackupPasswordDialog() {
    Column({ space: 12 }) {
      Text(translate(this.backupPasswordMode === 'export' ? '设置备份密码' : '输入备份密码', this.uiLanguage))
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(translate(this.backupPasswordMode === 'export' ?
        '连接密码将被加密写入备份。备份密码不会保存在应用中，忘记后无法恢复。' :
        '请输入创建该加密备份时设置的密码。', this.uiLanguage))
        .fontSize(13)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      TextInput({ placeholder: translate('至少 8 位备份密码', this.uiLanguage), text: this.backupPasswordDraft })
        .type(InputType.Password)
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .border({ width: 1, color: this.backupPasswordError.length > 0 ? RustDeskTheme.ERROR : (this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER) })
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.backupPasswordDraft = value
          this.backupPasswordError = ''
        })

      if (this.backupPasswordMode === 'export') {
        TextInput({ placeholder: translate('再次输入备份密码', this.uiLanguage), text: this.backupPasswordConfirm })
          .type(InputType.Password)
          .width('100%')
          .height(46)
          .fontSize(15)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .border({ width: 1, color: this.backupPasswordError.length > 0 ? RustDeskTheme.ERROR : (this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER) })
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.backupPasswordConfirm = value
            this.backupPasswordError = ''
          })
      }

      if (this.backupPasswordError.length > 0) {
        Text(translate(this.backupPasswordError, this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button(translate('取消', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.closeBackupDialogs()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate(this.backupBusy ? '处理中…' : (this.backupPasswordMode === 'export' ? '加密并导出' : '解密'), this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(this.backupBusy ? RustDeskTheme.DARK_GRAY : RustDeskTheme.ACCENT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.confirmBackupPassword()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 440 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildImportPreviewDialog() {
    Column({ space: 12 }) {
      Text(translate('确认导入连接', this.uiLanguage))
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(translate(`备份包含 ${this.importPreviewGroupCount} 个分组、${this.importPreviewConnectionCount} 个连接`, this.uiLanguage))
        .fontSize(14)
        .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(translate(this.importPreviewIncludesPasswords ?
        '这是加密备份，连接密码将恢复到系统安全凭据库。' :
        '普通备份不包含密码；新增连接需要重新填写密码。', this.uiLanguage))
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      Row({ space: 4 }) {
        Button(translate('合并导入', this.uiLanguage))
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontColor(!this.importReplaceExisting ? this.selectedControlText() :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
          .backgroundColor(!this.importReplaceExisting ? this.selectedControlBackground() : Color.Transparent)
          .borderRadius(5)
          .onClick(() => {
            this.importReplaceExisting = false
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 5, ButtonType.Capsule))
        Button(translate('覆盖现有', this.uiLanguage))
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontColor(this.importReplaceExisting ? this.selectedControlText() :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
          .backgroundColor(this.importReplaceExisting ? this.selectedControlBackground() : Color.Transparent)
          .borderRadius(5)
          .onClick(() => {
            this.importReplaceExisting = true
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 5, ButtonType.Capsule))
      }
      .width('100%')
      .padding(3)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
      .borderRadius(12)

      if (this.importReplaceExisting) {
        Text(translate('覆盖后，当前已保存的连接、分组和连接密码将被替换。', this.uiLanguage))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      } else {
        Text(translate('相同远程 ID 会更新名称、分组和连接模式，并优先保留本机已有密码。', this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button(translate('取消', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.closeBackupDialogs()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
        Button(translate(this.backupBusy ? '导入中…' : '开始导入', this.uiLanguage))
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(this.backupBusy ? RustDeskTheme.DARK_GRAY : RustDeskTheme.ACCENT)
          .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
          .onClick(() => {
            this.importPreparedBackup()
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 440 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildGroupPickerOption(groupId: string, groupName: string) {
    Button() {
      Row() {
        Text(groupId.length === 0 ? translate('未分组', this.uiLanguage) : groupName)
          .fontSize(14)
          .fontColor(this.groupPickerCurrentGroupId() === groupId ? this.selectedControlText() : (this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text(translate(this.groupPickerCurrentGroupId() === groupId ? '✓' : '', this.uiLanguage))
          .fontSize(16)
          .fontColor(this.selectedControlText())
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height(42)
    .backgroundColor(this.groupPickerCurrentGroupId() === groupId ? this.selectedControlBackground() : (this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE))
    .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
    .onClick(() => {
      this.selectGroupFromPicker(groupId)
    })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
  }

  @Builder
  buildConnectionEditActions() {
    Row({ space: 10 }) {
      Button(translate(this.selectedConnectionId.length > 0 ? '保存修改' : '保存连接', this.uiLanguage))
        .enabled(!this.savingConnection && this.remoteId.trim().length > 0)
        .height(this.connectionEditButtonHeight())
        .layoutWeight(1)
        .fontSize(14)
        .labelStyle({ maxLines: 2, minFontSize: 11, maxFontSize: 14,
          heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST })
        .fontColor(Color.White)
        .backgroundColor(this.remoteId.trim().length > 0 ? RustDeskTheme.ACCENT : RustDeskTheme.DARK_GRAY)
        .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
        .onClick(() => {
          this.saveConnectionWithTip()
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))

      Button(translate('新建', this.uiLanguage))
        .height(this.connectionEditButtonHeight())
        .fontSize(14)
        .labelStyle({ maxLines: 2, minFontSize: 11, maxFontSize: 14,
          heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST })
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
        .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
        .onClick(() => {
          this.clearConnectionForm()
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
    }
    .width('100%')
  }

  @Builder
  buildCustomServerIndicator() {
    Row() {
      Circle()
        .width(6)
        .height(6)
        .fill(RustDeskTheme.SUCCESS)
      Text(translate('Custom Server', this.uiLanguage) + ': ' + this.customServerHint)
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .margin({ left: 6 })
    }
    .width('100%')
    .padding({ left: 4, top: 4, bottom: 4 })
  }

  @Builder
  buildPerformancePresetSelector() {
    Column({ space: 8 }) {
      Text(translate('连接模式', this.uiLanguage))
        .fontSize(13)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      Row({ space: 3 }) {
        this.buildPresetButton('稳定', 'stable')
        this.buildPresetButton('高帧率', 'high_fps')
        this.buildPresetButton('高流畅', 'smooth')
        this.buildPresetButton('高丝滑', 'silky')
      }
      .width('100%')
      .padding(3)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
      .borderRadius(12)
      Row({ space: 3 }) {
        this.buildPresetButton('高清优先', 'best')
        this.buildPresetButton('自定义', 'custom')
      }
      .width('100%')
      .padding(3)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
      .borderRadius(12)

      if (PerformanceSettings.isCustom(this.performancePreset)) {
        Text(translate(`码率比例：${PerformanceSettings.bitrate(this.performancePreset)}%`, this.uiLanguage))
          .fontSize(13)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')
        Slider({ value: PerformanceSettings.bitrate(this.performancePreset), min: 10, max: 2000, step: 10 })
          .width('100%')
          .onChange((value: number) => {
            this.performancePreset = PerformanceSettings.custom(value, PerformanceSettings.fps(this.performancePreset))
          })
        Text(translate(`目标帧率：${PerformanceSettings.fps(this.performancePreset)} FPS`, this.uiLanguage))
          .fontSize(13)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')
        Slider({ value: PerformanceSettings.fps(this.performancePreset), min: 5, max: 120, step: 1 })
          .width('100%')
          .onChange((value: number) => {
            this.performancePreset = PerformanceSettings.custom(PerformanceSettings.bitrate(this.performancePreset), value)
          })
        Text(translate('高码率会增加流量、耗电和延迟风险，百分比不等于固定 Mbps。公共中继下超过 100% 将按官方规则回退至 50%，帧率最高 30 FPS；自建服务器或直连可用更高设置。保存后下次连接生效。', this.uiLanguage))
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
      }
    }
    .width('100%')
  }

  savedToolbarButtonWidth(baseWidth: number): number {
    return Math.ceil(baseWidth + Math.max(0, this.uiFontScale - 1) * baseWidth * 0.55)
  }

  savedToolbarButtonHeight(): number {
    return Math.ceil(30 + Math.max(0, this.uiFontScale - 1) * 15)
  }

  connectionEditButtonHeight(): number {
    return Math.ceil(40 + Math.max(0, this.uiFontScale - 1) * 18)
  }

  @Builder
  buildPresetButton(label: string, preset: string) {
    Button(translate(label, this.uiLanguage))
      .height(36)
      .layoutWeight(1)
      .fontSize(12)
      .fontColor(this.isPerformancePresetSelected(preset) ? this.selectedControlText() :
        (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
      .backgroundColor(this.isPerformancePresetSelected(preset) ? this.selectedControlBackground() : Color.Transparent)
      .border({ width: 1, color: this.isPerformancePresetSelected(preset) ?
        (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER) : Color.Transparent })
      .borderRadius(RustDeskTheme.HOME_CONTROL_RADIUS)
      .onClick(() => {
        this.performancePreset = preset === 'custom' ? PerformanceSettings.custom(
          PerformanceSettings.bitrate(this.performancePreset), PerformanceSettings.fps(this.performancePreset)) : preset
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, RustDeskTheme.HOME_CONTROL_RADIUS, ButtonType.Capsule))
  }

  private isPerformancePresetSelected(preset: string): boolean {
    return preset === 'custom' ? PerformanceSettings.isCustom(this.performancePreset) : this.performancePreset === preset
  }

  private selectedControlText(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT
  }

  private connectionInputBorder(field: string): ResourceColor {
    if (this.focusedConnectionField === field) {
      return this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER
    }
    return this.isDarkMode ? RustDeskTheme.HOME_BORDER_DARK : RustDeskTheme.HOME_BORDER
  }

  private selectedControlBackground(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG
  }

  async onConnect(fileOnly: boolean = false): Promise<void> {
    if (this.preparingAccount) return
    let peerId: string = this.normalizeRemoteId(this.remoteId)
    this.remoteId = peerId
    this.isIdEmpty = peerId.length === 0
    let nativeStatus: ConnectionStatus = this.syncConnectionState()
    if (nativeStatus === ConnectionStatus.CONNECTED || nativeStatus === ConnectionStatus.WAITING_2FA) {
      // A user-triggered connect action means this page is currently visible.
      // Reopen an existing session instead of silently ignoring the tap when a
      // previous page transition left hasOpenedRemotePage set.
      this.hasOpenedRemotePage = true
      router.pushUrl({ url: 'pages/RemotePage' })
      return
    }
    if (peerId.length <= 0) {
      this.connectionStatusText = '请输入远程 ID'
      this.connectionStatusColor = RustDeskTheme.ERROR
      return
    }
    let password: string = this.connectionPasswordForUse()
    if (password.length <= 0) {
      this.pendingFileOnly = fileOnly
      this.openConnectionPasswordDialog()
      return
    }
    if (peerId.length > 0 && !this.isConnecting) {
      this.isConnecting = true
      this.connectionStatusText = translate('Connecting...', this.uiLanguage)
      this.connectionStatusColor = RustDeskTheme.WARNING
      AppStorage.setOrCreate<string>('connectedPeerId', peerId)
      this.preparingAccount = true
      let status: ConnectionStatus
      try {
        const selectedMatchesPeer: boolean = this.savedConnections.some((item: SavedConnectionInfo) =>
          item.id === this.selectedConnectionId && this.normalizeRemoteId(item.remoteId) === peerId)
        if (this.autoUnlock && selectedMatchesPeer && this.osPasswordDraft.length === 0 &&
          !RemoteSecurityStore.isCurrentServer(this.selectedConnectionId)) {
          RustDeskNapi.appendDiagnosticLog('remote-security', 'auto_unlock_skipped server_configuration_changed')
        }
        const security: RemoteSecurityOptions = {
          lockAfterDisconnect: this.lockAfterDisconnect,
          privacyMode: this.privacyMode,
          autoUnlock: this.autoUnlock && this.lockAfterDisconnect && selectedMatchesPeer &&
            (this.osPasswordDraft.length > 0 || RemoteSecurityStore.isCurrentServer(this.selectedConnectionId))
        }
        const osPassword: string = security.autoUnlock ?
          (this.osPasswordDraft.length > 0 ? this.osPasswordDraft :
            (this.clearOsPassword ? '' : await RemoteSecurityStore.loadOsPassword(this.selectedConnectionId))) : ''
        status = await ConnectionService.connect(peerId, password, this.performancePreset, fileOnly,
          security, osPassword)
      } catch (_error) {
        this.preparingAccount = false
        this.connectionStatusText = '账号恢复失败或服务器配置已改变，请重试；必要时到设置中的 API 账号重新登录'
        this.connectionStatusColor = RustDeskTheme.ERROR
        this.isConnecting = false
        return
      }
      this.preparingAccount = false
      if (status !== ConnectionStatus.CONNECTING) {
        let error: string = ConnectionService.getLastConnectionError()
        this.connectionStatusText = error
        this.connectionStatusColor = RustDeskTheme.ERROR
        this.isConnecting = false
        this.hasOpenedRemotePage = false
        return
      }
      this.hasOpenedRemotePage = true
      router.pushUrl({ url: 'pages/RemotePage' })
    }
  }

  loadConnectionFormState(): void {
    try {
      this.connectionFormExpanded = RustDeskNapi.getOption('connection-advanced-expanded') === '1'
    } catch (_error) {
      this.connectionFormExpanded = false
    }
  }

  setConnectionFormExpanded(expanded: boolean): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.connectionFormExpanded = expanded
    })
    RustDeskNapi.setOption('connection-advanced-expanded', expanded ? '1' : '0')
  }

  toggleSavedConnectionsExpanded(): void {
    const expanded: boolean = !this.savedConnectionsExpanded
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, () => {
      this.savedConnectionsExpanded = expanded
    })
    RustDeskNapi.setOption('saved-connections-expanded', expanded ? '1' : '0')
  }

  loadConnectionGroups(): void {
    this.connectionGroups = []
    try {
      this.savedConnectionsExpanded = RustDeskNapi.getOption('saved-connections-expanded') !== '0'
      this.ungroupedExpanded = RustDeskNapi.getOption('saved-connections-ungrouped-expanded') !== '0'
      let raw: string = RustDeskNapi.getOption('saved-connection-groups')
      if (raw.length <= 0) {
        return
      }
      let rows: Record<string, string | boolean>[] = JSON.parse(raw) as Record<string, string | boolean>[]
      let groups: SavedConnectionGroup[] = []
      rows.forEach((row: Record<string, string | boolean>) => {
        let id: string = `${row['id'] ?? ''}`.trim()
        let name: string = `${row['name'] ?? ''}`.trim()
        if (id.length > 0 && name.length > 0 && !groups.some((group: SavedConnectionGroup) => group.id === id)) {
          groups.push({
            id: id,
            name: name,
            expanded: row['expanded'] !== false
          })
        }
      })
      this.connectionGroups = this.cloneConnectionGroups(groups)
    } catch (_e) {
      this.connectionGroups = []
    }
  }

  persistConnectionGroups(): void {
    let rows: SavedConnectionGroupRow[] = []
    this.connectionGroups.forEach((group: SavedConnectionGroup) => {
      rows.push({ id: group.id, name: group.name, expanded: group.expanded })
    })
    RustDeskNapi.setOption('saved-connection-groups', JSON.stringify(rows))
    CloudSyncService.markLocalChanged()
  }

  cloneConnectionGroups(groups: SavedConnectionGroup[]): SavedConnectionGroup[] {
    let cloned: SavedConnectionGroup[] = []
    groups.forEach((group: SavedConnectionGroup) => {
      cloned.push({ id: group.id, name: group.name, expanded: group.expanded })
    })
    return cloned
  }

  loadSavedConnectionSort(): void {
    try {
      const mode: string = RustDeskNapi.getOption('saved-connections-sort')
      this.savedConnectionSort = mode === 'name' || mode === 'online' ? mode : 'id'
      this.savedConnectionSortAscending = RustDeskNapi.getOption('saved-connections-sort-direction') !== 'desc'
    } catch (_error) {
      this.savedConnectionSort = 'id'
      this.savedConnectionSortAscending = true
    }
  }

  setSavedConnectionSort(mode: string): void {
    this.savedConnectionSort = mode === 'name' || mode === 'online' ? mode : 'id'
    RustDeskNapi.setOption('saved-connections-sort', this.savedConnectionSort)
    this.savedConnectionsVersion++
  }

  toggleSavedConnectionSortDirection(): void {
    this.savedConnectionSortAscending = !this.savedConnectionSortAscending
    RustDeskNapi.setOption('saved-connections-sort-direction',
      this.savedConnectionSortAscending ? 'asc' : 'desc')
    this.savedConnectionsVersion++
  }

  compareSavedConnectionIds(left: string, right: string): number {
    // Match RustDesk's ID string ordering, including IDs of different lengths.
    return left < right ? -1 : left > right ? 1 : 0
  }

  savedConnectionOnlineRank(remoteId: string): number {
    if (!this.peerOnlineQueryEnabled) return 2
    const state: number = this.peerOnlineStates[remoteId] ?? PEER_STATE_CHECKING
    return state === PEER_STATE_ONLINE ? 0 : state === PEER_STATE_OFFLINE ? 1 : 2
  }

  compareSavedConnections(left: SavedConnectionInfo, right: SavedConnectionInfo): number {
    let order: number = 0
    if (this.savedConnectionSort === 'online') {
      const rank: number = this.savedConnectionOnlineRank(left.remoteId) -
        this.savedConnectionOnlineRank(right.remoteId)
      if (rank !== 0) order = rank
    }
    if (order === 0 && (this.savedConnectionSort === 'name' || this.savedConnectionSort === 'online')) {
      const leftName: string = (left.name.trim() || left.remoteId).toLowerCase()
      const rightName: string = (right.name.trim() || right.remoteId).toLowerCase()
      const nameOrder: number = leftName.localeCompare(rightName, 'zh-CN')
      if (nameOrder !== 0) order = nameOrder
    }
    if (order === 0) {
      const idOrder: number = this.compareSavedConnectionIds(left.remoteId, right.remoteId)
      order = idOrder !== 0 ? idOrder : this.compareSavedConnectionIds(left.id, right.id)
    }
    return this.savedConnectionSortAscending ? order : -order
  }

  connectionsForGroup(groupId: string): SavedConnectionInfo[] {
    let result: SavedConnectionInfo[] = []
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      if (this.validGroupId(item.groupId) === groupId && this.matchesSavedConnectionSearch(item)) {
        result.push(item)
      }
    })
    // Sort only a display copy; keep groups, credentials and backup order intact.
    return result.sort((left: SavedConnectionInfo, right: SavedConnectionInfo) =>
      this.compareSavedConnections(left, right))
  }

  matchesSavedConnectionSearch(item: SavedConnectionInfo): boolean {
    const query: string = (this.savedConnectionSearch ?? '').trim().toLowerCase()
    if (query.length === 0) {
      return true
    }
    const compactQuery: string = query.replace(/\s+/g, '')
    const compactRemoteId: string = item.remoteId.toLowerCase().replace(/\s+/g, '')
    return item.name.toLowerCase().includes(query) || compactRemoteId.includes(compactQuery)
  }

  filteredSavedConnectionCount(): number {
    let count: number = 0
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      if (this.matchesSavedConnectionSearch(item)) {
        count++
      }
    })
    return count
  }

  shouldShowSavedConnectionGroup(groupId: string): boolean {
    return (this.savedConnectionSearch ?? '').trim().length === 0 || this.connectionsForGroup(groupId).length > 0
  }

  validGroupId(groupId: string): string {
    return this.connectionGroups.some((group: SavedConnectionGroup) => group.id === groupId) ? groupId : ''
  }

  groupNameForId(groupId: string): string {
    let validId: string = this.validGroupId(groupId)
    if (validId.length <= 0) {
      return '未分组'
    }
    let found: SavedConnectionGroup | undefined = this.connectionGroups.find((group: SavedConnectionGroup) => group.id === validId)
    return found?.name ?? '未分组'
  }

  toggleConnectionGroup(groupId: string): void {
    if (groupId.length <= 0) {
      const expanded: boolean = !this.ungroupedExpanded
      this.getUIContext().animateTo({ duration: 210, curve: Curve.EaseInOut }, () => {
        this.ungroupedExpanded = expanded
      })
      RustDeskNapi.setOption('saved-connections-ungrouped-expanded', expanded ? '1' : '0')
      return
    }
    let groups: SavedConnectionGroup[] = []
    this.connectionGroups.forEach((group: SavedConnectionGroup) => {
      groups.push({
        id: group.id,
        name: group.name,
        expanded: group.id === groupId ? !group.expanded : group.expanded
      })
    })
    this.getUIContext().animateTo({ duration: 210, curve: Curve.EaseInOut }, () => {
      this.connectionGroups = groups
      this.savedConnectionsVersion++
    })
    this.persistConnectionGroups()
  }

  openRenameConnectionDialog(connectionId: string): void {
    if (this.savingConnection) return
    const connection: SavedConnectionInfo | undefined = this.savedConnections.find((item: SavedConnectionInfo) =>
      item.id === connectionId)
    if (connection === undefined) return
    this.closeAllDialogs()
    this.renamingConnectionId = connectionId
    this.connectionNameDraft = connection.name
    this.connectionNameError = ''
    this.showRenameConnectionDialog = true
  }

  saveConnectionName(): void {
    if (!this.showRenameConnectionDialog || this.savingConnection) return
    const name: string = this.connectionNameDraft.trim()
    if (name.length === 0) {
      this.connectionNameError = '连接名称不能为空'
      return
    }
    const connection: SavedConnectionInfo | undefined = this.savedConnections.find((item: SavedConnectionInfo) =>
      item.id === this.renamingConnectionId)
    if (connection === undefined) {
      this.connectionNameError = '此连接已不存在，请关闭后重试'
      return
    }
    if (name === connection.name) {
      this.closeRenameConnectionDialog()
      return
    }
    // Use the latest rows, preserving credentials, ID, group and performance settings.
    const list: SavedConnectionInfo[] = this.cloneSavedConnections(this.savedConnections)
    list.forEach((item: SavedConnectionInfo) => {
      if (item.id === connection.id) item.name = name
    })
    try {
      this.persistSavedConnections(list)
    } catch (_error) {
      this.connectionNameError = '保存失败，请重试'
      return
    }
    this.savedConnections = list
    this.savedConnectionsVersion++
    // Keep an untouched matching editor in sync, without overwriting a user's draft.
    if (this.selectedConnectionId === connection.id && this.connectionName === connection.name) {
      this.connectionName = name
    }
    this.closeRenameConnectionDialog()
    this.showSavedTip()
    RustDeskNapi.appendDiagnosticLog('connection', 'saved_connection_renamed')
  }

  closeRenameConnectionDialog(): void {
    this.showRenameConnectionDialog = false
    this.renamingConnectionId = ''
    this.connectionNameDraft = ''
    this.connectionNameError = ''
  }

  openNewGroupDialog(assignToForm: boolean = false, connectionId: string = ''): void {
    this.showGroupPicker = false
    this.showGroupNameDialog = true
    this.editingGroupId = ''
    this.groupNameDraft = ''
    this.groupNameError = ''
    this.assignCreatedGroupToForm = assignToForm
    this.assignCreatedGroupConnectionId = connectionId
  }

  openRenameGroupDialog(groupId: string): void {
    let group: SavedConnectionGroup | undefined = this.connectionGroups.find((item: SavedConnectionGroup) => item.id === groupId)
    if (group === undefined) {
      return
    }
    this.showGroupPicker = false
    this.showGroupNameDialog = true
    this.editingGroupId = groupId
    this.groupNameDraft = group.name
    this.groupNameError = ''
    this.assignCreatedGroupToForm = false
    this.assignCreatedGroupConnectionId = ''
  }

  saveGroupName(): void {
    let name: string = this.groupNameDraft.trim()
    if (name.length <= 0) {
      this.groupNameError = '分组名称不能为空'
      return
    }
    if (this.connectionGroups.some((group: SavedConnectionGroup) => group.id !== this.editingGroupId && group.name.toLowerCase() === name.toLowerCase())) {
      this.groupNameError = '已存在同名分组'
      return
    }

    if (this.editingGroupId.length > 0) {
      let groups: SavedConnectionGroup[] = []
      this.connectionGroups.forEach((group: SavedConnectionGroup) => {
        groups.push({ id: group.id, name: group.id === this.editingGroupId ? name : group.name, expanded: group.expanded })
      })
      this.connectionGroups = groups
    } else {
      let groupId: string = `group-${Date.now()}-${this.connectionGroups.length}`
      let groups: SavedConnectionGroup[] = this.cloneConnectionGroups(this.connectionGroups)
      groups.push({ id: groupId, name: name, expanded: true })
      this.connectionGroups = groups
      if (this.assignCreatedGroupToForm) {
        this.selectedGroupId = groupId
      }
      if (this.assignCreatedGroupConnectionId.length > 0) {
        this.moveConnectionToGroup(this.assignCreatedGroupConnectionId, groupId)
      }
    }
    this.savedConnectionsVersion++
    this.persistConnectionGroups()
    this.closeGroupDialogs()
  }

  openGroupPickerForForm(): void {
    this.groupPickerForForm = true
    this.groupPickerConnectionId = ''
    this.showGroupNameDialog = false
    this.showGroupPicker = true
  }

  openGroupPickerForConnection(connectionId: string): void {
    this.groupPickerForForm = false
    this.groupPickerConnectionId = connectionId
    this.showGroupNameDialog = false
    this.showGroupPicker = true
  }

  groupPickerCurrentGroupId(): string {
    if (this.groupPickerForForm) {
      return this.validGroupId(this.selectedGroupId)
    }
    let found: SavedConnectionInfo | undefined = this.savedConnections.find((item: SavedConnectionInfo) => item.id === this.groupPickerConnectionId)
    return this.validGroupId(found?.groupId ?? '')
  }

  selectGroupFromPicker(groupId: string): void {
    let validId: string = this.validGroupId(groupId)
    if (this.groupPickerForForm) {
      this.selectedGroupId = validId
    } else if (this.groupPickerConnectionId.length > 0) {
      this.moveConnectionToGroup(this.groupPickerConnectionId, validId)
    }
    this.closeGroupDialogs()
  }

  moveConnectionToGroup(connectionId: string, groupId: string): void {
    let validId: string = this.validGroupId(groupId)
    let list: SavedConnectionInfo[] = []
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      list.push({
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        password: item.password,
        performancePreset: item.performancePreset,
        groupId: item.id === connectionId ? validId : item.groupId
      })
    })
    this.savedConnections = list
    if (this.selectedConnectionId === connectionId) {
      this.selectedGroupId = validId
    }
    this.savedConnectionsVersion++
    this.persistSavedConnections(list)
  }

  closeGroupDialogs(): void {
    this.showGroupNameDialog = false
    this.showGroupPicker = false
    this.editingGroupId = ''
    this.groupNameDraft = ''
    this.groupNameError = ''
    this.assignCreatedGroupToForm = false
    this.assignCreatedGroupConnectionId = ''
    this.groupPickerConnectionId = ''
    this.groupPickerForForm = false
  }

  closeAllDialogs(): void {
    this.closeRenameConnectionDialog()
    this.closeConnectionPasswordDialog()
    this.closeGroupDialogs()
    this.closeBackupDialogs()
  }

  openConnectionPasswordDialog(): void {
    let peerId: string = this.normalizeRemoteId(this.remoteId)
    if (peerId.length <= 0) {
      this.connectionStatusText = '请输入远程 ID'
      this.connectionStatusColor = RustDeskTheme.ERROR
      return
    }
    this.remoteId = peerId
    this.closeGroupDialogs()
    this.connectionPasswordDraft = ''
    this.rememberConnectionPassword = false
    this.connectionPasswordError = ''
    this.showConnectionPasswordDialog = true
  }

  closeConnectionPasswordDialog(): void {
    this.showConnectionPasswordDialog = false
    this.connectionPasswordDraft = ''
    this.rememberConnectionPassword = false
    this.connectionPasswordError = ''
  }

  async confirmConnectionPassword(): Promise<void> {
    let password: string = this.connectionPasswordDraft.trim()
    if (password.length <= 0) {
      this.connectionPasswordError = '请输入连接密码'
      return
    }
    let remember: boolean = this.rememberConnectionPassword
    this.password = password
    this.passwordEditMode = 'replace'
    this.closeConnectionPasswordDialog()
    if (remember) {
      await this.saveCurrentConnection()
    }
    this.onConnect(this.pendingFileOnly)
  }

  closeBackupDialogs(): void {
    if (this.backupBusy) {
      return
    }
    this.showBackupPasswordDialog = false
    this.showImportPreviewDialog = false
    this.backupPasswordMode = ''
    this.backupPasswordDraft = ''
    this.backupPasswordConfirm = ''
    this.backupPasswordError = ''
    this.pendingEncryptedBackup = ''
    this.pendingImportPayload = undefined
    this.importReplaceExisting = false
  }

  openEncryptedExportDialog(): void {
    if (this.savedConnections.length <= 0 || this.backupBusy) {
      promptAction.showToast({ message: translate('暂无可导出的连接', this.uiLanguage) })
      return
    }
    this.closeGroupDialogs()
    this.backupPasswordMode = 'export'
    this.backupPasswordDraft = ''
    this.backupPasswordConfirm = ''
    this.backupPasswordError = ''
    this.showImportPreviewDialog = false
    this.showBackupPasswordDialog = true
  }

  async exportPlainBackup(): Promise<void> {
    if (this.savedConnections.length <= 0 || this.backupBusy) {
      promptAction.showToast({ message: translate('暂无可导出的连接', this.uiLanguage) })
      return
    }
    this.backupBusy = true
    try {
      let payload: ConnectionBackupPayload = this.buildBackupPayload(false)
      let content: string = ConnectionBackupService.createPlainText(payload)
      await this.saveBackupFile(content, `StarRustDesk连接备份-${this.backupTimestamp()}.json`)
      promptAction.showToast({ message: translate('连接已导出，备份中不包含密码', this.uiLanguage) })
    } catch (_error) {
      promptAction.showToast({ message: translate('导出失败，请重新选择保存位置', this.uiLanguage) })
    } finally {
      this.backupBusy = false
    }
  }

  async confirmBackupPassword(): Promise<void> {
    if (this.backupBusy) {
      return
    }
    let password: string = this.backupPasswordDraft
    if (password.length < 8) {
      this.backupPasswordError = '备份密码至少需要 8 位'
      return
    }
    if (this.backupPasswordMode === 'export' && password !== this.backupPasswordConfirm) {
      this.backupPasswordError = '两次输入的备份密码不一致'
      return
    }

    this.backupBusy = true
    if (this.backupPasswordMode === 'export') {
      try {
        let payload: ConnectionBackupPayload = this.buildBackupPayload(true)
        let content: string = await ConnectionBackupService.encrypt(payload, password)
        await this.saveBackupFile(content, `StarRustDesk加密备份-${this.backupTimestamp()}.srdbak`)
        this.backupBusy = false
        this.closeBackupDialogs()
        promptAction.showToast({ message: translate('加密备份导出成功，请妥善保管备份密码', this.uiLanguage) })
      } catch (_error) {
        this.backupBusy = false
        this.backupPasswordError = '加密导出失败，请重试'
      }
      return
    }

    try {
      let payload: ConnectionBackupPayload = await ConnectionBackupService.decrypt(
        this.pendingEncryptedBackup, password)
      this.backupBusy = false
      this.showBackupPasswordDialog = false
      this.backupPasswordDraft = ''
      this.backupPasswordConfirm = ''
      this.backupPasswordError = ''
      this.pendingEncryptedBackup = ''
      this.prepareImportPreview(payload)
    } catch (_error) {
      this.backupBusy = false
      this.backupPasswordError = '备份密码错误或文件已损坏'
    }
  }

  async selectBackupForImport(): Promise<void> {
    if (this.backupBusy) {
      return
    }
    this.backupBusy = true
    let source: fileIo.File | undefined = undefined
    try {
      let context = getContext(this) as common.UIAbilityContext
      let documentPicker = new picker.DocumentViewPicker(context)
      let options = new picker.DocumentSelectOptions()
      options.maxSelectNumber = 1
      options.fileSuffixFilters = ['StarRustDesk backup (*.json;*.srdbak)|.json,.srdbak']
      let uris: string[] = await documentPicker.select(options)
      if (uris.length <= 0) {
        return
      }
      source = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY)
      let fileSize: number = fileIo.statSync(source.fd).size
      if (fileSize <= 0 || fileSize > 5 * 1024 * 1024) {
        throw new Error('备份文件大小异常')
      }
      let buffer: ArrayBuffer = new ArrayBuffer(fileSize)
      let readSize: number = fileIo.readSync(source.fd, buffer)
      let raw: string = util.TextDecoder.create('utf-8', { ignoreBOM: true })
        .decodeToString(new Uint8Array(buffer, 0, readSize), { stream: false })
      if (ConnectionBackupService.isEncrypted(raw)) {
        this.pendingEncryptedBackup = raw
        this.backupPasswordMode = 'import'
        this.backupPasswordDraft = ''
        this.backupPasswordConfirm = ''
        this.backupPasswordError = ''
        this.showImportPreviewDialog = false
        this.showBackupPasswordDialog = true
      } else {
        this.prepareImportPreview(ConnectionBackupService.parsePlainText(raw))
      }
    } catch (_error) {
      promptAction.showToast({ message: translate('无法读取备份，请确认文件格式正确', this.uiLanguage) })
    } finally {
      if (source !== undefined) {
        try {
          fileIo.closeSync(source)
        } catch (_error) {
        }
      }
      this.backupBusy = false
    }
  }

  prepareImportPreview(payload: ConnectionBackupPayload): void {
    let validCount: number = 0
    payload.connections.forEach((item: ConnectionBackupItem) => {
      if (this.normalizeRemoteId(item.remoteId).length > 0) {
        validCount++
      }
    })
    if (validCount <= 0) {
      throw new Error('备份中没有有效连接')
    }
    this.pendingImportPayload = payload
    this.importPreviewGroupCount = payload.groups.length
    this.importPreviewConnectionCount = validCount
    this.importPreviewIncludesPasswords = payload.includesPasswords
    this.importReplaceExisting = false
    this.showBackupPasswordDialog = false
    this.showImportPreviewDialog = true
  }

  async importPreparedBackup(): Promise<void> {
    if (this.backupBusy || this.pendingImportPayload === undefined) {
      return
    }
    this.backupBusy = true
    try {
      let importedCount: number = this.importReplaceExisting ?
        await this.replaceConnectionsFromBackup(this.pendingImportPayload) :
        await this.mergeConnectionsFromBackup(this.pendingImportPayload)
      this.backupBusy = false
      this.closeBackupDialogs()
      this.savedConnectionsVersion++
      this.nextPeerOnlineRefreshAt = 0
      this.refreshSavedConnectionOnlineStates(true)
      promptAction.showToast({ message: translate(`已导入 ${importedCount} 个连接`, this.uiLanguage) })
    } catch (_error) {
      this.backupBusy = false
      promptAction.showToast({ message: translate('导入失败，请检查备份后重试', this.uiLanguage) })
    }
  }

  async replaceConnectionsFromBackup(payload: ConnectionBackupPayload): Promise<number> {
    let oldConnections: SavedConnectionInfo[] = this.cloneSavedConnections(this.savedConnections)
    let imported: NormalizedImportData = this.normalizeImportedData(payload, [], [])
    for (let item of oldConnections) {
      await CredentialStore.remove(item.id)
      await RemoteSecurityStore.remove(item.id)
    }
    for (let item of imported.connections) {
      await CredentialStore.save(item.id, item.password)
    }
    this.connectionGroups = imported.groups
    this.savedConnections = imported.connections
    this.persistConnectionGroups()
    this.persistSavedConnections(imported.connections)
    this.clearConnectionForm()
    return imported.connections.length
  }

  async mergeConnectionsFromBackup(payload: ConnectionBackupPayload): Promise<number> {
    let existingConnections: SavedConnectionInfo[] = this.cloneSavedConnections(this.savedConnections)
    let imported: NormalizedImportData = this.normalizeImportedData(payload,
      this.cloneConnectionGroups(this.connectionGroups), existingConnections)
    for (let item of imported.connections) {
      let existing: SavedConnectionInfo | undefined = existingConnections.find(
        (current: SavedConnectionInfo) => current.id === item.id)
      if (existing === undefined || existing.password !== item.password) {
        await CredentialStore.save(item.id, item.password)
      }
    }
    this.connectionGroups = imported.groups
    this.savedConnections = imported.connections
    this.persistConnectionGroups()
    this.persistSavedConnections(imported.connections)
    return imported.importedCount
  }

  normalizeImportedData(payload: ConnectionBackupPayload, baseGroups: SavedConnectionGroup[],
    baseConnections: SavedConnectionInfo[]): NormalizedImportData {
    let groups: SavedConnectionGroup[] = this.cloneConnectionGroups(baseGroups)
    let groupIdMap: Record<string, string> = {}
    payload.groups.forEach((source: ConnectionBackupGroup) => {
      let name: string = source.name.trim().substring(0, 100)
      let sameName: SavedConnectionGroup | undefined = groups.find((group: SavedConnectionGroup) =>
        group.name.toLowerCase() === name.toLowerCase())
      if (sameName !== undefined) {
        groupIdMap[source.id] = sameName.id
        return
      }
      let id: string = source.id.trim()
      if (id.length === 0 || groups.some((group: SavedConnectionGroup) => group.id === id)) {
        id = `group-${Date.now()}-${groups.length}`
      }
      groups.push({ id: id, name: name, expanded: true })
      groupIdMap[source.id] = id
    })

    let connections: SavedConnectionInfo[] = this.cloneSavedConnections(baseConnections)
    let importedCount: number = 0
    payload.connections.forEach((source: ConnectionBackupItem) => {
      let remoteId: string = this.normalizeRemoteId(source.remoteId)
      if (remoteId.length <= 0) {
        return
      }
      let existingIndex: number = connections.findIndex((item: SavedConnectionInfo) => item.remoteId === remoteId)
      let groupId: string = groupIdMap[source.groupId] ?? ''
      let preset: string = this.normalizePerformancePreset(source.performancePreset)
      let name: string = source.name.trim().length > 0 ? source.name.trim().substring(0, 200) : remoteId
      if (existingIndex >= 0) {
        let existing: SavedConnectionInfo = connections[existingIndex]
        connections[existingIndex] = {
          id: existing.id,
          name: name,
          remoteId: remoteId,
          password: existing.password.length > 0 ? existing.password :
            (payload.includesPasswords ? source.password : ''),
          performancePreset: preset,
          groupId: groupId
        }
      } else {
        let id: string = source.id.trim()
        if (id.length === 0 || connections.some((item: SavedConnectionInfo) => item.id === id)) {
          id = this.makeConnectionId(remoteId)
        }
        connections.push({
          id: id,
          name: name,
          remoteId: remoteId,
          password: payload.includesPasswords ? source.password : '',
          performancePreset: preset,
          groupId: groupId
        })
      }
      importedCount++
    })
    let result: NormalizedImportData = {
      groups: groups,
      connections: connections,
      importedCount: importedCount
    }
    return result
  }

  normalizePerformancePreset(value: string): string {
    return PerformanceSettings.normalize(value)
  }

  buildBackupPayload(includesPasswords: boolean): ConnectionBackupPayload {
    let groups: ConnectionBackupGroup[] = []
    this.connectionGroups.forEach((group: SavedConnectionGroup) => {
      groups.push({ id: group.id, name: group.name })
    })
    let connections: ConnectionBackupItem[] = []
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      connections.push({
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        password: includesPasswords ? item.password : '',
        performancePreset: item.performancePreset,
        groupId: item.groupId
      })
    })
    return ConnectionBackupService.createPayload(groups, connections, includesPasswords)
  }

  async saveBackupFile(content: string, fileName: string): Promise<void> {
    let outputFile: fileIo.File | undefined = undefined
    try {
      let context = getContext(this) as common.UIAbilityContext
      let documentPicker = new picker.DocumentViewPicker(context)
      let saveUris: string[] = await documentPicker.save({ newFileNames: [fileName] })
      if (saveUris.length <= 0) {
        throw new Error('未选择保存位置')
      }
      outputFile = fileIo.openSync(saveUris[0],
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
      fileIo.writeSync(outputFile.fd, content)
      fileIo.fsyncSync(outputFile.fd)
    } finally {
      if (outputFile !== undefined) {
        try {
          fileIo.closeSync(outputFile)
        } catch (_error) {
        }
      }
    }
  }

  backupTimestamp(): string {
    let now: Date = new Date()
    let pad: (value: number) => string = (value: number): string => value < 10 ? `0${value}` : value.toString()
    return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-` +
      `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
  }

  editSavedConnection(item: SavedConnectionInfo): void {
    this.applySavedConnection(item)
    this.setConnectionFormExpanded(true)
    if (this.isWideDeviceLayout()) this.setTabletEditorVisible(true)
  }

  async loadSavedConnections(): Promise<void> {
    let raw: string = RustDeskNapi.getOption('saved-connections')
    if (raw.length <= 0) {
      this.savedConnections = []
      this.savedConnectionsVersion++
      return
    }
    try {
      let rows: Record<string, string>[] = JSON.parse(raw) as Record<string, string>[]
      let list: SavedConnectionInfo[] = []
      for (let row of rows) {
        let remoteId: string = this.normalizeRemoteId(row['remoteId'] ?? '')
        if (remoteId.length > 0) {
          let id: string = row['id'] ?? this.makeConnectionId(remoteId)
          let savedPassword: string = await CredentialStore.load(id)
          let legacyPassword: string = row['passwordEnc'] ?? row['password'] ?? ''
          if (savedPassword.length === 0 && legacyPassword.length > 0) {
            savedPassword = legacyPassword
            await CredentialStore.save(id, legacyPassword)
          }
          list.push({
            id: id,
            name: row['name'] ?? '',
            remoteId: remoteId,
            password: savedPassword,
            performancePreset: PerformanceSettings.normalize(row['performancePreset'] ?? 'smooth'),
            groupId: this.validGroupId(row['groupId'] ?? '')
          })
        }
      }
      this.savedConnections = this.cloneSavedConnections(list)
      this.savedConnectionsVersion++
      this.persistSavedConnections(list, false)
      RustDeskNapi.setOption('password', '')
      this.nextPeerOnlineRefreshAt = 0
      this.refreshSavedConnectionOnlineStates(true)
    } catch (_e) {
      this.savedConnections = []
      this.savedConnectionsVersion++
    }
  }

  persistSavedConnections(list: SavedConnectionInfo[], markChanged: boolean = true): void {
    let rows: SavedConnectionRow[] = []
    list.forEach((item: SavedConnectionInfo) => {
      rows.push({
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        credentialAlias: item.id,
        performancePreset: item.performancePreset,
        groupId: item.groupId
      })
    })
    RustDeskNapi.setOption('saved-connections', JSON.stringify(rows))
    if (markChanged) {
      CloudSyncService.markLocalChanged()
    }
  }

  refreshSavedConnectionOnlineStates(force: boolean = false): void {
    if (!this.peerOnlineQueryEnabled || this.peerOnlineQueryInFlight || this.savedConnections.length <= 0) {
      return
    }
    let peerIds: string[] = []
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      if (!this.isDirectPeerEndpoint(item.remoteId) && !peerIds.includes(item.remoteId)) {
        peerIds.push(item.remoteId)
      }
    })
    if (peerIds.length <= 0) {
      this.markAllPeerStatesUnknown()
      this.nextPeerOnlineRefreshAt = Date.now() + PEER_STATE_REFRESH_MS
      return
    }
    if (force || this.savedConnections.some((item: SavedConnectionInfo) => this.isDirectPeerEndpoint(item.remoteId))) {
      let checkingStates: Record<string, number> = {}
      this.savedConnections.forEach((item: SavedConnectionInfo) => {
        checkingStates[item.remoteId] = this.isDirectPeerEndpoint(item.remoteId) ? PEER_STATE_UNKNOWN :
          (this.peerOnlineStates[item.remoteId] ?? PEER_STATE_CHECKING)
      })
      this.peerOnlineStates = checkingStates
      this.peerOnlineStatesVersion++
    }
    let result: number = RustDeskNapi.queryPeerOnlineStates(peerIds, this.peerStateServer)
    if (result === 0) {
      // Diagnostic only: do not delay the query for the platform network snapshot.
      ConnectionService.recordNetworkSnapshot('online_state').catch(() => {})
    }
    if (result === 0 || result === 1) {
      this.peerOnlineQueryInFlight = true
      this.peerOnlineQueryStartedAt = Date.now()
      this.nextPeerOnlineRefreshAt = Date.now() + PEER_STATE_REFRESH_MS
      return
    }
    this.markAllPeerStatesUnknown()
    this.nextPeerOnlineRefreshAt = Date.now() + 10000
  }

  pollPeerOnlineStates(): void {
    if (!this.peerOnlineQueryEnabled) {
      if (this.peerOnlineQueryInFlight && RustDeskNapi.takePeerOnlineStates().length > 0) {
        this.peerOnlineQueryInFlight = false
      }
      return
    }
    // A timed-out UI request can still complete in the native worker.
    // Always drain its result before starting another query.
    let raw: string = RustDeskNapi.takePeerOnlineStates()
    if (raw.length <= 0) {
      if (this.peerOnlineQueryInFlight &&
        Date.now() - this.peerOnlineQueryStartedAt >= PEER_STATE_QUERY_TIMEOUT_MS) {
        this.peerOnlineQueryInFlight = false
        this.markAllPeerStatesUnknown()
        RustDeskNapi.appendDiagnosticLog('online-state', 'query_ui_timeout awaiting_late_result')
        this.nextPeerOnlineRefreshAt = Date.now() + 10000
      }
      return
    }
    this.peerOnlineQueryInFlight = false
    try {
      let result: PeerOnlineResult = JSON.parse(raw) as PeerOnlineResult
      if (result.server !== this.peerStateServer) {
        this.nextPeerOnlineRefreshAt = 0
        return
      }
      if (result.error.length > 0) {
        this.markAllPeerStatesUnknown()
        this.nextPeerOnlineRefreshAt = Date.now() + 10000
        return
      }
      let states: Record<string, number> = {}
      this.savedConnections.forEach((item: SavedConnectionInfo) => {
        states[item.remoteId] = PEER_STATE_UNKNOWN
      })
      result.peers.forEach((peer: PeerOnlineState) => {
        if (typeof peer.id === 'string' && !this.isDirectPeerEndpoint(peer.id) &&
          this.savedConnections.some((item: SavedConnectionInfo) => item.remoteId === peer.id) &&
          typeof peer.online === 'boolean') {
          states[peer.id] = peer.online ? PEER_STATE_ONLINE : PEER_STATE_OFFLINE
        }
      })
      this.peerOnlineStates = states
      this.peerOnlineStatesVersion++
      RustDeskNapi.appendDiagnosticLog('online-state',
        `query_applied count=${Object.keys(states).length} ` +
        `online=${Object.keys(states).filter((id: string) => states[id] === PEER_STATE_ONLINE).length}`)
      this.nextPeerOnlineRefreshAt = Date.now() + PEER_STATE_REFRESH_MS
    } catch (_error) {
      this.markAllPeerStatesUnknown()
      this.nextPeerOnlineRefreshAt = Date.now() + 10000
    }
  }

  markAllPeerStatesUnknown(): void {
    let states: Record<string, number> = {}
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      states[item.remoteId] = PEER_STATE_UNKNOWN
    })
    this.peerOnlineStates = states
    this.peerOnlineStatesVersion++
  }

  isDirectPeerEndpoint(remoteId: string): boolean {
    const endpoint: string = remoteId.trim()
    // A query exclusion classifier, not an address validator or reachability
    // check. Native connection parsing validates ports and IPs. Keep malformed
    // endpoint-like inputs out of hbbs too; bare numeric RustDesk IDs stay IDs.
    return endpoint.includes(':') || endpoint.includes('[') || endpoint.includes(']') ||
      (endpoint.includes('.') && /^[\d.]+$/.test(endpoint))
  }

  peerOnlineStateColor(remoteId: string): ResourceColor {
    if (!this.peerOnlineQueryEnabled) return this.isDarkMode ? '#697386' : '#A5ADBA'
    let state: number = this.isDirectPeerEndpoint(remoteId) ? PEER_STATE_UNKNOWN :
      (this.peerOnlineStates[remoteId] ?? PEER_STATE_CHECKING)
    if (state === PEER_STATE_ONLINE) {
      return RustDeskTheme.SUCCESS
    }
    if (state === PEER_STATE_OFFLINE) {
      return this.isDarkMode ? '#697386' : '#A5ADBA'
    }
    return RustDeskTheme.WARNING
  }

  peerOnlineStateHint(remoteId: string): string {
    if (!this.peerOnlineQueryEnabled) return '在线查询已关闭，仍可尝试连接'
    if (this.isDirectPeerEndpoint(remoteId)) return '直连地址 · 状态未知，请尝试连接'
    const state: number = this.peerOnlineStates[remoteId] ?? PEER_STATE_CHECKING
    if (state === PEER_STATE_ONLINE) return '在线'
    if (state === PEER_STATE_OFFLINE) return '离线'
    if (state === PEER_STATE_CHECKING) return '正在查询在线状态…'
    return '状态未知 · 查询未确认，仍可尝试连接'
  }

  applySavedConnection(item: SavedConnectionInfo): void {
    this.selectedConnectionId = item.id
    this.connectionName = item.name
    this.remoteId = this.normalizeRemoteId(item.remoteId)
    this.password = ''
    this.passwordEditMode = 'keep'
    this.performancePreset = PerformanceSettings.normalize(item.performancePreset)
    this.selectedGroupId = this.validGroupId(item.groupId)
    this.isIdEmpty = this.remoteId.length === 0
    const security: RemoteSecurityOptions = RemoteSecurityStore.options(item.id)
    this.lockAfterDisconnect = security.lockAfterDisconnect
    this.privacyMode = security.privacyMode
    this.autoUnlock = security.autoUnlock && security.lockAfterDisconnect
    this.osPasswordDraft = ''
    this.clearOsPassword = false
    this.hasStoredOsPassword = false
    RemoteSecurityStore.loadOsPassword(item.id).then((secret: string) => {
      if (this.selectedConnectionId === item.id) this.hasStoredOsPassword = secret.length > 0
    })
  }

  connectSavedConnection(item: SavedConnectionInfo): void {
    this.applySavedConnection(item)
    this.onConnect()
  }

  savedConnectionForPassword(): SavedConnectionInfo | undefined {
    const peerId: string = this.normalizeRemoteId(this.remoteId)
    return this.savedConnections.find((item: SavedConnectionInfo) =>
      item.id === this.selectedConnectionId && this.normalizeRemoteId(item.remoteId) === peerId)
  }

  hasSavedConnectionPassword(): boolean {
    return (this.savedConnectionForPassword()?.password.length ?? 0) > 0
  }

  connectionPasswordForUse(): string {
    if (this.passwordEditMode === 'clear') return ''
    if (this.password.trim().length > 0) return this.password.trim()
    if (this.passwordEditMode !== 'keep') return ''
    // Only the matching saved device may supply an authentication secret.
    return this.savedConnectionForPassword()?.password.trim() ?? ''
  }

  startPasswordReplacement(): void {
    this.password = ''
    this.passwordEditMode = 'replace'
  }

  clearSavedPassword(): void {
    this.password = ''
    this.passwordEditMode = 'clear'
  }

  cancelPasswordChange(): void {
    this.password = ''
    this.passwordEditMode = 'keep'
  }

  clearSaveTip(): void {
    this.saveTipGeneration++
    if (this.saveTipTimer !== -1) clearTimeout(this.saveTipTimer)
    if (this.saveTipRemoveTimer !== -1) clearTimeout(this.saveTipRemoveTimer)
    this.saveTipTimer = -1
    this.saveTipRemoveTimer = -1
    this.saveTipVisible = false
  }

  showSavedTip(): void {
    this.clearSaveTip()
    const generation: number = this.saveTipGeneration
    this.saveTipOpacity = 1
    this.saveTipOffsetY = 0
    this.saveTipVisible = true
    this.saveTipTimer = setTimeout(() => {
      if (generation !== this.saveTipGeneration || !this.savePageActive) return
      this.saveTipTimer = -1
      this.getUIContext().animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
        this.saveTipOffsetY = -32
        this.saveTipOpacity = 0
      })
      this.saveTipRemoveTimer = setTimeout(() => {
        if (generation !== this.saveTipGeneration) return
        this.saveTipRemoveTimer = -1
        this.saveTipVisible = false
      }, 440)
    }, 1200)
  }

  async saveConnectionWithTip(): Promise<void> {
    if (this.savingConnection || this.normalizeRemoteId(this.remoteId).length === 0) return
    if (this.passwordEditMode === 'replace' && this.password.trim().length === 0) {
      promptAction.showToast({ message: translate('请输入新密码，或取消更换后选择清除', this.uiLanguage) })
      return
    }
    this.savingConnection = true
    try {
      await this.saveCurrentConnection()
      if (this.savePageActive) {
        if (this.tabletEditorVisible) this.setTabletEditorVisible(false)
        this.showSavedTip()
      }
    } catch (_e) {
      if (this.savePageActive) promptAction.showToast({ message: translate('保存失败，请重试', this.uiLanguage) })
    } finally {
      this.savingConnection = false
    }
  }

  async saveCurrentConnection(): Promise<void> {
    let peerId: string = this.normalizeRemoteId(this.remoteId)
    let password: string = this.connectionPasswordForUse()
    if (peerId.length <= 0) {
      return
    }
    if (this.passwordEditMode === 'replace' && password.length === 0) {
      throw new Error('Empty replacement password')
    }
    const originalSelection: string = this.selectedConnectionId
    const originalDraft: string = this.password
    const originalMode: string = this.passwordEditMode
    let savedName: string = this.connectionName.trim()
    let targetId: string = this.selectedConnectionId.length > 0 ? this.selectedConnectionId : this.makeConnectionId(peerId)
    const identityChanged: boolean = this.savedConnections.some((item: SavedConnectionInfo) =>
      item.id === targetId && this.normalizeRemoteId(item.remoteId) !== peerId)
    const osPasswordDraft: string = this.osPasswordDraft
    const storedOsPassword: boolean = this.hasStoredOsPassword
    const draftClearOsPassword: boolean = this.clearOsPassword
    const draftAutoUnlock: boolean = this.autoUnlock
    const clearOsPassword: boolean = this.clearOsPassword || (identityChanged && osPasswordDraft.length === 0)
    const security: RemoteSecurityOptions = {
      lockAfterDisconnect: this.lockAfterDisconnect,
      privacyMode: this.privacyMode,
      autoUnlock: this.autoUnlock && this.lockAfterDisconnect && !(identityChanged && osPasswordDraft.length === 0)
    }
    if (identityChanged && osPasswordDraft.length === 0) {
      RustDeskNapi.appendDiagnosticLog('remote-security', 'os_password_cleared peer_identity_changed')
    }
    let next: SavedConnectionInfo = {
      id: targetId,
      name: savedName.length > 0 ? savedName : peerId,
      remoteId: peerId,
      password: password,
      performancePreset: this.performancePreset,
      groupId: this.validGroupId(this.selectedGroupId)
    }
    let list: SavedConnectionInfo[] = []
    let updated: boolean = false
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      if (item.id === targetId) {
        list.push(next)
        updated = true
      } else {
        list.push(item)
      }
    })
    if (!updated) {
      list.unshift(next)
    }
    await CredentialStore.save(targetId, password)
    if (clearOsPassword) await RemoteSecurityStore.removeOsPassword(targetId)
    if (osPasswordDraft.length > 0) await RemoteSecurityStore.saveOsPassword(targetId, osPasswordDraft)
    RemoteSecurityStore.saveOptions(targetId, security)
    RustDeskNapi.appendDiagnosticLog('remote-security',
      `options_saved lock=${security.lockAfterDisconnect} privacy=${security.privacyMode} auto_unlock=${security.autoUnlock} ` +
      `os_password_configured=${osPasswordDraft.length > 0 || (storedOsPassword && !clearOsPassword)}`)
    if (this.selectedConnectionId === originalSelection && this.normalizeRemoteId(this.remoteId) === peerId &&
      this.osPasswordDraft === osPasswordDraft && this.clearOsPassword === draftClearOsPassword &&
      this.autoUnlock === draftAutoUnlock && this.lockAfterDisconnect === security.lockAfterDisconnect &&
      this.privacyMode === security.privacyMode) {
      this.hasStoredOsPassword = osPasswordDraft.length > 0 || (storedOsPassword && !clearOsPassword)
      this.osPasswordDraft = ''
      this.clearOsPassword = false
      this.autoUnlock = security.autoUnlock
    }
    this.savedConnections = this.cloneSavedConnections(list)
    this.savedConnectionsVersion++
    if (this.selectedConnectionId === originalSelection && this.normalizeRemoteId(this.remoteId) === peerId &&
      this.password === originalDraft && this.passwordEditMode === originalMode) {
      this.selectedConnectionId = targetId
      this.password = ''
      this.passwordEditMode = 'keep'
    }
    this.persistSavedConnections(list)
    this.nextPeerOnlineRefreshAt = 0
    this.refreshSavedConnectionOnlineStates(true)
  }

  async deleteSavedConnection(id: string): Promise<void> {
    let list: SavedConnectionInfo[] = []
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      if (item.id !== id) {
        list.push(item)
      }
    })
    this.savedConnections = this.cloneSavedConnections(list)
    this.savedConnectionsVersion++
    if (this.selectedConnectionId === id) {
      this.clearConnectionForm()
    }
    await CredentialStore.remove(id)
    await RemoteSecurityStore.remove(id)
    this.persistSavedConnections(list)
    this.nextPeerOnlineRefreshAt = 0
    this.refreshSavedConnectionOnlineStates(true)
  }

  clearConnectionForm(): void {
    this.selectedConnectionId = ''
    this.selectedGroupId = ''
    this.connectionName = ''
    this.remoteId = ''
    this.password = ''
    this.passwordEditMode = 'keep'
    this.performancePreset = 'smooth'
    this.lockAfterDisconnect = false
    this.privacyMode = false
    this.autoUnlock = false
    this.osPasswordDraft = ''
    this.hasStoredOsPassword = false
    this.clearOsPassword = false
    this.isIdEmpty = true
  }

  makeConnectionId(remoteId: string): string {
    return `${remoteId}-${Date.now()}`
  }

  normalizeRemoteId(remoteId: string): string {
    return remoteId.replace(/[\s\u200B-\u200D\uFEFF]+/g, '')
  }

  cloneSavedConnections(list: SavedConnectionInfo[]): SavedConnectionInfo[] {
    let cloned: SavedConnectionInfo[] = []
    list.forEach((item: SavedConnectionInfo) => {
      cloned.push({
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        password: item.password,
        performancePreset: item.performancePreset,
        groupId: item.groupId
      })
    })
    return cloned
  }
}
