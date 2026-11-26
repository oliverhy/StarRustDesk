import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { REMOTE_CONTROL_CATEGORIES, remoteControlCategoryLabel, RemoteMenuAnchor } from '../model/RemoteControlMenu';
import { toolbarAxisFraction, toolbarAxisPosition, toolbarDockEdge } from '../model/RemoteToolbarPlacement';
import { RemoteGlassMenu } from './RemoteGlassMenu';
import { glassMenuMetrics, placeGlassMenu, RemoteGlassMenuMetrics, RemoteGlassMenuPlacement, RemoteGlassMenuState } from '../model/RemoteGlassMenu';
import { STREAM_KEYS, StreamControlsBack, streamKeyCode, streamKeyGrid } from '../model/SunshineControlMenu';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { ButtonShapeModifier } from '../theme/ButtonShapeModifier';
import { translate } from '../utils/I18n';
import { RemoteGlassStyle } from '../theme/RemoteGlassStyle';

const IME_SEED: string = '                    ';
// Same scrim as the RustDesk quality monitor: only the backdrop has alpha.
const MONITOR_SCRIM: string = '#96000000';
@Extend(Text)
function monitorLineStyle() {
  .width('100%').textAlign(TextAlign.Start).fontFamily(RemoteGlassStyle.FONT)
  .fontSize(12).fontColor('#FFF2F2F2').wordBreak(WordBreak.BREAK_ALL)
}
interface StreamToolbarLayout {
  x: number;
  y: number;
  collapsed: boolean;
  edge: string;
  touchMode?: boolean;
  virtualMouse?: boolean;
  pointerGain?: number;
  closeOnSubmit?: boolean;
  gridOrder?: string[];
}

@Component
export struct SunshineRemoteControls {
  @Prop dark: boolean = false;
  @Prop fontScale: number = 1;
  @Prop viewportW: number = 360;
  @Prop viewportH: number = 640;
  @Prop videoLeft: number = 0;
  @Prop videoTop: number = 0;
  @Prop videoW: number = 1;
  @Prop videoH: number = 1;
  @Prop @Watch('inputStateChanged') inputState: number = 0;
  @Prop route: string = '';
  @Prop fps: number = 0;
  @Prop rtt: number = 0;
  @Prop zoomPercent: number = 100;
  @Prop displayCatalog: number = 256;
  onChooseDisplay: (slot: number) => void = (_slot: number): void => {};
  @Prop fullscreen: boolean = false;
  @Prop orientation: string = 'system';
  @Prop orientationAvailable: boolean = false;
  @Prop receivedKbps: number = 0;
  @Prop requestKbps: number = 0;
  @Prop gapCount: number = 0;
  @Prop videoKbps: number = 0;
  @Prop sampledAt: string = '';
  @StorageLink('uiLanguage') private language: string = 'zh-Hans';
  @StorageLink('roundedRectButtons') private rectangular: boolean = true;
  back: StreamControlsBack = new StreamControlsBack();
  onFullscreen: () => void = (): void => {};
  onOrientation: (mode: string) => void = (_mode: string): void => {};
  @Prop hostKey: string = '';
  onToggleInput: () => void = (): void => {};
  onDisconnect: () => void = (): void => {};
  onScale: (value: number) => void = (_value: number): void => {};
  onPan: (dx: number, dy: number) => void = (_dx: number, _dy: number): void => {};
  onIme: (active: boolean) => void = (_active: boolean): void => {};
  onInput: (kind: number, flag: number, a: number, b: number, text: string) => boolean =
    (_kind: number, _flag: number, _a: number, _b: number, _text: string): boolean => false;
  @State private collapsed: boolean = false;
  @State private edge: string = '';
  @State private xFraction: number = -1;
  @State private yFraction: number = -1;
  @State private menu: string = '';
  @State private soft: boolean = false;
  @State private inputText: string = IME_SEED;
  @State private keyboardNote: string = '';
  @State private keyboardTab: string = 'modifiers';
  @State private modifiers: number[] = [];
  @State private touchMode: boolean = false;
  @State private virtualMouse: boolean = false;
  @State private monitor: boolean = false;
  @State private detail: string = '';
  @State private localPan: boolean = false;
  @State private pointerGain: number = 1.5;
  @State private closeOnSubmit: boolean = true;
  @State private gridOrder: string[] = streamKeyGrid([]);
  private panLastX: number = 0;
  private panLastY: number = 0;
  @State private infoX: number = -1;
  @State private infoY: number = 8;
  @State private infoH: number = 150;
  private infoStartX: number = 0;
  private infoStartY: number = 0;
  @State private anchors: RemoteMenuAnchor[] = [];
  @State private originX: number = 0;
  @State private originY: number = 0;
  private beforeDragX: number = -1;
  private beforeDragY: number = -1;
  private beforeDragEdge: string = '';
  private ignoreHandleUntil: number = 0;
  @State private launcherDX: number = 0;
  @State private launcherDY: number = 0;
  private launcherStartX: number = 0;
  private launcherStartY: number = 0;
  private ignoreLauncherUntil: number = 0;
  private composing: boolean = false;
  private committed: string = IME_SEED;
  private controller: TextInputController = new TextInputController();
  private focusTimer: number = -1;
  private gestureActive: boolean = false;
  private pressed: boolean = false;
  private multi: boolean = false;
  private moved: boolean = false;
  private startAt: number = 0;
  private lastTap: number = 0;
  private x: number = 0;
  private y: number = 0;
  private barOriginX: number = 0;
  private barOriginY: number = 0;
  private dragging: boolean = false;
  private store?: preferences.Preferences;

  aboutToAppear(): void {
    this.back.dismiss = (): boolean => {
      if (this.detail) { this.detail = ''; return true; }
      if (this.soft) { this.closeKeyboard(); return true; }
      if (this.menu) { this.selectMenu(this.menu); return true; }
      return false;
    };
    const context = this.getUIContext().getHostContext();
    if (!context || !/^[a-f0-9]{64}$/.test(this.hostKey)) return;
    try {
      this.store = preferences.getPreferencesSync(context, { name: 'sunshine_remote_layout_v1' });
      const value = this.store.getSync(this.hostKey, '');
      if (typeof value !== 'string' || !value) return;
      const parsed = JSON.parse(value) as StreamToolbarLayout;
      if (!Number.isFinite(parsed.x) || !Number.isFinite(parsed.y)) return;
      this.xFraction = Math.max(-1, Math.min(1, parsed.x));
      this.yFraction = Math.max(-1, Math.min(1, parsed.y));
      this.collapsed = parsed.collapsed === true;
      this.touchMode = parsed.touchMode === true;
      this.virtualMouse = parsed.virtualMouse === true;
      if (parsed.pointerGain !== undefined && [1, 1.5, 2].includes(parsed.pointerGain)) this.pointerGain = parsed.pointerGain;
      this.closeOnSubmit = parsed.closeOnSubmit !== false;
      if (Array.isArray(parsed.gridOrder)) this.gridOrder=streamKeyGrid(parsed.gridOrder);
      this.edge = ''; // As in remote control, docking requires a drag in this session.
    } catch (_error) {}
  }

  aboutToDisappear(): void {
    this.back.dismiss = (): boolean => false;
    this.balance();
    this.closeKeyboard();
  }
  inputStateChanged(): void {
    if (this.inputState !== 2) {
      this.modifiers = [];
      this.cancelTouch();
      this.closeKeyboard();
    }
  }

  private remember(): void {
    if (!this.store) return;
    const next: StreamToolbarLayout = { x: this.xFraction, y: this.yFraction, collapsed: this.collapsed, edge: '',
      touchMode: this.touchMode, virtualMouse: this.virtualMouse, pointerGain: this.pointerGain, closeOnSubmit: this.closeOnSubmit,
      gridOrder: this.gridOrder };
    try {
      this.store.putSync(this.hostKey, JSON.stringify(next));
      this.store.flush().catch((): void => {});
    } catch (_error) {}
  }

  private barW(): number {
    return Math.max(1, Math.min(this.viewportW - 16, this.collapsed ? (this.edge ? 16 : 56) :
      Math.ceil(38 * Math.max(1, this.fontScale)) * 5 + Math.ceil(68 * Math.max(1, this.fontScale)) + 92));
  }
  private barH(): number { return Math.max(1, Math.min(this.viewportH - 16, this.collapsed && !this.edge ? 54 :
    Math.ceil(40 + Math.max(0, this.fontScale - 1) * 20) + 22)); }
  private barX(): number {
    if (this.edge === 'left') return 0;
    if (this.edge === 'right') return Math.max(0, this.viewportW - this.barW());
    if (this.xFraction >= 0) return toolbarAxisPosition(this.xFraction, this.viewportW, this.barW());
    return this.collapsed ? Math.max(8, this.viewportW - this.barW() - 8) : Math.max(8, (this.viewportW - this.barW()) / 2);
  }
  private barY(): number {
    if (this.yFraction >= 0) return toolbarAxisPosition(this.yFraction, this.viewportH, this.barH());
    return Math.max(8, this.viewportH - this.barH() - 18);
  }
  private dragStart(): void {
    this.beforeDragX=this.xFraction; this.beforeDragY=this.yFraction; this.beforeDragEdge=this.edge;
    this.balance();
    this.menu = '';
    const previousX: number = this.barX();
    const oldWidth: number = this.barW();
    this.barOriginY = this.barY();
    const previousEdge: string = this.edge;
    this.edge = '';
    this.barOriginX = previousEdge === 'right' ? previousX + oldWidth - this.barW() : previousX;
    this.dragging = true;
  }
  private dragUpdate(dx: number, dy: number): void {
    this.xFraction = toolbarAxisFraction(this.barOriginX + dx, this.viewportW, this.barW(), 0.5);
    this.yFraction = toolbarAxisFraction(this.barOriginY + dy, this.viewportH, this.barH(), 0.8);
  }
  private dragEnd(): void {
    if (this.collapsed) {
      this.edge = toolbarDockEdge(this.barX(), this.viewportW, this.barW());
    }
    this.dragging = false;
    this.ignoreHandleUntil = Date.now() + 140;
    this.remember();
  }
  private handleTap(): void {
    if (this.dragging || Date.now() < this.ignoreHandleUntil) return;
    if (this.edge) {
      this.xFraction = this.edge === 'left' ? 0 : 1;
      this.edge = '';
    } else {
      this.collapsed = false;
    }
    this.remember();
  }
  private tone(): string { return this.dark ? RemoteGlassStyle.TEXT_DARK : RemoteGlassStyle.TEXT; }
  private panelTone(): string { return this.dark ? RemoteGlassStyle.SURFACE_DARK : RemoteGlassStyle.SURFACE; }
  private borderTone(): string { return this.dark ? RemoteGlassStyle.BORDER_DARK : RemoteGlassStyle.BORDER; }
  private selectedTone(): string { return this.dark ? RemoteGlassStyle.SELECTED_DARK : RemoteGlassStyle.SELECTED; }
  private cancelDrag(): void {
    this.xFraction=this.beforeDragX; this.yFraction=this.beforeDragY; this.edge=this.beforeDragEdge;
    this.dragging=false; this.ignoreHandleUntil=Date.now()+140;
  }
  private tr(label: string): string { return translate(label, this.language); }
  private blue(): string { return this.dark ? RemoteGlassStyle.BLUE_DARK : RemoteGlassStyle.BLUE; }
  private barIcon(category: string): ResourceColor {
    if (category === 'disconnect') return this.dark ? RustDeskTheme.CONTROL_DANGER_ICON_DARK : RustDeskTheme.ERROR;
    if (this.activeCategory() === category) return this.dark ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT;
    return this.dark ? RustDeskTheme.CONTROL_ICON_DARK : RustDeskTheme.CONTROL_ICON;
  }
  private activeCategory(): string { return this.menu === 'orientation' ? 'view' : this.menu; }
  private categoryWidth(category: string): number {
    const label=this.tr(remoteControlCategoryLabel(category)), scale=Math.max(1,this.fontScale);
    let units=0;
    for(let i=0;i<label.length;i++) units+=label.charCodeAt(i)<=127?7:12;
    return Math.max(Math.ceil(38*scale),Math.ceil(units*scale+12));
  }
  private icon(category: string): Resource {
    switch (category) {
      case 'screens': return $r('app.media.remote_menu_screens');
      case 'input': return $r('app.media.remote_menu_input');
      case 'keyboard': return $r('app.media.keyboard_launcher');
      case 'view': return $r('app.media.remote_menu_view');
      case 'disconnect': return $r('app.media.remote_menu_disconnect');
      default: return $r('app.media.remote_menu_more');
    }
  }
  private selectMenu(category: string): void {
    if (category === 'disconnect') {
      this.menu = '';
      this.balance();
      this.onDisconnect();
      return;
    }
    this.cancelTouch();
    this.closeKeyboard();
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
      this.menu = category === this.menu ? '' : category;
    });
  }

  private command(kind: number, flag: number = 0, a: number = 0, b: number = 0, text: string = ''): boolean {
    return this.inputState === 2 && this.onInput(kind, flag, a, b, text);
  }
  private tapKey(code: number): boolean {
    return this.command(5, 1, code) && this.command(5, 0, code);
  }
  private click(code: number): void {
    if (this.command(3, 1, code)) this.command(3, 0, code);
  }
  private modifier(code: number): void {
    if (this.inputState !== 2) return;
    const held = this.modifiers.includes(code);
    if (!this.command(5, held ? 0 : 1, code)) return;
    this.modifiers = held ? this.modifiers.filter((c: number) => c !== code) : this.modifiers.concat([code]);
  }
  private cancelTouch(): void {
    if (this.pressed) this.command(3, 0, 1);
    this.pressed = false;
    this.gestureActive = false;
    this.multi = false;
  }
  private balance(): void {
    this.cancelTouch();
    this.command(7);
    this.modifiers = [];
  }
  private absolute(x: number, y: number, width: number, height: number): void {
    const xx = Math.round(65535 * Math.min(1, Math.max(0, x / Math.max(width, 1))));
    const yy = Math.round(65535 * Math.min(1, Math.max(0, y / Math.max(height, 1))));
    this.command(1, 0, xx, yy);
  }
  private touch(event: TouchEvent, width: number, height: number, pad: boolean): void {
    event.stopPropagation();
    if (this.inputState !== 2 || event.type === TouchType.Cancel || event.touches.length > 2) {
      this.cancelTouch();
      return;
    }
    // ArkUI may still include the lifted finger in touches during Up, and
    // changedTouches can be empty after a window/layout transition.
    if (event.type === TouchType.Up) {
      if (!this.gestureActive) return;
      const short = Date.now() - this.startAt < 390;
      if (this.pressed) {
        this.command(3, 0, 1);
      } else if (!this.moved && !pad) {
        if (this.multi) { if (short) this.click(2); }
        else if (this.touchMode || short) this.click(short ? 1 : 2);
      }
      if (!this.multi && !this.moved && short && !pad) this.lastTap = Date.now();
      this.pressed = false;
      this.gestureActive = false;
      this.multi = false;
      return;
    }
    const point = event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
    if (!point) {
      this.cancelTouch();
      return;
    }
    const direct = this.touchMode && !pad;
    if (event.type === TouchType.Down && !this.gestureActive) {
      this.gestureActive = true;
      this.startAt = Date.now();
      this.moved = false;
      this.multi = false;
      this.x = point.x;
      this.y = point.y;
      if (direct) this.absolute(this.x, this.y, width, height);
      if (!direct && !pad && this.startAt - this.lastTap < 345) {
        this.pressed = this.command(3, 1, 1);
      }
      return;
    }
    if (!this.gestureActive) return;
    if (event.touches.length === 2) {
      const center = (point.y + event.touches[1].y) / 2;
      if (!this.multi) {
        if (this.pressed) this.command(3, 0, 1);
        this.pressed = false;
        this.multi = true;
        this.y = center;
      } else if (event.type === TouchType.Move && Math.abs(center - this.y) >= 12) {
        const step = Math.max(-4, Math.min(4, Math.trunc((center - this.y) / 12)));
        this.command(4, 0, step);
        this.moved = true;
        this.y = center;
      }
      return;
    }
    if (event.type === TouchType.Move && !this.multi) {
      const dx = point.x - this.x;
      const dy = point.y - this.y;
      if (Math.abs(dx) + Math.abs(dy) < (this.moved ? 1 : 5)) return;
      if (direct) {
        if (!this.moved) this.pressed = this.command(3, 1, 1);
        this.absolute(point.x, point.y, width, height);
      } else {
        this.command(2, 0, Math.max(-2048, Math.min(2048, Math.round(dx * this.pointerGain))),
          Math.max(-2048, Math.min(2048, Math.round(dy * this.pointerGain))));
      }
      this.moved = true;
      this.x = point.x;
      this.y = point.y;
    }
  }

  private closeKeyboard(): void {
    if (this.focusTimer !== -1) clearTimeout(this.focusTimer);
    this.focusTimer = -1;
    if (this.soft) {
      try { this.controller.stopEditing(); } catch (_error) {}
      this.onIme(false);
    }
    this.soft = false;
    this.inputText = IME_SEED;
    this.committed = IME_SEED;
    this.composing = false;
  }
  private toggleKeyboard(): void {
    if (this.soft) { this.closeKeyboard(); return; }
    if (this.inputState !== 2) {
      this.menu = 'input';
      if(this.collapsed){this.edge='';this.collapsed=false;}
      return;
    }
    this.cancelTouch();
    this.menu = '';
    this.inputText = IME_SEED;
    this.committed = IME_SEED;
    this.soft = true;
    this.onIme(true);
    this.keyboardNote = '';
    this.focusTimer = setTimeout((): void => {
      if (this.soft && this.inputState === 2) {
        this.getUIContext().getFocusController().requestFocus('sunshine-native-ime');
        this.controller.caretPosition(IME_SEED.length);
      }
    }, 80);
  }
  private changeText(value: string, preview?: PreviewText): void {
    if (!this.soft || this.inputState !== 2) return;
    this.inputText = value;
    this.composing = preview !== undefined && preview.value.length > 0;
    if (this.composing || value === this.committed) return;
    // Mirror the append/backspace behavior without logging the content or
    // issuing deletions for focus/reset callbacks or multiline clipboard text.
    if (!value || (value.length < IME_SEED.length && IME_SEED.startsWith(value))) return;
    const previous = this.committed;
    const emptyBufferWasReplaced = previous === IME_SEED && !value.startsWith(IME_SEED);
    if (value.startsWith(previous) || emptyBufferWasReplaced) {
      const delta = emptyBufferWasReplaced ? value : value.substring(previous.length);
      if (delta && !/[\x00-\x1F\x7F-\x9F]/.test(delta) && this.command(6, 0, 0, 0, delta)) {
        this.committed = value;
        this.keyboardNote = '';
      } else if (delta) {
        this.keyboardNote = '内容未发送，请检查连接或分段输入';
      }
    } else if (previous.startsWith(value) && previous.length - value.length === 1) {
      if (this.tapKey(8)) this.committed = value;
    } else {
      this.keyboardNote = '这次编辑未发送，请用退格后重新输入';
    }
  }

  private recordAnchor(category: string, area: Area): void {
    const x=Number(area.globalPosition.x), y=Number(area.globalPosition.y), w=Number(area.width), h=Number(area.height);
    if (![x,y,w,h].every((n: number) => Number.isFinite(n)) || w<=0 || h<=0) return;
    const old=this.anchors.find((v: RemoteMenuAnchor) => v.category===category);
    if (old && Math.abs(old.x-x)<0.5 && Math.abs(old.y-y)<0.5 && old.width===w && old.height===h) return;
    const next: RemoteMenuAnchor={category:category,x:x,y:y,width:w,height:h};
    this.anchors=this.anchors.filter((v: RemoteMenuAnchor)=>v.category!==category).concat([next]);
  }
  private glassState(): RemoteGlassMenuState {
    const state=new RemoteGlassMenuState();
    state.category=this.menu; state.zoom=this.zoomPercent; state.fullscreen=this.fullscreen;
    state.explicitActions=true;
    state.displayCount=Math.min(16,Math.max(1,this.displayCatalog>>8));
    state.currentDisplay=this.displayCatalog & 255;
    state.inputMode=this.touchMode?'touch':'mouse'; state.virtualMouse=this.virtualMouse;
    state.keyboardItems=this.gridOrder.concat(STREAM_KEYS.filter((k: string)=>k.includes('+') || k==='Ins'));
    state.keyboardTab=this.keyboardTab; state.keyboardOpen=this.soft;
    state.modifiers=(this.modifiers.includes(17)?1:0)|(this.modifiers.includes(18)?2:0)|
      (this.modifiers.includes(16)?4:0)|(this.modifiers.includes(91)?8:0);
    state.orientation=this.orientation; state.followSystem=this.orientation==='system';
    state.pan=this.localPan && this.zoomPercent>100;
    state.monitor=this.monitor;
    if (this.menu==='view') {
      state.items=this.orientationAvailable ? ['zoomOut','zoomIn','pan','fullscreen','orientation'] : ['zoomOut','zoomIn','pan','fullscreen'];
      if(this.zoomPercent<=100) state.disabledActions=['pan'];
    } else if (this.menu==='input') {
      state.items=['input','virtualMouse','controlAccess'];
      state.inputTools=['gestureHelp','keyboardSettings','mouseSettings'];
      state.controlAccess=this.inputState===2;
      state.virtualMouse=this.virtualMouse && state.controlAccess;
      if(!state.controlAccess) state.disabledActions=this.inputState===1?['controlAccess','virtualMouse']:['virtualMouse'];
      state.note=state.controlAccess?'已开启，本次有效':this.inputState===1?'正在核对授权…':
        this.inputState===3?'电脑助手未允许本次键鼠控制':this.inputState===4?'输入连接已中断，需手动重新开启':'现在只看画面';
    } else if (this.menu==='screens') state.note=state.currentDisplay===0 ? '当前串流来源：Windows 主屏' :
      '当前串流来源：屏幕 '+(state.currentDisplay+1);
    else if (this.menu==='more') state.items=['monitor','sort'];
    return state;
  }
  private metrics(): RemoteGlassMenuMetrics {
    return glassMenuMetrics(this.glassState(),this.viewportW,this.viewportH,this.fontScale);
  }
  private menuPlacement(): RemoteGlassMenuPlacement {
    const a=this.anchors.find((v: RemoteMenuAnchor)=>v.category===this.activeCategory());
    return placeGlassMenu(this.metrics(),this.viewportW,this.viewportH,a ? a.x-this.originX : this.barX(),
      a ? a.y-this.originY : this.barY(),a ? a.width : 38,a ? a.height : this.barH());
  }
  private sharedAction(action: string): void {
    if (/^display-\d+$/.test(action)) {
      const slot=Number(action.slice(8));
      if (slot>=0 && slot<(this.displayCatalog>>8) && slot!==(this.displayCatalog & 255)) {
        this.balance(); this.onChooseDisplay(slot);
      }
      this.menu=''; return;
    }
    if (action==='mode-touch' || action==='mode-mouse') { this.mode(action==='mode-touch'); return; }
    if (action==='controlAccess') { this.toggleRow('consent'); return; }
    if (action==='virtualMouse') { this.toggleRow('mouse'); return; }
    if (action==='monitor') { this.toggleRow('info'); return; }
    if (['gestureHelp','keyboardSettings','mouseSettings','sort'].includes(action)) { this.detail=action; return; }
    if (action==='pan') {
      if(this.zoomPercent>100) {
        this.cancelTouch(); this.localPan=!this.localPan; this.menu='';
        hilog.info(0x5338,'SesameSunshineUi','ui_local_view_pan_enabled=%{public}d',this.localPan?1:0);
      }
      return;
    }
    if (action==='zoomReset' || action==='zoomIn' || action==='zoomOut') {
      const scale=action==='zoomReset'?100:Math.max(50,Math.min(500,this.zoomPercent+(action==='zoomIn'?25:-25)));
      this.cancelTouch(); if(scale<=100)this.localPan=false; this.onScale(scale); return;
    }
    if (action==='fullscreen') { this.menu=''; this.onFullscreen(); return; }
    if (action==='orientation') { this.menu='orientation'; return; }
    if (action==='follow-system') { this.onOrientation(this.orientation==='system'?'auto':'system'); return; }
    if (['orientation-auto','orientation-portrait','orientation-landscape'].includes(action)) {
      this.onOrientation(action.substring(12)); return;
    }
    if (['tab-modifiers','tab-function','tab-more'].includes(action)) { this.keyboardTab=action.substring(4); return; }
    if (action==='release') {
      if(this.inputState===2)this.balance();
      else this.getUIContext().getPromptAction().showToast({message:this.tr('当前只看画面，没有按键需要释放')});
      return;
    }
    if (action==='softKeyboard') { this.toggleKeyboard(); return; }
    if (!action.startsWith('key-')) return;
    if (this.inputState!==2) { this.menu='input'; return; }
    const key=action.substring(4);
    if (['Ctrl','Alt','Shift','Win/Cmd'].includes(key)) { this.modifier(streamKeyCode(key)); return; }
    if (key==='Ctrl+Shift+Esc' || key==='Ctrl+Shift+Del' || key==='Alt+F4') {
      const parts=key==='Alt+F4'?[18,115]:[17,16,key==='Ctrl+Shift+Del'?46:27];
      const temporary: number[]=[];
      for (let i=0;i<parts.length-1;i++) {
        if (this.modifiers.includes(parts[i])) continue;
        if (!this.command(5,1,parts[i])) { this.balance(); return; }
        temporary.push(parts[i]);
      }
      const ok=this.tapKey(parts[parts.length-1]);
      for (let i=temporary.length-1;i>=0;i--) { if (!this.command(5,0,temporary[i])) { this.balance(); return; } }
      if (!ok) this.balance();
      return;
    }
    const code=streamKeyCode(key); if (code && !this.tapKey(code)) this.balance();
  }
  private mode(touch: boolean): void { this.cancelTouch(); this.lastTap=0; this.touchMode=touch; this.remember(); }
  private moveKey(key: string, step: number): void {
    const from=this.gridOrder.indexOf(key), to=from+step;
    if (Math.abs(step)!==1 || from<0 || to<0 || to>=this.gridOrder.length) return;
    const next=this.gridOrder.slice();
    next.splice(from,1); next.splice(to,0,key); this.gridOrder=next; this.remember();
  }
  private submitIme(event?: SubmitEvent): void {
    // Never send Enter for an unfinished composition or unsent edit. An IME
    // may hide itself after Done unless explicitly asked to keep editing.
    if (!this.soft || this.inputState!==2) return;
    if (this.composing || this.inputText!==this.committed || !this.tapKey(13)) {
      event?.keepEditableState(); return;
    }
    if (this.closeOnSubmit) this.closeKeyboard();
    else event?.keepEditableState();
  }
  private launchX(): number { return Math.max(0, Math.min(this.viewportW-52,Math.max(8,this.viewportW-64)+this.launcherDX)); }
  private launchY(): number {
    const base=this.viewportH-(this.soft?54:(this.viewportW>this.viewportH?118:this.barH()+78));
    return Math.max(0,Math.min(this.viewportH-46, Math.max(8,base)+this.launcherDY));
  }
  @Builder
  dragGrip() {
    Button('⋮').width(20).constraintSize({ minHeight:38 }).padding(0).fontSize(18)
      .fontColor(RemoteGlassStyle.SECONDARY).backgroundColor(Color.Transparent).focusable(false).id('sunshine-drag-controls')
      .accessibilityText(this.tr('拖动控栏'))
      .gesture(PanGesture({ fingers:1,direction:PanDirection.All,distance:4 }).onActionStart(()=>this.dragStart())
        .onActionUpdate((e: GestureEvent)=>this.dragUpdate(e.offsetX,e.offsetY))
        .onActionEnd(()=>this.dragEnd()).onActionCancel(()=>this.cancelDrag()))
  }
  @Builder
  controlBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.collapsed) {
        Button({ type:ButtonType.Normal }) {
          if (this.edge) {
            Row().width('100%').height('100%').backgroundColor('#B3A6A8AC')
              .borderRadius({topLeft:this.edge==='left'?0:10,bottomLeft:this.edge==='left'?0:10,
                topRight:this.edge==='right'?0:10,bottomRight:this.edge==='right'?0:10}).hitTestBehavior(HitTestMode.None)
          } else {
            Text(this.tr('控')).fontSize(16).fontWeight(600).fontColor(this.dark?RustDeskTheme.CONTROL_SELECTED_TEXT_DARK:RustDeskTheme.CONTROL_SELECTED_TEXT)
          }
        }.id('sunshine-remote-control-handle').width('100%').height('100%').padding(0).backgroundColor(Color.Transparent)
          .stateEffect(!this.edge).hoverEffect(this.edge?HoverEffect.None:HoverEffect.Auto)
          .borderRadius(this.edge?0:16).focusable(false).accessibilityText(this.tr('控'))
          .gesture(PanGesture({fingers:1,direction:PanDirection.All,distance:4}).onActionStart(()=>this.dragStart())
            .onActionUpdate((e: GestureEvent)=>this.dragUpdate(e.offsetX,e.offsetY))
            .onActionEnd(()=>this.dragEnd()).onActionCancel(()=>this.cancelDrag()))
          .onClick(()=>this.handleTap())
          .attributeModifier(new ButtonShapeModifier(this.edge?false:this.rectangular,this.edge?0:16,
            this.edge?ButtonType.Normal:ButtonType.Capsule))
      } else {
        Row({space:4}) {
          this.dragGrip()
          Scroll() {
            Row({space:3}) {
              ForEach(REMOTE_CONTROL_CATEGORIES,(category: string)=>{
                Button({type:ButtonType.Normal}) {
                  Column({space:3}) {
                    Image(this.icon(category)).width(20).height(20).fillColor(this.barIcon(category)).hitTestBehavior(HitTestMode.None)
                    Text(this.tr(remoteControlCategoryLabel(category))).fontFamily(RemoteGlassStyle.FONT).fontSize(11)
                      .wordBreak(WordBreak.BREAK_ALL).fontWeight(this.activeCategory()===category?600:500)
                      .fontColor(category==='disconnect'||this.activeCategory()===category?this.barIcon(category):this.tone())
                  }
                }.id('sunshine-menu-'+category).focusable(false)
                  .padding({left:2,right:2,top:3,bottom:3})
                  .width(this.categoryWidth(category))
                  .height(this.barH()-14).accessibilityText(this.tr(remoteControlCategoryLabel(category)))
                  .backgroundColor(this.activeCategory()===category?(this.dark?RustDeskTheme.CONTROL_SELECTED_BG_DARK:RustDeskTheme.CONTROL_SELECTED_BG):Color.Transparent)
                  .border({width:this.activeCategory()===category?1:0,color:this.dark?RustDeskTheme.CONTROL_SELECTED_BORDER_DARK:RustDeskTheme.CONTROL_SELECTED_BORDER})
                  .borderRadius(10)
                  .onAreaChange((_old: Area,area: Area)=>this.recordAnchor(category,area))
                  .onClick(()=>this.selectMenu(category))
              },(category: string)=>category)
            }.height('100%').alignItems(VerticalAlign.Center)
          }.layoutWeight(1).height('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          Button({type:ButtonType.Normal}) {
            Image($r('app.media.remote_keyboard_expand')).width(18).height(18).fillColor(this.barIcon('keyboard')).hitTestBehavior(HitTestMode.None)
          }.id('sunshine-collapse-controls').width(34).height(38).padding(0).focusable(false)
            .backgroundColor(this.dark?'#991C222D':'#99F7F9FD').border({width:1,color:this.borderTone()}).borderRadius(8)
            .accessibilityText(this.tr('收起')).onClick(()=>{this.cancelTouch(); this.menu=''; this.collapsed=true; this.remember();})
            .attributeModifier(new ButtonShapeModifier(this.rectangular,8,ButtonType.Capsule))
        }.width('100%').height('100%').padding(7)
      }
    }.id('sunshine-remote-toolbar').width(this.barW()).height(this.barH()).borderRadius(this.edge?0:16)
      .border({width:this.edge?0:1,color:this.dark?'#805C93E6':'#80518BDD'})
      .backgroundColor(this.edge?Color.Transparent:(this.dark?'#A61B2638':'#A6FFFFFF')).clip(true)
      .shadow({radius:this.edge?0:12,color:'#26000000',offsetY:4}).position({x:this.barX(),y:this.barY()})
  }

  @Builder
  note(label: string) {
    Text(this.tr(label)).fontFamily(RemoteGlassStyle.FONT).fontSize(12).fontColor(this.dark?'#B8C7DB':'#50647F')
      .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_ALL)
  }
  private toggleRow(key:string): void {
    if (key==='consent') {
      if(this.inputState!==1) { this.balance(); this.closeKeyboard(); this.onToggleInput(); }
    } else if (key==='mouse' && this.inputState===2) { this.virtualMouse=!this.virtualMouse; this.remember(); this.menu=''; }
    else if (key==='info') { this.monitor=!this.monitor; this.menu=''; }
  }
  @Builder
  menuOverlay() {
    Column().width('100%').height('100%').backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.Block)
      .onClick(()=>{this.menu='';})
    Column() {
      ForEach([this.menu],(category: string)=>{
        RemoteGlassMenu({state:this.glassState(),metrics:this.metrics(),dark:this.dark,language:this.language,
          onOrderEdit:(key:string)=>{
            if(this.menu==='keyboard' && this.keyboardTab==='more' && key.startsWith('key-') &&
              this.gridOrder.includes(key.substring(4))) this.detail='sort';
          },
          onAction:(action: string)=>{if(this.menu===category && !this.detail)this.sharedAction(action);}})
      },(category:string)=>category)
    }.id('sunshine-glass-menu').width(this.metrics().width).height(this.metrics().height).padding(12)
      .backgroundColor(this.panelTone()).backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN,{
        colorMode:this.dark?ThemeColorMode.DARK:ThemeColorMode.LIGHT,adaptiveColor:AdaptiveColor.DEFAULT,scale:.35})
      .border({width:1,color:this.borderTone()}).borderRadius(RemoteGlassStyle.RADIUS)
      .shadow({radius:20,color:'#33000000',offsetY:6})
      .position({x:this.menuPlacement().x,y:this.menuPlacement().y})
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({x:.97,y:.97})))
    if (this.menuPlacement().arrowVisible) {
      Polygon().width(16).height(9).points(this.menuPlacement().arrowAbove?[[0,9],[8,0],[16,9]]:[[0,0],[8,9],[16,0]])
        .id('sunshine-menu-pointer').fill(this.panelTone()).hitTestBehavior(HitTestMode.None)
        .position({x:this.menuPlacement().x+this.menuPlacement().arrowX-8,
          y:this.menuPlacement().arrowAbove?this.menuPlacement().y-8:this.menuPlacement().y+this.metrics().height-1})
    }
  }

  private detailTitle(): string {
    return this.detail==='sort'?'调整“更多”按键顺序':this.detail==='mouseSettings'?'鼠标设置':
      this.detail==='keyboardSettings'?'键盘设置':'手势操作指南';
  }
  @Builder
  guideRow(icon: Resource, label: string, description: string) {
    Row({space:12}) {
      Image(icon).width(46).height(42).objectFit(ImageFit.Contain).hitTestBehavior(HitTestMode.None)
      Column({space:4}) {
        Text(this.tr(label)).fontSize(14).fontWeight(600).fontColor(this.tone()).width('100%')
        this.note(description)
      }.layoutWeight(1)
    }.width('100%').padding(8).backgroundColor(this.dark?RemoteGlassStyle.KEY_DARK:RemoteGlassStyle.KEY).borderRadius(10)
  }
  @Builder
  option(label: string, active: boolean, id: string, callback: () => void) {
    Button(this.tr(label),{type:ButtonType.Normal}).id(id).fontSize(13)
      .labelStyle({maxLines:6,overflow:TextOverflow.Clip}).constraintSize({minHeight:36}).width('100%').padding(5)
      .fontColor(active?this.blue():this.tone()).backgroundColor(active?this.selectedTone():Color.Transparent)
      .borderRadius(8).accessibilityDescription(this.tr(active?'已选中':'')).onClick(callback)
  }
  @Builder
  detailOverlay() {
    Stack({alignContent:Alignment.Center}) {
      Column().width('100%').height('100%').backgroundColor('#55000000').hitTestBehavior(HitTestMode.Block)
        .onClick(()=>{this.detail='';})
      Column({space:8}) {
        Row({space:8}) {
          Text(this.tr(this.detailTitle())).fontSize(18).fontWeight(600).fontColor(this.tone()).layoutWeight(1)
          Button(this.tr('完成'),{type:ButtonType.Normal}).id('sunshine-detail-done').fontSize(13)
            .fontColor(this.blue()).backgroundColor(this.selectedTone()).borderRadius(8).onClick(()=>{this.detail='';})
        }.width('100%')
        Scroll() {
          Column({space:8}) {
            if(this.detail==='gestureHelp') {
              this.guideRow($r('app.media.guide_tap'),this.touchMode?'触摸模式':'鼠标模式',
                this.touchMode?'轻点画面，在对应位置单击。手指按下后拖动，可拖拽目标。':'滑动移动指针，轻点单击；轻点一次，再按住并移动可拖拽。')
              this.guideRow($r('app.media.guide_two_scroll'),'双指滑动','上下滑动滚动窗口；双指轻点为右键。')
              this.guideRow($r('app.media.guide_pan'),'移动画面','在“画面”中放大并开启“移动画面”，单指拖动只平移本地画面，不操作远端。')
            } else if(this.detail==='mouseSettings') {
              this.note('移动速度仅影响相对鼠标和虚拟鼠标，不改变触摸的落点。')
              ForEach([1,1.5,2],(gain:number)=>{
                this.option(gain===1?'慢速':gain===1.5?'标准':'快速',this.pointerGain===gain,'sunshine-gain-'+gain,
                  ()=>{this.pointerGain=gain;this.remember();})
              },(gain:number)=>String(gain))
            } else if(this.detail==='keyboardSettings') {
              this.note('仅在成功发送回车后生效；正在选词或未发送的内容不会触发回车。')
              this.option('提交后收起键盘',this.closeOnSubmit,'sunshine-submit-close',()=>{this.closeOnSubmit=true;this.remember();})
              this.option('连续输入，保持键盘',!this.closeOnSubmit,'sunshine-submit-continue',()=>{this.closeOnSubmit=false;this.remember();})
            } else if(this.detail==='sort') {
              this.note('调整键盘“更多”页的普通按键，自动保存到这台电脑。组合键保留在单独分组。')
              ForEach(this.gridOrder,(key:string,index:number)=>{
                Row({space:6}) {
                  Text(key).fontSize(14).fontColor(this.tone()).layoutWeight(1)
                  Button('↑').id('sunshine-key-up-'+key).enabled(index>0).accessibilityText(key+' 上移')
                    .width(38).height(32).padding(0).fontColor(this.blue()).backgroundColor(this.selectedTone()).onClick(()=>this.moveKey(key,-1))
                  Button('↓').id('sunshine-key-down-'+key).enabled(index<this.gridOrder.length-1).accessibilityText(key+' 下移')
                    .width(38).height(32).padding(0).fontColor(this.blue()).backgroundColor(this.selectedTone()).onClick(()=>this.moveKey(key,1))
                }.width('100%')
              },(key:string,index:number)=>key+':'+String(index))
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').constraintSize({maxHeight:Math.max(32,this.viewportH*.68-65)}).scrollBar(BarState.Auto)
      }.id('sunshine-detail-'+this.detail).width(Math.max(1,Math.min(420,this.viewportW-24))).padding(14).borderRadius(16)
        .backgroundColor(this.dark?'#F21B2638':'#F7FFFFFF').border({width:1,color:this.borderTone()})
        .hitTestBehavior(HitTestMode.Default).onClick(()=>{})
    }.width('100%').height('100%')
  }
  private infoWidth(): number {return Math.max(1,Math.min(200+48*(Math.max(1,this.fontScale)-1),this.viewportW-16));}
  private infoLeft(): number {
    const last=Math.max(0,this.viewportW-this.infoWidth()-8);
    return this.infoX<0?last:Math.max(Math.min(8,last),Math.min(last,this.infoX));
  }
  private infoTop(): number {return Math.max(0,Math.min(this.infoY,this.viewportH-this.infoH-8));}
  private rate(value:number): string {return value>0?(value/1000).toFixed(2)+' Mbps':'—';}
  @Builder
  monitorPanel() {
    Column({space:4}) {
      Row() {
        Text(this.tr('连接信息')).id('sunshine-monitor-grip').layoutWeight(1).fontWeight(600).fontColor(Color.White).fontSize(14)
          .constraintSize({minHeight:32}).accessibilityDescription(this.tr('可拖动'))
          .gesture(PanGesture({fingers:1,distance:4}).onActionStart(()=>{
            this.infoStartX=this.infoLeft(); this.infoStartY=this.infoTop();
          }).onActionUpdate((e:GestureEvent)=>{
            this.infoX=Math.max(0,this.infoStartX+e.offsetX); this.infoY=Math.max(0,this.infoStartY+e.offsetY);
          }))
        Button('×',{type:ButtonType.Normal}).id('sunshine-monitor-close').width(32).height(32).padding(0).focusable(false)
          .accessibilityText(this.tr('关闭')).backgroundColor(Color.Transparent).fontColor(Color.White).onClick(()=>{this.monitor=false;})
      }.width('100%')
      Scroll() {
        Column({space:4}) {
          Text(this.tr(this.route)+' · '+this.tr('已加密')).monitorLineStyle()
          Text(this.tr('实际帧率')+' '+(this.sampledAt ? this.fps.toFixed(1)+' FPS' : '—'))
            .id('sunshine-monitor-fps').monitorLineStyle()
          Text(this.tr('网络往返')+' '+(this.sampledAt && this.rtt>0 ? Math.round(this.rtt)+' ms' : '—'))
            .id('sunshine-monitor-rtt').monitorLineStyle()
          Text(this.tr('画面接收')+' '+(this.sampledAt ? (this.receivedKbps/1000).toFixed(2)+' Mbps' : '—'))
            .id('sunshine-monitor-received').monitorLineStyle()
          Text(this.tr('初始视频请求')+' '+this.rate(this.requestKbps)).monitorLineStyle()
          Text(this.tr('已应用视频码率')+' '+this.rate(this.videoKbps)).monitorLineStyle()
          Text(this.tr('累计视频帧缺口')+' '+this.gapCount).id('sunshine-monitor-gaps').monitorLineStyle()
          Text(this.sampledAt ? this.tr('最近采样')+' '+this.sampledAt : this.tr('等待数据'))
            .id('sunshine-monitor-sample').monitorLineStyle()
        }.width('100%').backgroundColor(Color.Transparent)
      }.width('100%').backgroundColor(Color.Transparent)
        .constraintSize({maxHeight:Math.max(24,this.viewportH*.62-56)}).scrollBar(BarState.Auto)
    }.id('sunshine-monitor').width(this.infoWidth()).padding(10)
      .backgroundColor(MONITOR_SCRIM).borderRadius(12).border({width:1,color:'#4DFFFFFF'})
      .hitTestBehavior(HitTestMode.Default).onClick(()=>{}).position({x:this.infoLeft(),y:this.infoTop()})
      .onAreaChange((_old:Area,area:Area)=>{const h=Number(area.height); if(h>0 && h!==this.infoH)this.infoH=h;})
  }

  @Builder
  wheel(part: number) {
    Button({ type: ButtonType.Normal }) {
      Image(part > 0 ? $r('app.media.virtual_mouse_wheel_up') : part < 0 ? $r('app.media.virtual_mouse_wheel_down') :
        $r('app.media.virtual_mouse_wheel_grip')).width(16).height(16).fillColor(this.tone()).hitTestBehavior(HitTestMode.None)
    }.width('100%').height(28).padding(0).backgroundColor(Color.Transparent).focusable(false)
      .accessibilityText(this.tr(part > 0 ? '向上滚动' : part < 0 ? '向下滚动' : '鼠标中键'))
      .onClick(() => { if (part === 0) this.click(3); else this.command(4, 0, part); })
  }
  @Builder
  virtualPad() {
    Column({ space: 3 }) {
      Row({ space: 2 }) {
        Button(this.tr('左键'),{type:ButtonType.Normal}).layoutWeight(1).height(84).padding(0).fontSize(14)
          .fontColor(this.tone()).borderRadius(8).backgroundColor(this.selectedTone()).onClick(() => this.click(1)).focusable(false)
        Column() { this.wheel(1); this.wheel(0); this.wheel(-1) }.width(32)
        Button(this.tr('右键'),{type:ButtonType.Normal}).layoutWeight(1).height(84).padding(0).fontSize(14)
          .fontColor(this.tone()).borderRadius(8).backgroundColor(this.selectedTone()).onClick(() => this.click(2)).focusable(false)
      }.width('100%')
      Text('⠿  移动').width('100%').height(42).textAlign(TextAlign.Center).fontColor(this.tone())
        .borderRadius(8).backgroundColor(this.selectedTone()).onTouch((event: TouchEvent) => {
          this.touch(event, 138, 42, true);
        })
    }.width(146).padding(4).borderRadius(15).backgroundColor(this.panelTone())
      .border({ width: 1, color: this.borderTone() })
      .position({ x: 10, y: Math.min(Math.max(8,this.viewportH-146),Math.max(8, this.barY() - 146)) })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack().id('sunshine-touch-surface').width(this.videoW).height(this.videoH)
        .position({ x: this.videoLeft, y: this.videoTop }).onTouch((event: TouchEvent) => {
          this.touch(event, this.videoW, this.videoH, false);
        })
      if (this.localPan && this.zoomPercent>100) {
        Stack().id('sunshine-local-pan').width('100%').height('100%').hitTestBehavior(HitTestMode.Block)
          .accessibilityText(this.tr('移动画面'))
          .accessibilityDescription(this.tr(Math.abs(this.videoLeft-(this.viewportW-this.videoW)/2)>1 ||
            Math.abs(this.videoTop-(this.viewportH-this.videoH)/2)>1 ? '画面已平移':'画面居中'))
          .onTouch((e:TouchEvent)=>e.stopPropagation())
          .gesture(PanGesture({fingers:1,distance:2}).onActionStart(()=>{this.panLastX=0;this.panLastY=0;})
            .onActionUpdate((e:GestureEvent)=>{
              this.onPan(e.offsetX-this.panLastX,e.offsetY-this.panLastY);this.panLastX=e.offsetX;this.panLastY=e.offsetY;
            }))
      }
      if (!this.localPan && this.virtualMouse && this.inputState === 2 && !this.menu && !this.soft) this.virtualPad()
      if (this.monitor && !this.soft) this.monitorPanel()
      if (this.menu && !this.detail) this.menuOverlay()
      if (!this.soft) this.controlBar()
      Button({ type: ButtonType.Normal }) {
        Image($r('app.media.keyboard_launcher')).width(26).height(26)
          .fillColor(this.soft?this.blue():(this.dark?RustDeskTheme.CONTROL_ICON_DARK:RustDeskTheme.CONTROL_ICON))
          .hitTestBehavior(HitTestMode.None)
      }.id('sunshine-keyboard-launcher').width(52).height(46).padding(0).borderRadius(16).focusable(false)
        .backgroundColor(this.soft ? this.selectedTone() : (this.dark?'#D91B2638':'#D9FFFFFF'))
        .border({ width: 1, color: this.soft?RemoteGlassStyle.SELECTED_BORDER:(this.dark?'#805C93E6':'#80518BDD') })
        .borderRadius(16).shadow({ radius: 10, color: '#26000000', offsetY: 3 })
        .position({ x: this.launchX(), y: this.launchY() })
        .gesture(PanGesture({fingers:1,direction:PanDirection.All,distance:5})
          .onActionStart(()=>{this.launcherStartX=this.launcherDX;this.launcherStartY=this.launcherDY;})
          .onActionUpdate((e:GestureEvent)=>{
            this.launcherDX=this.launcherStartX+e.offsetX;this.launcherDY=this.launcherStartY+e.offsetY;
          }).onActionEnd(()=>{this.ignoreLauncherUntil=Date.now()+140;})
          .onActionCancel(()=>{this.launcherDX=this.launcherStartX;this.launcherDY=this.launcherStartY;this.ignoreLauncherUntil=Date.now()+140;}))
        .accessibilityText(this.tr(this.soft ? '收起键盘' : '打开键盘'))
        .onClick(() => { if(Date.now()>=this.ignoreLauncherUntil)this.toggleKeyboard(); })
      if (this.soft && this.inputState === 2) {
        TextInput({ text: this.inputText, controller: this.controller })
          .id('sunshine-native-ime').width(28).height(25).opacity(0.01)
          .fontSize(1).fontColor(Color.Transparent).backgroundColor(Color.Transparent).caretColor(Color.Transparent)
          .padding(0).border({ width: 0 }).position({ x: 0, y: 0 }).focusable(true).defaultFocus(true)
          .type(InputType.Normal).enterKeyType(EnterKeyType.Done).maxLength(1024).enablePreviewText(true)
          .onEditChange((editing: boolean) => {
            if (editing && this.soft && this.inputState === 2) {
              hilog.info(0x5338, 'SesameSunshineUi', 'ui_remote_ime_editing=1');
            }
          })
          .onChange((value: string, preview?: PreviewText) => this.changeText(value, preview))
          .onSubmit((_key:EnterKeyType,event:SubmitEvent)=>this.submitIme(event))
        if (this.keyboardNote) {
          Text(this.keyboardNote).fontSize(12).fontColor(this.tone()).padding(6)
            .backgroundColor(this.panelTone()).borderRadius(8).position({ x: 8, y: Math.max(0, this.viewportH - 34) })
        }
      }
      if (this.soft && this.inputState !== 2) {
        Button('输入已中断').fontSize(12).onClick(() => { this.closeKeyboard(); this.menu = 'input'; })
          .position({ x: 10, y: Math.max(8, this.viewportH - 46) })
      }
      if (this.detail) { this.detailOverlay() }
    }.width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((_old:Area,area:Area)=>{
        const x=Number(area.globalPosition.x),y=Number(area.globalPosition.y);
        if(Number.isFinite(x)&&Math.abs(x-this.originX)>=0.5)this.originX=x;
        if(Number.isFinite(y)&&Math.abs(y-this.originY)>=0.5)this.originY=y;
      })
  }
}
