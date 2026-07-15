import { router } from '@kit.ArkUI'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { ConnectionService } from '../service/ConnectionService'
import { ConnectionStatus } from '../model/ConnectionModel'
import { RustDeskNapi } from '../service/RustDeskNapi'
import { CredentialStore } from '../service/CredentialStore'

interface SavedConnectionInfo {
  id: string
  name: string
  remoteId: string
  password: string
  performancePreset: string
}

interface SavedConnectionRow {
  id: string
  name: string
  remoteId: string
  credentialAlias: string
  performancePreset: string
}

@Component
export struct ConnectionPage {
  @State connectionName: string = ''
  @State remoteId: string = ''
  @State password: string = ''
  @State isIdEmpty: boolean = true
  @State isConnecting: boolean = false
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
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
  @State savedConnectionsVersion: number = 0
  private statusTimer: number = -1

  aboutToAppear(): void {
    this.checkServerConfig()
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
    this.isUsingPublicServer = RustDeskNapi.isUsingPublicServer()
    let idServer: string = RustDeskNapi.getOption('custom-rendezvous-server')
    if (idServer.length > 0) {
      this.customServerHint = idServer
    } else {
      this.customServerHint = ''
    }
  }

  startStatusPolling(): void {
    let poll = () => {
      let status: ConnectionStatus = this.syncConnectionState()
      if (status === ConnectionStatus.CONNECTED) {
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
    this.connectionStatusValue = status
    if (status === ConnectionStatus.CONNECTING) {
      this.connectionStatusText = translate('Connecting...')
      this.connectionStatusColor = RustDeskTheme.WARNING
      this.isConnecting = true
    } else if (status === ConnectionStatus.CONNECTED) {
      this.connectionStatusText = translate('Connected')
      this.connectionStatusColor = RustDeskTheme.SUCCESS
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
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        if (this.showUpdateBanner) {
          this.buildUpdateBanner()
        }
        this.buildPageHeader()
        Scroll() {
          if (this.pageWidth >= 820) {
            Row({ space: 18 }) {
              Column() {
                this.buildSavedConnections()
              }
              .layoutWeight(1)
              .height('100%')

              Column() {
                this.buildConnectionForm()
              }
              .layoutWeight(1.2)
              .height('100%')
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            Column({ space: 14 }) {
              this.buildSavedConnections()
              this.buildConnectionForm()
            }
            .width('100%')
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .padding({ left: this.pageWidth >= 820 ? 32 : RustDeskTheme.PAGE_PADDING, right: this.pageWidth >= 820 ? 32 : RustDeskTheme.PAGE_PADDING })
      .alignItems(HorizontalAlign.Center)
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

      this.buildRemoteIdInput()
      this.buildConnectionNameInput()
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
        TextInput({ placeholder: translate('Remote ID'), text: this.remoteId })
          .type(InputType.Normal)
          .maxLength(12)
          .fontSize(RustDeskTheme.FONT_SIZE_ID)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(RustDeskTheme.ID_COLOR)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.remoteId = value
            this.isIdEmpty = value.length === 0
          })

        if (!this.isIdEmpty) {
          Button({ type: ButtonType.Circle }) {
            Text('✕')
              .fontSize(14)
              .fontColor(Color.White)
          }
          .width(24)
          .height(24)
          .backgroundColor(RustDeskTheme.DARK_GRAY)
          .onClick(() => {
            this.remoteId = ''
            this.isIdEmpty = true
          })
          .transition(TransitionEffect.OPACITY)
        }

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
  buildPasswordInput() {
    TextInput({ placeholder: translate('Password'), text: this.password })
      .type(InputType.Password)
      .fontSize(RustDeskTheme.FONT_SIZE_BODY)
      .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
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
        Text('已保存连接')
          .fontSize(18)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(`${this.savedConnections.length} 个设备`)
          .fontSize(12)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
      }
      .width('100%')
      .margin({ bottom: 2 })

      if (this.savedConnections.length === 0) {
        Column({ space: 8 }) {
          Text('暂无保存的连接')
            .fontSize(15)
            .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_PRIMARY)
          Text('连接信息会安全保存在本机')
            .fontSize(12)
            .fontColor(RustDeskTheme.TEXT_SECONDARY)
        }
        .width('100%')
        .height(112)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
        .borderRadius(6)
      } else {
        ForEach(this.savedConnections, (item: SavedConnectionInfo) => {
          Row({ space: 8 }) {
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
                .fontColor(RustDeskTheme.TEXT_SECONDARY)
                .width('100%')
            }
            .layoutWeight(1)

            Button('使用')
              .height(32)
              .fontSize(12)
              .fontColor(item.id === this.selectedConnectionId ? Color.White : RustDeskTheme.ACCENT)
              .backgroundColor(item.id === this.selectedConnectionId ? RustDeskTheme.ACCENT : (this.isDarkMode ? '#29364A' : RustDeskTheme.ACCENT_SOFT))
              .borderRadius(6)
              .onClick(() => {
                this.applySavedConnection(item)
              })

            Button('删除')
              .height(32)
              .fontSize(12)
              .fontColor(RustDeskTheme.ERROR)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.deleteSavedConnection(item.id)
              })
          }
          .width('100%')
          .height(58)
          .padding({ left: 8, right: 4 })
          .border({ width: { bottom: 1 }, color: this.isDarkMode ? '#303B4D' : RustDeskTheme.DIVIDER })
        }, (item: SavedConnectionInfo) => `${item.id}-${this.savedConnectionsVersion}`)
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
        .fontColor(RustDeskTheme.TEXT_SECONDARY)
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
        .fontColor(RustDeskTheme.TEXT_SECONDARY)
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
        .fontColor(RustDeskTheme.TEXT_SECONDARY)
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
      .fontColor(this.performancePreset === preset ? Color.White : RustDeskTheme.TEXT_SECONDARY)
      .backgroundColor(this.performancePreset === preset ? RustDeskTheme.ACCENT : Color.Transparent)
      .borderRadius(5)
      .onClick(() => {
        this.performancePreset = preset
      })
  }

  onConnect(): void {
    let peerId: string = this.remoteId.trim()
    let password: string = this.password.trim()
    let nativeStatus: ConnectionStatus = this.syncConnectionState()
    if (nativeStatus === ConnectionStatus.CONNECTED) {
      if (!this.hasOpenedRemotePage) {
        this.hasOpenedRemotePage = true
        router.pushUrl({ url: 'pages/RemotePage' })
      }
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
        let remoteId: string = (row['remoteId'] ?? '').trim()
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
            performancePreset: row['performancePreset'] ?? 'smooth'
          })
        }
      }
      this.savedConnections = this.cloneSavedConnections(list)
      this.savedConnectionsVersion++
      this.persistSavedConnections(list)
      RustDeskNapi.setOption('password', '')
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
        performancePreset: item.performancePreset
      })
    })
    RustDeskNapi.setOption('saved-connections', JSON.stringify(rows))
  }

  applySavedConnection(item: SavedConnectionInfo): void {
    this.selectedConnectionId = item.id
    this.connectionName = item.name
    this.remoteId = item.remoteId
    this.password = item.password
    this.performancePreset = item.performancePreset.length > 0 ? item.performancePreset : 'smooth'
    this.isIdEmpty = this.remoteId.length === 0
  }

  async saveCurrentConnection(): Promise<void> {
    let peerId: string = this.remoteId.trim()
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
      performancePreset: this.performancePreset
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
  }

  clearConnectionForm(): void {
    this.selectedConnectionId = ''
    this.connectionName = ''
    this.remoteId = ''
    this.password = ''
    this.performancePreset = 'smooth'
    this.isIdEmpty = true
  }

  makeConnectionId(remoteId: string): string {
    return `${remoteId}-${Date.now()}`
  }

  cloneSavedConnections(list: SavedConnectionInfo[]): SavedConnectionInfo[] {
    let cloned: SavedConnectionInfo[] = []
    list.forEach((item: SavedConnectionInfo) => {
      cloned.push({
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        password: item.password,
        performancePreset: item.performancePreset
      })
    })
    return cloned
  }
}
