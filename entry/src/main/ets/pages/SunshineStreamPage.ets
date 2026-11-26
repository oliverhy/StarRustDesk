import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { KeyboardAvoidMode, router, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RemoteDisplayPolicy } from '../service/RemoteDisplayPolicy';
import { RemoteFullscreenPolicy } from '../service/RemoteFullscreenPolicy';
import { StreamControlsBack, streamBoundPan, streamRefreshingPicture } from '../model/SunshineControlMenu';
import { SunshineExperiment } from '../service/SunshineExperiment';
import { SunshineCompanionStore } from '../service/SunshineCompanionStore';
import { SunshineRemoteControls } from '../widget/SunshineRemoteControls';
import probe from 'libsunshine_stream_exp.so';

const DOMAIN = 0x5338;
const TAG = 'SesameSunshineUi';

// Only packaged content gets this narrow interface. No URLs, input, keys or
// file names can come from JavaScript, and neither runtime sends analytics.
class StreamBridge {
  private nonce: string = '';
  private files: string = '';
  private generation: number = 0;
  private requested: boolean = false;
  private spent: boolean = false;
  private starting: boolean = false;
  private playerStarted: boolean = false;
  private overrideStatus: number = 0;
  private companionProfile: string = '';
  private companionMode: boolean = false;
  private rateStore?: preferences.Preferences;
  private preferredKbps: number = 20000;
  private showCompanion: () => void = (): void => {};
  private surface: () => string = (): string => '';
  private position: (x: number, y: number, w: number, h: number) => void =
    (_x: number, _y: number, _w: number, _h: number): void => {};
  private marker: (x: number, y: number) => void = (_x: number, _y: number): void => {};
  private awake: (active: boolean) => void = (_active: boolean): void => {};
  private playback: (active: boolean, link: number, fps: number, rtt: number) => void =
    (_active: boolean, _link: number, _fps: number, _rtt: number): void => {};
  private hasPicture: boolean = false;
  private nativeOwnsReadout: boolean = false;
  private cachedReadout: string = '';
  sampleSequence: number = 0;
  refreshingPicture: boolean = false;
  private refreshStart: number = 0;
  receivedKbps: number = 0;
  requestKbps: number = 0;
  gapCount: number = 0;
  appliedKbps: number = 0;

  configure(nonce: string, files: string, surface: () => string,
    position: (x: number, y: number, w: number, h: number) => void,
    marker: (x: number, y: number) => void, awake: (active: boolean) => void,
    playback: (active: boolean, link: number, fps: number, rtt: number) => void): void {
    this.nonce = nonce;
    this.files = files;
    this.surface = surface;
    this.position = position;
    this.marker = marker;
    this.awake = awake;
    this.playback = playback;
  }

  configureCompanion(enabled: boolean, open: () => void): void {
    this.companionMode = enabled;
    this.showCompanion = open;
  }

  setCompanionProfile(record: string): void { this.companionProfile = record; }
  mode(): number { return this.companionMode ? 1 : 0; }

  configureRate(store: preferences.Preferences): void {
    this.rateStore = store;
    const value = store.getSync('preferredVideoKbps', 20000);
    if (typeof value === 'number' && this.validRate(value)) this.preferredKbps = value;
  }
  private validRate(value: number): boolean {
    return Number.isInteger(value) && value >= 2000 && value <= 50000 && value % 1000 === 0;
  }
  preferredVideoRate(): number { return this.preferredKbps; }
  saveVideoRate(kbps: number): number {
    if (!this.companionMode || this.requested || !this.validRate(kbps) || !this.rateStore) return 0;
    try {
      this.rateStore.putSync('preferredVideoKbps', kbps);
      this.rateStore.flush().catch(() => hilog.warn(DOMAIN, TAG, 'video_preference_flush_failed'));
      this.preferredKbps = kbps;
      return 1;
    } catch (_) { return 0; }
  }

  manageCompanion(): void {
    if (this.companionMode && !this.requested && !this.starting) this.showCompanion();
  }

  prepared(): number {
    if (this.companionMode) return SunshineCompanionStore.isProfile(this.companionProfile) ? 1 : 0;
    return /^[0-9a-f]{24}$/.test(this.nonce) && this.files === '/data/storage/el2/base/files' &&
      (!this.spent || this.requested) ? 1 : 0;
  }

  launch(kbps: number): number {
    if (this.prepared() !== 1 || this.requested || this.starting || (!this.companionMode && this.spent) ||
      !(this.companionMode ? this.validRate(kbps) : [2000, 4000, 8000].includes(kbps))) return 0;
    if (this.companionMode) {
      this.nonce = probe.newCompanionNonce();
      if (!/^[0-9a-f]{24}$/.test(this.nonce)) return 0;
    }
    this.spent = true; // one-use offer; a new device test provisions a new attempt
    this.requested = true;
    this.starting = true;
    this.playerStarted = false;
    this.nativeOwnsReadout = false;
    this.cachedReadout = '';
    this.sampleSequence = 0;
    this.hasPicture = false;
    this.refreshingPicture = false;
    this.refreshStart = 0;
    this.overrideStatus = 0;
    const current = ++this.generation;
    this.awake(true);
    hilog.info(DOMAIN, TAG, 'ui_start_tapped=1');
    const work = this.companionMode ? probe.runCompanionLink(this.companionProfile, this.nonce, kbps) :
      probe.runUiLink(this.files, this.nonce, kbps);
    work.then((status: string) => {
      this.starting = false;
      if (current === this.generation) this.awake(false);
      if (current === this.generation && (status === 'link_busy' || status === 'link_worker_failed')) {
        this.overrideStatus = 7;
      }
    }).catch(() => {
      this.starting = false;
      if (current === this.generation) this.awake(false);
      if (current === this.generation) this.overrideStatus = 7;
    });
    return 1;
  }

  snapshot(): string {
    if (!this.requested) return '0,0,0,0,0,0,0,0,0,0,0,0,0';
    // The Web starts the session. Once covered by the native player it is
    // only a reader of the last status; it need not keep scheduling JS timers.
    if (this.nativeOwnsReadout) return this.cachedReadout;
    const link = this.overrideStatus || probe.readUiLink();
    if ((link === 4 || link === 5 || link === 11) && !this.playerStarted) {
      const id = this.surface();
      if (id.length > 0) {
        this.playerStarted = true;
        const current = this.generation;
        probe.runSecureClient(id, this.nonce, 1400, this.companionMode).then((result: string) => {
          if (current === this.generation) this.awake(false);
          if (current === this.generation && this.companionMode) probe.cancelUiLink();
          if (current === this.generation && result === 'secure_client_busy') this.overrideStatus = 7;
        }).catch(() => {
          if (current === this.generation) this.awake(false);
          if (current === this.generation && this.companionMode) probe.cancelUiLink();
          if (current === this.generation) this.overrideStatus = 7;
        });
      }
    }
    return this.readPlayback(link);
  }

  pollNativePlayback(): void {
    if (this.nativeOwnsReadout && this.requested && this.playerStarted && this.companionMode) {
      this.readPlayback(this.overrideStatus || probe.readUiLink());
    }
  }

  private readPlayback(link: number): string {
    const sample: string = this.playerStarted ? probe.secureSnapshot(this.companionMode) : '0,0,0,0,0,0,0,0,0,0,0,0';
    const fields = sample.split(',');
    this.cachedReadout = link + ',' + fields.slice(0,12).join(','); // keep original Web protocol
    if (this.companionMode && this.playerStarted) {
      const active = (link === 4 || link === 5 || link === 11) &&
        Number(fields[0]) === 3 && Number(fields[1]) > 0;
      const previousPicture = this.hasPicture || this.refreshingPicture;
      if (active || previousPicture) {
        if (active) this.refreshStart = 0;
        else if (this.refreshStart === 0) this.refreshStart = Date.now();
        this.refreshingPicture = !active && streamRefreshingPicture(Number(fields[0]), link, previousPicture, Date.now()-this.refreshStart);
        this.hasPicture = active;
        this.nativeOwnsReadout = active || this.refreshingPicture;
        this.sampleSequence = active ? Math.max(0, Number(fields[12]) || 0) : 0;
        this.receivedKbps = Math.max(0, Number(fields[2]) || 0);
        this.requestKbps = Math.max(0, Number(fields[6]) || 0);
        this.gapCount = Math.max(0, Number(fields[4]) || 0);
        this.appliedKbps = Math.max(0, Number(fields[7]) || 0);
        this.playback(active, link, Number(fields[3]) / 100, Number(fields[5]));
      }
    }
    return this.cachedReadout;
  }

  // ArkUI calls these directly; they are never exposed to the web page.
  inputState(): number { return this.hasPicture ? probe.inputState(this.nonce) : 0; }
  openInput(): boolean { return this.hasPicture && this.requested && probe.inputOpen(this.nonce); }
  sendInput(kind: number, flag: number, a: number, b: number, text: string): boolean {
    return this.hasPicture && this.requested && probe.inputSend(this.nonce, kind, flag, a, b, text);
  }

  halt(): void {
    if (!this.requested) return;
    this.requested = false;
    this.nativeOwnsReadout = false;
    this.cachedReadout = '';
    this.sampleSequence = 0;
    this.hasPicture = false;
    this.refreshingPicture = false;
    this.refreshStart = 0;
    ++this.generation;
    this.awake(false);
    probe.inputClose();
    this.playback(false, 0, 0, 0);
    probe.cancelSecureClient();
    probe.cancelUiLink();
    this.position(0, 0, 0, 0);
    hilog.info(DOMAIN, TAG, 'ui_session_halted=1');
  }

  frame(x: number, y: number, w: number, h: number): void {
    if ([x, y, w, h].some((n: number) => !Number.isFinite(n)) || x < -1 || x > 1 || y < -1.5 || y > 1 ||
      w < 0 || w > 1 || h < 0 || h > 1.5) return;
    this.position(x, y, w, h);
  }

  buttonSpot(x: number, y: number): void {
    if (this.prepared() === 1 && Number.isFinite(x) && Number.isFinite(y) && x > 0 && x < 1 && y > 0 && y < 1) {
      this.marker(x, y);
    }
  }

  event(name: string): void {
    if (name === 'native_first_frame' && this.requested && this.playerStarted) {
      hilog.info(DOMAIN, TAG, 'ui_player_first_decoded_frame=1');
    }
  }

  back(): void {
    this.halt();
    router.back();
  }
}

function toNumber(length: Length): number {
  if (typeof length === 'number') return length;
  if (typeof length === 'string') {
    const value = parseFloat(length);
    return Number.isFinite(value) ? value : 0;
  }
  return 0;
}

@Entry
@Component
struct SunshineStreamPage {
  private web: webview.WebviewController = new webview.WebviewController();
  private decoder: XComponentController = new XComponentController();
  private bridge: StreamBridge = new StreamBridge();
  private videoId: string = '';
  @State private pageW: number = 0;
  @State private pageH: number = 0;
  private pageX: number = 0;
  private pageY: number = 0;
  private keepScreenWindow?: window.Window;
  private wantAwake: boolean = false;
  private windowOps: Promise<void> = Promise.resolve();
  @State private admitted: boolean = false;
  @State private companionMode: boolean = false;
  @State private showPairing: boolean = true;
  @State private pairing: boolean = false;
  @State private hasSavedHost: boolean = false;
  @State private invitation: string = '';
  @State private pairStatus: string = '先在同一个 Wi-Fi 下打开 Windows 游戏串流助手。';
  private pageOpen: boolean = false;
  private webReady: boolean = false;
  @StorageLink('sunshineTestEpoch') @Watch('leaveStream') private epoch: number = 0;
  @StorageLink('isDarkMode') @Watch('applyTheme') private dark: boolean = false;
  @StorageLink('uiFontScale') private fontScale: number = 1;
  @State private videoLeft: number = -190;
  @State private videoTop: number = -120;
  @State private videoW: number = 160;
  @State private videoH: number = 90;
  @State private remoteVisible: boolean = false;
  @State private refreshingVideo: boolean = false;
  @State private hostLayoutKey: string = '';
  @State private remoteRoute: string = '';
  @State private remoteFps: number = 0;
  @State private remoteRtt: number = 0;
  @State private remoteReceived: number = 0;
  @State private remoteRequest: number = 0;
  @State private remoteGaps: number = 0;
  @State private remoteDisplays: number = 256;
  private panX: number = 0;
  private panY: number = 0;
  @State private remoteApplied: number = 0;
  @State private sampledAt: string = '';
  private displayedSample: number = 0;
  @State private full: boolean = false;
  @State private streamRotation: string = 'system';
  private controlsBack: StreamControlsBack = new StreamControlsBack();
  private windowSession: number = 0;
  private viewWindowOps: Promise<void> = Promise.resolve();
  private fullBefore?: boolean;
  private directionBefore?: window.Orientation;
  @State private controlState: number = 0;
  @State private viewScale: number = 100;
  private readControlTimer: number = -1;
  private imeBaseH: number = 0;
  private imeBaseW: number = 0;
  private imeAvoidMode?: KeyboardAvoidMode;
  private imeWindow?: window.Window;
  private imeWindowListener?: (height: number) => void;
  private confirmingDisconnect: boolean = false;

  aboutToAppear(): void {
    const host = this.getUIContext().getHostContext();
    const info = host?.applicationInfo;
    if (!info || !SunshineExperiment.mayOpen(info.name, info.debug)) return;
    this.admitted = true;
    try {
      if (host) this.bridge.configureRate(preferences.getPreferencesSync(host, { name: 'sunshine_stream_quality' }));
    } catch (_) { hilog.warn(DOMAIN, TAG, 'video_preference_load_failed'); }
    this.pageOpen = true;
    const nonce = AppStorage.get<string>('sunshineUiNonce') || '';
    const files = host?.getApplicationContext().filesDir || '';
    this.bridge.configure(nonce, files, (): string => this.videoId,
      (x: number, y: number, w: number, h: number): void => {
        if (this.remoteVisible) return;
        const visible = w > 0 && h > 0 && this.pageW > 0 && this.pageH > 0;
        this.videoW = visible ? w * this.pageW : 160;
        this.videoH = visible ? h * this.pageH : 90;
        this.videoLeft = visible ? x * this.pageW : -190;
        this.videoTop = visible ? y * this.pageH : -120;
        if (visible) {
          hilog.info(DOMAIN, TAG, 'ui_video_box x=%{public}d y=%{public}d w=%{public}d h=%{public}d',
            Math.round(vp2px(this.videoLeft + this.pageX)), Math.round(vp2px(this.videoTop + this.pageY)),
            Math.round(vp2px(this.videoW)), Math.round(vp2px(this.videoH)));
        }
      }, (x: number, y: number): void => {
        if (this.pageW > 0 && this.pageH > 0) {
          hilog.info(DOMAIN, TAG, 'ui_start_button x=%{public}d y=%{public}d',
            Math.round(vp2px(x * this.pageW + this.pageX)), Math.round(vp2px(y * this.pageH + this.pageY)));
        }
      }, (active: boolean): void => { this.keepWindowVisible(active); },
      (active: boolean, link: number, fps: number, rtt: number): void => {
        this.updatePlayback(active, link, fps, rtt);
      });
    this.companionMode = !nonce && probe.companionAvailable();
    this.bridge.configureCompanion(this.companionMode, (): void => {
      this.webReady = false;
      this.showPairing = true;
    });
    if (this.companionMode) {
      SunshineCompanionStore.load().then((record: string): void => {
        if (!record || !this.pageOpen || this.pairing) return;
        this.bridge.setCompanionProfile(record);
        this.hostLayoutKey = record.split('-')[3];
        this.hasSavedHost = true;
        this.showPairing = false;
        hilog.info(DOMAIN,TAG,'companion_saved_host_loaded=1');
      });
    }
  }

  private async pairWindows(): Promise<void> {
    if (!this.companionMode || this.pairing) return;
    const code = this.invitation.trim();
    if (!SunshineCompanionStore.isProfile(code)) {
      this.pairStatus = '配对码格式不正确，请重新复制。';
      return;
    }
    this.pairing = true;
    this.invitation = '';
    this.pairStatus = '正在核对电脑身份…';
    try {
      const result = await probe.pairCompanion(code);
      if (!this.pageOpen) return;
      if (SunshineCompanionStore.isProfile(result)) {
        await SunshineCompanionStore.save(result);
        if (!this.pageOpen) return;
        this.bridge.setCompanionProfile(result);
        this.hostLayoutKey = result.split('-')[3];
        this.hasSavedHost = true;
        this.showPairing = false;
        hilog.info(DOMAIN,TAG,'companion_pairing_saved=1');
      } else {
        this.pairStatus = result === 'companion_identity_unconfirmed' ? '电脑身份不匹配，已停止。' :
          result === 'companion_unreachable' ? '连不到电脑助手。请确认两台设备在同一局域网，并保持助手打开。' :
          '配对未完成。请从电脑助手获取新的配对码。';
        hilog.info(DOMAIN,TAG,'companion_pairing_failed=1');
      }
    } catch (_e) {
      this.pairStatus = '无法保存配对，请解锁手机后重新配对。';
    } finally {
      this.pairing = false;
    }
  }

  private async forgetWindows(): Promise<void> {
    if (this.pairing || !this.hasSavedHost) return;
    this.pairing = true;
    try {
      await SunshineCompanionStore.forget();
      this.bridge.setCompanionProfile('');
      this.hostLayoutKey = '';
      this.hasSavedHost = false;
      this.pairStatus = '已移除这台电脑。';
    } catch (_e) {
      this.pairStatus = '暂时无法移除，请重试。';
    } finally {
      this.pairing = false;
    }
  }

  private keepWindowVisible(active: boolean): void {
    this.wantAwake = active;
    const context = this.getUIContext().getHostContext();
    this.windowOps = this.windowOps.then(async (): Promise<void> => {
      if (!this.wantAwake) {
        if (this.keepScreenWindow) await this.keepScreenWindow.setWindowKeepScreenOn(false);
        this.keepScreenWindow = undefined;
        return;
      }
      if (!context || this.keepScreenWindow) return;
      const owned = await window.getLastWindow(context);
      if (this.wantAwake && !owned.getWindowProperties().isKeepScreenOn) {
        await owned.setWindowKeepScreenOn(true);
        this.keepScreenWindow = owned;
      }
    }).catch((): void => {
      hilog.warn(DOMAIN, TAG, 'ui_window_keep_screen_update_failed=1');
    });
  }

  aboutToDisappear(): void {
    this.pageOpen = false;
    this.webReady = false;
    this.invitation = '';
    this.bridge.halt();
  }

  onPageHide(): void { this.leaveStream(); }

  private leaveStream(): void {
    this.invitation = '';
    this.bridge.halt();
    this.updatePlayback(false, 0, 0, 0);
    this.sendToWeb('window.sesameNativeSuspend?.()');
  }

  private rotationAvailable(): boolean {
    return deviceInfo.deviceType === 'phone' || deviceInfo.deviceType === 'tablet';
  }
  private sessionWindowChange(action: string): void {
    const current = this.windowSession;
    const main = RemoteDisplayPolicy.getMainWindow();
    if (!main || !this.remoteVisible) return;
    this.viewWindowOps = this.viewWindowOps.then(async (): Promise<void> => {
      if (!this.remoteVisible || current !== this.windowSession || main !== RemoteDisplayPolicy.getMainWindow()) return;
      if (action === 'fullscreen') {
        const next = !this.full;
        if (this.fullBefore === undefined) this.fullBefore = this.full;
        await RemoteFullscreenPolicy.apply(next);
        if (current === this.windowSession) this.full = next;
      } else if (this.rotationAvailable() && ['system','auto','portrait','landscape'].includes(action)) {
        if (this.directionBefore === undefined) this.directionBefore = main.getPreferredOrientation();
        const before: window.Orientation = this.directionBefore;
        const target = action === 'system' ? before : action === 'portrait' ? window.Orientation.PORTRAIT :
          action === 'landscape' ? window.Orientation.LANDSCAPE : window.Orientation.AUTO_ROTATION;
        await main.setPreferredOrientation(target);
        if (current === this.windowSession) this.streamRotation = action;
      }
    }).catch((): void => {
      if (this.remoteVisible && current === this.windowSession) {
        this.getUIContext().getPromptAction().showToast({ message: '当前窗口未能切换显示模式' });
      }
    });
  }
  private restoreStreamWindow(): void {
    ++this.windowSession;
    const main = RemoteDisplayPolicy.getMainWindow();
    const full = this.fullBefore, orientation = this.directionBefore;
    this.fullBefore = undefined; this.directionBefore = undefined;
    this.streamRotation = 'system'; this.full = false;
    this.viewWindowOps = this.viewWindowOps.then(async (): Promise<void> => {
      if (!main || main !== RemoteDisplayPolicy.getMainWindow()) return;
      if (orientation !== undefined) {
        try { await main.setPreferredOrientation(orientation); } catch (_error) {}
      }
      if (full !== undefined) {
        try { await RemoteFullscreenPolicy.apply(full); } catch (_error) {}
      }
    });
  }

  private fitVideo(): void {
    if (!this.remoteVisible || this.pageW <= 0 || this.pageH <= 0) return;
    let ratio = probe.secureVideoRatio();
    if (!(ratio >= 0.3 && ratio <= 4.5)) ratio = 16 / 9;
    const baseH = this.imeBaseH > 0 && Math.abs(this.imeBaseW - this.pageW) < 2 ?
      Math.max(this.pageH, this.imeBaseH) : this.pageH;
    const width = Math.min(this.pageW, baseH * ratio) * this.viewScale / 100;
    this.videoW = width;
    this.videoH = width / ratio;
    this.panX = streamBoundPan(this.panX, width, this.pageW);
    this.panY = streamBoundPan(this.panY, this.videoH, baseH);
    this.videoLeft = (this.pageW - width) / 2 + this.panX;
    // Keyboard insets only move the canvas; they never change its zoom.
    this.videoTop = (baseH - this.videoH) / 2 + this.panY - Math.max(0, baseH - this.pageH);
  }

  private updatePlayback(active: boolean, link: number, fps: number, rtt: number): void {
    if (!active) {
      this.sampledAt = ''; this.displayedSample = 0;
      // Rebuilding the decoder on the same authenticated link is not a new
      // viewing session. Keep the local layout but immediately revoke input.
      if (this.bridge.refreshingPicture && this.remoteVisible) {
        if (!this.refreshingVideo) {
          probe.inputClose(); this.controlState=0; this.refreshingVideo=true;
          hilog.info(DOMAIN,TAG,'ui_local_layout_kept_during_video_restart=1');
        }
        return;
      }
      this.refreshingVideo=false;
      if (this.remoteVisible) this.restoreStreamWindow();
      if (this.readControlTimer !== -1) clearInterval(this.readControlTimer);
      this.readControlTimer = -1;
      if (this.remoteVisible || this.controlState !== 0) probe.inputClose();
      this.remoteVisible = false;
      this.controlState = 0;
      this.keyboardVisible(false);
      this.confirmingDisconnect = false;
      return;
    }
    if (!this.pageOpen) return;
    if (this.refreshingVideo) { this.refreshingVideo=false; this.fitVideo(); }
    this.remoteRoute = link === 11 ? '局域网直连' : (link === 4 ? '公网 UDP 直连' : 'UDP 中继');
    this.remoteFps = Math.max(0, fps || 0);
    this.remoteRtt = Math.max(0, rtt || 0);
    this.remoteReceived = this.bridge.receivedKbps;
    this.remoteRequest = this.bridge.requestKbps;
    this.remoteGaps = this.bridge.gapCount;
    this.remoteDisplays = probe.displayCatalog();
    this.remoteApplied = this.bridge.appliedKbps;
    const sequence = this.bridge.sampleSequence;
    if (sequence !== this.displayedSample) {
      this.displayedSample = sequence;
      const now=new Date();
      this.sampledAt = sequence>0 ? [now.getHours(),now.getMinutes(),now.getSeconds()]
        .map((n:number):string => n.toString().padStart(2,'0')).join(':') : '';
    }
    if (!this.remoteVisible) {
      ++this.windowSession;
      try { this.full = RemoteDisplayPolicy.getMainWindow()?.getWindowProperties().isFullScreen ?? false; } catch (_e) {}
      this.viewScale = 100;
      this.panX = 0; this.panY = 0;
      this.remoteVisible = true;
      this.fitVideo();
      hilog.info(DOMAIN, TAG, 'ui_native_remote_controls_visible=1');
      this.readControlTimer = setInterval((): void => {
        if (!this.remoteVisible) return;
        this.bridge.pollNativePlayback();
        if (!this.remoteVisible) return; // the poll may have closed the lease
        const next = this.bridge.inputState();
        if (next !== this.controlState) {
          this.controlState = next;
          hilog.info(DOMAIN, TAG, 'ui_companion_input_state=%{public}d', next);
        }
      }, 120);
    }
  }

  private keyboardVisible(active: boolean): void {
    if (active && this.imeBaseH > 0) return;
    const context = this.getUIContext();
    if (active) {
      this.imeBaseH = this.pageH;
      this.imeBaseW = this.pageW;
      try {
        this.imeAvoidMode = context.getKeyboardAvoidMode();
        context.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
        const name = context.getWindowName();
        if (name) {
          const target = window.findWindow(name);
          const report = (height: number): void => {
            if (this.remoteVisible && this.imeBaseH > 0 && height > 0) {
              hilog.info(DOMAIN, TAG, 'ui_remote_soft_keyboard_visible=1');
            }
          };
          target.on('keyboardHeightChange', report);
          this.imeWindow = target;
          this.imeWindowListener = report;
          report(target.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height);
        }
      } catch (_error) {}
    } else {
      this.imeBaseH = 0;
      this.imeBaseW = 0;
      try {
        if (this.imeWindow && this.imeWindowListener) {
          this.imeWindow.off('keyboardHeightChange', this.imeWindowListener);
        }
        if (this.imeAvoidMode !== undefined) context.setKeyboardAvoidMode(this.imeAvoidMode);
      } catch (_error) {}
      this.imeAvoidMode = undefined;
      this.imeWindow = undefined;
      this.imeWindowListener = undefined;
    }
    this.fitVideo();
  }

  private toggleInput(): void {
    if (!this.remoteVisible) return;
    if (this.controlState === 1 || this.controlState === 2) {
      probe.inputClose();
      this.controlState = 0;
    } else {
      this.controlState = this.bridge.openInput() ? 1 : 4;
    }
  }

  private requestDisconnect(): void {
    if (this.confirmingDisconnect || !this.remoteVisible) return;
    this.bridge.sendInput(7, 0, 0, 0, '');
    this.confirmingDisconnect = true;
    const keep = (): void => { this.confirmingDisconnect = false; };
    this.getUIContext().showAlertDialog({
      title: '断开远程连接',
      message: '是否断开当前游戏串流？',
      autoCancel: true,
      cancel: keep,
      primaryButton: { value: '继续远控', action: keep },
      secondaryButton: { value: '断开连接', fontColor: '#DF434B', action: () => {
        if (!this.confirmingDisconnect || !this.remoteVisible) return;
        keep();
        this.bridge.back();
      } }
    });
  }

  private sendToWeb(script: string): boolean {
    if (!this.pageOpen || !this.webReady || (this.companionMode && this.showPairing)) return false;
    try {
      this.web.runJavaScript(script).catch((): void => {});
      return true;
    } catch (_e) {
      // ArkWeb can synchronously reject calls while attaching or tearing down.
      return false;
    }
  }

  private applyTheme(): void {
    const scheme = this.dark ? 'dark' : 'light';
    this.sendToWeb(`document.documentElement.style.colorScheme = '${scheme}'`);
  }

  onBackPress(): boolean {
    if (!this.admitted) return false;
    if (this.remoteVisible) {
      if (!this.controlsBack.dismiss()) this.requestDisconnect();
      return true;
    }
    if (this.companionMode && this.showPairing) {
      if (this.hasSavedHost) this.showPairing = false; else router.back();
      return true;
    }
    if (!this.sendToWeb('window.sesameNativeBack?.()')) this.bridge.back();
    return true;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.admitted && this.companionMode && this.showPairing) {
        Scroll() {
          Column({ space: 14 }) {
            Text('配对 Windows 电脑').fontSize(23).fontWeight(FontWeight.Bold)
              .fontColor(this.dark ? '#EDF3FF' : '#142439')
            Text(this.pairStatus).fontSize(15).fontColor(this.dark ? '#BCCBE0' : '#42546D')
            TextInput({ text: this.invitation, placeholder: '粘贴电脑助手的配对码' })
              .id('sunshine-companion-invitation').type(InputType.Password).maxLength(160)
              .onChange((value: string) => { this.invitation = value; })
            Button(this.pairing ? '正在配对…' : '配对电脑').id('sunshine-companion-pair')
              .enabled(!this.pairing).width('100%').onClick(() => { void this.pairWindows(); })
            if (this.hasSavedHost) {
              Button('返回已配对电脑').enabled(!this.pairing).onClick(() => { this.showPairing = false; })
              Button('忘记这台电脑').id('sunshine-companion-forget')
                .enabled(!this.pairing).onClick(() => { void this.forgetWindows(); })
            } else {
              Button('返回').onClick(() => router.back())
            }
          }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
        }.width('100%').height('100%')
      } else if (this.admitted) {
      Web({ src: $rawfile('sunshine/sesame-sunshine.html'), controller: this.web })
        .width('100%').height('100%')
        .javaScriptAccess(true).domStorageAccess(false).fileAccess(false)
        .blockNetwork(true).zoomAccess(false).geolocationAccess(false)
        .textZoomRatio(Math.round(Math.max(1, Math.min(3, this.fontScale)) * 100))
        .allowWindowOpenMethod(false).mixedMode(MixedMode.None)
        .javaScriptProxy({ object: this.bridge, name: 'SesameLink',
          methodList: ['prepared', 'mode', 'preferredVideoRate', 'saveVideoRate', 'manageCompanion', 'launch', 'snapshot', 'halt', 'frame', 'buttonSpot', 'event', 'back'],
          controller: this.web })
        .onLoadIntercept((event) => {
          const url = event?.data.getRequestUrl() || '';
          return url !== 'resource://rawfile/sunshine/sesame-sunshine.html' &&
            !/^file:\/\/\/data\/storage\/el1\/bundle\/[A-Za-z0-9_/.-]+\/rawfile\/sunshine\/sesame-sunshine\.html$/.test(url);
        })
        .onPageEnd(() => {
          if (!this.pageOpen || (this.companionMode && this.showPairing)) return;
          this.webReady = true;
          this.applyTheme();
          this.sendToWeb('window.sesameNativeRefresh?.()');
          hilog.info(DOMAIN, TAG, 'ui_approved_page_loaded=1');
        })
        .onAreaChange((_old: Area, area: Area) => {
          this.pageW = toNumber(area.width);
          this.pageH = toNumber(area.height);
          this.pageX = toNumber(area.globalPosition.x ?? 0);
          this.pageY = toNumber(area.globalPosition.y ?? 0);
          this.fitVideo();
          this.sendToWeb('window.sesameNativeRefresh?.()');
        })
      if (this.remoteVisible) {
        Stack().width('100%').height('100%').backgroundColor('#0B1017').hitTestBehavior(HitTestMode.Block)
      }
      XComponent({ id: 'sunshine-native-surface', type: XComponentType.TEXTURE, controller: this.decoder })
        .width(this.videoW).height(this.videoH).position({ x: this.videoLeft, y: this.videoTop })
        .borderRadius(this.remoteVisible ? 0 : 15).clip(true).hitTestBehavior(HitTestMode.None)
        .onLoad(() => { this.videoId = this.decoder.getXComponentSurfaceId(); })
      if (this.remoteVisible) {
        SunshineRemoteControls({
          dark: this.dark, fontScale: this.fontScale, viewportW: this.pageW, viewportH: this.pageH,
          videoLeft: this.videoLeft, videoTop: this.videoTop, videoW: this.videoW, videoH: this.videoH,
          inputState: this.controlState, route: this.remoteRoute, fps: this.remoteFps, rtt: this.remoteRtt,
          hostKey: this.hostLayoutKey, zoomPercent: this.viewScale,
          displayCatalog: this.remoteDisplays,
          onChooseDisplay: (slot: number): void => {
            if (!this.remoteVisible || this.refreshingVideo) return;
            if (probe.selectDisplay(slot)) {
              probe.inputClose(); this.controlState=0;
              this.viewScale=100; this.panX=0; this.panY=0; this.fitVideo();
            }
          },
          receivedKbps: this.remoteReceived, requestKbps: this.remoteRequest, gapCount: this.remoteGaps,
          videoKbps: this.remoteApplied, sampledAt: this.sampledAt, back: this.controlsBack,
          fullscreen: this.full, orientation: this.streamRotation, orientationAvailable: this.rotationAvailable(),
          onFullscreen: (): void => this.sessionWindowChange('fullscreen'),
          onOrientation: (mode: string): void => this.sessionWindowChange(mode),
          onToggleInput: (): void => this.toggleInput(),
          onDisconnect: (): void => this.requestDisconnect(),
          onScale: (value: number): void => {
            this.viewScale = value;
            if (value <= 100) { this.panX = 0; this.panY = 0; }
            this.fitVideo();
          },
          onPan: (dx: number, dy: number): void => { this.panX += dx; this.panY += dy; this.fitVideo(); },
          onIme: (active: boolean): void => this.keyboardVisible(active),
          onInput: (kind: number, flag: number, a: number, b: number, text: string): boolean =>
            this.bridge.sendInput(kind, flag, a, b, text)
        })
        if (this.refreshingVideo) {
          Text('正在刷新串流画面…').fontSize(13).fontColor('#FFFFFF').backgroundColor('#B31B2638')
            .borderRadius(8).padding(6).position({x:10,y:10}).hitTestBehavior(HitTestMode.None)
        }
      }
      } else {
        Column({ space: 16 }) {
          Text('游戏串流实验未开启').fontSize(18).fontColor(this.dark ? '#EDF3FF' : '#142439')
          Button('返回连接').onClick(() => router.back())
        }.justifyContent(FlexAlign.Center).width('100%').height('100%').padding(16)
      }
    }.width('100%').height('100%').clip(true).backgroundColor(this.dark ? '#101A29' : '#F3F6FD');
  }
}
