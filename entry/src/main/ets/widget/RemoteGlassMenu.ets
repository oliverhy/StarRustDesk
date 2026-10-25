import { RemoteGlassMenuMetrics, RemoteGlassMenuState, glassOrientationDescription } from '../model/RemoteGlassMenu';
import { RemoteGlassStyle as Style } from '../theme/RemoteGlassStyle';
import { translate } from '../utils/I18n';

@Component
export struct RemoteGlassMenu {
  @StorageLink('uiFontScale') uiFontScale: number = 1;
  @Prop state: RemoteGlassMenuState = new RemoteGlassMenuState();
  @Prop metrics: RemoteGlassMenuMetrics = { width: 224, height: 300, rowHeight: 36, contentHeight: 274,
    bodyHeight: 274, padding: 12, headerHeight: 26, segmentHeight: 40, screenHeight: 62, displayWidth: 70, footerHeight: 18, stacked: false };
  @Prop dark: boolean = false;
  @Prop language: string = 'zh-Hans';
  @State keyboardScrollY: number = 0;
  @State keyboardScrollAtEnd: boolean = false;
  @State menuScrollY: number = 0;
  @State menuScrollAtEnd: boolean = false;
  onAction: (action: string) => void = () => {};
  onOrderEdit: (key: string) => void = () => {};
  private keyboardScroller: Scroller = new Scroller();
  private menuScroller: Scroller = new Scroller();

  textColor(): string { return this.dark ? Style.TEXT_DARK : Style.TEXT; }
  blue(): string { return this.dark ? Style.BLUE_DARK : Style.BLUE; }
  selected(): string { return this.dark ? Style.SELECTED_DARK : Style.SELECTED; }
  keyColor(): string { return this.dark ? Style.KEY_DARK : Style.KEY; }
  title(): string {
    switch (this.state.category) {
      case 'screens': return '选择屏幕';
      case 'input': return '输入';
      case 'keyboard': return '键盘';
      case 'view': return '画面';
      case 'more': return '更多';
      default: return this.state.projection ? '投屏方向' : '屏幕方向';
    }
  }
  icon(key: string): Resource {
    switch (key) {
      case 'mouse': case 'mouseSettings': return $r('app.media.glass_mouse');
      case 'touch': case 'gestureHelp': return $r('app.media.remote_input_touch');
      case 'keyboardSettings': case 'release': case 'softKeyboard': return $r('app.media.keyboard_launcher');
      case 'upload': return $r('app.media.glass_file_upload');
      case 'download': return $r('app.media.glass_upload');
      case 'uploadFolder': return $r('app.media.glass_folder');
      case 'chat': return $r('app.media.glass_chat');
      case 'recording': return $r('app.media.glass_record');
      case 'recordings': return $r('app.media.glass_recordings');
      case 'privacy': return $r('app.media.glass_list');
      case 'monitor': return $r('app.media.glass_info');
      case 'sort': return $r('app.media.glass_sliders');
      case 'fullscreen': return $r('app.media.glass_fullscreen');
      case 'pip': return $r('app.media.glass_pip');
      case 'orientation': return $r('app.media.glass_orientation');
      default: return $r('app.media.glass_monitor');
    }
  }
  label(key: string): string {
    switch (key) {
      case 'virtualMouse': return '虚拟鼠标';
      case 'clipboard': return '剪贴板同步';
      case 'gestureHelp': return '手势说明';
      case 'keyboardSettings': return '键盘设置';
      case 'mouseSettings': return '鼠标设置';
      case 'pan': return '移动画面';
      case 'edgePan': return '边缘跟随';
      case 'fullscreen': return this.state.fullscreen ? '退出全屏' : '全屏';
      case 'pip': return this.state.pip ? '关闭小窗' : '画中画';
      case 'orientation': return this.state.projection ? '投屏方向' : '屏幕方向';
      case 'chat': return '聊天';
      case 'upload': return '发送文件';
      case 'uploadFolder': return '发送文件夹';
      case 'download': return '取回文件';
      case 'recording': return this.state.recording ? '停止录像' : '录像';
      case 'recordings': return '录像列表';
      case 'privacy': return this.state.privacyPending ? '隐私屏处理中' : '隐私屏';
      case 'monitor': return '连接信息';
      case 'sort': return '工具栏排序';
      case 'mobileActions': return '手机操作';
      case 'release': return '释放按键';
      case 'softKeyboard': return this.state.keyboardOpen ? '收起键盘' : '打开键盘';
      case 'immersive': return this.state.immersive ? '退出沉浸' : '沉浸窗口';
      case 'adjustWindow': return this.state.windowBusy ? '调整中…' : '调整窗口';
      default: return key;
    }
  }
  isToggle(key: string): boolean {
    return ['virtualMouse', 'clipboard', 'pan', 'edgePan', 'privacy', 'monitor'].includes(key);
  }
  isOn(key: string): boolean {
    switch (key) {
      case 'virtualMouse': return this.state.virtualMouse;
      case 'clipboard': return this.state.clipboard;
      case 'pan': return this.state.pan;
      case 'edgePan': return this.state.edgePan;
      case 'privacy': return this.state.privacy;
      case 'monitor': return this.state.monitor;
      default: return false;
    }
  }
  actionEnabled(key: string): boolean {
    if (['upload', 'uploadFolder', 'download'].includes(key)) return !this.state.transferBusy;
    if (key === 'privacy') return !this.state.privacyPending;
    if (key === 'adjustWindow') return !this.state.windowBusy && !this.state.fullscreen;
    return true;
  }
  gridKeys(): string[] {
    if (this.state.keyboardTab === 'function') return ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'];
    if (this.state.keyboardTab === 'modifiers') return ['Ctrl', 'Alt', 'Shift', 'Win/Cmd'];
    return this.state.keyboardItems.filter((key: string) => !key.includes('+') && key !== 'Ins');
  }
  gridRows(): number[] {
    const count = Math.ceil(this.gridKeys().length / (this.metrics.stacked ? 2 : 3));
    const rows: number[] = [];
    for (let index = 0; index < count; index++) rows.push(index);
    return rows;
  }
  rowKeys(row: number): string[] {
    const columns = this.metrics.stacked ? 2 : 3;
    return this.gridKeys().slice(row * columns, (row + 1) * columns);
  }
  displayIndexes(): number[] {
    const indexes: number[] = [];
    for (let index = 0; index < Math.max(1, this.state.displayCount); index++) indexes.push(index);
    return indexes;
  }
  shortcutKeys(): string[] {
    return this.state.keyboardItems.filter((key: string) => ['Ctrl+Alt+Del', 'Ctrl+Shift+Esc'].includes(key) &&
      (key !== 'Ctrl+Alt+Del' || this.state.canSendCtrlAltDel));
  }
  extraKeys(): string[] {
    return this.state.keyboardItems.filter((key: string) => key === 'Ins' || key === 'Ctrl+Shift+Del' || key === 'Alt+F4');
  }
  keySelected(key: string): boolean {
    const mask = key === 'Ctrl' ? 1 : key === 'Alt' ? 2 : key === 'Shift' ? 4 : key === 'Win/Cmd' ? 8 : 0;
    return (this.state.modifiers & mask) !== 0;
  }
  segmentSelected(key: string): boolean {
    if (key === 'mode-mouse') return this.state.inputMode === 'mouse';
    if (key === 'mode-touch') return this.state.inputMode !== 'mouse';
    if (key.startsWith('tab-')) return this.state.keyboardTab === key.substring(4);
    if (key.startsWith('view-')) return this.state.desktopViewMode === key.substring(5);
    if (key.startsWith('orientation-')) return this.state.orientation === key.substring(12) ||
      (key === 'orientation-auto' && this.state.orientation === 'system');
    return false;
  }
  keyLabel(key: string): string {
    switch (key) { case 'Left': return '←'; case 'Up': return '↑'; case 'Down': return '↓'; case 'Right': return '→'; default: return key; }
  }

  hasVerticalOverflow(): boolean {
    // The function/more key grids intentionally keep the approved compact
    // viewport and expose their remaining rows by scrolling. Their calculated
    // content height can equal the outer menu height even though the fixed tab
    // strip reduces the grid viewport, so keep the affordance explicit.
    if (this.state.category === 'keyboard' &&
      (this.state.keyboardTab === 'function' || this.state.keyboardTab === 'more')) return true;
    return this.metrics.contentHeight > this.metrics.bodyHeight + 1;
  }

  updateKeyboardScroll(): void {
    const offset: OffsetResult = this.keyboardScroller.currentOffset();
    this.keyboardScrollY = Math.abs(offset.yOffset);
    this.keyboardScrollAtEnd = this.keyboardScroller.isAtEnd();
  }

  updateMenuScroll(): void {
    const offset: OffsetResult = this.menuScroller.currentOffset();
    this.menuScrollY = Math.abs(offset.yOffset);
    this.menuScrollAtEnd = this.menuScroller.isAtEnd();
  }

  updateKeyboardScrollEdge(side: Edge): void {
    if (side === Edge.Top) { this.keyboardScrollY = 0; this.keyboardScrollAtEnd = false; }
    else if (side === Edge.Bottom) { this.keyboardScrollY = Math.max(1, this.keyboardScrollY); this.keyboardScrollAtEnd = true; }
  }

  updateMenuScrollEdge(side: Edge): void {
    if (side === Edge.Top) { this.menuScrollY = 0; this.menuScrollAtEnd = false; }
    else if (side === Edge.Bottom) { this.menuScrollY = Math.max(1, this.menuScrollY); this.menuScrollAtEnd = true; }
  }

  verticalSegment(key: string): boolean {
    return this.metrics.stacked && (key.startsWith('mode-') || key.startsWith('orientation-'));
  }

  screenCaptionWidth(display: number): number {
    const caption: string = translate(`屏幕 ${display + 1}`, this.language);
    let units: number = 0;
    for (let index = 0; index < caption.length; index++) units += caption.charCodeAt(index) <= 127 ? 8 : 13;
    return Math.max(this.metrics.displayWidth, Math.ceil(units * Math.max(1, this.uiFontScale) + 16));
  }

  @Builder
  divider() { Divider().height(1).color(Style.DIVIDER).margin({ top: 4, bottom: 4 }) }

  @Builder
  scrollHint(up: boolean) {
    Row() {
      Image($r('app.media.glass_chevron')).width(13).height(13).fillColor(this.blue())
        .rotate({ angle: up ? 270 : 90 }).hitTestBehavior(HitTestMode.None)
        .accessibilityText(translate('上滑查看更多', this.language))
    }.width(30).height(18).justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  keyboardScrollHint(up: boolean) {
    Row() {
      if ((up && this.keyboardScrollY > 0.5) || (!up && !this.keyboardScrollAtEnd)) {
        this.scrollHint(up)
      } else {
        Blank().width(30).height(18)
      }
    }.width('100%').height(18).justifyContent(FlexAlign.Center)
  }

  @Builder
  menuScrollHint(up: boolean) {
    Row() {
      if ((up && this.menuScrollY > 0.5) || (!up && !this.menuScrollAtEnd)) {
        this.scrollHint(up)
      } else {
        Blank().width(30).height(18)
      }
    }.width('100%').height(18).justifyContent(FlexAlign.Center)
  }

  @Builder
  text(label: string, secondary: boolean = false) {
    Text(translate(label, this.language)).fontFamily(Style.FONT).fontSize(13).fontWeight(500)
      .fontColor(secondary ? Style.SECONDARY : this.textColor()).wordBreak(WordBreak.BREAK_ALL)
      .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
  }

  @Builder
  actionContent(key: string) {
    Row({ space: 10 }) {
      if (this.state.category === 'more' || !this.isToggle(key)) {
        Image(this.icon(key)).width(17).height(17).fillColor(this.textColor()).flexShrink(0)
          .hitTestBehavior(HitTestMode.None)
      }
      Text(translate(this.label(key), this.language)).fontFamily(Style.FONT).fontSize(13).fontWeight(500)
        .fontColor(this.textColor()).layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
        .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
      if (this.isToggle(key)) {
        Toggle({ type: ToggleType.Switch, isOn: this.isOn(key) }).width(40).height(24)
          .selectedColor(Style.BLUE).switchPointColor('#FFFFFF').focusable(false)
          .accessibilityText(translate(this.label(key), this.language))
          .onChange((value: boolean) => { if (value !== this.isOn(key)) this.onAction(key); })
      } else {
        if (key === 'orientation') {
          Text(translate(this.state.orientation === 'portrait' ? '竖屏' : this.state.orientation === 'landscape' ? '横屏' : '自动', this.language))
            .fontFamily(Style.FONT).fontSize(12).fontColor(Style.SECONDARY).wordBreak(WordBreak.BREAK_ALL)
        }
        if (key !== 'release') {
          Image($r('app.media.glass_chevron')).width(12).height(12).fillColor(Style.SECONDARY)
            .hitTestBehavior(HitTestMode.None)
        }
      }
    }.width('100%').constraintSize({ minHeight: this.metrics.rowHeight }).padding({ left: 3, right: 2 })
  }

  @Builder
  action(key: string) {
    if (this.isToggle(key)) {
      Row() { this.actionContent(key) }.width('100%').constraintSize({ minHeight: this.metrics.rowHeight })
        .enabled(this.actionEnabled(key)).opacity(this.actionEnabled(key) ? 1 : 0.5)
        .id(`glass-action-${key}`)
        .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => { this.onOrderEdit(key); }))
    } else {
      Button({ type: ButtonType.Normal }) { this.actionContent(key) }
        .width('100%').constraintSize({ minHeight: this.metrics.rowHeight }).padding(0).backgroundColor(Color.Transparent)
        .borderRadius(7).focusable(false).enabled(this.actionEnabled(key)).opacity(this.actionEnabled(key) ? 1 : 0.5)
        .id(`glass-action-${key}`).accessibilityText(translate(this.label(key), this.language))
        .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => { this.onOrderEdit(key); }))
        .onClick(() => { this.onAction(key); })
    }
  }

  @Builder
  segment(key: string, label: string, selected: boolean, icon: string = '') {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 5 }) {
        if (this.segmentSelected(key) && !key.startsWith('tab-') && !key.startsWith('mode-') && !key.startsWith('orientation-')) { Text('✓').fontFamily(Style.FONT).fontSize(13).fontColor(this.blue()).flexShrink(0) }
        if (icon) { Image(this.icon(icon)).width(17).height(17).fillColor(this.segmentSelected(key) ? this.blue() : this.textColor()).flexShrink(0) }
        Text(translate(label, this.language)).fontFamily(Style.FONT).fontSize(13).fontWeight(this.segmentSelected(key) ? 600 : 500)
          .fontColor(this.segmentSelected(key) ? this.blue() : this.textColor()).layoutWeight(1).textAlign(TextAlign.Center).wordBreak(WordBreak.BREAK_ALL)
          .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
      }.width('100%').justifyContent(FlexAlign.Center)
    }.layoutWeight(this.verticalSegment(key) ? 0 : 1).width(this.verticalSegment(key) ? '100%' : undefined)
      .constraintSize({ minHeight: this.metrics.segmentHeight }).padding(3).focusable(false)
      .backgroundColor(this.segmentSelected(key) ? this.selected() : this.keyColor())
      .border({ width: this.segmentSelected(key) ? 1 : 0, color: Style.SELECTED_BORDER }).borderRadius(7)
      .id(`glass-segment-${key}`).accessibilityText(translate(label, this.language))
      .accessibilityDescription(translate(this.segmentSelected(key) ? '已选中' : '', this.language))
      .onClick(() => { this.onAction(key); })
  }

  @Builder
  input() {
    if (this.metrics.stacked) {
      Column({ space: 4 }) {
        this.segment('mode-mouse', '鼠标', this.state.inputMode === 'mouse', 'mouse')
        this.segment('mode-touch', '触摸', this.state.inputMode !== 'mouse', 'touch')
      }.width('100%').margin({ bottom: 8 })
    } else {
      Row({ space: 4 }) {
        this.segment('mode-mouse', '鼠标', this.state.inputMode === 'mouse', 'mouse')
        this.segment('mode-touch', '触摸', this.state.inputMode !== 'mouse', 'touch')
      }.width('100%').margin({ bottom: 8 })
    }
    ForEach(this.state.items.filter((key: string) => key !== 'input' && key !== 'gestureHelp'), (key: string) => {
      this.action(key)
    }, (key: string) => key)
    this.divider()
    this.action('gestureHelp')
    this.action('keyboardSettings')
    this.action('mouseSettings')
  }

  @Builder
  screens() {
    Scroll() {
      Row({ space: 5 }) {
        ForEach(this.displayIndexes(), (display: number) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 5 }) {
              Image($r('app.media.glass_monitor')).width(23).height(23)
                .fillColor(display === this.state.currentDisplay ? this.blue() : this.textColor())
              Text(translate(`屏幕 ${display + 1}`, this.language)).fontFamily(Style.FONT).fontSize(12).wordBreak(WordBreak.BREAK_ALL)
                .fontWeight(display === this.state.currentDisplay ? 600 : 500)
                .fontColor(display === this.state.currentDisplay ? this.blue() : this.textColor())
            }
          }.width(this.screenCaptionWidth(display)).height(this.metrics.screenHeight).padding(4).focusable(false)
            .backgroundColor(display === this.state.currentDisplay ? this.selected() : this.keyColor())
            .border({ width: 1, color: display === this.state.currentDisplay ? Style.SELECTED_BORDER : Style.DIVIDER })
            .borderRadius(7).id(`glass-display-${display}`)
            .gesture(LongPressGesture({ duration: 550 }).onAction(() => { this.onOrderEdit('displays'); }))
            .onClick(() => { this.onAction(`display-${display}`); })
        }, (display: number) => `display-${display}`)
      }
    }.width('100%').height(this.metrics.screenHeight + 8).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
  }

  @Builder
  zoomControls() {
    Row({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.glass_zoom_minus')).width(16).height(16)
          .objectFit(ImageFit.Contain).fillColor(this.textColor()).hitTestBehavior(HitTestMode.None)
      }.width(32).height(this.metrics.stacked ? this.metrics.rowHeight : 30).padding(0)
        .accessibilityText(translate('缩小', this.language))
        .id('glass-zoom-out')
        .backgroundColor(this.keyColor()).borderRadius({ topLeft: 6, bottomLeft: 6 }).focusable(false)
        .onClick(() => { this.onAction('zoomOut'); })
      Button({ type: ButtonType.Normal }) {
        Text(`${this.state.zoom}%`).fontFamily(Style.FONT).fontSize(12).fontColor(this.textColor())
      }.layoutWeight(1).padding(0)
        .constraintSize({ minHeight: this.metrics.stacked ? this.metrics.rowHeight : 30 })
        .backgroundColor(this.keyColor()).borderRadius(0).focusable(false)
        .border({ width: { left: 1, right: 1 }, color: Style.DIVIDER })
        .accessibilityText(translate('恢复 100% 并居中', this.language)).id('glass-zoom-reset')
        .onClick(() => { this.onAction('zoomReset'); })
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.glass_zoom_plus')).width(16).height(16)
          .objectFit(ImageFit.Contain).fillColor(this.textColor()).hitTestBehavior(HitTestMode.None)
      }.width(32).height(this.metrics.stacked ? this.metrics.rowHeight : 30).padding(0)
        .accessibilityText(translate('放大', this.language))
        .id('glass-zoom-in')
        .backgroundColor(this.keyColor()).borderRadius({ topRight: 6, bottomRight: 6 }).focusable(false)
        .onClick(() => { this.onAction('zoomIn'); })
    }.width(this.metrics.stacked ? '100%' : 122)
  }

  @Builder
  zoom() {
    if (this.metrics.stacked) {
      Column({ space: 4 }) {
        this.text('缩放')
        this.zoomControls()
      }.width('100%').padding({ left: 3, right: 2 })
    } else {
      Row() {
        Text(translate('缩放', this.language)).fontFamily(Style.FONT).fontSize(13).fontColor(this.textColor()).layoutWeight(1)
        this.zoomControls()
      }.width('100%').constraintSize({ minHeight: this.metrics.rowHeight }).padding({ left: 3, right: 2 })
    }
  }

  @Builder
  desktop() {
    Row({ space: 3 }) {
      this.segment('view-adaptive', '适应窗口', this.state.desktopViewMode === 'adaptive')
      this.segment('view-original', '原始比例', this.state.desktopViewMode === 'original')
      this.segment('view-custom', '自定义', this.state.desktopViewMode === 'custom')
    }.width('100%')
    Row() {
      Text(translate('显示比例', this.language)).fontFamily(Style.FONT).fontSize(12).fontColor(Style.SECONDARY).layoutWeight(1)
      Text(`${this.state.desktopPercent}%`).fontFamily(Style.FONT).fontSize(12).fontColor(this.textColor())
    }.width('100%').constraintSize({ minHeight: this.metrics.rowHeight }).padding({ left: 3, right: 2 })
    if (this.state.desktopViewMode === 'custom') {
      Slider({ value: this.state.desktopCustomPercent, min: 25, max: 300, step: 5 }).height(this.metrics.rowHeight)
        .onChange((value: number) => { this.onAction(`scale-${value}`); })
    }
    this.action('adjustWindow')
    this.action('immersive')
    Text(translate('按远端比例调整窗口，不拉伸画面', this.language)).fontFamily(Style.FONT).fontSize(11)
      .fontColor(Style.SECONDARY).wordBreak(WordBreak.BREAK_ALL).width('100%').constraintSize({ minHeight: this.metrics.rowHeight })
    this.divider()
  }

  @Builder
  view() {
    if (this.state.desktop) { this.desktop() }
    this.zoom()
    ForEach(this.state.items.filter((key: string) => key === 'pan' || key === 'edgePan'), (key: string) => {
      this.action(key)
    }, (key: string) => key)
    this.divider()
    ForEach(this.state.items.filter((key: string) => !['pan', 'edgePan', 'zoomIn', 'zoomOut'].includes(key)), (key: string) => {
      this.action(key)
    }, (key: string) => key)
  }

  @Builder
  more() {
    Text(translate('文件传输', this.language)).fontFamily(Style.FONT).fontSize(11).fontColor(Style.SECONDARY).constraintSize({ minHeight: 20 })
    ForEach(this.state.items.filter((key: string) => ['upload', 'uploadFolder', 'download'].includes(key)), (key: string) => {
      this.action(key)
    }, (key: string) => key)
    this.divider()
    ForEach(this.state.items.filter((key: string) => !['upload', 'uploadFolder', 'download'].includes(key)), (key: string) => {
      this.action(key)
    }, (key: string) => key)
    this.divider()
    this.action('monitor')
    this.action('sort')
  }

  @Builder
  keyCap(key: string) {
    Button(this.keyLabel(key), { type: ButtonType.Normal }).layoutWeight(1).constraintSize({ minHeight: this.metrics.rowHeight })
      .labelStyle({ maxLines: 100, overflow: TextOverflow.Clip }).padding(3).fontFamily(Style.FONT).fontSize(12).fontColor(this.keySelected(key) ? this.blue() : this.textColor())
      .backgroundColor(this.keySelected(key) ? this.selected() : this.keyColor())
      .border({ width: 1, color: this.keySelected(key) ? Style.SELECTED_BORDER : Style.DIVIDER })
      .borderRadius(Style.KEY_RADIUS).focusable(false).id(`glass-key-${key}`)
      .gesture(LongPressGesture({ duration: 550 }).onAction(() => { this.onOrderEdit(`key-${key}`); }))
      .onClick(() => { this.onAction(`key-${key}`); })
  }

  @Builder
  keyboard() {
    Column() {
      if (this.hasVerticalOverflow()) { this.keyboardScrollHint(true) }
      Scroll(this.keyboardScroller) {
        Column() {
          ForEach(this.gridRows(), (row: number) => {
            Row({ space: 5 }) {
              ForEach(this.rowKeys(row), (key: string) => { this.keyCap(key) }, (key: string) => key)
              if (this.rowKeys(row).length < (this.metrics.stacked ? 2 : 3)) { Blank().layoutWeight(1) }
            }.width('100%').margin({ bottom: 4 })
          }, (row: number) => `row-${row}-${this.state.keyboardTab}`)
          this.divider()
          if (this.state.keyboardTab === 'more') {
            ForEach(this.shortcutKeys(), (key: string) => {
              Row() { this.keyCap(key) }.width('100%').margin({ bottom: 4 })
            }, (key: string) => key)
            if (this.extraKeys().length > 0) {
              this.divider()
              ForEach(this.extraKeys(), (key: string) => {
                Row() { this.keyCap(key) }.width('100%').margin({ bottom: 4 })
              }, (key: string) => key)
            }
          } else if (this.state.keyboardTab === 'modifiers') { this.action('softKeyboard') }
        }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
        .onScroll(() => { this.updateKeyboardScroll(); })
        .onScrollStop(() => { this.updateKeyboardScroll(); })
        .onScrollEdge((side: Edge) => { this.updateKeyboardScrollEdge(side); })
      if (this.hasVerticalOverflow()) { this.keyboardScrollHint(false) }
    }.width('100%').layoutWeight(1)
    Row({ space: 0 }) {
      this.segment('tab-modifiers', '修饰键', this.state.keyboardTab === 'modifiers')
      this.segment('tab-function', '功能键', this.state.keyboardTab === 'function')
      this.segment('tab-more', '更多按键', this.state.keyboardTab === 'more')
    }.width('100%').margin({ top: 8 })
  }

  @Builder
  orientationSegments() {
    if (this.metrics.stacked) {
      Column({ space: 2 }) {
        this.segment('orientation-auto', '自动', this.state.orientation === 'auto' || this.state.orientation === 'system')
        this.segment('orientation-portrait', '竖屏', this.state.orientation === 'portrait')
        this.segment('orientation-landscape', '横屏', this.state.orientation === 'landscape')
      }.width('100%')
    } else {
      Row({ space: 0 }) {
        this.segment('orientation-auto', '自动', this.state.orientation === 'auto' || this.state.orientation === 'system')
        this.segment('orientation-portrait', '竖屏', this.state.orientation === 'portrait')
        this.segment('orientation-landscape', '横屏', this.state.orientation === 'landscape')
      }.width('100%')
    }
  }

  @Builder
  orientation() {
    if (!this.state.projection) {
      Row({ space: 8 }) {
        Text(translate('跟随系统旋转', this.language)).fontFamily(Style.FONT).fontSize(13).fontColor(this.textColor()).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.state.followSystem }).width(40).height(24)
          .selectedColor(Style.BLUE).switchPointColor('#FFFFFF').focusable(false).id('glass-follow-system')
          .onChange((value: boolean) => { if (value !== this.state.followSystem) this.onAction('follow-system'); })
      }.width('100%').constraintSize({ minHeight: this.metrics.rowHeight }).margin({ bottom: 10 })
    }
    if (!this.state.followSystem || this.state.projection) { this.orientationSegments() }
    Text(translate(glassOrientationDescription(this.state), this.language))
      .fontFamily(Style.FONT).fontSize(11).fontColor(Style.SECONDARY).wordBreak(WordBreak.BREAK_ALL)
      .width('100%').constraintSize({ minHeight: this.metrics.footerHeight }).margin({ top: 10 })
    if (this.state.orientationError) {
      Text(translate(this.state.orientationError, this.language)).fontFamily(Style.FONT).fontSize(11).fontColor('#D84A4A').wordBreak(WordBreak.BREAK_ALL)
    }
  }

  build() {
    Column() {
        Row({ space: 8 }) {
          Text(translate(this.title(), this.language)).fontFamily(Style.FONT).fontSize(14).fontWeight(600)
            .fontColor(this.textColor()).layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
          if (this.state.category === 'keyboard') {
            Button({ type: ButtonType.Normal }) {
              Text(translate(this.label('release'), this.language)).fontFamily(Style.FONT).fontSize(11)
                .wordBreak(WordBreak.BREAK_ALL).fontColor(this.blue())
                .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
            }.constraintSize({ minHeight: this.metrics.headerHeight, maxWidth: '65%' })
              .padding({ left: 6, right: 3, top: 0, bottom: 0 }).backgroundColor(Color.Transparent)
              .borderRadius(5).focusable(false).id('glass-action-release')
              .accessibilityText(translate(this.label('release'), this.language))
              .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => { this.onOrderEdit('release'); }))
              .onClick(() => { this.onAction('release'); })
          }
          if (this.state.category === 'orientation' && this.state.projection) {
            Text(translate('仅本次', this.language)).fontFamily(Style.FONT).fontSize(12).fontColor(Style.SECONDARY)
          }
        }.width('100%').constraintSize({ minHeight: this.metrics.headerHeight })
        if (this.state.category === 'keyboard') { this.keyboard() }
        else {
          if (this.hasVerticalOverflow()) { this.menuScrollHint(true) }
          Scroll(this.menuScroller) {
            Column() {
              if (this.state.category === 'screens') { this.screens() }
              else if (this.state.category === 'input') { this.input() }
              else if (this.state.category === 'view') { this.view() }
              else if (this.state.category === 'more') { this.more() }
              else if (this.state.category === 'orientation') { this.orientation() }
            }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
            .onScroll(() => { this.updateMenuScroll(); })
            .onScrollStop(() => { this.updateMenuScroll(); })
            .onScrollEdge((side: Edge) => { this.updateMenuScrollEdge(side); })
          if (this.hasVerticalOverflow()) { this.menuScrollHint(false) }
        }
    }.width('100%').height(this.metrics.bodyHeight).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
  }
}
