import { common } from '@kit.AbilityKit'
import { promptAction, router } from '@kit.ArkUI'
import { fileIo, picker } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { ConnectionService } from '../service/ConnectionService'
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask'
import { ConnectionStatus } from '../model/ConnectionModel'
import { PeerOnlineResult, PeerOnlineState, RustDeskNapi } from '../service/RustDeskNapi'
import { CredentialStore } from '../service/CredentialStore'
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
  @State connectionName: string = ''
  @State remoteId: string = ''
  @State password: string = ''
  @State isIdEmpty: boolean = true
  @State isConnecting: boolean = false
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @State showUpdateBanner: boolean = false
  @State isUsingPublicServer: boolean = true
  @State customServerHint: string = ''
  @State connectionStatusText: string = ''
  @State connectionStatusColor: ResourceColor = Color.Transparent
  @State connectionStatusValue: number = 0
  @State performancePreset: string = 'smooth'
  @State hasOpenedRemotePage: boolean = false
  @State pageWidth: number = 0
  @State savedConnections: SavedConnectionInfo[] = []
  @State selectedConnectionId: string = ''
  @State selectedGroupId: string = ''
  @State savedConnectionsVersion: number = 0
  @State peerOnlineStatesVersion: number = 0
  @State connectionGroups: SavedConnectionGroup[] = []
  @State savedConnectionsExpanded: boolean = true
  @State savedConnectionSort: string = 'id'
  @State connectionFormExpanded: boolean = true
  @State ungroupedExpanded: boolean = true
  @State showGroupNameDialog: boolean = false
  @State editingGroupId: string = ''
  @State groupNameDraft: string = ''
  @State groupNameError: string = ''
  @State assignCreatedGroupToForm: boolean = false
  @State assignCreatedGroupConnectionId: string = ''
  @State showGroupPicker: boolean = false
  @State groupPickerConnectionId: string = ''
  @State groupPickerForForm: boolean = false
  @State showBackupPasswordDialog: boolean = false
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

  aboutToAppear(): void {
    this.checkServerConfig()
    this.loadConnectionFormState()
    this.loadConnectionGroups()
    this.loadSavedConnectionSort()
    this.loadSavedConnections()
    this.syncConnectionState()
    this.startStatusPolling()
  }

  aboutToDisappear(): void {
    if (this.statusTimer !== -1) {
      clearTimeout(this.statusTimer)
      this.statusTimer = -1
    }
  }

  checkServerConfig(): void {
    try {
      let idServer: string = RustDeskNapi.getOption('custom-rendezvous-server')
      this.isUsingPublicServer = idServer.length === 0
      this.customServerHint = idServer
    } catch (error) {
      // Server status is informational and must never prevent app startup.
      this.isUsingPublicServer = true
      this.customServerHint = ''
    }
  }

  startStatusPolling(): void {
    let poll = () => {
      this.pollPeerOnlineStates()
      if (Date.now() >= this.nextPeerOnlineRefreshAt) {
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
    let status: ConnectionStatus = RustDeskNapi.getConnectionStatus() as ConnectionStatus
    RemoteSessionBackgroundTask.syncForConnectionStatus(status)
    this.connectionStatusValue = status
    if (status === ConnectionStatus.CONNECTING) {
      this.connectionStatusText = translate('Connecting...')
      this.connectionStatusColor = RustDeskTheme.WARNING
      this.isConnecting = true
    } else if (status === ConnectionStatus.CONNECTED) {
      this.connectionStatusText = translate('Connected')
      this.connectionStatusColor = RustDeskTheme.SUCCESS
      this.isConnecting = false
    } else if (status === ConnectionStatus.WAITING_2FA) {
      this.connectionStatusText = '需要二次验证'
      this.connectionStatusColor = RustDeskTheme.WARNING
      this.isConnecting = false
    } else if (status === ConnectionStatus.FAILED) {
      let error: string = ConnectionService.getLastConnectionError()
      this.connectionStatusText = error.length > 0 ? error : translate('Connection failed')
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
        if (this.pageWidth >= 820) {
          Row({ space: 18 }) {
            Scroll() {
              Column() {
                this.buildSavedConnections()
              }
              .width('100%')
              .padding({ bottom: 8 })
            }
            .layoutWeight(1)
            .height('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)

            Scroll() {
              Column() {
                this.buildConnectionForm()
              }
              .width('100%')
              .padding({ bottom: 8 })
            }
            .layoutWeight(1.2)
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
              this.buildSavedConnections()
              this.buildConnectionForm()
            }
            .width('100%')
            .padding({ bottom: 8 })
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

      if (this.showGroupNameDialog || this.showGroupPicker ||
        this.showBackupPasswordDialog || this.showImportPreviewDialog) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.closeAllDialogs()
          })
          .zIndex(10)

        if (this.showGroupNameDialog) {
          this.buildGroupNameDialog()
        } else if (this.showGroupPicker) {
          this.buildGroupPickerDialog()
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
      this.pageWidth = newValue.width as number
    })
  }

  @Builder
  buildPageHeader() {
    Row() {
      Column({ space: 4 }) {
        Text('StarRustDesk')
          .fontSize(this.pageWidth >= 820 ? 30 : 26)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')
        Text('轻松连接并控制你的远端设备')
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
        Text(this.isUsingPublicServer ? '公共网络' : '自建网络')
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
      }
      .height(34)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.isDarkMode ? '#263142' : '#F7FAFF')
      .border({ width: 1, color: this.isDarkMode ? '#364256' : '#DFE7F2' })
      .borderRadius(7)
    }
    .width('100%')
    .height(this.pageWidth >= 820 ? 116 : 104)
    .padding({ top: 24, bottom: 18 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildConnectionForm() {
    Column({ space: 12 }) {
      Row() {
        Button() {
          Image(this.connectionFormExpanded ?
            $r('app.media.group_chevron_up') : $r('app.media.group_chevron_down'))
            .width(12)
            .height(12)
            .objectFit(ImageFit.Contain)
        }
          .width(44)
          .height(34)
          .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .padding(0)
          .onClick(() => {
            this.setConnectionFormExpanded(!this.connectionFormExpanded)
          })
        Text(this.selectedConnectionId.length > 0 ? '编辑连接' : '新建连接')
          .fontSize(18)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(this.performancePreset === 'stable' ? '稳定优先' : this.performancePreset === 'high_fps' ? '帧率优先' : this.performancePreset === 'silky' ? '丝滑优先' : '流畅优先')
          .fontSize(12)
          .fontColor(RustDeskTheme.ACCENT)
      }
      .width('100%')
      .margin({ bottom: 2 })

      if (this.connectionFormExpanded) {
        this.buildRemoteIdInput()
        this.buildConnectionNameInput()
        this.buildConnectionGroupSelector()
        this.buildPasswordInput()
        this.buildPerformancePresetSelector()
        this.buildConnectionEditActions()
        if (this.connectionStatusText.length > 0) {
          this.buildConnectionStatus()
        }
        if (!this.isUsingPublicServer && this.customServerHint.length > 0) {
          this.buildCustomServerIndicator()
        }
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .shadow({ radius: 16, color: this.isDarkMode ? '#44000000' : '#15345A84', offsetX: 0, offsetY: 6 })
    .margin({ bottom: 18 })
  }

  @Builder
  buildUpdateBanner() {
    Row() {
      Text(translate('Download new version'))
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
      Text(this.connectionStatusText)
        .fontSize(14)
        .fontColor(this.connectionStatusColor)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .margin({ left: 6 })

      if (this.connectionStatusValue === ConnectionStatus.FAILED) {
        Button(translate('Retry'))
          .fontSize(12)
          .fontColor(RustDeskTheme.ACCENT)
          .backgroundColor(Color.Transparent)
          .margin({ left: 12 })
          .onClick(() => {
            this.onConnect()
          })
      }

      if (this.connectionStatusValue === ConnectionStatus.CONNECTED) {
        Button(translate('Disconnect'))
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .backgroundColor(Color.Transparent)
          .margin({ left: 12 })
          .onClick(() => {
            ConnectionService.disconnect()
          })
      }
    }
    .width('100%')
    .height(38)
    .padding({ left: 12, right: 8 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
    .borderRadius(6)
  }

  @Builder
  buildRemoteIdInput() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.End }) {
          TextInput({ placeholder: translate('Remote ID'), text: this.remoteId })
            .type(InputType.Normal)
            .fontSize(RustDeskTheme.FONT_SIZE_ID)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.ID_COLOR)
            .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
            .height(52)
            .padding({ left: 12, right: 44 })
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
          }
        }
        .layoutWeight(1)
        .height(52)

        Button({ type: ButtonType.Circle }) {
          Text('→')
            .fontSize(24)
            .fontColor(Color.White)
        }
        .width(44)
        .height(44)
        .backgroundColor(this.remoteId.trim().length > 0 && this.password.trim().length > 0 ? RustDeskTheme.ACCENT : RustDeskTheme.DARK_GRAY)
        .onClick(() => {
          this.onConnect()
        })
      }
      .padding({ left: 16, right: 8 })
      .height(68)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
      .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#DEE6F1' })
      .borderRadius(RustDeskTheme.CONTROL_RADIUS)
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
    TextInput({ placeholder: '连接名称（可选）', text: this.connectionName })
      .type(InputType.Normal)
      .fontSize(RustDeskTheme.FONT_SIZE_BODY)
      .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
      .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#DEE6F1' })
      .borderRadius(RustDeskTheme.CONTROL_RADIUS)
      .onChange((value: string) => {
        this.connectionName = value
      })
  }

  @Builder
  buildConnectionGroupSelector() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('保存到分组')
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        Text(this.groupNameForId(this.selectedGroupId))
          .fontSize(14)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('选择')
        .height(32)
        .fontSize(12)
        .fontColor(RustDeskTheme.ACCENT)
        .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
        .borderRadius(6)
        .onClick(() => {
          this.openGroupPickerForForm()
        })

      Button('+ 分组')
        .height(32)
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor(RustDeskTheme.ACCENT)
        .borderRadius(6)
        .onClick(() => {
          this.openNewGroupDialog(true)
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 8 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#DEE6F1' })
    .borderRadius(RustDeskTheme.CONTROL_RADIUS)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildPasswordInput() {
    TextInput({ placeholder: translate('Password'), text: this.password })
      .type(InputType.Password)
      .fontSize(RustDeskTheme.FONT_SIZE_BODY)
      .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
      .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
      .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#DEE6F1' })
      .borderRadius(RustDeskTheme.CONTROL_RADIUS)
      .onChange((value: string) => {
        this.password = value
      })
  }

  @Builder
  buildSavedConnections() {
    Column({ space: 8 }) {
      Row() {
        Button() {
          Image(this.savedConnectionsExpanded ?
            $r('app.media.group_chevron_up') : $r('app.media.group_chevron_down'))
            .width(12)
            .height(12)
            .objectFit(ImageFit.Contain)
        }
          .width(44)
          .height(34)
          .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .padding(0)
          .onClick(() => {
            this.savedConnectionsExpanded = !this.savedConnectionsExpanded
            RustDeskNapi.setOption('saved-connections-expanded', this.savedConnectionsExpanded ? '1' : '0')
          })
        Text('已保存连接')
          .fontSize(18)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
          .maxLines(1)
          .minFontSize(14)
          .maxFontSize(18)
          .margin({ left: 6, right: 6 })
        Button(`排序：${this.savedConnectionSort === 'name' ? '名称' :
          this.savedConnectionSort === 'online' ? '在线优先' : 'ID'}`)
          .height(30)
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .padding({ left: 10, right: 10 })
          .bindMenu([
            { value: `${this.savedConnectionSort === 'id' ? '✓ ' : ''}远端 ID`,
              action: () => { this.setSavedConnectionSort('id') } },
            { value: `${this.savedConnectionSort === 'name' ? '✓ ' : ''}设备名称`,
              action: () => { this.setSavedConnectionSort('name') } },
            { value: `${this.savedConnectionSort === 'online' ? '✓ ' : ''}在线优先`,
              action: () => { this.setSavedConnectionSort('online') } }
          ], { placement: Placement.BottomRight, enableArrow: true })
      }
      .width('100%')

      Row() {
        Text(`${this.savedConnections.length} 个设备`)
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        Blank()
        Button('备份')
          .height(30)
          .fontSize(12)
          .fontColor(RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .padding(0)
          .margin({ left: 8 })
          .bindMenu([
            {
              value: '普通导出（不含密码）',
              action: () => {
                this.exportPlainBackup()
              }
            },
            {
              value: '加密导出（包含密码）',
              action: () => {
                this.openEncryptedExportDialog()
              }
            },
            {
              value: '导入备份',
              action: () => {
                this.selectBackupForImport()
              }
            }
          ], {
            placement: Placement.BottomRight,
            enableArrow: true
          })
        Button('+ 分组')
          .height(30)
          .fontSize(12)
          .fontColor(RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .padding(0)
          .margin({ left: 8 })
          .onClick(() => {
            this.openNewGroupDialog()
          })
      }
      .width('100%')
      .margin({ bottom: 2 })

      if (this.savedConnectionsExpanded) {
        if (this.savedConnections.length === 0 && this.connectionGroups.length === 0) {
          Column({ space: 8 }) {
            Text('暂无保存的连接')
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_PRIMARY)
            Text('可先创建分组，再保存连接')
              .fontSize(12)
              .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          }
          .width('100%')
          .height(112)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
        } else {
          if (this.connectionsForGroup('').length > 0) {
            this.buildSavedConnectionGroup('', '未分组', this.ungroupedExpanded, false)
          }

          ForEach(this.connectionGroups, (group: SavedConnectionGroup) => {
            this.buildSavedConnectionGroup(group.id, group.name, group.expanded, true)
          }, (group: SavedConnectionGroup) => `${group.id}-${this.savedConnectionsVersion}`)
        }
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .shadow({ radius: 16, color: this.isDarkMode ? '#44000000' : '#15345A84', offsetX: 0, offsetY: 6 })
    .margin({ bottom: 18 })
  }

  @Builder
  buildSavedConnectionGroup(groupId: string, groupName: string, expanded: boolean, canRename: boolean) {
    Column() {
      Row({ space: 6 }) {
        Button() {
          Image((groupId.length <= 0 ? this.ungroupedExpanded : expanded) ?
            $r('app.media.group_chevron_up') : $r('app.media.group_chevron_down'))
            .width(12)
            .height(12)
            .objectFit(ImageFit.Contain)
        }
          .width(44)
          .height(34)
          .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .onClick(() => {
            this.toggleConnectionGroup(groupId)
          })
        Text(groupName)
          .fontSize(14)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.connectionsForGroup(groupId).length}`)
          .fontSize(11)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.isDarkMode ? '#29364A' : '#E7EEF9')
          .borderRadius(8)
        Blank()
        if (canRename) {
          Button('重命名')
            .height(28)
            .fontSize(11)
            .fontColor(RustDeskTheme.ACCENT)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.openRenameGroupDialog(groupId)
            })
        }
      }
      .width('100%')
      .height(42)
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)

      if (groupId.length <= 0 ? this.ungroupedExpanded : expanded) {
        ForEach(this.connectionsForGroup(groupId), (item: SavedConnectionInfo) => {
          Row({ space: 8 }) {
            Stack() {
              Column() {
                Text(item.name.length > 0 ? item.name.substring(0, 1).toUpperCase() : 'R')
                  .fontSize(15)
                  .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
                  .fontColor(RustDeskTheme.ACCENT)
              }
              .width(36)
              .height(36)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor(this.isDarkMode ? '#26364E' : RustDeskTheme.ACCENT_SOFT)
              .borderRadius(6)

              Row()
                .width(10)
                .height(10)
                .backgroundColor(this.peerOnlineStateColor(item.remoteId))
                .border({ width: 2, color: this.isDarkMode ? '#1E2938' : '#F7F9FD' })
                .borderRadius(5)
                .position({ x: 27, y: 27 })
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
              Text(this.peerOnlineStateHint(item.remoteId))
                .fontSize(10)
                .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
                .width('100%')
                .maxLines(2)
            }
            .layoutWeight(1)

            Button('连接')
              .height(32)
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor(RustDeskTheme.ACCENT)
              .borderRadius(6)
              .onClick(() => {
                this.connectSavedConnection(item)
              })

            Button('更多')
              .height(32)
              .fontSize(12)
              .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
              .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.SURFACE_MUTED)
              .borderRadius(6)
              .bindMenu([
                {
                  value: '移动到分组',
                  action: () => {
                    this.openGroupPickerForConnection(item.id)
                  }
                },
                {
                  value: '修改连接',
                  action: () => {
                    this.editSavedConnection(item)
                  }
                },
                {
                  value: '删除连接',
                  action: () => {
                    this.deleteSavedConnection(item.id)
                  }
                }
              ], {
                placement: Placement.BottomRight,
                enableArrow: true
              })
          }
          .width('100%')
          .height(58)
          .padding({ left: 8, right: 4 })
          .border({ width: { bottom: 1 }, color: this.isDarkMode ? '#303B4D' : RustDeskTheme.DIVIDER })
        }, (item: SavedConnectionInfo) =>
          `${item.id}-${this.savedConnectionsVersion}-${this.peerOnlineStatesVersion}`)
      }
    }
    .width('100%')
    .margin({ top: 4 })
    .backgroundColor(this.isDarkMode ? '#1E2938' : '#F7F9FD')
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(7)
  }

  @Builder
  buildGroupNameDialog() {
    Column({ space: 14 }) {
      Text(this.editingGroupId.length > 0 ? '重命名分组' : '新建分组')
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      TextInput({ placeholder: '输入分组名称', text: this.groupNameDraft })
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .border({ width: 1, color: this.groupNameError.length > 0 ? RustDeskTheme.ERROR : (this.isDarkMode ? '#303B4D' : '#DEE6F1') })
        .borderRadius(7)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.groupNameDraft = value
          this.groupNameError = ''
        })

      if (this.groupNameError.length > 0) {
        Text(this.groupNameError)
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
          .onClick(() => {
            this.closeGroupDialogs()
          })
        Button(this.editingGroupId.length > 0 ? '保存名称' : '创建')
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
          .onClick(() => {
            this.saveGroupName()
          })
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 420 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#3A465A' : '#DDE5F0' })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildGroupPickerDialog() {
    Column({ space: 12 }) {
      Row() {
        Text(this.groupPickerForForm ? '选择保存分组' : '移动连接到分组')
          .fontSize(19)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Button('关闭')
          .height(30)
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.closeGroupDialogs()
          })
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

      Button('+ 新建分组')
        .width('100%')
        .height(40)
        .fontColor(RustDeskTheme.ACCENT)
        .backgroundColor(this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT)
        .borderRadius(6)
        .onClick(() => {
          this.openNewGroupDialog(this.groupPickerForForm, this.groupPickerForForm ? '' : this.groupPickerConnectionId)
        })
    }
    .width(this.pageWidth >= 820 ? 420 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#3A465A' : '#DDE5F0' })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildBackupPasswordDialog() {
    Column({ space: 12 }) {
      Text(this.backupPasswordMode === 'export' ? '设置备份密码' : '输入备份密码')
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(this.backupPasswordMode === 'export' ?
        '连接密码将被加密写入备份。备份密码不会保存在应用中，忘记后无法恢复。' :
        '请输入创建该加密备份时设置的密码。')
        .fontSize(13)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      TextInput({ placeholder: '至少 8 位备份密码', text: this.backupPasswordDraft })
        .type(InputType.Password)
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .border({ width: 1, color: this.backupPasswordError.length > 0 ? RustDeskTheme.ERROR : (this.isDarkMode ? '#303B4D' : '#DEE6F1') })
        .borderRadius(7)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.backupPasswordDraft = value
          this.backupPasswordError = ''
        })

      if (this.backupPasswordMode === 'export') {
        TextInput({ placeholder: '再次输入备份密码', text: this.backupPasswordConfirm })
          .type(InputType.Password)
          .width('100%')
          .height(46)
          .fontSize(15)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .placeholderColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .border({ width: 1, color: this.backupPasswordError.length > 0 ? RustDeskTheme.ERROR : (this.isDarkMode ? '#303B4D' : '#DEE6F1') })
          .borderRadius(7)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.backupPasswordConfirm = value
            this.backupPasswordError = ''
          })
      }

      if (this.backupPasswordError.length > 0) {
        Text(this.backupPasswordError)
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
          .onClick(() => {
            this.closeBackupDialogs()
          })
        Button(this.backupBusy ? '处理中…' : (this.backupPasswordMode === 'export' ? '加密并导出' : '解密'))
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(this.backupBusy ? RustDeskTheme.DARK_GRAY : RustDeskTheme.ACCENT)
          .borderRadius(6)
          .onClick(() => {
            this.confirmBackupPassword()
          })
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 440 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#3A465A' : '#DDE5F0' })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildImportPreviewDialog() {
    Column({ space: 12 }) {
      Text('确认导入连接')
        .fontSize(19)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(`备份包含 ${this.importPreviewGroupCount} 个分组、${this.importPreviewConnectionCount} 个连接`)
        .fontSize(14)
        .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      Text(this.importPreviewIncludesPasswords ?
        '这是加密备份，连接密码将恢复到系统安全凭据库。' :
        '普通备份不包含密码；新增连接需要重新填写密码。')
        .fontSize(12)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .width('100%')

      Row({ space: 4 }) {
        Button('合并导入')
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontColor(!this.importReplaceExisting ? Color.White :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
          .backgroundColor(!this.importReplaceExisting ? RustDeskTheme.ACCENT : Color.Transparent)
          .borderRadius(5)
          .onClick(() => {
            this.importReplaceExisting = false
          })
        Button('覆盖现有')
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontColor(this.importReplaceExisting ? Color.White :
            (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
          .backgroundColor(this.importReplaceExisting ? RustDeskTheme.ACCENT : Color.Transparent)
          .borderRadius(5)
          .onClick(() => {
            this.importReplaceExisting = true
          })
      }
      .width('100%')
      .padding(3)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
      .borderRadius(7)

      if (this.importReplaceExisting) {
        Text('覆盖后，当前已保存的连接、分组和连接密码将被替换。')
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      } else {
        Text('相同远程 ID 会更新名称、分组和连接模式，并优先保留本机已有密码。')
          .fontSize(12)
          .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
          .onClick(() => {
            this.closeBackupDialogs()
          })
        Button(this.backupBusy ? '导入中…' : '开始导入')
          .layoutWeight(1)
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(this.backupBusy ? RustDeskTheme.DARK_GRAY : RustDeskTheme.ACCENT)
          .borderRadius(6)
          .onClick(() => {
            this.importPreparedBackup()
          })
      }
      .width('100%')
    }
    .width(this.pageWidth >= 820 ? 440 : '88%')
    .padding(20)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#3A465A' : '#DDE5F0' })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 8 })
    .zIndex(11)
  }

  @Builder
  buildGroupPickerOption(groupId: string, groupName: string) {
    Button() {
      Row() {
        Text(groupName)
          .fontSize(14)
          .fontColor(this.groupPickerCurrentGroupId() === groupId ? Color.White : (this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text(this.groupPickerCurrentGroupId() === groupId ? '✓' : '')
          .fontSize(16)
          .fontColor(Color.White)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height(42)
    .backgroundColor(this.groupPickerCurrentGroupId() === groupId ? RustDeskTheme.ACCENT : (this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED))
    .borderRadius(6)
    .onClick(() => {
      this.selectGroupFromPicker(groupId)
    })
  }

  @Builder
  buildConnectionEditActions() {
    Row({ space: 10 }) {
      Button(this.selectedConnectionId.length > 0 ? '保存修改' : '保存连接')
        .height(40)
        .layoutWeight(1)
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor(this.remoteId.trim().length > 0 ? RustDeskTheme.ACCENT : RustDeskTheme.DARK_GRAY)
        .borderRadius(6)
        .onClick(() => {
          this.saveCurrentConnection()
        })

      Button('新建')
        .height(40)
        .fontSize(14)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .borderRadius(6)
        .onClick(() => {
          this.clearConnectionForm()
        })
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
      Text(translate('Custom Server') + ': ' + this.customServerHint)
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
      Text('连接模式')
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
      .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
      .borderRadius(7)
    }
    .width('100%')
  }

  @Builder
  buildPresetButton(label: string, preset: string) {
    Button(label)
      .height(36)
      .layoutWeight(1)
      .fontSize(12)
      .fontColor(this.performancePreset === preset ? Color.White :
        (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
      .backgroundColor(this.performancePreset === preset ? RustDeskTheme.ACCENT : Color.Transparent)
      .borderRadius(5)
      .onClick(() => {
        this.performancePreset = preset
      })
  }

  onConnect(): void {
    let peerId: string = this.normalizeRemoteId(this.remoteId)
    this.remoteId = peerId
    this.isIdEmpty = peerId.length === 0
    let password: string = this.password.trim()
    let nativeStatus: ConnectionStatus = this.syncConnectionState()
    if (nativeStatus === ConnectionStatus.CONNECTED || nativeStatus === ConnectionStatus.WAITING_2FA) {
      // A user-triggered connect action means this page is currently visible.
      // Reopen an existing session instead of silently ignoring the tap when a
      // previous page transition left hasOpenedRemotePage set.
      this.hasOpenedRemotePage = true
      router.pushUrl({ url: 'pages/RemotePage' })
      return
    }
    if (password.length <= 0) {
      this.connectionStatusText = translate('Password is required')
      this.connectionStatusColor = RustDeskTheme.ERROR
      return
    }
    if (peerId.length > 0 && !this.isConnecting) {
      this.isConnecting = true
      this.connectionStatusText = translate('Connecting...')
      this.connectionStatusColor = RustDeskTheme.WARNING
      AppStorage.set<string>('connectedPeerId', peerId)
      let status: ConnectionStatus = ConnectionService.connect(peerId, password, this.performancePreset)
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
      this.connectionFormExpanded = RustDeskNapi.getOption('connection-form-expanded') !== '0'
    } catch (_error) {
      this.connectionFormExpanded = true
    }
  }

  setConnectionFormExpanded(expanded: boolean): void {
    this.connectionFormExpanded = expanded
    RustDeskNapi.setOption('connection-form-expanded', expanded ? '1' : '0')
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
    } catch (_error) {
      this.savedConnectionSort = 'id'
    }
  }

  setSavedConnectionSort(mode: string): void {
    this.savedConnectionSort = mode === 'name' || mode === 'online' ? mode : 'id'
    RustDeskNapi.setOption('saved-connections-sort', this.savedConnectionSort)
    this.savedConnectionsVersion++
  }

  compareSavedConnectionIds(left: string, right: string): number {
    // Match RustDesk's ID string ordering, including IDs of different lengths.
    return left < right ? -1 : left > right ? 1 : 0
  }

  savedConnectionOnlineRank(remoteId: string): number {
    const state: number = this.peerOnlineStates[remoteId] ?? PEER_STATE_CHECKING
    return state === PEER_STATE_ONLINE ? 0 : state === PEER_STATE_OFFLINE ? 1 : 2
  }

  compareSavedConnections(left: SavedConnectionInfo, right: SavedConnectionInfo): number {
    if (this.savedConnectionSort === 'online') {
      const rank: number = this.savedConnectionOnlineRank(left.remoteId) -
        this.savedConnectionOnlineRank(right.remoteId)
      if (rank !== 0) return rank
    }
    if (this.savedConnectionSort === 'name' || this.savedConnectionSort === 'online') {
      const leftName: string = (left.name.trim() || left.remoteId).toLowerCase()
      const rightName: string = (right.name.trim() || right.remoteId).toLowerCase()
      const nameOrder: number = leftName.localeCompare(rightName, 'zh-CN')
      if (nameOrder !== 0) return nameOrder
    }
    const idOrder: number = this.compareSavedConnectionIds(left.remoteId, right.remoteId)
    return idOrder !== 0 ? idOrder : this.compareSavedConnectionIds(left.id, right.id)
  }

  connectionsForGroup(groupId: string): SavedConnectionInfo[] {
    let result: SavedConnectionInfo[] = []
    this.savedConnections.forEach((item: SavedConnectionInfo) => {
      if (this.validGroupId(item.groupId) === groupId) {
        result.push(item)
      }
    })
    // Sort only a display copy; keep groups, credentials and backup order intact.
    return result.sort((left: SavedConnectionInfo, right: SavedConnectionInfo) =>
      this.compareSavedConnections(left, right))
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
      this.ungroupedExpanded = !this.ungroupedExpanded
      RustDeskNapi.setOption('saved-connections-ungrouped-expanded', this.ungroupedExpanded ? '1' : '0')
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
    this.connectionGroups = groups
    this.savedConnectionsVersion++
    this.persistConnectionGroups()
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
    this.closeGroupDialogs()
    this.closeBackupDialogs()
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
      promptAction.showToast({ message: '暂无可导出的连接' })
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
      promptAction.showToast({ message: '暂无可导出的连接' })
      return
    }
    this.backupBusy = true
    try {
      let payload: ConnectionBackupPayload = this.buildBackupPayload(false)
      let content: string = ConnectionBackupService.createPlainText(payload)
      await this.saveBackupFile(content, `StarRustDesk连接备份-${this.backupTimestamp()}.json`)
      promptAction.showToast({ message: '连接已导出，备份中不包含密码' })
    } catch (_error) {
      promptAction.showToast({ message: '导出失败，请重新选择保存位置' })
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
        promptAction.showToast({ message: '加密备份导出成功，请妥善保管备份密码' })
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
      promptAction.showToast({ message: '无法读取备份，请确认文件格式正确' })
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
      promptAction.showToast({ message: `已导入 ${importedCount} 个连接` })
    } catch (_error) {
      this.backupBusy = false
      promptAction.showToast({ message: '导入失败，请检查备份后重试' })
    }
  }

  async replaceConnectionsFromBackup(payload: ConnectionBackupPayload): Promise<number> {
    let oldConnections: SavedConnectionInfo[] = this.cloneSavedConnections(this.savedConnections)
    let imported: NormalizedImportData = this.normalizeImportedData(payload, [], [])
    for (let item of oldConnections) {
      await CredentialStore.remove(item.id)
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
    return value === 'stable' || value === 'high_fps' || value === 'silky' || value === 'smooth' ? value : 'smooth'
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
            performancePreset: row['performancePreset'] ?? 'smooth',
            groupId: this.validGroupId(row['groupId'] ?? '')
          })
        }
      }
      this.savedConnections = this.cloneSavedConnections(list)
      this.savedConnectionsVersion++
      this.persistSavedConnections(list)
      RustDeskNapi.setOption('password', '')
      this.nextPeerOnlineRefreshAt = 0
      this.refreshSavedConnectionOnlineStates(true)
    } catch (_e) {
      this.savedConnections = []
      this.savedConnectionsVersion++
    }
  }

  persistSavedConnections(list: SavedConnectionInfo[]): void {
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
  }

  refreshSavedConnectionOnlineStates(force: boolean = false): void {
    if (this.peerOnlineQueryInFlight || this.savedConnections.length <= 0) {
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
    let result: number = RustDeskNapi.queryPeerOnlineStates(peerIds, this.customServerHint)
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
      if (result.server !== this.customServerHint.trim()) {
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
    this.password = item.password
    this.performancePreset = item.performancePreset.length > 0 ? item.performancePreset : 'smooth'
    this.selectedGroupId = this.validGroupId(item.groupId)
    this.isIdEmpty = this.remoteId.length === 0
  }

  connectSavedConnection(item: SavedConnectionInfo): void {
    this.applySavedConnection(item)
    this.onConnect()
  }

  async saveCurrentConnection(): Promise<void> {
    let peerId: string = this.normalizeRemoteId(this.remoteId)
    let password: string = this.password.trim()
    if (peerId.length <= 0) {
      return
    }
    let savedName: string = this.connectionName.trim()
    let targetId: string = this.selectedConnectionId.length > 0 ? this.selectedConnectionId : this.makeConnectionId(peerId)
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
    this.savedConnections = this.cloneSavedConnections(list)
    this.savedConnectionsVersion++
    this.selectedConnectionId = targetId
    await CredentialStore.save(targetId, password)
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
    this.performancePreset = 'smooth'
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
