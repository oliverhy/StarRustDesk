import { common } from '@kit.AbilityKit';
import { ConnectionStatus } from '../model/ConnectionModel';
import { RustDeskNapi, SecondaryDisplayState } from '../service/RustDeskNapi';
import { SecondaryPoint, secondaryRemotePoint } from '../model/SecondaryPointerPolicy';
import { isTouchOnlyMouseEvent } from '../model/PhysicalMousePolicy';
import { RemoteWheelNormalizer, RemoteWheelStep } from '../model/RemoteWheelNormalizer';
import { SecondaryTouchAction, SecondaryTouchGesture, SecondaryTouchPoint } from '../model/SecondaryTouchGesture';
import { ExtendedDisplayFullscreen } from '../service/ExtendedDisplayFullscreen';
import { translate } from '../utils/I18n';

@Entry({ useSharedStorage: true })
@Component
struct ExtendedDisplayPage {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans';
  @LocalStorageProp('remoteDisplay') @Watch('onRemoteDisplayChanged') remoteDisplay: number = -1;
  @State statusText: string = '正在连接扩展画面…';
  @State offerVp9: boolean = false;
  @State frameReady: boolean = false;
  @State remoteWidth: number = 0;
  @State remoteHeight: number = 0;
  @State areaWidth: number = 1;
  @State areaHeight: number = 1;
  @State touchCursorVisible: boolean = false;
  @State touchCursorX: number = 0;
  @State touchCursorY: number = 0;
  @State zoom: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  @State fullscreen: boolean = false;
  @State fullscreenBusy: boolean = false;
  private pageActive: boolean = false;
  private fullscreenPolicy?: ExtendedDisplayFullscreen;
  private controller: XComponentController = new XComponentController();
  private timer: number = -1;
  private retryTimer: number = -1;
  private started: boolean = false;
  private startedAt: number = 0;
  private token: number = 0;
  private mouseButtons: number = 0;
  private keyboardFocused: boolean = false;
  private touchId: number = -1;
  private touchDraining: boolean = false;
  private lastTouchAt: number = 0;
  private lastMoveAt: number = 0;
  private lastPoint?: SecondaryPoint;
  private wheel: RemoteWheelNormalizer = new RemoteWheelNormalizer();
  private touchWheel: RemoteWheelNormalizer = new RemoteWheelNormalizer();
  private touchGesture: SecondaryTouchGesture = new SecondaryTouchGesture();
  private longPressTimer: number = -1;

  aboutToAppear(): void {
    this.pageActive = true;
    this.prepareFullscreen();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.fullscreenPolicy?.dispose();
    this.fullscreenPolicy = undefined;
    if (this.timer !== -1) clearInterval(this.timer);
    if (this.retryTimer !== -1) clearInterval(this.retryTimer);
    this.timer = -1;
    this.retryTimer = -1;
    this.releaseInputs();
    if (this.token > 0) RustDeskNapi.stopSecondaryDisplay(this.token);
  }

  private prepareFullscreen(): boolean {
    if (!this.pageActive) return false;
    if (this.fullscreenPolicy) return true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // The stage belongs to ExtendedDisplayAbility, not the primary window.
      const target = context.windowStage.getMainWindowSync();
      this.fullscreenPolicy = new ExtendedDisplayFullscreen(target, (fullscreen: boolean, busy: boolean) => {
        if (this.pageActive) { this.fullscreen = fullscreen; this.fullscreenBusy = busy; }
      });
      this.fullscreenPolicy.start();
      return true;
    } catch (_error) {
      RustDeskNapi.appendDiagnosticLog('multi-display', 'fullscreen_window_unavailable');
      return false;
    }
  }

  private async toggleFullscreen(): Promise<void> {
    if (this.fullscreenBusy) return;
    if (!this.prepareFullscreen() || !this.fullscreenPolicy) {
      this.showFullscreenFailure();
      return;
    }
    this.releaseInputs();
    if (this.keyboardFocused) this.keyboardFocus(false);
    const policy = this.fullscreenPolicy;
    const success = await policy.toggle();
    if (!this.pageActive || this.fullscreenPolicy !== policy) return;
    if (!success) this.showFullscreenFailure();
    this.focusInput();
  }

  private showFullscreenFailure(): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: translate('全屏切换失败，请稍后重试', this.uiLanguage), duration: 2500 });
    } catch (_error) {}
  }

  private close(): void {
    if (this.retryTimer !== -1) clearInterval(this.retryTimer);
    this.retryTimer = -1;
    this.releaseInputs();
    if (this.token > 0) RustDeskNapi.stopSecondaryDisplay(this.token);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.terminateSelf().catch(() => {});
  }

  private releaseInputs(): void {
    if (this.token > 0) RustDeskNapi.releaseSecondaryButtons(this.token);
    this.mouseButtons = 0;
    this.touchId = -1;
    this.lastPoint = undefined;
    this.touchCursorVisible = false;
    this.wheel.reset();
    this.touchWheel.reset();
    this.touchGesture.reset();
    this.clearTouchLongPress();
  }

  private modifiers(event: BaseEvent): number {
    if (event.getModifierKeyState === undefined) return 0;
    let mask = 0;
    try { if (event.getModifierKeyState(['Ctrl'])) mask |= 1; } catch (_error) {}
    try { if (event.getModifierKeyState(['Shift'])) mask |= 2; } catch (_error) {}
    try { if (event.getModifierKeyState(['Alt'])) mask |= 4; } catch (_error) {}
    try { if (event.getModifierKeyState(['Meta'])) mask |= 8; } catch (_error) {}
    return mask;
  }

  private point(x: number, y: number, held: boolean): SecondaryPoint | undefined {
    return secondaryRemotePoint(x, y, this.areaWidth, this.areaHeight, this.remoteWidth, this.remoteHeight, held,
      this.zoom, this.panX, this.panY);
  }

  private focusInput(): void {
    try { this.getUIContext().getFocusController().requestFocus('extended-remote-input'); } catch (_error) {}
  }

  private keyboardFocus(focused: boolean): void {
    this.keyboardFocused = focused;
    if (this.token > 0) RustDeskNapi.setSecondaryKeyboardFocus(this.token, focused);
  }

  private keyboard(event: KeyEvent): boolean {
    if (!this.keyboardFocused || !this.frameReady || this.token <= 0 ||
      event.keySource === KeySource.JOYSTICK ||
      (event.type !== KeyType.Down && event.type !== KeyType.Up)) return false;
    let mask = 0; let valid = false;
    if (event.getModifierKeyState !== undefined) {
      try {
        if (event.getModifierKeyState(['Ctrl'])) mask |= 1;
        if (event.getModifierKeyState(['Shift'])) mask |= 2;
        if (event.getModifierKeyState(['Alt'])) mask |= 4;
        if (event.getModifierKeyState(['Meta'])) mask |= 8;
        valid = true;
      } catch (_error) {}
    }
    const caps = event.isCapsLockOn === undefined ? -1 : event.isCapsLockOn ? 1 : 0;
    return RustDeskNapi.queueSecondaryKey(this.token, event.keyCode,
      event.type === KeyType.Down ? 0 : 1, mask, valid, caps) === 0;
  }

  private showTouchCursor(point: SecondaryPoint): void {
    if (this.remoteWidth <= 0 || this.remoteHeight <= 0) return;
    const scale = Math.min(this.areaWidth / this.remoteWidth, this.areaHeight / this.remoteHeight) * this.zoom;
    this.touchCursorX = (this.areaWidth - this.remoteWidth * scale) / 2 + this.panX + point.x * scale;
    this.touchCursorY = (this.areaHeight - this.remoteHeight * scale) / 2 + this.panY + point.y * scale;
    this.touchCursorVisible = true;
  }

  private mouse(event: MouseEvent): void {
    if (!this.frameReady || this.token <= 0 || this.touchId >= 0 || Date.now() - this.lastTouchAt < 450 ||
      isTouchOnlyMouseEvent(event.source === SourceType.TouchScreen, event.source === SourceType.Mouse,
        event.sourceTool === SourceTool.MOUSE || event.sourceTool === SourceTool.TOUCHPAD,
        event.sourceTool === SourceTool.Finger || event.sourceTool === SourceTool.Pen)) return;
    this.touchCursorVisible = false;
    const held = this.mouseButtons !== 0;
    const point = this.point(event.x, event.y, held);
    if (!point) { this.lastPoint = undefined; return; }
    let action = -1; let bit = 0;
    if (event.action === MouseAction.Move || event.action === MouseAction.Hover) action = 0;
    else {
      if (event.button === MouseButton.Left) bit = 1;
      else if (event.button === MouseButton.Right) bit = 2;
      else if (event.button === MouseButton.Middle) bit = 4;
      if (event.action === MouseAction.Release && bit === 0 && held) { this.releaseInputs(); return; }
      if (bit === 0) return;
      if (event.action === MouseAction.Press && (this.mouseButtons & bit) === 0) action = bit === 1 ? 1 : bit === 2 ? 3 : 5;
      if (event.action === MouseAction.Release && (this.mouseButtons & bit) !== 0) action = bit === 1 ? 2 : bit === 2 ? 4 : 6;
    }
    if (action < 0) return;
    if (event.action === MouseAction.Press) this.focusInput();
    if (action === 0 && Date.now() - this.lastMoveAt < 8) return;
    if (RustDeskNapi.sendSecondaryPointer(this.token, point.x, point.y, action, this.modifiers(event)) === 0) {
      if (action === 0) this.lastMoveAt = Date.now();
      this.lastPoint = point;
      if (action === 1 || action === 3 || action === 5) this.mouseButtons |= bit;
      if (action === 2 || action === 4 || action === 6) this.mouseButtons &= ~bit;
    }
    event.stopPropagation();
  }

  private axis(event: AxisEvent): void {
    if (!this.frameReady || this.token <= 0 || !this.lastPoint || this.touchId >= 0 ||
      Date.now() - this.lastTouchAt < 450 ||
      isTouchOnlyMouseEvent(event.source === SourceType.TouchScreen, event.source === SourceType.Mouse,
        event.sourceTool === SourceTool.MOUSE || event.sourceTool === SourceTool.TOUCHPAD,
        event.sourceTool === SourceTool.Finger || event.sourceTool === SourceTool.Pen)) return;
    if (event.action !== AxisAction.UPDATE && event.action !== AxisAction.BEGIN) { this.wheel.reset(); return; }
    const source: string = event.sourceTool === SourceTool.TOUCHPAD ? 'touchpad' : 'mouse';
    const step: RemoteWheelStep = this.wheel.convert(event.getHorizontalAxisValue(), -event.getVerticalAxisValue(),
      source, event.deviceId ?? -1, Date.now());
    if (step.x !== 0 || step.y !== 0) RustDeskNapi.sendSecondaryWheel(this.token, this.lastPoint.x, this.lastPoint.y,
      step.x, step.y, this.modifiers(event));
  }

  private touch(event: TouchEvent): void {
    if (!this.frameReady || this.token <= 0) return;
    if (event.source === SourceType.Mouse || event.sourceTool === SourceTool.MOUSE ||
      event.sourceTool === SourceTool.TOUCHPAD) return;
    this.lastTouchAt = Date.now();
    const kind = event.type === TouchType.Down ? 'down' : event.type === TouchType.Move ? 'move' :
      event.type === TouchType.Up ? 'up' : 'cancel';
    if (kind === 'cancel') { this.releaseInputs(); event.stopPropagation(); return; }
    const changed: SecondaryTouchPoint[] = event.changedTouches.map((item: TouchObject): SecondaryTouchPoint =>
      ({ id: item.id, x: item.x, y: item.y }));
    const points: SecondaryTouchPoint[] = event.touches.filter((item: TouchObject) =>
      kind !== 'up' || !changed.some((p: SecondaryTouchPoint) => p.id === item.id)).map((item: TouchObject): SecondaryTouchPoint =>
      ({ id: item.id, x: item.x, y: item.y }));
    if (kind === 'down' && points.length === 1 && this.mouseButtons === 0) {
      if (!this.point(points[0].x, points[0].y, false)) { this.touchDraining = true; return; }
      this.touchDraining = false; this.focusInput();
      this.clearTouchLongPress();
      this.longPressTimer = setTimeout(() => {
        this.longPressTimer = -1; this.sendTouchActions(this.touchGesture.longPress());
      }, 600);
    }
    if (this.touchDraining) { if (points.length === 0) this.touchDraining = false; return; }
    if (points.length >= 2 || kind === 'up') this.clearTouchLongPress();
    const actions = this.touchGesture.handle(kind, points, changed, Date.now());
    if (actions.some((item: SecondaryTouchAction) => item.kind === 'down')) this.clearTouchLongPress();
    this.sendTouchActions(actions);
    this.touchId = points.length > 0 ? points[0].id : -1;
    event.stopPropagation();
  }

  private clearTouchLongPress(): void {
    if (this.longPressTimer !== -1) clearTimeout(this.longPressTimer);
    this.longPressTimer = -1;
  }

  private sendTouchActions(actions: SecondaryTouchAction[]): void {
    for (const item of actions) {
      if (item.kind === 'release') { RustDeskNapi.releaseSecondaryButtons(this.token); continue; }
      if (item.kind === 'zoom') { this.applyTouchZoom(item); continue; }
      const point = this.point(item.x, item.y, item.kind === 'up' || item.kind === 'move' || item.kind === 'scroll');
      if (!point) continue;
      if (item.kind === 'preview') { this.showTouchCursor(point); continue; }
      if (item.kind === 'scroll') {
        const step = this.touchWheel.convert(-item.dx, -item.dy, 'touch', -1, Date.now());
        if (step.x !== 0 || step.y !== 0) RustDeskNapi.sendSecondaryWheel(this.token, point.x, point.y, step.x, step.y, 0);
        continue;
      }
      const first = item.kind === 'down' || item.kind === 'click' ? 1 :
        item.kind === 'up' ? 2 : item.kind === 'right' ? 3 : 0;
      const result = RustDeskNapi.sendSecondaryPointer(this.token, point.x, point.y, first, 0);
      if (result === 0) {
        this.lastPoint = point; this.showTouchCursor(point);
        if (item.kind === 'click' || item.kind === 'right')
          RustDeskNapi.sendSecondaryPointer(this.token, point.x, point.y, item.kind === 'click' ? 2 : 4, 0);
      }
      if (item.kind !== 'move') RustDeskNapi.appendDiagnosticLog('multi-display-input',
        `touch_action kind=${item.kind} result=${result}`);
    }
  }

  private applyTouchZoom(item: SecondaryTouchAction): void {
    if (!Number.isFinite(item.scale) || item.scale <= 0) return;
    const next = Math.max(1, Math.min(5, this.zoom * item.scale));
    const ratio = next / this.zoom;
    const cx = item.x - this.areaWidth / 2; const cy = item.y - this.areaHeight / 2;
    const x = cx - (cx - this.panX - item.dx) * ratio;
    const y = cy - (cy - this.panY - item.dy) * ratio;
    this.zoom = next;
    const limitX = Math.max(0, (this.surfaceWidth() - this.areaWidth) / 2);
    const limitY = Math.max(0, (this.surfaceHeight() - this.areaHeight) / 2);
    this.panX = Math.max(-limitX, Math.min(limitX, x));
    this.panY = Math.max(-limitY, Math.min(limitY, y));
    if (this.lastPoint) this.showTouchCursor(this.lastPoint);
  }

  private onRemoteDisplayChanged(): void {
    if (this.retryTimer !== -1) clearInterval(this.retryTimer);
    this.retryTimer = -1;
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
    this.releaseInputs();
    if (this.token > 0) RustDeskNapi.stopSecondaryDisplay(this.token);
    this.token = 0;
    this.started = false;
    this.frameReady = false;
    this.offerVp9 = false;
    this.remoteWidth = 0;
    this.remoteHeight = 0;
    this.zoom = 1; this.panX = 0; this.panY = 0;
    this.statusText = '正在切换扩展画面…';
    this.onSurface();
  }

  private onSurface(): void {
    if (this.started) return;
    let surface = '';
    try { surface = this.controller.getXComponentSurfaceId(); } catch (_error) {}
    const result = RustDeskNapi.startSecondaryDisplay(surface, this.remoteDisplay);
    if (result <= 0) {
      this.offerVp9 = result === -5;
      this.statusText = result === -5 ? '当前编码暂不支持扩展显示，可选择本次请求 VP9。' :
        '无法开启扩展画面，请检查远端多屏和设备支持情况。';
      RustDeskNapi.appendDiagnosticLog('multi-display', `secondary_start_failed code=${result}`);
      return;
    }
    this.offerVp9 = false;
    this.token = result;
    if (this.keyboardFocused) RustDeskNapi.setSecondaryKeyboardFocus(this.token, true);
    this.started = true;
    this.startedAt = Date.now();
    this.timer = setInterval(() => this.poll(), 300);
  }

  private retryWithVp9(): void {
    if (this.retryTimer !== -1) return;
    this.offerVp9 = false;
    const result = RustDeskNapi.fallbackVideoToVp9();
    RustDeskNapi.appendDiagnosticLog('multi-display', `vp9_request result=${result}`);
    if (result !== 0) { this.offerVp9 = true; this.statusText = '无法请求 VP9 编码。'; return; }
    this.statusText = '正在请求 VP9 编码…';
    let tries: number = 0;
    this.retryTimer = setInterval(() => {
      tries++;
      if (RustDeskNapi.getVideoFrame().codec === 2) {
        clearInterval(this.retryTimer); this.retryTimer = -1;
        RustDeskNapi.appendDiagnosticLog('multi-display', 'vp9_request ready');
        this.onSurface();
      } else if (tries >= 30 || RustDeskNapi.getConnectionStatus() !== ConnectionStatus.CONNECTED) {
        clearInterval(this.retryTimer); this.retryTimer = -1;
        this.offerVp9 = true;
        this.statusText = '远端未切换到 VP9，无法开启扩展画面。';
        RustDeskNapi.appendDiagnosticLog('multi-display', 'vp9_request timeout_or_disconnected');
      }
    }, 500);
  }

  private poll(): void {
    if (RustDeskNapi.getConnectionStatus() !== ConnectionStatus.CONNECTED) { this.close(); return; }
    const state: SecondaryDisplayState = RustDeskNapi.getSecondaryDisplayState();
    if (state.token !== this.token || (state.error === 0 && state.display !== this.remoteDisplay)) { this.close(); return; }
    if (state.error !== 0) {
      RustDeskNapi.stopSecondaryDisplay(this.token);
      this.token = 0;
      this.started = false;
      this.frameReady = false;
      this.offerVp9 = (state.error === -5 || state.error === -7) && RustDeskNapi.getVideoFrame().codec !== 2;
      this.statusText = state.error === -5 ? '远端编码暂不支持扩展显示。' : state.error === -7 ?
        '扩展画面解码失败，设备可能不支持同时解码该格式。' : '扩展画面已停止。';
      if (this.timer !== -1) clearInterval(this.timer);
      this.timer = -1;
      return;
    }
    this.remoteWidth = state.width;
    this.remoteHeight = state.height;
    this.frameReady = state.frames > 0;
    if (!this.frameReady && Date.now() - this.startedAt > 15000) {
      RustDeskNapi.stopSecondaryDisplay(this.token);
      this.token = 0;
      this.started = false;
      this.offerVp9 = RustDeskNapi.getVideoFrame().codec !== 2;
      this.statusText = '未收到扩展画面，请确认远端支持多屏；也可尝试 VP9。';
      if (this.timer !== -1) clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private surfaceWidth(): number {
    if (this.remoteWidth <= 0 || this.remoteHeight <= 0) return this.areaWidth;
    return Math.min(this.areaWidth, this.areaHeight * this.remoteWidth / this.remoteHeight) * this.zoom;
  }

  private surfaceHeight(): number {
    if (this.remoteWidth <= 0 || this.remoteHeight <= 0) return this.areaHeight;
    return Math.min(this.areaHeight, this.areaWidth * this.remoteHeight / this.remoteWidth) * this.zoom;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
    Column() {
      if (!this.fullscreen) {
        Row({ space: 8 }) {
          Text(`远端屏幕 ${this.remoteDisplay + 1}`).fontColor(Color.White).fontSize(15).layoutWeight(1)
          Button(translate('全屏', this.uiLanguage)).fontSize(14).focusable(false).enabled(!this.fullscreenBusy).onClick(() => { this.toggleFullscreen(); })
          Button('关闭扩展').fontSize(14).focusable(false).onClick(() => this.close())
        }.width('100%').height(48).padding({ left: 16, right: 16 }).backgroundColor('#172134')
      }
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ id: 'extended-remote-surface', type: XComponentType.SURFACE, controller: this.controller })
          .width(this.surfaceWidth()).height(this.surfaceHeight()).translate({ x: this.panX, y: this.panY })
          .hitTestBehavior(HitTestMode.None).onLoad(() => this.onSurface())
        if (this.frameReady && this.touchCursorVisible) {
          Path().commands('M 1 1 L 1 21 L 6.5 15.5 L 10.5 24 L 14 22.2 L 10 14.5 L 18 14.5 Z')
            .fill(Color.White).stroke('#E6000000').strokeWidth(1.4).width(20).height(26)
            .position({ x: this.touchCursorX, y: this.touchCursorY })
            .zIndex(11).hitTestBehavior(HitTestMode.None)
        }
        if (!this.frameReady) {
          Column({ space: 12 }) {
            Text(this.statusText).fontColor('#D7E6FF').fontSize(16)
            if (this.offerVp9) {
              Text('将请求本次连接使用 VP9，主画面也会受影响，可能降低流畅度；重新连接后恢复原设置。')
                .fontColor('#B8C8DD').fontSize(13).textAlign(TextAlign.Center)
              Button('本次请求 VP9').onClick(() => this.retryWithVp9())
            }
          }.padding(20).hitTestBehavior(HitTestMode.Default)
        }
      }.layoutWeight(1).width('100%').clip(true).backgroundColor('#090D14')
        .onMouse((event: MouseEvent) => this.mouse(event))
        .onAxisEvent((event: AxisEvent) => this.axis(event))
        .onTouch((event: TouchEvent) => this.touch(event))
        .onHover((hover: boolean) => { if (!hover && this.mouseButtons !== 0) this.releaseInputs(); })
        .onAreaChange((_old: Area, area: Area) => {
          this.areaWidth = Math.max(1, Number(area.width));
          this.areaHeight = Math.max(1, Number(area.height));
          const limitX = Math.max(0, (this.surfaceWidth() - this.areaWidth) / 2);
          const limitY = Math.max(0, (this.surfaceHeight() - this.areaHeight) / 2);
          this.panX = Math.max(-limitX, Math.min(limitX, this.panX));
          this.panY = Math.max(-limitY, Math.min(limitY, this.panY));
          if (this.touchCursorVisible && this.lastPoint) this.showTouchCursor(this.lastPoint);
        })
    }.width('100%').height('100%').backgroundColor('#090D14').id('extended-remote-input')
      .focusable(true).onFocus(() => this.keyboardFocus(true))
      .onBlur(() => { this.keyboardFocus(false); this.releaseInputs(); })
      .onKeyEvent((event: KeyEvent) => this.keyboard(event))
    if (this.fullscreen) {
      Button(translate('退出全屏', this.uiLanguage)).fontSize(13).fontColor(Color.White).backgroundColor('#C5223044')
        .borderRadius(12).margin({ top: 10, right: 10 }).focusable(false).enabled(!this.fullscreenBusy)
        .onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .onMouse((event: MouseEvent) => { event.stopPropagation(); })
        .onClick(() => { this.toggleFullscreen(); }).zIndex(30)
    }
    }.width('100%').height('100%').backgroundColor('#090D14')
  }
}
