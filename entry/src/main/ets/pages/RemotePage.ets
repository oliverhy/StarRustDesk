import { router } from '@kit.ArkUI';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { translate } from '../utils/I18n';
import { ConnectionStatus } from '../model/ConnectionModel';
import { ConnectionService } from '../service/ConnectionService';
import { FileTransferStatus, RemoteDirectoryEntry, RemoteDirectoryResult, RustDeskNapi, VideoFrameInfo } from '../service/RustDeskNapi';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

interface RemotePoint {
  x: number;
  y: number;
}

const REMOTE_WHEEL_SCALE: number = 0.08;
const LOG_DOMAIN: number = 0x0000;

@Entry
@Component
struct RemotePage {
  @State connectionStatus: ConnectionStatus = ConnectionStatus.DISCONNECTED;
  @State showToolbar: boolean = true;
  @State zoomScale: number = 1.0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State toolbarOpacity: number = 1.0;
  @State hasVideo: boolean = false;
  @State remoteWidth: number = 1920;
  @State remoteHeight: number = 1080;
  @State componentWidth: number = 0;
  @State componentHeight: number = 0;
  @State lastAbsX: number = 0;
  @State lastAbsY: number = 0;
  @State showKeyboardPanel: boolean = false;
  @State keyboardInput: string = '';
  @State showCursor: boolean = false;
  @State cursorX: number = 0;
  @State cursorY: number = 0;
  @State surfaceId: string = '';
  @State surfaceEpoch: number = 0;
  @State showRemoteSurface: boolean = true;
  @State displayCount: number = 1;
  @State currentDisplay: number = 0;
  @State fpsText: string = '0 fps';
  @State speedText: string = '0 KB/s';
  @State routeText: string = '未知';
  @State pageWidth: number = 0;
  @State clipboardSyncEnabled: boolean = true;
  @State showRemoteFileBrowser: boolean = false;
  @State remoteDirectoryPath: string = '';
  @State remoteDirectoryEntries: RemoteDirectoryEntry[] = [];
  @State remoteDirectoryLoading: boolean = false;
  @State transferProgress: number = 0;
  @State transferActive: boolean = false;
  @State connectedPeerId: string = '';
  private xComponentController: XComponentController = new XComponentController();
  private toolbarTimer: number = -1;
  private statusTimer: number = -1;
  private frameTimer: number = -1;
  private clipboardTimer: number = -1;
  private surfaceRebindTimer: number = -1;
  private remoteDirectoryTimer: number = -1;
  private longPressTimer: number = -1;
  private tapTimer: number = -1;
  private longPressTriggered: boolean = false;
  private pendingTapRemoteX: number = 0;
  private pendingTapRemoteY: number = 0;
  private pendingTapLocalX: number = 0;
  private pendingTapLocalY: number = 0;
  private pinchStartDistance: number = 0;
  private pinchStartScale: number = 1.0;
  private lastPinchCenterX: number = 0;
  private lastPinchCenterY: number = 0;
  private isPinching: boolean = false;
  private lastPinchEndedAt: number = 0;
  private ignoreTouchUntilNextDown: boolean = false;
  private lastStatsTime: number = 0;
  private lastStatsFrames: number = 0;
  private lastStatsBytes: number = 0;
  private smoothFps: number = 0;
  private smoothKbps: number = 0;
  private lastMoveSentAt: number = 0;
  private lastMouseEventAt: number = 0;
  private lastPinchUpdateAt: number = 0;
  private lastWheelSentAt: number = 0;
  private wheelRemainderX: number = 0;
  private wheelRemainderY: number = 0;
  private lastDisplayPollAt: number = 0;
  // The remote peer reports its current display in the login response, but it
  // does not continuously acknowledge display switches. Keep the user's local
  // selection after the initial sync instead of overwriting it during polling.
  private displayStateInitialized: boolean = false;
  private connectingStartedAt: number = 0;
  private lastSurfaceWidth: number = 0;
  private lastSurfaceHeight: number = 0;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private clipboardPolling: boolean = false;
  private lastLocalClipboardText: string = '';
  private lastRemoteClipboardText: string = '';
  private suppressClipboardText: string = '';
  private clipboardBaselineInitialized: boolean = false;
  private isLeavingAfterDisconnect: boolean = false;
  private pendingUploadPath: string = '';
  private pendingUploadName: string = '';

  aboutToAppear(): void {
    this.connectedPeerId = AppStorage.get<string>('connectedPeerId') ?? '';
    let status: number = RustDeskNapi.getConnectionStatus();
    this.connectionStatus = status as ConnectionStatus;
    this.connectingStartedAt = status === ConnectionStatus.CONNECTING ? Date.now() : 0;
    this.startPolling();
  }

  aboutToDisappear(): void {
    if (this.toolbarTimer !== -1) { clearTimeout(this.toolbarTimer); }
    if (this.statusTimer !== -1) { clearTimeout(this.statusTimer); }
    if (this.frameTimer !== -1) { clearTimeout(this.frameTimer); }
    if (this.surfaceRebindTimer !== -1) { clearTimeout(this.surfaceRebindTimer); }
    if (this.remoteDirectoryTimer !== -1) { clearTimeout(this.remoteDirectoryTimer); }
    this.stopClipboardSync();
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.cleanupPendingUploadFile();
  }

  cleanupPendingUploadFile(): void {
    if (this.pendingUploadPath.length === 0) return;
    try {
      fileIo.unlinkSync(this.pendingUploadPath);
    } catch (_e) {
    }
    this.pendingUploadPath = '';
  }

  startPolling(): void {
    let poll = () => {
      let status: number = RustDeskNapi.getConnectionStatus();
      let now: number = Date.now();
      if (status === ConnectionStatus.CONNECTING) {
        if (this.connectingStartedAt === 0) {
          this.connectingStartedAt = now;
        } else if (now - this.connectingStartedAt > 30000) {
          ConnectionService.disconnect();
          status = ConnectionStatus.FAILED;
        }
      } else {
        this.connectingStartedAt = 0;
      }
      this.connectionStatus = status as ConnectionStatus;
      if (status === ConnectionStatus.CONNECTED && now - this.lastDisplayPollAt > 2000) {
        this.lastDisplayPollAt = now;
        this.displayCount = Math.max(1, RustDeskNapi.getDisplayCount());
        if (!this.displayStateInitialized) {
          // Always start a new remote session on the first display, regardless
          // of which display the remote peer reported as currently active.
          this.currentDisplay = 0;
          this.displayStateInitialized = true;
          const switchResult: number = RustDeskNapi.switchDisplay(0);
          if (switchResult === 0) {
            RustDeskNapi.refreshVideo();
          } else {
            hilog.error(LOG_DOMAIN, 'StarRustDesk', `Initial display switch failed result=${switchResult}`);
          }
        }
        this.updateConnectionRoute();
      }
      if (status === ConnectionStatus.CONNECTED) {
        this.ensureClipboardSyncRunning();
        this.pollFileTransferStatus();
      }
      if (status !== ConnectionStatus.CONNECTED) {
        this.displayStateInitialized = false;
        this.hasVideo = false;
        this.routeText = '未连接';
        this.pauseClipboardSync();
      }
      this.statusTimer = setTimeout(poll, 1000);
    };
    this.statusTimer = setTimeout(poll, 200);
  }

  onSurfaceReady(): void {
    let surfaceId: string = this.xComponentController.getXComponentSurfaceId();
    this.surfaceId = surfaceId;
    this.bindSurfaceIfReady();
    this.startFramePolling();
    // Get component size for coordinate mapping
    let ctx = this.xComponentController.getXComponentContext();
    if (ctx != undefined) {
      // XComponent size is typically full screen
    }
  }

  onAreaChangeCallback(oldValue: Area, newValue: Area): void {
    this.componentWidth = newValue.width as number;
    this.componentHeight = newValue.height as number;
    if (this.lastSurfaceWidth <= 0 || this.lastSurfaceHeight <= 0) {
      this.lastSurfaceWidth = this.componentWidth;
      this.lastSurfaceHeight = this.componentHeight;
      this.bindSurfaceIfReady();
      return;
    }
    this.scheduleSurfaceRebindIfSizeChanged();
  }

  startFramePolling(): void {
    let poll = () => {
      let frame: VideoFrameInfo = RustDeskNapi.getVideoFrame();
      if (frame.hasFrame) {
        if (!this.hasVideo) {
          this.hasVideo = true;
        }
        this.updateStats(frame);
        if (frame.width > 0 && frame.height > 0 && (frame.width !== this.remoteWidth || frame.height !== this.remoteHeight)) {
          this.remoteWidth = frame.width;
          this.remoteHeight = frame.height;
        }
      }
      this.frameTimer = setTimeout(poll, 250);
    };
    // Start polling after a short delay to allow surface to be ready
    setTimeout(() => {
      this.frameTimer = setTimeout(poll, 250);
    }, 2000);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.connectionStatus === ConnectionStatus.DISCONNECTED) {
          this.buildDisconnectedView();
        } else if (this.connectionStatus === ConnectionStatus.CONNECTING) {
          this.buildConnectingView();
        } else if (this.connectionStatus === ConnectionStatus.CONNECTED) {
          this.buildRemoteScreen();
        } else {
          this.buildErrorView();
        }
      }
      .width('100%')
      .height('100%');

      if (this.showRemoteFileBrowser) {
        this.buildRemoteFileBrowser();
      }
      if (this.transferActive && !this.showRemoteFileBrowser) {
        this.buildTransferProgress();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E7EEF8')
    .focusable(true)
    .onKeyEventDispatch((event: KeyEvent) => {
      return this.handleRemoteKey(event);
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.pageWidth = newValue.width as number;
      this.scheduleSurfaceRebindIfSizeChanged();
    });
  }

  @Builder
  buildDisconnectedView() {
    Column({ space: 12 }) {
      Text('StarRustDesk')
        .fontSize(28)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .fontColor(RustDeskTheme.TEXT_PRIMARY);
      Text(translate('No active connection'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE).fontColor(RustDeskTheme.TEXT_PRIMARY);
      Text(translate('Enter a Remote ID to connect'))
        .fontSize(RustDeskTheme.FONT_SIZE_SMALL).fontColor(RustDeskTheme.TEXT_SECONDARY);
      Button(translate('Back')).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).borderRadius(6)
        .onClick(() => { router.back(); });
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  buildConnectingView() {
    Column({ space: 14 }) {
      LoadingProgress().width(42).height(42).color(RustDeskTheme.ACCENT);
      Text('正在连接远端设备')
        .fontSize(20)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(RustDeskTheme.TEXT_PRIMARY);
      Text(this.connectedPeerId.length > 0 ? this.connectedPeerId : translate('Connecting'))
        .fontSize(13)
        .fontColor(RustDeskTheme.TEXT_SECONDARY);
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  buildRemoteScreen() {
    if (this.isLargeLayout()) {
      Row() {
        Column() {
          this.buildStatsPanel();
          this.buildRemoteViewport();
          if (this.showKeyboardPanel) {
            this.buildKeyboardPanel();
          }
        }
        .layoutWeight(1)
        .height('100%')

        this.buildSideToolbar();
      }
      .width('100%').height('100%')
      .backgroundColor('#DCE5F2');
    } else {
      Column() {
        this.buildStatsPanel();
        this.buildRemoteViewport();
        if (this.showKeyboardPanel) {
          this.buildKeyboardPanel();
        }
        this.buildFloatingToolbar();
      }
      .width('100%').height('100%')
      .backgroundColor('#DCE5F2');
    }
  }

  @Builder
  buildRemoteFileBrowser() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Button('上一级')
            .height(40)
            .fontColor(RustDeskTheme.ACCENT)
            .backgroundColor(RustDeskTheme.ACCENT_SOFT)
            .borderRadius(8)
            .enabled(!this.remoteDirectoryLoading)
            .onClick(() => {
              this.openRemoteDirectory(this.getRemoteParentPath());
            })
          Text(this.remoteDirectoryPath === '/' ? '此电脑' : this.remoteDirectoryPath)
            .layoutWeight(1)
            .fontSize(15)
            .fontColor(RustDeskTheme.TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        if (this.remoteDirectoryLoading) {
          Column() {
            LoadingProgress().width(40).height(40).color(RustDeskTheme.ACCENT)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 2 }) {
            ForEach(this.getRemoteFolders(), (entry: RemoteDirectoryEntry) => {
              ListItem() {
                Row({ space: 12 }) {
                  Text(entry.entryType === 3 ? '磁盘' : '文件夹')
                    .fontSize(12)
                    .fontColor(RustDeskTheme.TEXT_SECONDARY)
                    .width(52)
                  Text(entry.name)
                    .layoutWeight(1)
                    .fontSize(15)
                    .fontColor(RustDeskTheme.TEXT_PRIMARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .height(48)
                .padding({ left: 12, right: 12 })
                .onClick(() => {
                  this.openRemoteDirectory(this.joinRemotePath(entry.name));
                })
              }
            }, (entry: RemoteDirectoryEntry) => `${entry.entryType}:${entry.name}`)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 1, color: RustDeskTheme.DIVIDER })
        }

        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .borderRadius(8)
            .fontColor(RustDeskTheme.TEXT_PRIMARY)
            .backgroundColor(RustDeskTheme.SURFACE_MUTED)
            .onClick(() => {
              this.closeRemoteFileBrowser(true);
            })
          Button('发送到这里')
            .layoutWeight(1)
            .height(42)
            .borderRadius(8)
            .enabled(this.remoteDirectoryPath.length > 0 && this.remoteDirectoryPath !== '/' && !this.remoteDirectoryLoading)
            .backgroundColor(RustDeskTheme.ACCENT)
            .onClick(() => {
              this.startPendingFileUpload();
            })
        }
        .width('100%')
      }
      .width(this.isLargeLayout() ? 560 : '92%')
      .height(this.isLargeLayout() ? '78%' : '84%')
      .padding(16)
      .backgroundColor(Color.White)
      .border({ width: 1, color: '#DEE6F1' })
      .borderRadius(8)
      .shadow({ radius: 28, color: '#500C1524', offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  @Builder
  buildTransferProgress() {
    Row({ space: 10 }) {
      Text('正在发送文件')
        .fontSize(13)
        .fontColor(RustDeskTheme.TEXT_PRIMARY)
      Progress({ value: this.transferProgress, total: 100, type: ProgressType.Linear })
        .layoutWeight(1)
        .height(6)
        .color(RustDeskTheme.ACCENT)
      Text(`${Math.floor(this.transferProgress)}%`)
        .width(44)
        .fontSize(13)
        .fontColor(RustDeskTheme.TEXT_PRIMARY)
        .textAlign(TextAlign.End)
    }
    .width(this.isLargeLayout() ? 420 : '88%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .backgroundColor(Color.White)
    .border({ width: 1, color: '#DEE6F1' })
    .borderRadius(8)
    .position({ x: this.isLargeLayout() ? 24 : '6%', y: 16 })
  }

  @Builder
  buildRemoteViewport() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.showRemoteSurface) {
        XComponent({
          id: 'remoteScreen' + this.surfaceEpoch.toString(),
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .width(this.getDisplayWidth())
          .height(this.getDisplayHeight())
          .onLoad(() => {
            this.onSurfaceReady();
          })
          .onTouch((event: TouchEvent) => {
            this.handleRemoteTouch(event);
          })
        .onMouse((event: MouseEvent) => {
          this.handleRemoteMouse(event);
        })
        .onAxisEvent((event: AxisEvent) => {
          this.handleRemoteAxis(event);
        })
      }

      Stack()
        .id('remoteInputCapture')
        .width(this.getDisplayWidth())
        .height(this.getDisplayHeight())
        .backgroundColor('#01000000')
        .focusable(true)
        .defaultFocus(true)
        .focusOnTouch(true)
        .onClick(() => {
          this.requestRemoteInputFocus();
        })
        .onTouch((event: TouchEvent) => {
          this.handleRemoteTouch(event);
        })
        .onMouse((event: MouseEvent) => {
          this.handleRemoteMouse(event);
        })
        .onAxisEvent((event: AxisEvent) => {
          this.handleRemoteAxis(event);
        })
        .onKeyEvent((event: KeyEvent) => {
          return this.handleRemoteKey(event);
        })
        .onKeyEventDispatch((event: KeyEvent) => {
          return this.handleRemoteKey(event);
        })

      if (!this.hasVideo) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(42)
            .height(42)
            .color(RustDeskTheme.ACCENT)
          Text(translate('Connected'))
            .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
            .fontColor(Color.White)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          Text(translate('Remote Desktop'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(Color.Gray)
          Text(translate('Waiting for video stream...'))
            .fontSize(12)
            .fontColor(Color.Gray)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      }

      if (this.showCursor) {
        this.buildCursorOverlay();
      }
    }
    .width('100%')
    .layoutWeight(1)
    .clip(true)
    .backgroundColor('#090D14')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.componentWidth = newValue.width as number;
      this.componentHeight = newValue.height as number;
      this.scheduleSurfaceRebindIfSizeChanged();
    })
    .translate({ x: this.offsetX, y: this.offsetY })
    .scale({ x: this.zoomScale, y: this.zoomScale })
  }

  @Builder
  buildErrorView() {
    Column({ space: 14 }) {
      Text('连接失败')
        .fontSize(24)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .fontColor(RustDeskTheme.TEXT_PRIMARY);
      Text(translate('Connection failed')).fontSize(RustDeskTheme.FONT_SIZE_TITLE).fontColor(RustDeskTheme.ERROR);
      Button(translate('Retry')).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).borderRadius(8)
        .onClick(() => { router.back(); });
      Button(translate('Back')).fontColor(RustDeskTheme.TEXT_PRIMARY).backgroundColor(RustDeskTheme.SURFACE_MUTED).borderRadius(8)
        .onClick(() => { router.back(); });
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  buildFloatingToolbar() {
    Scroll() {
      Row({ space: 6 }) {
        if (this.displayCount > 1) {
          ForEach(this.makeDisplayIndexes(), (display: number) => {
            Button(`屏${display + 1}`)
              .width(54)
              .height(40)
              .padding({ left: 2, right: 2 })
              .fontSize(12)
              .fontWeight(display === this.currentDisplay ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
              .fontColor(display === this.currentDisplay ? Color.White : RustDeskTheme.TEXT_PRIMARY)
              .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : RustDeskTheme.SURFACE_MUTED)
              .borderRadius(6)
              .onClick(() => {
                this.switchDisplay(display);
              })
          }, (display: number) => `${display}-${this.currentDisplay}`)
        }
        this.buildToolbarButton('键盘', 64, this.showKeyboardPanel, false, true, () => {
          this.showKeyboardPanel = !this.showKeyboardPanel;
        })
        this.buildToolbarButton('输入', 64, false, false, true, () => {
          this.showKeyboardPanel = true;
        })
        this.buildToolbarButton('发送文件', 82, false, false, !this.transferActive, () => {
          this.pickFileForUpload();
        })
        this.buildToolbarButton(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关', 82, this.clipboardSyncEnabled, false, true, () => {
          this.toggleClipboardSync();
        })
        this.buildToolbarButton('+', 40, false, false, true, () => {
          this.zoomScale = Math.min(this.zoomScale + 0.25, 5.0);
        })
        this.buildToolbarButton('-', 40, false, false, true, () => {
          this.zoomScale = Math.max(this.zoomScale - 0.25, 0.5);
        })
        this.buildToolbarButton('断开', 64, false, true, true, () => {
          this.disconnectSession();
        })
      }
      .height(40)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .backgroundColor(Color.White)
    .border({ width: { top: 1 }, color: '#DEE6F1' })
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off);
  }

  @Builder
  buildSideToolbar() {
    Scroll() {
      Column({ space: 6 }) {
        if (this.displayCount > 1) {
          ForEach(this.makeDisplayIndexes(), (display: number) => {
            Button(`屏${display + 1}`)
              .width(80)
              .height(40)
              .padding({ left: 2, right: 2 })
              .fontSize(12)
              .fontWeight(display === this.currentDisplay ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
              .fontColor(display === this.currentDisplay ? Color.White : RustDeskTheme.TEXT_PRIMARY)
              .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : RustDeskTheme.SURFACE_MUTED)
              .borderRadius(6)
              .onClick(() => {
                this.switchDisplay(display);
              })
          }, (display: number) => `${display}-${this.currentDisplay}`)
        }
        this.buildToolbarButton('键盘', 80, this.showKeyboardPanel, false, true, () => {
          this.showKeyboardPanel = !this.showKeyboardPanel;
        })
        this.buildToolbarButton('输入', 80, false, false, true, () => {
          this.showKeyboardPanel = true;
        })
        this.buildToolbarButton('发送文件', 80, false, false, !this.transferActive, () => {
          this.pickFileForUpload();
        })
        this.buildToolbarButton(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关', 80, this.clipboardSyncEnabled, false, true, () => {
          this.toggleClipboardSync();
        })
        this.buildToolbarButton('+', 80, false, false, true, () => {
          this.zoomScale = Math.min(this.zoomScale + 0.25, 5.0);
        })
        this.buildToolbarButton('-', 80, false, false, true, () => {
          this.zoomScale = Math.max(this.zoomScale - 0.25, 0.5);
        })
        this.buildToolbarButton('断开', 80, false, true, true, () => {
          this.disconnectSession();
        })
      }
      .width(80)
      .alignItems(HorizontalAlign.Center)
    }
    .width(104)
    .height('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(Color.White)
    .border({ width: { left: 1 }, color: '#DEE6F1' })
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto);
  }

  @Builder
  buildToolbarButton(label: string, buttonWidth: number, selected: boolean, danger: boolean,
    enabled: boolean, onClick: () => void) {
    Button(label)
      .width(buttonWidth)
      .height(40)
      .padding({ left: 2, right: 2 })
      .fontSize(label === '+' || label === '-' ? 18 : (buttonWidth <= 40 ? 11 : 12))
      .fontWeight(selected ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
      .fontColor(danger ? RustDeskTheme.ERROR : (selected ? Color.White : RustDeskTheme.TEXT_PRIMARY))
      .backgroundColor(danger ? '#FDECEC' : (selected ? RustDeskTheme.ACCENT : RustDeskTheme.SURFACE_MUTED))
      .borderRadius(6)
      .enabled(enabled)
      .onClick(() => {
        onClick();
      })
  }

  @Builder
  buildKeyboardPanel() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '输入后点发送', text: this.keyboardInput })
          .id('remoteKeyboardInput')
          .height(40)
          .layoutWeight(1)
          .fontColor(RustDeskTheme.TEXT_PRIMARY)
          .backgroundColor(RustDeskTheme.SURFACE_MUTED)
          .border({ width: 1, color: '#DEE6F1', radius: 6 })
          .focusable(true)
          .defaultFocus(true)
          .onChange((value: string) => {
            this.keyboardInput = value;
          })
        Button('发送')
          .height(40)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
          .onClick(() => {
            this.sendKeyboardText(this.keyboardInput);
            this.keyboardInput = '';
          })
        Button('发剪贴板')
          .height(40)
          .fontColor(RustDeskTheme.ACCENT)
          .backgroundColor(RustDeskTheme.ACCENT_SOFT)
          .borderRadius(6)
          .onClick(() => {
            this.sendManualClipboardText(this.keyboardInput);
          })
        Button('关闭')
          .height(40)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(RustDeskTheme.SURFACE_MUTED)
          .borderRadius(6)
          .onClick(() => {
            this.showKeyboardPanel = false;
          })
      }
      Row({ space: 8 }) {
        Button('Enter').backgroundColor(RustDeskTheme.SURFACE_MUTED).fontColor(RustDeskTheme.TEXT_PRIMARY).borderRadius(6).onClick(() => { this.sendControlKey(13); })
        Button('Backspace').backgroundColor(RustDeskTheme.SURFACE_MUTED).fontColor(RustDeskTheme.TEXT_PRIMARY).borderRadius(6).onClick(() => { this.sendControlKey(8); })
        Button('Esc').backgroundColor(RustDeskTheme.SURFACE_MUTED).fontColor(RustDeskTheme.TEXT_PRIMARY).borderRadius(6).onClick(() => { this.sendControlKey(27); })
        Button('Tab').backgroundColor(RustDeskTheme.SURFACE_MUTED).fontColor(RustDeskTheme.TEXT_PRIMARY).borderRadius(6).onClick(() => { this.sendControlKey(9); })
      }
    }
    .width('96%')
    .padding(10)
    .backgroundColor(Color.White)
    .border({ width: 1, color: '#DEE6F1' })
    .borderRadius(8)
    .margin({ left: 8, right: 8, bottom: 6 });
  }

  @Builder
  buildStatsPanel() {
    Scroll() {
      Row({ space: 14 }) {
        Row({ space: 7 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(RustDeskTheme.SUCCESS)
          Text(this.connectedPeerId.length > 0 ? this.connectedPeerId : '远端设备')
            .fontSize(13)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(RustDeskTheme.TEXT_PRIMARY)
        }
        Text(this.routeText)
          .fontSize(11)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
        Text(this.speedText)
          .fontSize(11)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
        Text(this.fpsText)
          .fontSize(11)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
      }
      .height(44)
      .padding({ left: 14, right: 14 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(44)
    .backgroundColor(Color.White)
    .border({ width: { bottom: 1 }, color: '#DEE6F1' })
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off);
  }

  @Builder
  buildCursorOverlay() {
    Stack() {
      Path()
        .commands('M 0 0 L 0 18 L 5 13 L 8 20 L 11 19 L 8 12 L 15 12 Z')
        .fill(Color.White)
        .stroke('#CC000000')
        .strokeWidth(1)
    }
    .width(16)
    .height(21)
    .hitTestBehavior(HitTestMode.None)
    .position({ x: this.cursorX, y: this.cursorY });
  }

  @Builder
  buildDisplaySwitcher() {
    if (this.displayCount > 1) {
      Row({ space: 6 }) {
        ForEach(this.makeDisplayIndexes(), (display: number) => {
          Button(`屏幕 ${display + 1}`)
            .height(34)
            .fontSize(12)
            .fontColor(Color.White)
            .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : '#80000000')
            .borderRadius(17)
            .onClick(() => {
              this.switchDisplay(display);
            })
        })
      }
      .padding(6)
      .backgroundColor('#99000000')
      .borderRadius(22)
      .margin({ top: 6, bottom: 6 });
    }
  }

  resetToolbarTimer(): void {
    if (this.toolbarTimer !== -1) { clearTimeout(this.toolbarTimer); }
    this.toolbarOpacity = 1.0;
    this.showToolbar = true;
  }

  isLargeLayout(): boolean {
    return this.pageWidth >= 840;
  }

  startToolbarTimer(): void {
    if (this.toolbarTimer !== -1) { clearTimeout(this.toolbarTimer); }
    this.toolbarTimer = setTimeout(() => {
      this.toolbarOpacity = 0.0;
      this.showToolbar = false;
    }, 5000);
  }

  getDisplayWidth(): number {
    if (this.componentWidth <= 0 || this.componentHeight <= 0 || this.remoteWidth <= 0 || this.remoteHeight <= 0) {
      return this.componentWidth > 0 ? this.componentWidth : 1;
    }
    let scale: number = Math.min(this.componentWidth / this.remoteWidth, this.componentHeight / this.remoteHeight);
    return Math.max(1, this.remoteWidth * scale);
  }

  getDisplayHeight(): number {
    if (this.componentWidth <= 0 || this.componentHeight <= 0 || this.remoteWidth <= 0 || this.remoteHeight <= 0) {
      return this.componentHeight > 0 ? this.componentHeight : 1;
    }
    let scale: number = Math.min(this.componentWidth / this.remoteWidth, this.componentHeight / this.remoteHeight);
    return Math.max(1, this.remoteHeight * scale);
  }

  handleRemoteTouch(event: TouchEvent): void {
    if (Date.now() - this.lastMouseEventAt < 120) {
      return;
    }

    if (event.touches.length <= 0) {
      if (this.isPinching || this.pinchStartDistance > 0) {
        this.endPinchTouch();
      }
      this.ignoreTouchUntilNextDown = false;
      return;
    }

    if (event.touches.length >= 2) {
      this.handlePinchTouch(event);
      return;
    }

    if (this.isPinching || this.pinchStartDistance > 0) {
      this.endPinchTouch();
      return;
    }

    if (this.ignoreTouchUntilNextDown) {
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.ignoreTouchUntilNextDown = false;
      }
      return;
    }

    if (Date.now() - this.lastPinchEndedAt < 90) {
      return;
    }

    let touch = event.touches[0];
    let remotePoint: RemotePoint = this.updatePointerFromLocal(touch.x, touch.y);
    let remoteX: number = remotePoint.x;
    let remoteY: number = remotePoint.y;

    if (event.type === TouchType.Down) {
      this.requestRemoteInputFocus();
      this.touchStartX = touch.x;
      this.touchStartY = touch.y;
      this.longPressTriggered = false;
      this.startRightClickTimer(remoteX, remoteY);
      this.showToolbar = true;
      this.resetToolbarTimer();
    } else if (event.type === TouchType.Move) {
      let movedX: number = touch.x - this.touchStartX;
      let movedY: number = touch.y - this.touchStartY;
      if (Math.sqrt(movedX * movedX + movedY * movedY) >= 12) {
        this.clearLongPressTimer();
      }
      let now: number = Date.now();
      if (now - this.lastMoveSentAt > 16) {
        this.lastMoveSentAt = now;
        ConnectionService.sendMouseEvent(remoteX, remoteY, 0);
      }
    } else if (event.type === TouchType.Up) {
      this.clearLongPressTimer();
      let movedX: number = touch.x - this.touchStartX;
      let movedY: number = touch.y - this.touchStartY;
      if (!this.longPressTriggered && Math.sqrt(movedX * movedX + movedY * movedY) < 12) {
        this.handleTap(remoteX, remoteY, touch.x, touch.y);
      }
    } else if (event.type === TouchType.Cancel) {
      this.clearLongPressTimer();
    }
  }

  startRightClickTimer(remoteX: number, remoteY: number): void {
    this.clearLongPressTimer();
    this.longPressTimer = setTimeout(() => {
      this.longPressTriggered = true;
      ConnectionService.sendMouseEvent(remoteX, remoteY, 3);
      ConnectionService.sendMouseEvent(remoteX, remoteY, 4);
      this.longPressTimer = -1;
    }, 600);
  }

  clearLongPressTimer(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  handleTap(remoteX: number, remoteY: number, localX: number, localY: number): void {
    if (this.tapTimer !== -1) {
      let dx: number = localX - this.pendingTapLocalX;
      let dy: number = localY - this.pendingTapLocalY;
      if (Math.sqrt(dx * dx + dy * dy) < 24) {
        this.clearTapTimer();
        this.sendLeftClick(this.pendingTapRemoteX, this.pendingTapRemoteY);
        this.sendLeftClick(remoteX, remoteY);
        return;
      }
      this.flushPendingTap();
    }

    this.pendingTapRemoteX = remoteX;
    this.pendingTapRemoteY = remoteY;
    this.pendingTapLocalX = localX;
    this.pendingTapLocalY = localY;
    this.tapTimer = setTimeout(() => {
      this.sendLeftClick(this.pendingTapRemoteX, this.pendingTapRemoteY);
      this.tapTimer = -1;
    }, 240);
  }

  flushPendingTap(): void {
    if (this.tapTimer !== -1) {
      this.clearTapTimer();
      this.sendLeftClick(this.pendingTapRemoteX, this.pendingTapRemoteY);
    }
  }

  clearTapTimer(): void {
    if (this.tapTimer !== -1) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  sendLeftClick(remoteX: number, remoteY: number): void {
    ConnectionService.sendMouseEvent(remoteX, remoteY, 1);
    ConnectionService.sendMouseEvent(remoteX, remoteY, 2);
  }

  handleRemoteMouse(event: MouseEvent): void {
    this.lastMouseEventAt = Date.now();
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();

    let action: number = this.mapMouseAction(event);
    if (action < 0) {
      return;
    }

    let remotePoint: RemotePoint = this.updatePointerFromLocal(event.x, event.y);

    let now: number = Date.now();
    if (action === 0 && now - this.lastMoveSentAt <= 8) {
      return;
    }
    if (action === 0) {
      this.lastMoveSentAt = now;
    }
    ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, action);
    event.stopPropagation();
  }

  handleRemoteAxis(event: AxisEvent): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel) {
      return;
    }
    if (event.action !== AxisAction.UPDATE && event.action !== AxisAction.BEGIN) {
      return;
    }

    let deltaX: number = this.scaleRemoteWheelDeltaX(event.getHorizontalAxisValue());
    let deltaY: number = this.scaleRemoteWheelDeltaY(event.getVerticalAxisValue());
    if (Math.abs(deltaX) < 0.01 && Math.abs(deltaY) < 0.01) {
      return;
    }

    let now: number = Date.now();
    if (now - this.lastWheelSentAt < 8) {
      this.wheelRemainderX += deltaX;
      this.wheelRemainderY += deltaY;
      return;
    }
    this.lastWheelSentAt = now;
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();
    ConnectionService.sendMouseWheel(deltaX, deltaY);
  }

  scaleRemoteWheelDeltaX(delta: number): number {
    this.wheelRemainderX += delta * REMOTE_WHEEL_SCALE;
    let step: number = this.takeWholeWheelStep(this.wheelRemainderX);
    this.wheelRemainderX -= step;
    return step;
  }

  scaleRemoteWheelDeltaY(delta: number): number {
    this.wheelRemainderY += -delta * REMOTE_WHEEL_SCALE;
    let step: number = this.takeWholeWheelStep(this.wheelRemainderY);
    this.wheelRemainderY -= step;
    return step;
  }

  takeWholeWheelStep(delta: number): number {
    if (Math.abs(delta) < 0.01) {
      return 0;
    }
    if (delta >= 1) {
      return Math.floor(delta);
    }
    if (delta <= -1) {
      return Math.ceil(delta);
    }
    return 0;
  }

  mapMouseAction(event: MouseEvent): number {
    if (event.action === MouseAction.Move) {
      return 0;
    }
    if (event.button === MouseButton.Left) {
      if (event.action === MouseAction.Press) {
        return 1;
      }
      if (event.action === MouseAction.Release) {
        return 2;
      }
    }
    if (event.button === MouseButton.Right) {
      if (event.action === MouseAction.Press) {
        return 3;
      }
      if (event.action === MouseAction.Release) {
        return 4;
      }
    }
    return -1;
  }

  updatePointerFromLocal(localX: number, localY: number): RemotePoint {
    let displayWidth: number = this.getDisplayWidth();
    let displayHeight: number = this.getDisplayHeight();
    let clampedX: number = Math.max(0, Math.min(displayWidth, localX));
    let clampedY: number = Math.max(0, Math.min(displayHeight, localY));
    let remoteX: number = Math.max(0, Math.min(this.remoteWidth - 1, clampedX * this.remoteWidth / displayWidth));
    let remoteY: number = Math.max(0, Math.min(this.remoteHeight - 1, clampedY * this.remoteHeight / displayHeight));
    this.lastAbsX = remoteX;
    this.lastAbsY = remoteY;
    this.cursorX = this.getDisplayLeft() + clampedX;
    this.cursorY = this.getDisplayTop() + clampedY;
    this.showCursor = true;
    return { x: remoteX, y: remoteY };
  }

  handleRemoteKey(event: KeyEvent): boolean {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel) {
      return false;
    }

    let controlCode: number = this.mapControlKeyCode(event.keyCode);
    if (controlCode > 0) {
      ConnectionService.sendKeyEvent(controlCode, event.type === KeyType.Down ? 0 : 1);
      return true;
    }

    let text: string = this.getKeyEventText(event);
    if (text.length > 0) {
      let scanCode: number = this.mapAsciiToWindowsScanCode(text);
      if (scanCode > 0) {
        ConnectionService.sendPhysicalKeyEvent(scanCode, event.type === KeyType.Down ? 0 : 1);
      } else if (event.type === KeyType.Down) {
        ConnectionService.sendText(text);
      }
      return true;
    }
    return false;
  }

  requestRemoteInputFocus(): void {
    try {
      this.getUIContext()?.getFocusController().requestFocus('remoteInputCapture');
    } catch (_e) {
      // Some windows reject focus while relayout or navigation is in progress.
    }
  }

  getKeyEventText(event: KeyEvent): string {
    if (event.keyText.length === 1) {
      return event.keyText;
    }
    if (event.unicode !== undefined && event.unicode > 0) {
      return String.fromCharCode(event.unicode);
    }
    return '';
  }

  mapAsciiToWindowsScanCode(text: string): number {
    if (text.length !== 1) {
      return 0;
    }
    switch (text.toLowerCase()) {
      case 'a': return 0x1E;
      case 'b': return 0x30;
      case 'c': return 0x2E;
      case 'd': return 0x20;
      case 'e': return 0x12;
      case 'f': return 0x21;
      case 'g': return 0x22;
      case 'h': return 0x23;
      case 'i': return 0x17;
      case 'j': return 0x24;
      case 'k': return 0x25;
      case 'l': return 0x26;
      case 'm': return 0x32;
      case 'n': return 0x31;
      case 'o': return 0x18;
      case 'p': return 0x19;
      case 'q': return 0x10;
      case 'r': return 0x13;
      case 's': return 0x1F;
      case 't': return 0x14;
      case 'u': return 0x16;
      case 'v': return 0x2F;
      case 'w': return 0x11;
      case 'x': return 0x2D;
      case 'y': return 0x15;
      case 'z': return 0x2C;
      case '1': return 0x02;
      case '2': return 0x03;
      case '3': return 0x04;
      case '4': return 0x05;
      case '5': return 0x06;
      case '6': return 0x07;
      case '7': return 0x08;
      case '8': return 0x09;
      case '9': return 0x0A;
      case '0': return 0x0B;
      default: return 0;
    }
  }

  mapControlKeyCode(keyCode: number): number {
    switch (keyCode) {
      case 2012:
        return 38;
      case 2013:
        return 40;
      case 2014:
        return 37;
      case 2015:
        return 39;
      case 2049:
        return 9;
      case 2050:
        return 32;
      case 2054:
        return 13;
      case 2055:
        return 8;
      case 2070:
        return 27;
      case 2071:
        return 46;
      default:
        return 0;
    }
  }

  handlePinchTouch(event: TouchEvent): void {
    let first = event.touches[0];
    let second = event.touches[1];
    let dx: number = first.x - second.x;
    let dy: number = first.y - second.y;
    let distance: number = Math.sqrt(dx * dx + dy * dy);
    let centerX: number = (first.x + second.x) / 2;
    let centerY: number = (first.y + second.y) / 2;
    if (event.type === TouchType.Down || this.pinchStartDistance <= 0) {
      this.isPinching = true;
      this.clearLongPressTimer();
      this.clearTapTimer();
      this.showCursor = false;
      this.pinchStartDistance = distance;
      this.pinchStartScale = this.zoomScale;
      this.lastPinchCenterX = centerX;
      this.lastPinchCenterY = centerY;
      this.lastPinchUpdateAt = Date.now();
      return;
    }
    if (event.type === TouchType.Move && this.pinchStartDistance > 0) {
      let now: number = Date.now();
      if (now - this.lastPinchUpdateAt < 24) {
        return;
      }
      let nextScale: number = Math.max(0.5, Math.min(5.0, this.pinchStartScale * distance / this.pinchStartDistance));
      let deltaX: number = centerX - this.lastPinchCenterX;
      let deltaY: number = centerY - this.lastPinchCenterY;
      if (Math.abs(nextScale - this.zoomScale) < 0.006 && Math.abs(deltaX) < 0.5 && Math.abs(deltaY) < 0.5) {
        return;
      }
      this.lastPinchUpdateAt = now;
      this.lastPinchCenterX = centerX;
      this.lastPinchCenterY = centerY;
      this.applyPinchTransform(centerX, centerY, nextScale, deltaX, deltaY);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.endPinchTouch();
    }
  }

  endPinchTouch(): void {
    this.isPinching = false;
    this.pinchStartDistance = 0;
    this.lastPinchCenterX = 0;
    this.lastPinchCenterY = 0;
    this.lastPinchUpdateAt = 0;
    this.lastPinchEndedAt = Date.now();
    this.ignoreTouchUntilNextDown = true;
    this.clampViewportOffset();
  }

  applyPinchTransform(localX: number, localY: number, nextScale: number, deltaX: number, deltaY: number): void {
    let anchorX: number = this.getDisplayLeft() + localX;
    let anchorY: number = this.getDisplayTop() + localY;
    let centerX: number = this.componentWidth / 2;
    let centerY: number = this.componentHeight / 2;
    let nextOffsetX: number = this.offsetX + deltaX + (anchorX - centerX) * (this.zoomScale - nextScale);
    let nextOffsetY: number = this.offsetY + deltaY + (anchorY - centerY) * (this.zoomScale - nextScale);
    this.zoomScale = nextScale;
    this.offsetX = this.clampOffset(nextOffsetX, nextScale, this.componentWidth);
    this.offsetY = this.clampOffset(nextOffsetY, nextScale, this.componentHeight);
  }

  applyZoomAt(localX: number, localY: number, nextScale: number): void {
    if (nextScale === this.zoomScale) {
      return;
    }
    let anchorX: number = this.getDisplayLeft() + localX;
    let anchorY: number = this.getDisplayTop() + localY;
    let centerX: number = this.componentWidth / 2;
    let centerY: number = this.componentHeight / 2;
    this.offsetX += (anchorX - centerX) * (this.zoomScale - nextScale);
    this.offsetY += (anchorY - centerY) * (this.zoomScale - nextScale);
    this.zoomScale = nextScale;
    this.clampViewportOffset();
  }

  clampViewportOffset(): void {
    this.offsetX = this.clampOffset(this.offsetX, this.zoomScale, this.componentWidth);
    this.offsetY = this.clampOffset(this.offsetY, this.zoomScale, this.componentHeight);
  }

  clampOffset(value: number, scale: number, size: number): number {
    if (size <= 0 || scale <= 1.0) {
      return 0;
    }
    let limit: number = Math.max(0, size * (scale - 1.0) / 2 + 96);
    return Math.max(-limit, Math.min(limit, value));
  }

  sendKeyboardText(text: string): void {
    if (text.length <= 0) {
      return;
    }
    ConnectionService.sendText(text);
  }

  sendManualClipboardText(text: string): void {
    if (text.length <= 0) {
      return;
    }
    let result: number = RustDeskNapi.sendClipboardText(text);
    this.lastLocalClipboardText = text;
    hilog.info(LOG_DOMAIN, 'StarRustDesk', 'Manual clipboard sent result=%{public}d', result);
  }

  async pickFileForUpload(): Promise<void> {
    try {
      let context = getContext(this) as common.UIAbilityContext;
      let documentPicker = new picker.DocumentViewPicker(context);
      let options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['All files (*.*)|.*'];
      let uris: string[] = await documentPicker.select(options);
      if (uris.length <= 0) {
        return;
      }

      let source: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      let fileName: string = source.name;
      let safeName: string = fileName.replace(/[\\/:*?"<>|]/g, '_');
      let cachedPath: string = `${context.cacheDir}/upload-${Date.now()}-${safeName}`;
      fileIo.copyFileSync(source.fd, cachedPath);
      fileIo.closeSync(source);

      this.cleanupPendingUploadFile();
      this.pendingUploadPath = cachedPath;
      this.pendingUploadName = fileName;
      this.showRemoteFileBrowser = true;
      this.openRemoteDirectory('/');
    } catch (_e) {
      this.showFileToast('未选择文件或无法读取文件');
    }
  }

  openRemoteDirectory(path: string): void {
    this.remoteDirectoryLoading = true;
    this.remoteDirectoryEntries = [];
    if (this.remoteDirectoryTimer !== -1) {
      clearTimeout(this.remoteDirectoryTimer);
    }
    let result: number = RustDeskNapi.requestRemoteDirectory(path);
    if (result !== 0) {
      this.remoteDirectoryLoading = false;
      this.showFileToast(`无法读取远端目录 (${result})`);
      return;
    }
    this.pollRemoteDirectoryResult(0);
  }

  pollRemoteDirectoryResult(attempt: number): void {
    let raw: string = RustDeskNapi.takeRemoteDirectoryResult();
    if (raw.length > 0) {
      try {
        let result: RemoteDirectoryResult = JSON.parse(raw) as RemoteDirectoryResult;
        this.remoteDirectoryLoading = false;
        if (result.error.length > 0) {
          this.showFileToast(`读取远端目录失败：${result.error}`);
          return;
        }
        this.remoteDirectoryPath = result.path;
        this.remoteDirectoryEntries = result.entries;
        return;
      } catch (_e) {
        this.remoteDirectoryLoading = false;
        this.showFileToast('远端目录数据无效');
        return;
      }
    }
    if (attempt >= 150 || !this.showRemoteFileBrowser) {
      this.remoteDirectoryLoading = false;
      if (this.showRemoteFileBrowser) this.showFileToast('读取远端目录超时');
      return;
    }
    this.remoteDirectoryTimer = setTimeout(() => {
      this.pollRemoteDirectoryResult(attempt + 1);
    }, 100);
  }

  getRemoteFolders(): RemoteDirectoryEntry[] {
    return this.remoteDirectoryEntries.filter((entry: RemoteDirectoryEntry) => {
      return entry.entryType === 0 || entry.entryType === 2 || entry.entryType === 3;
    });
  }

  joinRemotePath(name: string): string {
    if (this.remoteDirectoryPath === '/') return `${name}\\`;
    if (this.remoteDirectoryPath.length === 0) return name;
    if (this.remoteDirectoryPath.endsWith('\\') || this.remoteDirectoryPath.endsWith('/')) {
      return `${this.remoteDirectoryPath}${name}`;
    }
    let separator: string = this.remoteDirectoryPath.includes('\\') || this.remoteDirectoryPath.includes(':') ? '\\' : '/';
    return `${this.remoteDirectoryPath}${separator}${name}`;
  }

  getRemoteParentPath(): string {
    let path: string = this.remoteDirectoryPath;
    if (path.length === 0 || path === '/') return '/';
    while (path.length > 1 && (path.endsWith('\\') || path.endsWith('/'))) {
      path = path.substring(0, path.length - 1);
    }
    if (/^[A-Za-z]:$/.test(path)) return '/';
    let separatorIndex: number = Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
    if (separatorIndex < 0) return '/';
    let parent: string = path.substring(0, separatorIndex);
    if (/^[A-Za-z]:$/.test(parent)) return `${parent}\\`;
    return parent;
  }

  startPendingFileUpload(): void {
    if (this.pendingUploadPath.length === 0 || this.pendingUploadName.length === 0) return;
    let result: number = RustDeskNapi.startFileUpload(
      this.pendingUploadPath,
      this.pendingUploadName,
      this.remoteDirectoryPath
    );
    if (result !== 0) {
      this.showFileToast(`发送文件失败 (${result})`);
      return;
    }
    this.transferActive = true;
    this.transferProgress = 0;
    this.closeRemoteFileBrowser(false);
    this.showFileToast('文件开始传输');
  }

  closeRemoteFileBrowser(removePendingFile: boolean): void {
    this.showRemoteFileBrowser = false;
    this.remoteDirectoryLoading = false;
    if (this.remoteDirectoryTimer !== -1) {
      clearTimeout(this.remoteDirectoryTimer);
      this.remoteDirectoryTimer = -1;
    }
    if (removePendingFile) {
      this.cleanupPendingUploadFile();
      this.pendingUploadName = '';
    }
  }

  pollFileTransferStatus(): void {
    if (!this.transferActive) return;
    let raw: string = RustDeskNapi.getFileTransferStatus();
    if (raw.length === 0) return;
    try {
      let status: FileTransferStatus = JSON.parse(raw) as FileTransferStatus;
      this.transferProgress = status.total > 0 ? Math.min(100, status.transferred * 100 / status.total) : 0;
      if (status.state === 'completed') {
        this.transferActive = false;
        this.transferProgress = 100;
        this.cleanupPendingUploadFile();
        this.pendingUploadName = '';
        this.showFileToast('文件传输完成');
      } else if (status.state === 'failed') {
        this.transferActive = false;
        this.showFileToast(status.error.length > 0 ? `文件传输失败：${status.error}` : '文件传输失败');
      }
    } catch (_e) {
    }
  }

  showFileToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
    } catch (_e) {
    }
  }

  sendControlKey(code: number): void {
    ConnectionService.sendKeyEvent(code, 2);
  }

  disconnectSession(): void {
    if (this.isLeavingAfterDisconnect) {
      return;
    }
    this.isLeavingAfterDisconnect = true;
    this.hasVideo = false;
    this.showKeyboardPanel = false;
    this.showCursor = false;
    this.stopClipboardSync();
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.pinchStartDistance = 0;
    this.isPinching = false;
    RustDeskNapi.setSurfaceId('');
    ConnectionService.disconnect();
    try {
      router.back();
    } catch (_e) {
      this.connectionStatus = ConnectionStatus.DISCONNECTED;
      this.isLeavingAfterDisconnect = false;
    }
  }

  toggleClipboardSync(): void {
    if (this.clipboardSyncEnabled) {
      this.stopClipboardSync();
    } else {
      this.startClipboardSync();
    }
  }

  startClipboardSync(): void {
    this.clipboardSyncEnabled = true;
    this.lastLocalClipboardText = '';
    this.lastRemoteClipboardText = '';
    this.suppressClipboardText = '';
    this.clipboardBaselineInitialized = false;
    if (this.connectionStatus === ConnectionStatus.CONNECTED) {
      this.scheduleClipboardPoll(100);
    }
  }

  stopClipboardSync(): void {
    this.clipboardSyncEnabled = false;
    this.pauseClipboardSync();
  }

  pauseClipboardSync(): void {
    this.clipboardPolling = false;
    if (this.clipboardTimer !== -1) {
      clearTimeout(this.clipboardTimer);
      this.clipboardTimer = -1;
    }
  }

  ensureClipboardSyncRunning(): void {
    if (!this.clipboardSyncEnabled || this.clipboardPolling || this.clipboardTimer !== -1) {
      return;
    }
    this.scheduleClipboardPoll(100);
  }

  scheduleClipboardPoll(delayMs: number): void {
    if (this.clipboardTimer !== -1) {
      clearTimeout(this.clipboardTimer);
    }
    this.clipboardTimer = setTimeout(() => {
      this.pollClipboardSync();
    }, delayMs);
  }

  async pollClipboardSync(): Promise<void> {
    this.clipboardTimer = -1;
    if (!this.clipboardSyncEnabled || this.clipboardPolling || this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    this.clipboardPolling = true;
    try {
      let remoteText: string = RustDeskNapi.takeRemoteClipboardText();
      if (remoteText.length > 0 && remoteText !== this.lastRemoteClipboardText) {
        this.lastRemoteClipboardText = remoteText;
        this.lastLocalClipboardText = remoteText;
        this.suppressClipboardText = remoteText;
        this.clipboardBaselineInitialized = true;
        RustDeskNapi.setClipboardText(remoteText);
      }

      let localText: string = await RustDeskNapi.getClipboardTextAsync();
      if (!this.clipboardBaselineInitialized) {
        this.lastLocalClipboardText = localText;
        this.clipboardBaselineInitialized = true;
        if (localText.length > 0 && localText !== this.suppressClipboardText) {
          let result: number = RustDeskNapi.sendClipboardText(localText);
          hilog.info(LOG_DOMAIN, 'StarRustDesk', 'Initial local clipboard synced result=%{public}d', result);
        } else if (localText === this.suppressClipboardText) {
          this.suppressClipboardText = '';
        }
      } else if (localText.length > 0 && localText !== this.lastLocalClipboardText) {
        this.lastLocalClipboardText = localText;
        if (localText === this.suppressClipboardText) {
          this.suppressClipboardText = '';
        } else {
          let result: number = RustDeskNapi.sendClipboardText(localText);
          hilog.info(LOG_DOMAIN, 'StarRustDesk', 'Local clipboard synced result=%{public}d', result);
        }
      }
    } catch (_e) {
      hilog.warn(LOG_DOMAIN, 'StarRustDesk', 'Clipboard sync poll failed');
    }
    this.clipboardPolling = false;
    if (this.clipboardSyncEnabled) {
      this.scheduleClipboardPoll(1000);
    }
  }

  makeDisplayIndexes(): number[] {
    let displays: number[] = [];
    for (let i: number = 0; i < this.displayCount; i++) {
      displays.push(i);
    }
    return displays;
  }

  switchDisplay(display: number): void {
    if (display < 0 || display >= this.displayCount || display === this.currentDisplay) {
      return;
    }
    this.currentDisplay = display;
    this.showCursor = false;
    this.lastStatsTime = 0;
    const result = RustDeskNapi.switchDisplay(display);
    if (result !== 0) {
      hilog.error(LOG_DOMAIN, 'StarRustDesk', `Switch display failed display=${display} result=${result}`);
      return;
    }
    RustDeskNapi.refreshVideo();
    this.bindSurfaceIfReady();
  }

  getDisplayLeft(): number {
    return Math.max(0, (this.componentWidth - this.getDisplayWidth()) / 2);
  }

  getDisplayTop(): number {
    return Math.max(0, (this.componentHeight - this.getDisplayHeight()) / 2);
  }

  bindSurfaceIfReady(): void {
    if (this.surfaceId.length <= 0) {
      try {
        this.surfaceId = this.xComponentController.getXComponentSurfaceId();
      } catch (_e) {
        return;
      }
    }
    if (this.surfaceId.length > 0) {
      RustDeskNapi.setSurfaceId(this.surfaceId);
      this.lastSurfaceWidth = this.componentWidth;
      this.lastSurfaceHeight = this.componentHeight;
      this.requestVideoRefreshAfterSurfaceRebind();
    }
  }

  scheduleSurfaceRebindIfSizeChanged(): void {
    if (this.componentWidth <= 0 || this.componentHeight <= 0 || this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    let widthDelta: number = Math.abs(this.componentWidth - this.lastSurfaceWidth);
    let heightDelta: number = Math.abs(this.componentHeight - this.lastSurfaceHeight);
    if (this.lastSurfaceWidth > 0 && this.lastSurfaceHeight > 0 && widthDelta < 24 && heightDelta < 24) {
      return;
    }
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
    }
    this.surfaceRebindTimer = setTimeout(() => {
      this.surfaceRebindTimer = -1;
      this.rebindSurfaceAfterLayoutChange();
    }, 180);
  }

  rebindSurfaceAfterLayoutChange(): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.componentWidth <= 0 || this.componentHeight <= 0) {
      return;
    }
    // XComponent keeps the same surface while its layout size changes. Reusing
    // that surface avoids racing an asynchronous native-window teardown against
    // the decoder startup that happens immediately after connection.
    this.bindSurfaceIfReady();
  }

  requestVideoRefreshAfterSurfaceRebind(): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    RustDeskNapi.refreshVideo();
    setTimeout(() => {
      if (this.connectionStatus === ConnectionStatus.CONNECTED) {
        RustDeskNapi.refreshVideo();
      }
    }, 700);
  }

  updateStats(frame: VideoFrameInfo): void {
    let now: number = Date.now();
    let totalFrames: number = frame.totalFrames ?? this.lastStatsFrames;
    let totalBytes: number = frame.totalBytes ?? this.lastStatsBytes;
    if (this.lastStatsTime === 0) {
      this.lastStatsTime = now;
      this.lastStatsFrames = totalFrames;
      this.lastStatsBytes = totalBytes;
      return;
    }
    let elapsed: number = now - this.lastStatsTime;
    if (elapsed < 1000) {
      return;
    }
    let frameDelta: number = Math.max(0, totalFrames - this.lastStatsFrames);
    let byteDelta: number = Math.max(0, totalBytes - this.lastStatsBytes);
    let fps: number = frameDelta * 1000 / elapsed;
    let kbps: number = byteDelta * 1000 / elapsed / 1024;
    this.smoothFps = this.smoothFps <= 0 ? fps : this.smoothFps * 0.65 + fps * 0.35;
    this.smoothKbps = this.smoothKbps <= 0 ? kbps : this.smoothKbps * 0.65 + kbps * 0.35;
    this.fpsText = `${this.smoothFps.toFixed(1)} fps`;
    this.speedText = this.smoothKbps >= 1024 ? `${(this.smoothKbps / 1024).toFixed(2)} MB/s` : `${this.smoothKbps.toFixed(0)} KB/s`;
    this.lastStatsTime = now;
    this.lastStatsFrames = totalFrames;
    this.lastStatsBytes = totalBytes;
  }

  updateConnectionRoute(): void {
    let route: number = ConnectionService.getConnectionRoute();
    if (route === 1) {
      this.routeText = '直连';
    } else if (route === 2) {
      this.routeText = '中继';
    } else {
      this.routeText = '未知';
    }
  }
}
