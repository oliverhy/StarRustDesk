import { router } from '@kit.ArkUI';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { translate } from '../utils/I18n';
import { ConnectionStatus } from '../model/ConnectionModel';
import { ConnectionService } from '../service/ConnectionService';
import { RustDeskNapi, VideoFrameInfo } from '../service/RustDeskNapi';

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
  @State pageWidth: number = 0;
  @State clipboardSyncEnabled: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private toolbarTimer: number = -1;
  private statusTimer: number = -1;
  private frameTimer: number = -1;
  private clipboardTimer: number = -1;
  private surfaceRebindTimer: number = -1;
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
  private lastPinchUpdateAt: number = 0;
  private lastDisplayPollAt: number = 0;
  private lastSurfaceWidth: number = 0;
  private lastSurfaceHeight: number = 0;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private clipboardPolling: boolean = false;
  private lastLocalClipboardText: string = '';
  private lastRemoteClipboardText: string = '';
  private suppressClipboardText: string = '';

  aboutToAppear(): void {
    let status: number = RustDeskNapi.getConnectionStatus();
    this.connectionStatus = status as ConnectionStatus;
    this.startPolling();
  }

  aboutToDisappear(): void {
    if (this.toolbarTimer !== -1) { clearTimeout(this.toolbarTimer); }
    if (this.statusTimer !== -1) { clearTimeout(this.statusTimer); }
    if (this.frameTimer !== -1) { clearTimeout(this.frameTimer); }
    if (this.surfaceRebindTimer !== -1) { clearTimeout(this.surfaceRebindTimer); }
    this.stopClipboardSync();
    this.clearLongPressTimer();
    this.clearTapTimer();
  }

  startPolling(): void {
    let poll = () => {
      let status: number = RustDeskNapi.getConnectionStatus();
      this.connectionStatus = status as ConnectionStatus;
      let now: number = Date.now();
      if (status === ConnectionStatus.CONNECTED && now - this.lastDisplayPollAt > 2000) {
        this.lastDisplayPollAt = now;
        this.displayCount = Math.max(1, RustDeskNapi.getDisplayCount());
        this.currentDisplay = RustDeskNapi.getCurrentDisplay();
      }
      if (status !== ConnectionStatus.CONNECTED) {
        this.hasVideo = false;
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.pageWidth = newValue.width as number;
      this.scheduleSurfaceRebindIfSizeChanged();
    });
  }

  @Builder
  buildDisconnectedView() {
    Column({ space: 16 }) {
      Text('🖥').fontSize(64);
      Text(translate('No active connection'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE).fontColor(Color.White);
      Text(translate('Enter a Remote ID to connect'))
        .fontSize(RustDeskTheme.FONT_SIZE_SMALL).fontColor(Color.Gray);
      Button(translate('Back')).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).borderRadius(8)
        .onClick(() => { router.back(); });
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  buildConnectingView() {
    Column({ space: 16 }) {
      LoadingProgress().width(48).height(48).color(Color.White);
      Text(translate('Connecting')).fontSize(RustDeskTheme.FONT_SIZE_BODY).fontColor(Color.White);
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
      .backgroundColor(Color.Black);
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
      .backgroundColor(Color.Black);
    }
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
      }

      Stack()
        .width(this.getDisplayWidth())
        .height(this.getDisplayHeight())
        .backgroundColor('#01000000')
        .onTouch((event: TouchEvent) => {
          this.handleRemoteTouch(event);
        })

      if (!this.hasVideo) {
        Column({ space: 12 }) {
          Text('🖥')
            .fontSize(64)
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
    Column({ space: 16 }) {
      Text('⚠').fontSize(48);
      Text(translate('Connection failed')).fontSize(RustDeskTheme.FONT_SIZE_TITLE).fontColor(RustDeskTheme.ERROR);
      Button(translate('Retry')).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).borderRadius(8)
        .onClick(() => { router.back(); });
      Button(translate('Back')).fontColor(RustDeskTheme.TEXT_PRIMARY).backgroundColor(Color.Gray).borderRadius(8)
        .onClick(() => { router.back(); });
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  buildFloatingToolbar() {
    Scroll() {
      Row({ space: 8 }) {
        if (this.displayCount > 1) {
          ForEach(this.makeDisplayIndexes(), (display: number) => {
            Button(`屏${display + 1}`)
              .height(40)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : '#66000000')
              .borderRadius(8)
              .onClick(() => {
                this.switchDisplay(display);
              })
          })
        }
        Button('鼠标')
          .height(40)
          .fontSize(14)
          .onClick(() => {
            ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 1);
            ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 2);
          })
        Button('键盘')
          .height(40)
          .fontSize(14)
          .onClick(() => {
            this.showKeyboardPanel = !this.showKeyboardPanel;
          })
        Button(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关')
          .height(40)
          .fontSize(13)
          .fontColor(this.clipboardSyncEnabled ? Color.White : Color.Gray)
          .backgroundColor(this.clipboardSyncEnabled ? RustDeskTheme.ACCENT : '#66000000')
          .borderRadius(8)
          .onClick(() => {
            this.toggleClipboardSync();
          })
        Button('+')
          .height(40)
          .fontSize(18)
          .onClick(() => {
            this.zoomScale = Math.min(this.zoomScale + 0.25, 5.0);
          })
        Button('-')
          .height(40)
          .fontSize(18)
          .onClick(() => {
            this.zoomScale = Math.max(this.zoomScale - 0.25, 0.5);
          })
        Button('断开')
          .height(40)
          .fontSize(14)
          .fontColor(RustDeskTheme.ERROR)
          .onClick(() => {
            this.disconnectSession();
          })
      }
      .height(40)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .backgroundColor('#CC000000')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off);
  }

  @Builder
  buildSideToolbar() {
    Scroll() {
      Column({ space: 8 }) {
        if (this.displayCount > 1) {
          ForEach(this.makeDisplayIndexes(), (display: number) => {
            Button(`屏${display + 1}`)
              .width(88)
              .height(40)
              .fontSize(13)
              .fontColor(Color.White)
              .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : '#66000000')
              .borderRadius(8)
              .onClick(() => {
                this.switchDisplay(display);
              })
          })
        }
        Button('鼠标')
          .width(88)
          .height(40)
          .fontSize(14)
          .onClick(() => {
            ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 1);
            ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 2);
          })
        Button('键盘')
          .width(88)
          .height(40)
          .fontSize(14)
          .onClick(() => {
            this.showKeyboardPanel = !this.showKeyboardPanel;
          })
        Button(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关')
          .width(88)
          .height(40)
          .fontSize(13)
          .fontColor(this.clipboardSyncEnabled ? Color.White : Color.Gray)
          .backgroundColor(this.clipboardSyncEnabled ? RustDeskTheme.ACCENT : '#66000000')
          .borderRadius(8)
          .onClick(() => {
            this.toggleClipboardSync();
          })
        Button('+')
          .width(88)
          .height(40)
          .fontSize(18)
          .onClick(() => {
            this.zoomScale = Math.min(this.zoomScale + 0.25, 5.0);
          })
        Button('-')
          .width(88)
          .height(40)
          .fontSize(18)
          .onClick(() => {
            this.zoomScale = Math.max(this.zoomScale - 0.25, 0.5);
          })
        Button('断开')
          .width(88)
          .height(40)
          .fontSize(14)
          .fontColor(RustDeskTheme.ERROR)
          .onClick(() => {
            this.disconnectSession();
          })
      }
      .width(88)
      .alignItems(HorizontalAlign.Center)
    }
    .width(112)
    .height('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor('#CC000000')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto);
  }

  @Builder
  buildKeyboardPanel() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '输入后点发送', text: this.keyboardInput })
          .id('remoteKeyboardInput')
          .height(40)
          .layoutWeight(1)
          .backgroundColor(Color.White)
          .focusable(true)
          .defaultFocus(true)
          .onChange((value: string) => {
            this.keyboardInput = value;
          })
        Button('发送')
          .height(40)
          .onClick(() => {
            this.sendKeyboardText(this.keyboardInput);
            this.keyboardInput = '';
          })
        Button('关闭')
          .height(40)
          .onClick(() => {
            this.showKeyboardPanel = false;
          })
      }
      Row({ space: 8 }) {
        Button('Enter').onClick(() => { this.sendControlKey(13); })
        Button('Backspace').onClick(() => { this.sendControlKey(8); })
        Button('Esc').onClick(() => { this.sendControlKey(27); })
        Button('Tab').onClick(() => { this.sendControlKey(9); })
      }
    }
    .width('96%')
    .padding(10)
    .backgroundColor('#D9000000')
    .borderRadius(8)
    .margin({ left: 8, right: 8, bottom: 6 });
  }

  @Builder
  buildStatsPanel() {
    Column({ space: 2 }) {
      Text(`速度 ${this.speedText}`)
        .fontSize(11)
        .fontColor(Color.White)
      Text(`帧率 ${this.fpsText}`)
        .fontSize(11)
        .fontColor(Color.White)
    }
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .width('100%')
    .height(40)
    .backgroundColor('#CC000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Start);
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
    let displayWidth: number = this.getDisplayWidth();
    let displayHeight: number = this.getDisplayHeight();
    let remoteX: number = Math.max(0, Math.min(this.remoteWidth - 1, touch.x * this.remoteWidth / displayWidth));
    let remoteY: number = Math.max(0, Math.min(this.remoteHeight - 1, touch.y * this.remoteHeight / displayHeight));
    this.lastAbsX = remoteX;
    this.lastAbsY = remoteY;
    this.cursorX = this.getDisplayLeft() + Math.max(0, Math.min(displayWidth, touch.x));
    this.cursorY = this.getDisplayTop() + Math.max(0, Math.min(displayHeight, touch.y));
    this.showCursor = true;

    if (event.type === TouchType.Down) {
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

  sendControlKey(code: number): void {
    ConnectionService.sendKeyEvent(code, 2);
  }

  disconnectSession(): void {
    this.connectionStatus = ConnectionStatus.DISCONNECTED;
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
    this.scheduleClipboardPoll(100);
  }

  stopClipboardSync(): void {
    this.clipboardSyncEnabled = false;
    this.clipboardPolling = false;
    if (this.clipboardTimer !== -1) {
      clearTimeout(this.clipboardTimer);
      this.clipboardTimer = -1;
    }
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
    if (!this.clipboardSyncEnabled || this.clipboardPolling) {
      return;
    }
    this.clipboardPolling = true;
    try {
      let remoteText: string = RustDeskNapi.takeRemoteClipboardText();
      if (remoteText.length > 0 && remoteText !== this.lastRemoteClipboardText) {
        this.lastRemoteClipboardText = remoteText;
        this.lastLocalClipboardText = remoteText;
        this.suppressClipboardText = remoteText;
        RustDeskNapi.setClipboardText(remoteText);
      }

      let localText: string = await RustDeskNapi.getClipboardTextAsync();
      if (localText.length > 0 && localText !== this.lastLocalClipboardText) {
        this.lastLocalClipboardText = localText;
        if (localText === this.suppressClipboardText) {
          this.suppressClipboardText = '';
        } else {
          RustDeskNapi.sendClipboardText(localText);
        }
      }
    } catch (_e) {
      // Ignore transient pasteboard permission/read failures and keep polling.
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
    if (display === this.currentDisplay) {
      return;
    }
    const result = RustDeskNapi.switchDisplay(display);
    if (result !== 0) {
      return;
    }
    this.currentDisplay = display;
    this.lastStatsTime = 0;
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
    this.hasVideo = false;
    this.showRemoteSurface = false;
    RustDeskNapi.setSurfaceId('');
    this.surfaceId = '';
    this.xComponentController = new XComponentController();
    this.surfaceEpoch++;
    setTimeout(() => {
      this.showRemoteSurface = true;
      setTimeout(() => {
        this.bindSurfaceIfReady();
        this.requestVideoRefreshAfterSurfaceRebind();
      }, 160);
    }, 120);
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
}
