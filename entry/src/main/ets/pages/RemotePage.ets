import { router } from '@kit.ArkUI';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { window } from '@kit.ArkUI';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { translate } from '../utils/I18n';
import { ConnectionStatus } from '../model/ConnectionModel';
import { ConnectionService } from '../service/ConnectionService';
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask';
import { FileDownloadRequest, FileTransferStatus, HardwareKeyState, NativeKeyInputEvent, NativeMouseInputEvent, RemoteCursorPosition, RemoteDirectoryEntry, RemoteDirectoryResult, RustDeskNapi, VideoFrameInfo } from '../service/RustDeskNapi';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import pointer from '@ohos.multimodalInput.pointer';
import { FileTransferHistoryRecord, FileTransferHistoryService } from '../service/FileTransferHistoryService';
import { FileTransferHistoryDialog } from '../widget/FileTransferHistoryDialog';

interface RemotePoint {
  x: number;
  y: number;
}

interface RemoteDownloadSelection extends FileDownloadRequest {
  key: string;
  size: number;
}

interface DownloadedFileCandidate {
  path: string;
  size: number;
}

const REMOTE_WHEEL_SCALE: number = 0.08;
const TOUCH_SCROLL_SCALE: number = 0.12;
const TOUCHPAD_POINTER_SPEED: number = 1.25;
const TOUCH_MOVE_THRESHOLD: number = 12;
const TOUCHPAD_DOUBLE_TAP_TIMEOUT_MS: number = 400;
const TOUCHPAD_DOUBLE_TAP_DISTANCE: number = 48;
const MULTI_TOUCH_MOVE_THRESHOLD: number = 8;
const PINCH_DISTANCE_THRESHOLD: number = 12;
const THREE_FINGER_SWIPE_THRESHOLD: number = 70;
const THREE_FINGER_HORIZONTAL_LIMIT: number = 120;
const THREE_FINGER_MAX_DURATION: number = 1500;
// RustDesk's controlled side suppresses cursor-position echoes to the input
// origin for roughly 300 ms. Keep the locally predicted cursor during that
// window so touchpad and physical-mouse movement remain visually responsive.
const LOCAL_CURSOR_ECHO_GUARD_MS: number = 360;
const PAN_MODE_ACTIVE_COLOR: string = '#2468D8';
const EDGE_AUTO_PAN_MOUSE_DWELL_MS: number = 90;
const EDGE_AUTO_PAN_TOUCH_DWELL_MS: number = 260;
const EDGE_AUTO_PAN_FRAME_MS: number = 16;
const EDGE_AUTO_PAN_MIN_SPEED: number = 88;
const EDGE_AUTO_PAN_MAX_SPEED: number = 640;
const VIEWPORT_PAN_SPEED: number = 1.5;
const NATIVE_MOUSE_ACTION_PRESS: number = 1;
const NATIVE_MOUSE_ACTION_RELEASE: number = 2;
const NATIVE_MOUSE_ACTION_MOVE: number = 3;
const NATIVE_MOUSE_ACTION_CANCEL: number = 13;
const NATIVE_MOUSE_BUTTON_LEFT: number = 1;
const NATIVE_MOUSE_BUTTON_RIGHT: number = 2;
const INPUT_MODE_MOUSE: string = 'mouse';
const INPUT_MODE_TOUCH: string = 'touch';
const MOBILE_ACTION_BACK: number = 0;
const MOBILE_ACTION_HOME: number = 1;
const MOBILE_ACTION_RECENTS: number = 2;
const MOBILE_ACTION_VOLUME_UP: number = 3;
const MOBILE_ACTION_VOLUME_DOWN: number = 4;
const MOBILE_ACTION_POWER: number = 5;
const LOG_DOMAIN: number = 0x0000;

@Entry
@Component
struct RemotePage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('appForegroundEpoch') @Watch('onAppForegroundEpochChanged') appForegroundEpoch: number = 0;
  @State connectionStatus: ConnectionStatus = ConnectionStatus.DISCONNECTED;
  @State showToolbar: boolean = true;
  @State zoomScale: number = 1.0;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State toolbarOpacity: number = 1.0;
  @State hasVideo: boolean = false;
  @State remoteWidth: number = 0;
  @State remoteHeight: number = 0;
  @State componentWidth: number = 0;
  @State componentHeight: number = 0;
  @State lastAbsX: number = 0;
  @State lastAbsY: number = 0;
  @State showKeyboardPanel: boolean = false;
  @State inputMode: string = INPUT_MODE_MOUSE;
  @State showGestureHelp: boolean = false;
  @State showMobileActions: boolean = false;
  @State isPeerAndroid: boolean = false;
  @State showLocalCursor: boolean = true;
  @State showLeftButtonHoldIndicator: boolean = false;
  @State keyboardInput: string = '';
  @State showCursor: boolean = false;
  @State remoteCursorEmbedded: boolean = false;
  @State embeddedCursorOverlayFallback: boolean = false;
  @State cursorX: number = 0;
  @State cursorY: number = 0;
  @State cursorImageWidth: number = 20;
  @State cursorImageHeight: number = 25;
  @State cursorPixelMap: image.PixelMap | undefined = undefined;
  @State surfaceId: string = '';
  @State surfaceEpoch: number = 0;
  @State showRemoteSurface: boolean = true;
  @State displayCount: number = 1;
  @State currentDisplay: number = 0;
  @State fpsText: string = '0 fps';
  @State speedText: string = '0 KB/s';
  @State codecText: string = '等待视频';
  @State routeText: string = '未知';
  @State pageWidth: number = 0;
  @State clipboardSyncEnabled: boolean = true;
  @State showRemoteFileBrowser: boolean = false;
  @State remoteDirectoryPath: string = '';
  @State remoteDirectoryEntries: RemoteDirectoryEntry[] = [];
  @State remoteDirectoryLoading: boolean = false;
  @State remoteFileBrowserMode: string = 'upload';
  @State selectedRemoteDownloads: RemoteDownloadSelection[] = [];
  @State transferProgress: number = 0;
  @State transferActive: boolean = false;
  @State transferDirection: string = 'upload';
  @State transferTransferredBytes: number = 0;
  @State transferTotalBytes: number = 0;
  @State transferSpeedBytesPerSecond: number = 0;
  @State transferCompletedItems: number = 0;
  @State transferTotalItems: number = 0;
  @State transferCancelling: boolean = false;
  @State connectedPeerId: string = '';
  @State twoFaCode: string = '';
  @State twoFaError: string = '';
  @State trustThisDevice: boolean = false;
  @State enableTrustedDevices: boolean = false;
  @State connectionError: string = '';
  @State isFullScreen: boolean = false;
  @State isPanMode: boolean = false;
  @State edgeAutoPanEnabled: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private toolbarTimer: number = -1;
  private statusTimer: number = -1;
  private frameTimer: number = -1;
  private framePollGeneration: number = 0;
  private cursorTimer: number = -1;
  private nativeMouseTimer: number = -1;
  private nativeMousePollGeneration: number = 0;
  private hardwareModifierTrackingActive: boolean = false;
  private hardwareCapsLockInitialized: boolean = false;
  private lastHardwareKeySyncAt: number = 0;
  private hardwareCapsLockOn: boolean = false;
  private pointerHoverExitTimer: number = -1;
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
  private touchpadDragCandidate: boolean = false;
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
  private decoderHealthInitialized: boolean = false;
  private lastDecoderInputFrames: number = 0;
  private lastDecodedFrames: number = 0;
  private decoderStallStartedAt: number = 0;
  private videoRecoveryRefreshRequested: boolean = false;
  private videoFallbackRequested: boolean = false;
  private lastLoggedConnectionStatus: number = -1;
  private smoothFps: number = 0;
  private smoothKbps: number = 0;
  private lastMoveSentAt: number = 0;
  private lastMouseEventAt: number = 0;
  private lastNativeMouseEventAt: number = 0;
  private lastTouchEventAt: number = 0;
  private lastMappedPhysicalLeftUpAt: number = 0;
  private lastLocalPointerInputAt: number = 0;
  private localPointerGestureActive: boolean = false;
  private leftButtonHeldAt: number = 0;
  private preferAuthoritativeCursor: boolean = false;
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
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private touchMoved: boolean = false;
  private pointerInitialized: boolean = false;
  private leftButtonHeld: boolean = false;
  private rightButtonHeld: boolean = false;
  private multiTouchActive: boolean = false;
  private multiTouchGesture: number = 0;
  private multiTouchStartedAt: number = 0;
  private multiTouchStartCenterX: number = 0;
  private multiTouchStartCenterY: number = 0;
  private multiTouchLastCenterX: number = 0;
  private multiTouchLastCenterY: number = 0;
  private multiTouchMoved: boolean = false;
  private multiTouchRemoteX: number = 0;
  private multiTouchRemoteY: number = 0;
  private threeFingerGestureActive: boolean = false;
  private threeFingerStartedAt: number = 0;
  private threeFingerStartCenterX: number = 0;
  private threeFingerStartCenterY: number = 0;
  private threeFingerLastCenterX: number = 0;
  private threeFingerLastCenterY: number = 0;
  private viewportPanActive: boolean = false;
  private viewportPanLastX: number = 0;
  private viewportPanLastY: number = 0;
  private directKeyboardCommittedText: string = '';
  private clipboardPolling: boolean = false;
  private lastLocalClipboardText: string = '';
  private lastRemoteClipboardText: string = '';
  private suppressClipboardText: string = '';
  private clipboardBaselineInitialized: boolean = false;
  private isLeavingAfterDisconnect: boolean = false;
  private pendingUploadPath: string = '';
  private pendingUploadName: string = '';
  private pendingDownloadRoot: string = '';
  private pendingDownloadDestinationUri: string = '';
  private pendingDownloadItems: FileDownloadRequest[] = [];
  private pendingDownloadSingleFile: boolean = false;
  private pendingDownloadAsArchive: boolean = false;
  private pendingDownloadArchivePath: string = '';
  private lastTransferSampleAt: number = 0;
  private lastTransferSampleBytes: number = 0;
  private transferHistoryStartedAt: number = 0;
  private transferHistoryDisplayName: string = '';
  private transferHistoryFileType: string = '';
  private transferHistoryItemCount: number = 0;
  private transferHistoryEstimatedBytes: number = 0;
  private transferHistoryDirection: string = 'upload';
  private remoteAudioEnabled: boolean = true;
  private fileTransferHistoryDialogController: CustomDialogController = new CustomDialogController({
    builder: FileTransferHistoryDialog(),
    autoCancel: true,
    customStyle: true,
    cornerRadius: 10,
  });
  private lastRemoteCursorSequence: number = -1;
  private lastRemoteCursorImageSequence: number = -1;
  private remoteCursorAbsX: number = 0;
  private remoteCursorAbsY: number = 0;
  private remoteCursorHotX: number = 0;
  private remoteCursorHotY: number = 0;
  private remoteCursorImageWidth: number = 0;
  private remoteCursorImageHeight: number = 0;
  private hasAuthoritativeRemoteCursor: boolean = false;
  private cursorPixelMapCache: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
  private pointerOverRemoteViewport: boolean = false;
  private systemPointerHidden: boolean = false;
  private edgePanTimer: number = -1;
  private edgePanEnteredAt: number = 0;
  private edgePanLastTickAt: number = 0;
  private edgePanVectorX: number = 0;
  private edgePanVectorY: number = 0;
  private edgePanTargetVisualX: number = 0;
  private edgePanTargetVisualY: number = 0;
  private edgePanTouchActive: boolean = false;
  private edgePanFromTouch: boolean = false;
  private edgePanMoving: boolean = false;

  aboutToAppear(): void {
    RustDeskNapi.appendDiagnosticLog('remote-page', 'about_to_appear')
    this.resetRemoteViewportForSession();
    this.showRemoteSurface = true;
    this.connectedPeerId = AppStorage.get<string>('connectedPeerId') ?? '';
    this.loadInputMode();
    this.loadLocalCursorPreference();
    this.loadEdgeAutoPanPreference();
    this.remoteAudioEnabled = RustDeskNapi.getOption('remote-audio-enabled') !== '0';
    RustDeskNapi.setRemoteAudioEnabled(this.remoteAudioEnabled);
    this.showGestureHelp = RustDeskNapi.getOption('mobile-gesture-help-shown') !== '1';
    let status: number = RustDeskNapi.getConnectionStatus();
    this.connectionStatus = status as ConnectionStatus;
    this.connectingStartedAt = status === ConnectionStatus.CONNECTING ? Date.now() : 0;
    if (status === ConnectionStatus.WAITING_2FA) {
      this.enableTrustedDevices = RustDeskNapi.getEnableTrustedDevices();
    }
    this.startPolling();
    this.startRemoteCursorPolling();
    this.startNativeMousePolling();
  }

  aboutToDisappear(): void {
    RustDeskNapi.appendDiagnosticLog('remote-page', 'about_to_disappear')
    if (this.toolbarTimer !== -1) { clearTimeout(this.toolbarTimer); }
    if (this.statusTimer !== -1) { clearTimeout(this.statusTimer); }
    this.stopFramePolling();
    if (this.cursorTimer !== -1) { clearTimeout(this.cursorTimer); }
    this.stopNativeMousePolling();
    this.cancelPointerHoverExit();
    this.stopEdgeAutoPan();
    this.releaseHeldMouseButtons('page_disappear');
    ConnectionService.releaseModifiers();
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
      this.surfaceRebindTimer = -1;
      RustDeskNapi.setSurfaceId('');
    }
    if (this.remoteDirectoryTimer !== -1) { clearTimeout(this.remoteDirectoryTimer); }
    this.stopClipboardSync();
    this.cancelActiveTouchGesture();
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.cleanupPendingUploadFile();
    this.cleanupPendingDownloadFiles();
    this.releaseRemoteCursorImages();
    this.pointerOverRemoteViewport = false;
    this.setSystemPointerHidden(false);
    if (this.isFullScreen) {
      this.applyFullscreenWindow(false);
      this.isFullScreen = false;
    }
  }

  onBackPress(): boolean {
    if (this.showRemoteFileBrowser) {
      this.closeRemoteFileBrowser(true);
      return true;
    }
    if (this.showGestureHelp) {
      this.showGestureHelp = false;
      return true;
    }
    if (this.showMobileActions) {
      this.showMobileActions = false;
      return true;
    }
    if (this.isFullScreen) {
      this.exitFullScreen();
      return true;
    }
    this.disconnectSession();
    return true;
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
      RemoteSessionBackgroundTask.syncForConnectionStatus(this.connectionStatus);
      RemoteSessionBackgroundTask.setAudioPlaybackActive(
        status === ConnectionStatus.CONNECTED && this.remoteAudioEnabled && RustDeskNapi.isRemoteAudioActive(),
        this.connectedPeerId);
      if (status !== this.lastLoggedConnectionStatus) {
        RustDeskNapi.appendDiagnosticLog('connection-ui', `status_changed from=${this.lastLoggedConnectionStatus} to=${status}`)
        this.lastLoggedConnectionStatus = status
      }
      this.updateSystemPointerVisibility();
      if (status === ConnectionStatus.WAITING_2FA) {
        this.enableTrustedDevices = RustDeskNapi.getEnableTrustedDevices();
        let message: string = ConnectionService.getLastConnectionError();
        this.twoFaError = message === 'Wrong 2FA Code' ? '验证码错误，请重试' : '';
      } else if (status === ConnectionStatus.CONNECTED) {
        this.twoFaCode = '';
        this.twoFaError = '';
        this.connectionError = '';
      } else if (status === ConnectionStatus.FAILED) {
        this.connectionError = ConnectionService.getLastConnectionError();
      }
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
        this.isPeerAndroid = RustDeskNapi.isPeerAndroid();
      }
      if (status === ConnectionStatus.CONNECTED) {
        this.ensureClipboardSyncRunning();
        this.pollFileTransferStatus();
      }
      if (status !== ConnectionStatus.CONNECTED) {
        this.displayStateInitialized = false;
        this.isPeerAndroid = false;
        this.showMobileActions = false;
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
    RustDeskNapi.appendDiagnosticLog('surface', `xcomponent_ready id_length=${surfaceId.length}`)
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
    this.stopFramePolling();
    const generation: number = this.framePollGeneration;
    let poll = () => {
      if (generation !== this.framePollGeneration) {
        return;
      }
      let frame: VideoFrameInfo = RustDeskNapi.getVideoFrame();
      if (frame.hasFrame) {
        let firstVideoFrame: boolean = !this.hasVideo;
        if (firstVideoFrame) {
          this.hasVideo = true;
        }
        this.updateStats(frame);
        this.checkDecoderHealth(frame);
        if (frame.width > 0 && frame.height > 0 && (frame.width !== this.remoteWidth || frame.height !== this.remoteHeight)) {
          let previousWidth: number = this.remoteWidth;
          let previousHeight: number = this.remoteHeight;
          this.remoteWidth = frame.width;
          this.remoteHeight = frame.height;
          this.resetViewportTransform();
          RustDeskNapi.appendDiagnosticLog('video-layout',
            `decoded_size width=${frame.width} height=${frame.height} previous=${previousWidth}x${previousHeight}`)
          setTimeout(() => {
            if (generation === this.framePollGeneration && this.connectionStatus === ConnectionStatus.CONNECTED) {
              this.scheduleSurfaceRebindIfSizeChanged(true);
            }
          }, 0);
        }
      }
      if (generation === this.framePollGeneration) {
        this.frameTimer = setTimeout(poll, 250);
      }
    };
    this.frameTimer = setTimeout(poll, 100);
  }

  onAppForegroundEpochChanged(): void {
    const status: ConnectionStatus = RustDeskNapi.getConnectionStatus() as ConnectionStatus;
    this.connectionStatus = status;
    RemoteSessionBackgroundTask.syncForConnectionStatus(status);
    if (status !== ConnectionStatus.CONNECTED) {
      return;
    }
    RustDeskNapi.appendDiagnosticLog('remote-page', `foreground_resume epoch=${this.appForegroundEpoch}`)
    this.showRemoteSurface = true;
    setTimeout(() => {
      if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
        return;
      }
      this.bindSurfaceIfReady();
      this.startFramePolling();
      this.startRemoteCursorPolling();
      this.startNativeMousePolling();
    }, 180);
  }

  stopFramePolling(): void {
    this.framePollGeneration += 1;
    if (this.frameTimer !== -1) {
      clearTimeout(this.frameTimer);
      this.frameTimer = -1;
    }
  }

  resetViewportTransform(): void {
    this.stopEdgeAutoPan();
    this.zoomScale = 1.0;
    this.offsetX = 0;
    this.offsetY = 0;
    this.isPanMode = false;
    this.viewportPanActive = false;
    this.pinchStartScale = 1.0;
    this.pinchStartDistance = 0;
    this.isPinching = false;
  }

  resetRemoteViewportForSession(): void {
    this.resetViewportTransform();
    this.hasVideo = false;
    this.remoteWidth = 0;
    this.remoteHeight = 0;
    this.showCursor = false;
    this.remoteCursorEmbedded = false;
    this.embeddedCursorOverlayFallback = false;
    this.lastRemoteCursorSequence = -1;
    this.lastRemoteCursorImageSequence = -1;
    this.hasAuthoritativeRemoteCursor = false;
    this.cursorPixelMap = undefined;
    this.remoteCursorHotX = 0;
    this.remoteCursorHotY = 0;
    this.remoteCursorImageWidth = 0;
    this.remoteCursorImageHeight = 0;
    this.localPointerGestureActive = false;
    this.lastLocalPointerInputAt = 0;
    this.leftButtonHeld = false;
    this.rightButtonHeld = false;
    this.leftButtonHeldAt = 0;
    this.preferAuthoritativeCursor = false;
    this.showLeftButtonHoldIndicator = false;
    this.touchpadDragCandidate = false;
    this.decoderHealthInitialized = false;
    this.lastDecoderInputFrames = 0;
    this.lastDecodedFrames = 0;
    this.decoderStallStartedAt = 0;
    this.videoRecoveryRefreshRequested = false;
    this.videoFallbackRequested = false;
    this.codecText = '等待视频';
  }

  checkDecoderHealth(frame: VideoFrameInfo): void {
    const totalFrames: number = frame.totalFrames ?? 0;
    const decodedFrames: number = frame.decodedFrames ?? 0;
    const codec: number = frame.codec ?? 0;
    if (!this.decoderHealthInitialized) {
      this.decoderHealthInitialized = true;
      this.lastDecoderInputFrames = totalFrames;
      this.lastDecodedFrames = decodedFrames;
      return;
    }

    const receivedMore: boolean = totalFrames > this.lastDecoderInputFrames;
    const decodedMore: boolean = decodedFrames > this.lastDecodedFrames;
    if (decodedMore || codec === 0) {
      this.decoderStallStartedAt = 0;
      this.videoRecoveryRefreshRequested = false;
    } else if (receivedMore && this.decoderStallStartedAt === 0) {
      this.decoderStallStartedAt = Date.now();
    }

    if (codec > 0 && this.decoderStallStartedAt > 0 && !this.videoFallbackRequested) {
      const stalledFor: number = Date.now() - this.decoderStallStartedAt;
      const codecName: string = this.videoCodecName(codec);
      if (stalledFor >= 1200 && !this.videoRecoveryRefreshRequested) {
        this.videoRecoveryRefreshRequested = true;
        RustDeskNapi.refreshVideo();
        RustDeskNapi.appendDiagnosticLog('video-recovery',
          `codec=${codecName} stalled action=request_keyframe stalled_ms=${stalledFor} input=${totalFrames} decoded=${decodedFrames}`)
        hilog.warn(LOG_DOMAIN, 'StarRustDesk', `${codecName} has input but no decoded output; requested key frame`);
      }
      if (codec !== 2 && stalledFor >= 3500) {
        const result: number = RustDeskNapi.fallbackVideoToVp9();
        if (result === 0) {
          this.videoFallbackRequested = true;
          this.decoderStallStartedAt = 0;
          RustDeskNapi.appendDiagnosticLog('video-recovery',
            `codec=${codecName} stalled action=fallback_vp9 stalled_ms=${stalledFor} input=${totalFrames} decoded=${decodedFrames}`)
          hilog.warn(LOG_DOMAIN, 'StarRustDesk', `${codecName} decoder stalled; requested VP9 fallback`);
        } else {
          if (result === -3) {
            this.videoFallbackRequested = true;
          }
          RustDeskNapi.appendDiagnosticLog('video-recovery', `fallback_vp9_failed result=${result}`)
          hilog.error(LOG_DOMAIN, 'StarRustDesk', `VP9 fallback request failed result=${result}`);
        }
      }
    }

    this.lastDecoderInputFrames = totalFrames;
    this.lastDecodedFrames = decodedFrames;
  }

  startRemoteCursorPolling(): void {
    if (this.cursorTimer !== -1) {
      clearTimeout(this.cursorTimer);
    }
    let poll = () => {
      if (this.connectionStatus === ConnectionStatus.CONNECTED) {
        try {
          let cursor: RemoteCursorPosition = RustDeskNapi.getRemoteCursorPosition();
          this.remoteCursorEmbedded = cursor.embedded;
          const now: number = Date.now();
          if (cursor.embedded && !this.embeddedCursorOverlayFallback && this.lastLocalPointerInputAt > 0 &&
            now - this.lastLocalPointerInputAt < 1000) {
            this.embeddedCursorOverlayFallback = true;
            RustDeskNapi.appendDiagnosticLog('input',
              `embedded_cursor_overlay_fallback display=${this.currentDisplay}`);
          }
          if (cursor.valid && cursor.sequence !== this.lastRemoteCursorSequence) {
            if (cursor.x >= 0 && cursor.y >= 0 && cursor.x < this.remoteWidth && cursor.y < this.remoteHeight) {
              const dragReadyForRemoteSync: boolean = this.leftButtonHeld && this.leftButtonHeldAt > 0 &&
                now - this.leftButtonHeldAt >= LOCAL_CURSOR_ECHO_GUARD_MS;
              const keepLocalPrediction: boolean = !this.preferAuthoritativeCursor &&
                !dragReadyForRemoteSync && (this.localPointerGestureActive ||
                now - this.lastLocalPointerInputAt < LOCAL_CURSOR_ECHO_GUARD_MS);
              if (!keepLocalPrediction) {
                this.lastRemoteCursorSequence = cursor.sequence;
                if (dragReadyForRemoteSync && !this.preferAuthoritativeCursor) {
                  this.preferAuthoritativeCursor = true;
                  RustDeskNapi.appendDiagnosticLog('input', 'cursor_prediction switched_to_remote_during_drag');
                }
                this.remoteCursorAbsX = cursor.x;
                this.remoteCursorAbsY = cursor.y;
                this.hasAuthoritativeRemoteCursor = true;
                // Outside local input, the controlled device is authoritative
                // and corrects any prediction error without introducing drift.
                this.updateCursorOverlayFromPosition(cursor.x, cursor.y);
                this.lastAbsX = cursor.x;
                this.lastAbsY = cursor.y;
                this.pointerInitialized = true;
              }
            } else {
              this.showCursor = false;
            }
          }
          if (cursor.embedded && !this.embeddedCursorOverlayFallback && !this.isPanMode) {
            this.showCursor = false;
          }
          this.pollRemoteCursorImage();
        } catch (_e) {
        }
      } else {
        this.remoteCursorEmbedded = false;
        this.embeddedCursorOverlayFallback = false;
        this.lastRemoteCursorSequence = -1;
        this.lastRemoteCursorImageSequence = -1;
        this.hasAuthoritativeRemoteCursor = false;
      }
      this.cursorTimer = setTimeout(poll, 33);
    };
    this.cursorTimer = setTimeout(poll, 33);
  }

  startNativeMousePolling(): void {
    this.stopNativeMousePolling();
    this.lastHardwareKeySyncAt = 0;
    const generation: number = ++this.nativeMousePollGeneration;
    let poll = () => {
      if (generation !== this.nativeMousePollGeneration) {
        return;
      }
      try {
        const now: number = Date.now();
        if (now - this.lastHardwareKeySyncAt >= 500) {
          this.lastHardwareKeySyncAt = now;
          this.syncHardwareKeyState();
        }
        let events: NativeMouseInputEvent[] = RustDeskNapi.takeNativeMouseEvents();
        for (let event of events) {
          this.handleNativeMouseInput(event);
        }
        let keyEvents: NativeKeyInputEvent[] = RustDeskNapi.takeNativeKeyEvents();
        for (let event of keyEvents) {
          this.handleNativeKeyInput(event);
        }
      } catch (_e) {
      }
      this.nativeMouseTimer = setTimeout(poll, 16);
    };
    this.nativeMouseTimer = setTimeout(poll, 16);
  }

  syncHardwareKeyState(): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel) {
      this.hardwareModifierTrackingActive = false;
      this.hardwareCapsLockInitialized = false;
      return;
    }
    const state: HardwareKeyState = RustDeskNapi.getHardwareKeyState();
    // Some HarmonyOS PC builds return a successful but permanently empty
    // global-key snapshot. Do not let that overwrite a real modifier captured
    // from the pointer/key event. Once polling observes a pressed modifier it
    // becomes authoritative until it observes the corresponding release.
    if (state.valid && (state.modifierMask !== 0 || this.hardwareModifierTrackingActive)) {
      ConnectionService.syncHardwareModifierState(
        (state.modifierMask & 1) !== 0,
        (state.modifierMask & 2) !== 0,
        (state.modifierMask & 4) !== 0
      );
      this.hardwareModifierTrackingActive = state.modifierMask !== 0;
    }
    if (!state.capsLockValid) {
      return;
    }
    if (!this.hardwareCapsLockInitialized) {
      this.hardwareCapsLockInitialized = true;
      this.hardwareCapsLockOn = state.capsLockOn;
      ConnectionService.syncCapsLockState(state.capsLockOn);
      return;
    }
    if (state.capsLockOn === this.hardwareCapsLockOn) {
      return;
    }
    this.hardwareCapsLockOn = state.capsLockOn;
    ConnectionService.sendCapsLockEvent(0, state.capsLockOn);
    ConnectionService.sendCapsLockEvent(1, state.capsLockOn);
    hilog.info(LOG_DOMAIN, 'StarRustDesk', `hardware CapsLock changed state=${state.capsLockOn}`);
  }

  stopNativeMousePolling(): void {
    this.nativeMousePollGeneration += 1;
    if (this.nativeMouseTimer !== -1) {
      clearTimeout(this.nativeMouseTimer);
      this.nativeMouseTimer = -1;
    }
  }

  handleNativeMouseInput(event: NativeMouseInputEvent): void {
    if (event.hover >= 0) {
      this.handleRemoteHover(event.hover === 1);
      return;
    }
    this.lastNativeMouseEventAt = Date.now();
    if (event.modifierValid) {
      ConnectionService.syncHeldModifierState(
        (event.modifierMask & 1) !== 0,
        (event.modifierMask & 2) !== 0,
        (event.modifierMask & 4) !== 0
      );
    }
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel ||
      this.remoteWidth <= 0 || this.remoteHeight <= 0) {
      return;
    }
    this.handleRemoteHover(true);
    this.lastMouseEventAt = this.lastNativeMouseEventAt;
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();

    let remotePoint: RemotePoint = this.updatePointerFromLocal(event.x, event.y);
    this.edgePanTouchActive = false;
    if (event.action === NATIVE_MOUSE_ACTION_MOVE) {
      this.updateEdgeAutoPan(remotePoint.x, remotePoint.y, false);
      if (this.lastNativeMouseEventAt - this.lastMoveSentAt > 8) {
        this.lastMoveSentAt = this.lastNativeMouseEventAt;
        ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 0);
      }
      return;
    }
    this.stopEdgeAutoPan();
    if (event.action === NATIVE_MOUSE_ACTION_CANCEL) {
      this.releaseHeldMouseButtons('native_cancel');
      return;
    }

    let forwardedAction: number = -1;
    if (event.button === NATIVE_MOUSE_BUTTON_LEFT) {
      if (event.action === NATIVE_MOUSE_ACTION_PRESS) {
        this.sendLeftDown(remotePoint.x, remotePoint.y);
        forwardedAction = 1;
      } else if (event.action === NATIVE_MOUSE_ACTION_RELEASE) {
        this.sendLeftUp(remotePoint.x, remotePoint.y, true);
        this.lastMappedPhysicalLeftUpAt = this.lastNativeMouseEventAt;
        forwardedAction = 2;
      }
    } else if (event.button === NATIVE_MOUSE_BUTTON_RIGHT) {
      if (event.action === NATIVE_MOUSE_ACTION_PRESS) {
        this.sendRightDown(remotePoint.x, remotePoint.y);
        forwardedAction = 3;
      } else if (event.action === NATIVE_MOUSE_ACTION_RELEASE) {
        this.sendRightUp(remotePoint.x, remotePoint.y, true);
        forwardedAction = 4;
      }
    }
    if (forwardedAction > 0) {
      RustDeskNapi.appendDiagnosticLog('input',
        `native_mouse_forwarded action=${forwardedAction} x=${Math.round(remotePoint.x)} y=${Math.round(remotePoint.y)}`);
    }
  }

  handleNativeKeyInput(event: NativeKeyInputEvent): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel) {
      return;
    }
    if (event.capsLockValid) {
      ConnectionService.syncCapsLockState(event.capsLockOn);
    }
    const action: number = event.action === 0 ? 0 : 1;
    const controlCode: number = this.mapControlKeyCode(event.keyCode);
    if (controlCode === 20) {
      ConnectionService.sendCapsLockEvent(action, event.capsLockValid ? event.capsLockOn : undefined);
      return;
    }
    if (controlCode > 0) {
      ConnectionService.sendKeyEvent(controlCode, action);
      return;
    }
    if (event.modifierValid) {
      ConnectionService.syncHeldModifierState(
        (event.modifierMask & 1) !== 0,
        (event.modifierMask & 2) !== 0,
        (event.modifierMask & 4) !== 0
      );
    }
    const scanCode: number = this.mapHarmonyKeyCodeToWindowsScanCode(event.keyCode);
    if (scanCode > 0) {
      const eventModifierMask: number | undefined = event.modifierValid ? event.modifierMask : undefined;
      const letter: string = this.mapHarmonyKeyCodeToLetter(event.keyCode);
      if (letter.length > 0) {
        ConnectionService.sendLetterKeyEvent(letter, scanCode, action, eventModifierMask);
      } else {
        ConnectionService.sendPhysicalKeyEvent(scanCode, action, eventModifierMask);
      }
      if (action === 0) {
        RustDeskNapi.appendDiagnosticLog('input',
          `native_key_forwarded code=${event.keyCode} scan=${scanCode} modifiers=${event.modifierMask} ` +
          `modifier_valid=${event.modifierValid ? 1 : 0}`);
      }
    }
  }

  pollRemoteCursorImage(): void {
    let cursorData = RustDeskNapi.getRemoteCursorData();
    if (!cursorData.valid || cursorData.sequence === undefined ||
      cursorData.sequence === this.lastRemoteCursorImageSequence) {
      return;
    }
    this.lastRemoteCursorImageSequence = cursorData.sequence;
    let id: number = cursorData.id ?? 0;
    let width: number = cursorData.width ?? 0;
    let height: number = cursorData.height ?? 0;
    let hotx: number = cursorData.hotx ?? 0;
    let hoty: number = cursorData.hoty ?? 0;
    if (width <= 0 || height <= 0 || cursorData.colors === undefined) {
      return;
    }
    let pixelMap: image.PixelMap | undefined = this.cursorPixelMapCache.get(id);
    if (pixelMap === undefined) {
      pixelMap = image.createPixelMapSync(cursorData.colors, {
        size: { width: width, height: height },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888
      });
      this.cursorPixelMapCache.set(id, pixelMap);
    }
    this.cursorPixelMap = pixelMap;
    this.remoteCursorHotX = Math.max(0, Math.min(width - 1, hotx));
    this.remoteCursorHotY = Math.max(0, Math.min(height - 1, hoty));
    this.remoteCursorImageWidth = width;
    this.remoteCursorImageHeight = height;
    if (this.hasAuthoritativeRemoteCursor) {
      this.updateCursorOverlayFromPosition(this.remoteCursorAbsX, this.remoteCursorAbsY);
    }
  }

  releaseRemoteCursorImages(): void {
    this.cursorPixelMapCache.forEach((pixelMap: image.PixelMap) => {
      pixelMap.release().catch(() => {
      });
    });
    this.cursorPixelMapCache.clear();
    this.cursorPixelMap = undefined;
  }

  primaryTextColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY;
  }

  secondaryTextColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY;
  }

  panelColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT;
  }

  mutedSurfaceColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED;
  }

  themeBorderColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.BORDER_DARK : '#DEE6F1';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.connectionStatus === ConnectionStatus.DISCONNECTED) {
          this.buildDisconnectedView();
        } else if (this.connectionStatus === ConnectionStatus.CONNECTING) {
          this.buildConnectingView();
        } else if (this.connectionStatus === ConnectionStatus.WAITING_2FA) {
          this.buildTwoFactorView();
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
      if (this.showKeyboardPanel && this.connectionStatus === ConnectionStatus.CONNECTED) {
        this.buildKeyboardCapture();
      }
      if (this.showGestureHelp && this.connectionStatus === ConnectionStatus.CONNECTED) {
        this.buildGestureHelpOverlay();
      }
      if (this.showMobileActions && this.connectionStatus === ConnectionStatus.CONNECTED && this.isPeerAndroid) {
        this.buildMobileActionsOverlay();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : '#E7EEF8')
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
        .fontColor(this.primaryTextColor());
      Text(translate('No active connection'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE).fontColor(this.primaryTextColor());
      Text(translate('Enter a Remote ID to connect'))
        .fontSize(RustDeskTheme.FONT_SIZE_SMALL).fontColor(this.secondaryTextColor());
      Button(translate('Back')).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).borderRadius(6)
        .onClick(() => { this.disconnectSession(); });
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
        .fontColor(this.primaryTextColor());
      Text(this.connectedPeerId.length > 0 ? this.connectedPeerId : translate('Connecting'))
        .fontSize(13)
        .fontColor(this.secondaryTextColor());
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  buildTwoFactorView() {
    Column({ space: 18 }) {
      Text('二次验证')
        .fontSize(26)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .fontColor(this.primaryTextColor());
      Text('被控端已开启二次验证，请输入身份验证器中的 6 位验证码')
        .fontSize(14)
        .fontColor(this.secondaryTextColor())
        .textAlign(TextAlign.Center)
        .width('100%');
      TextInput({ placeholder: '6 位验证码', text: this.twoFaCode })
        .type(InputType.Number)
        .maxLength(6)
        .fontSize(22)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.primaryTextColor())
        .placeholderColor(this.secondaryTextColor())
        .textAlign(TextAlign.Center)
        .height(52)
        .width('100%')
        .backgroundColor(this.mutedSurfaceColor())
        .border({ width: 1, color: this.twoFaError.length > 0 ? RustDeskTheme.ERROR : this.themeBorderColor() })
        .borderRadius(8)
        .onChange((value: string) => {
          this.twoFaCode = value.replace(/[^0-9]/g, '').slice(0, 6);
          this.twoFaError = '';
        });
      if (this.twoFaError.length > 0) {
        Text(this.twoFaError)
          .fontSize(13)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%');
      }
      if (this.enableTrustedDevices) {
        Row() {
          Text('信任此设备，以后连接时不再询问验证码')
            .fontSize(14)
            .fontColor(this.primaryTextColor())
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.trustThisDevice })
            .onChange((isOn: boolean) => {
              this.trustThisDevice = isOn;
            });
        }
        .width('100%');
      }
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontColor(this.primaryTextColor())
          .backgroundColor(this.mutedSurfaceColor())
          .borderRadius(8)
          .onClick(() => {
            this.disconnectSession();
          });
        Button('验证')
          .layoutWeight(1)
          .height(44)
          .enabled(this.isTwoFactorCodeReady())
          .fontColor(Color.White)
          .backgroundColor(this.isTwoFactorCodeReady() ? RustDeskTheme.ACCENT : '#94A3B8')
          .borderRadius(8)
          .onClick(() => {
            this.submitTwoFactor();
          });
      }
      .width('100%');
    }
    .width(this.pageWidth > 600 ? 440 : '88%')
    .padding(24)
    .backgroundColor(this.panelColor())
    .border({ width: 1, color: this.themeBorderColor() })
    .borderRadius(14)
    .shadow({ radius: 18, color: '#22000000', offsetX: 0, offsetY: 6 });
  }

  isTwoFactorCodeReady(): boolean {
    return /^\d{6}$/.test(this.twoFaCode);
  }

  submitTwoFactor(): void {
    if (!this.isTwoFactorCodeReady()) {
      this.twoFaError = '请输入 6 位数字验证码';
      return;
    }
    let result: number = ConnectionService.send2FA(
      this.twoFaCode, this.enableTrustedDevices && this.trustThisDevice);
    if (result === 0) {
      this.twoFaCode = '';
      this.twoFaError = '';
      this.connectionStatus = ConnectionStatus.CONNECTING;
      this.connectingStartedAt = Date.now();
    } else {
      this.twoFaError = '验证码发送失败，请重试';
    }
  }

  @Builder
  buildRemoteScreen() {
    if (this.isFullScreen) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.buildRemoteViewport();
        }
        .width('100%')
        .height('100%')

        Row({ space: 8 }) {
          if (this.isPeerAndroid) {
            Button('手机操作')
              .width(92)
              .height(36)
              .fontSize(12)
              .fontColor(Color.White)
              .backgroundColor('#99000000')
              .border({ width: 1, color: '#66FFFFFF' })
              .borderRadius(18)
              .onClick(() => {
                this.showMobileActions = true;
              })
          }
          if (this.canPanViewport()) {
            Button(this.edgeAutoPanEnabled ? '边缘跟随开' : '边缘跟随')
              .width(92)
              .height(36)
              .fontSize(12)
              .fontWeight(this.edgeAutoPanEnabled ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
              .fontColor(Color.White)
              .backgroundColor(this.edgeAutoPanEnabled ? PAN_MODE_ACTIVE_COLOR : '#99000000')
              .border({ width: 1, color: this.edgeAutoPanEnabled ? PAN_MODE_ACTIVE_COLOR : '#66FFFFFF' })
              .borderRadius(18)
              .onClick(() => {
                this.setEdgeAutoPanEnabled(!this.edgeAutoPanEnabled);
              })
            if (this.isPanMode) {
              Button('结束移动')
                .width(92)
                .height(36)
                .fontSize(12)
                .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
                .fontColor(Color.White)
                .backgroundColor(PAN_MODE_ACTIVE_COLOR)
                .border({ width: 1, color: PAN_MODE_ACTIVE_COLOR })
                .borderRadius(18)
                .onClick(() => {
                  this.setPanMode(false);
                })
            } else {
              Button('移动画面')
                .width(92)
                .height(36)
                .fontSize(12)
                .fontWeight(500)
                .fontColor(Color.White)
                .backgroundColor('#99000000')
                .border({ width: 1, color: '#66FFFFFF' })
                .borderRadius(18)
                .onClick(() => {
                  this.setPanMode(true);
                })
            }
          }
          Button('退出全屏')
            .width(88)
            .height(36)
            .fontSize(12)
            .fontColor(Color.White)
            .backgroundColor('#99000000')
            .border({ width: 1, color: '#66FFFFFF' })
            .borderRadius(18)
            .onClick(() => {
              this.exitFullScreen();
            })
        }
        .position({
          x: Math.max(12, this.pageWidth - (this.canPanViewport() ?
            (this.isPeerAndroid ? 400 : 300) : (this.isPeerAndroid ? 200 : 100))),
          y: 12,
        })
        .onHover((isHovering: boolean) => {
          this.handleNonRemoteHover(isHovering);
        })

      }
      .width('100%')
      .height('100%')
      .backgroundColor('#090D14');
    } else if (this.isLargeLayout()) {
      Row() {
        Column() {
          this.buildStatsPanel();
          this.buildRemoteViewport();
        }
        .layoutWeight(1)
        .height('100%')

        this.buildSideToolbar();
      }
      .width('100%').height('100%')
      .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : '#DCE5F2');
    } else {
      Column() {
        this.buildStatsPanel();
        this.buildRemoteViewport();
        this.buildFloatingToolbar();
      }
      .width('100%').height('100%')
      .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : '#DCE5F2');
    }
  }

  @Builder
  buildRemoteFileBrowser() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text(this.remoteFileBrowserMode === 'download' ? '从远端取回文件' : '选择远端保存位置')
            .layoutWeight(1)
            .fontSize(18)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.primaryTextColor())
          Button('历史')
            .height(34)
            .fontSize(13)
            .fontColor(RustDeskTheme.ACCENT)
            .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
            .borderRadius(7)
            .onClick(() => {
              this.fileTransferHistoryDialogController.open();
            })
        }
        .width('100%')
        Row({ space: 8 }) {
          Button('上一级')
            .height(40)
            .fontColor(RustDeskTheme.ACCENT)
            .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
            .borderRadius(8)
            .enabled(!this.remoteDirectoryLoading)
            .onClick(() => {
              this.openRemoteDirectory(this.getRemoteParentPath());
            })
          Text(this.remoteDirectoryPath === '/' ? '此电脑' : this.remoteDirectoryPath)
            .layoutWeight(1)
            .fontSize(15)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        if (this.remoteFileBrowserMode === 'download' && !this.remoteDirectoryLoading) {
          Row({ space: 8 }) {
            Button(this.areAllRemoteEntriesSelected() ? '取消全选' : '全选')
              .height(36)
              .fontSize(13)
              .fontColor(RustDeskTheme.ACCENT)
              .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
              .borderRadius(8)
              .enabled(this.getSelectableRemoteEntries().length > 0)
              .onClick(() => {
                this.toggleSelectAllRemoteEntries();
              })
            Button('取回当前文件夹')
              .height(36)
              .fontSize(13)
              .fontColor(RustDeskTheme.ACCENT)
              .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
              .borderRadius(8)
              .enabled(this.remoteDirectoryPath.length > 0 && this.remoteDirectoryPath !== '/')
              .onClick(() => {
                this.prepareCurrentRemoteFolderDownload();
              })
            Blank()
            Text(`已选 ${this.selectedRemoteDownloads.length} 项`)
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
          }
          .width('100%')
        }

        if (this.remoteDirectoryLoading) {
          Column() {
            LoadingProgress().width(40).height(40).color(RustDeskTheme.ACCENT)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 6 }) {
            ForEach(this.getVisibleRemoteEntries(), (entry: RemoteDirectoryEntry) => {
              ListItem() {
                Row({ space: 10 }) {
                  if (this.remoteFileBrowserMode === 'download' && entry.entryType !== 3) {
                    Toggle({ type: ToggleType.Checkbox, isOn: this.isRemoteEntrySelected(entry) })
                      .width(24)
                      .height(24)
                      .selectedColor(RustDeskTheme.ACCENT)
                      .onChange(() => {
                        this.toggleRemoteDownloadEntry(entry);
                      })
                  }
                  Column() {
                    Text(this.remoteEntryBadge(entry))
                      .fontSize(this.remoteEntryBadge(entry).length > 3 ? 10 : 12)
                      .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
                      .fontColor(this.isRemoteDirectory(entry) ? RustDeskTheme.ACCENT : this.secondaryTextColor())
                      .maxLines(1)
                  }
                  .width(44)
                  .height(44)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(this.isRemoteDirectory(entry) ?
                    (this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT) :
                    this.mutedSurfaceColor())
                  .borderRadius(10)

                  Column({ space: 4 }) {
                    Text(entry.name)
                      .width('100%')
                      .fontSize(15)
                      .fontWeight(500)
                      .fontColor(this.primaryTextColor())
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.remoteEntryMetadata(entry))
                      .width('100%')
                      .fontSize(12)
                      .fontColor(this.secondaryTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                    .layoutWeight(1)
                    .onClick(() => {
                      if (this.isRemoteDirectory(entry)) {
                        this.openRemoteDirectory(this.joinRemotePath(entry.name));
                      } else if (this.remoteFileBrowserMode === 'download') {
                        this.toggleRemoteDownloadEntry(entry);
                      }
                    })
                  if (this.isRemoteDirectory(entry)) {
                    Text('›')
                      .width(28)
                      .fontSize(24)
                      .fontColor(RustDeskTheme.ACCENT)
                      .textAlign(TextAlign.Center)
                      .onClick(() => {
                        this.openRemoteDirectory(this.joinRemotePath(entry.name));
                      })
                  }
                }
                .width('100%')
                .constraintSize({ minHeight: 68 })
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .backgroundColor(this.isRemoteEntrySelected(entry) ?
                  (this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT) :
                  Color.Transparent)
                .borderRadius(8)
              }
            }, (entry: RemoteDirectoryEntry) => `${entry.entryType}:${entry.name}`)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 1, color: this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER })
        }

        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(42)
            .borderRadius(8)
            .fontColor(this.primaryTextColor())
            .backgroundColor(this.mutedSurfaceColor())
            .onClick(() => {
              this.closeRemoteFileBrowser(true);
            })
          if (this.remoteFileBrowserMode === 'download') {
            Button(`取回所选 (${this.selectedRemoteDownloads.length})`)
              .layoutWeight(1)
              .height(42)
              .borderRadius(8)
              .enabled(this.selectedRemoteDownloads.length > 0 && !this.remoteDirectoryLoading)
              .backgroundColor(RustDeskTheme.ACCENT)
              .onClick(() => {
                this.prepareRemoteDownload(this.selectedRemoteDownloads);
              })
          } else {
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
        }
        .width('100%')
      }
      .width(this.isLargeLayout() ? 680 : '96%')
      .height(this.isLargeLayout() ? '84%' : '90%')
      .padding(16)
      .backgroundColor(this.panelColor())
      .border({ width: 1, color: this.themeBorderColor() })
      .borderRadius(8)
      .shadow({ radius: 28, color: '#500C1524', offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  @Builder
  buildTransferProgress() {
    Column({ space: 7 }) {
      Row({ space: 10 }) {
        Text(this.transferDirection === 'download' ? '正在取回文件' : '正在发送文件')
          .fontSize(14)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.primaryTextColor())
        if (this.transferTotalItems > 1) {
          Text(`${this.transferCompletedItems}/${this.transferTotalItems} 项`)
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
        }
        Blank()
        Text(this.transferCancelling ? '正在取消…' : this.formatTransferSpeed(this.transferSpeedBytesPerSecond))
          .fontSize(12)
          .fontColor(this.transferCancelling ? this.secondaryTextColor() : RustDeskTheme.ACCENT)
        Button('取消')
          .height(30)
          .fontSize(12)
          .fontColor('#C83B45')
          .backgroundColor(this.isDarkMode ? '#3A2025' : '#FFF0F1')
          .borderRadius(8)
          .enabled(!this.transferCancelling)
          .onClick(() => {
            this.cancelActiveFileTransfer();
          })
      }
      .width('100%')

      Progress({ value: this.transferProgress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(7)
        .color(RustDeskTheme.ACCENT)

      Row() {
        Text(`${this.formatFileSize(this.transferTransferredBytes)} / ${this.transferTotalBytes > 0 ?
          this.formatFileSize(this.transferTotalBytes) : '计算中'}`)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
        Blank()
        Text(`${Math.floor(this.transferProgress)}%`)
          .fontSize(12)
          .fontColor(this.primaryTextColor())
      }
      .width('100%')
    }
    .width(this.isLargeLayout() ? 520 : '94%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(this.panelColor())
    .border({ width: 1, color: this.themeBorderColor() })
    .borderRadius(12)
    .shadow({ radius: 14, color: '#300C1524', offsetX: 0, offsetY: 5 })
    .position({ x: this.isLargeLayout() ? 24 : '3%', y: 16 })
  }

  @Builder
  buildRemoteViewport() {
    Stack({ alignContent: Alignment.Center }) {
      Button('', { stateEffect: false })
        .id('remoteInputCapture')
        .width(this.inputMode === INPUT_MODE_MOUSE ? '100%' : this.getDisplayWidth())
        .height(this.inputMode === INPUT_MODE_MOUSE ? '100%' : this.getDisplayHeight())
        .padding(0)
        .borderRadius(0)
        .stateEffect(false)
        .backgroundColor('#01000000')
        .opacity(0.001)
        .zIndex(10)
        .hitTestBehavior(HitTestMode.Block)
        .mouseResponseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
        .focusable(true)
        .defaultFocus(true)
        .focusOnTouch(true)
        .onClick((event: ClickEvent) => {
          this.requestRemoteInputFocus();
          this.handleRemoteClickFallback(event);
        })
        .onTouch((event: TouchEvent) => {
          this.handleRemoteTouch(event);
        })
        .onMouse((event: MouseEvent) => {
          this.handleRemoteMouse(event);
        })
        .onHover((isHovering: boolean) => {
          this.handleRemoteHover(isHovering);
        })
        .onBlur(() => {
          if (this.localPointerGestureActive) {
            RustDeskNapi.appendDiagnosticLog('input', 'input_blur ignored_during_touch_gesture');
            return;
          }
          this.releaseHeldMouseButtons('input_blur');
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

      if (this.showRemoteSurface) {
        XComponent({
          id: 'remoteScreen' + this.surfaceEpoch.toString(),
          type: XComponentType.SURFACE,
          libraryname: 'entry',
          controller: this.xComponentController
        })
          .width(this.getDisplayWidth())
          .height(this.getDisplayHeight())
          .hitTestBehavior(HitTestMode.None)
          .id('remoteNativeInputCapture')
          .focusable(true)
          .onLoad(() => {
            this.onSurfaceReady();
            setTimeout(() => this.requestRemoteInputFocus(), 60);
          })
      }

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

      if (this.showCursor && (!this.remoteCursorEmbedded || this.embeddedCursorOverlayFallback || this.isPanMode) &&
        this.inputMode === INPUT_MODE_MOUSE) {
        this.buildCursorOverlay();
      }

      if (this.showLeftButtonHoldIndicator && this.inputMode === INPUT_MODE_MOUSE && !this.isPanMode) {
        Row({ space: 6 }) {
          Circle()
            .width(8)
            .height(8)
            .backgroundColor(Color.White)
          Text('左键按住')
            .fontSize(12)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(Color.White)
        }
        .padding({ left: 11, right: 11, top: 7, bottom: 7 })
        .borderRadius(16)
        .backgroundColor(PAN_MODE_ACTIVE_COLOR)
        .position({ x: 12, y: 12 })
        .zIndex(30)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .clip(true)
    .backgroundColor('#090D14')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      let previousWidth: number = this.componentWidth;
      let previousHeight: number = this.componentHeight;
      this.componentWidth = newValue.width as number;
      this.componentHeight = newValue.height as number;
      if (Math.abs(this.componentWidth - previousWidth) > 0.5 ||
        Math.abs(this.componentHeight - previousHeight) > 0.5) {
        this.stopEdgeAutoPan();
        this.clampViewportOffset();
      }
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
        .fontColor(this.primaryTextColor());
      Text(this.connectionError.length > 0 ? this.connectionError : translate('Connection failed'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontColor(RustDeskTheme.ERROR)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 });
      Button(translate('Retry')).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).borderRadius(8)
        .onClick(() => { this.disconnectSession(); });
      Button(translate('Back')).fontColor(this.primaryTextColor()).backgroundColor(this.mutedSurfaceColor()).borderRadius(8)
        .onClick(() => { this.disconnectSession(); });
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
              .fontColor(display === this.currentDisplay ? Color.White : this.primaryTextColor())
              .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : this.mutedSurfaceColor())
              .borderRadius(6)
              .onClick(() => {
                this.switchDisplay(display);
              })
          }, (display: number) => `${display}-${this.currentDisplay}`)
        }
        this.buildInputModeButton(70, false)
        if (this.canPanViewport()) {
          this.buildEdgeAutoPanButton(78)
        }
        this.buildToolbarButton('键盘', 64, this.showKeyboardPanel, false, true, () => {
          this.toggleRemoteKeyboard();
        })
        if (this.isPeerAndroid) {
          this.buildToolbarButton('手机操作', 76, this.showMobileActions, false, true, () => {
            this.showMobileActions = true;
          })
        }
        this.buildToolbarButton('手势', 54, false, false, true, () => {
          this.showGestureHelp = true;
        })
        if (this.canPanViewport()) {
          if (this.isPanMode) {
            this.buildToolbarButton('结束移动', 78, true, false, true, () => {
              this.setPanMode(false);
            })
          } else {
            this.buildToolbarButton('移动画面', 78, false, false, true, () => {
              this.setPanMode(true);
            })
          }
        }
        this.buildToolbarButton('发送文件', 82, false, false, !this.transferActive, () => {
          this.pickFileForUpload();
        })
        this.buildToolbarButton('取回文件', 82, false, false, !this.transferActive, () => {
          this.openRemoteDownloadBrowser();
        })
        this.buildToolbarButton(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关', 82, this.clipboardSyncEnabled, false, true, () => {
          this.toggleClipboardSync();
        })
        this.buildToolbarButton('+', 40, false, false, true, () => {
          this.adjustZoom(0.25);
        })
        this.buildToolbarButton('-', 40, false, false, true, () => {
          this.adjustZoom(-0.25);
        })
        this.buildToolbarButton('全屏', 58, false, false, true, () => {
          this.enterFullScreen();
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
    .backgroundColor(this.panelColor())
    .border({ width: { top: 1 }, color: this.themeBorderColor() })
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .onHover((isHovering: boolean) => {
      this.handleNonRemoteHover(isHovering);
    });
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
              .fontColor(display === this.currentDisplay ? Color.White : this.primaryTextColor())
              .backgroundColor(display === this.currentDisplay ? RustDeskTheme.ACCENT : this.mutedSurfaceColor())
              .borderRadius(6)
              .onClick(() => {
                this.switchDisplay(display);
              })
          }, (display: number) => `${display}-${this.currentDisplay}`)
        }
        this.buildInputModeButton(80, true)
        if (this.canPanViewport()) {
          this.buildEdgeAutoPanButton(80)
        }
        this.buildToolbarButton('键盘', 80, this.showKeyboardPanel, false, true, () => {
          this.toggleRemoteKeyboard();
        })
        if (this.isPeerAndroid) {
          this.buildToolbarButton('手机操作', 80, this.showMobileActions, false, true, () => {
            this.showMobileActions = true;
          })
        }
        this.buildToolbarButton('手势说明', 80, false, false, true, () => {
          this.showGestureHelp = true;
        })
        if (this.canPanViewport()) {
          if (this.isPanMode) {
            this.buildToolbarButton('结束移动', 80, true, false, true, () => {
              this.setPanMode(false);
            })
          } else {
            this.buildToolbarButton('移动画面', 80, false, false, true, () => {
              this.setPanMode(true);
            })
          }
        }
        this.buildToolbarButton('发送文件', 80, false, false, !this.transferActive, () => {
          this.pickFileForUpload();
        })
        this.buildToolbarButton('取回文件', 80, false, false, !this.transferActive, () => {
          this.openRemoteDownloadBrowser();
        })
        this.buildToolbarButton(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关', 80, this.clipboardSyncEnabled, false, true, () => {
          this.toggleClipboardSync();
        })
        this.buildToolbarButton('+', 80, false, false, true, () => {
          this.adjustZoom(0.25);
        })
        this.buildToolbarButton('-', 80, false, false, true, () => {
          this.adjustZoom(-0.25);
        })
        this.buildToolbarButton('全屏', 80, false, false, true, () => {
          this.enterFullScreen();
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
    .backgroundColor(this.panelColor())
    .border({ width: { left: 1 }, color: this.themeBorderColor() })
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .onHover((isHovering: boolean) => {
      this.handleNonRemoteHover(isHovering);
    });
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
      .fontColor(danger ? RustDeskTheme.ERROR : (selected ? Color.White : this.primaryTextColor()))
      .backgroundColor(danger ? (this.isDarkMode ? RustDeskTheme.DANGER_SOFT_DARK : '#FDECEC') :
        (selected ? ((label === '结束移动' || label === '边缘跟随开') ?
          PAN_MODE_ACTIVE_COLOR : RustDeskTheme.ACCENT) : this.mutedSurfaceColor()))
      .borderRadius(6)
      .enabled(enabled)
      .onClick(() => {
        onClick();
      })
  }

  @Builder
  buildEdgeAutoPanButton(buttonWidth: number) {
    Button(this.edgeAutoPanEnabled ? '边缘跟随开' : '边缘跟随')
      .width(buttonWidth)
      .height(40)
      .padding({ left: 2, right: 2 })
      .fontSize(12)
      .fontWeight(this.edgeAutoPanEnabled ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
      .fontColor(this.edgeAutoPanEnabled ? Color.White : this.primaryTextColor())
      .backgroundColor(this.edgeAutoPanEnabled ? PAN_MODE_ACTIVE_COLOR : this.mutedSurfaceColor())
      .border({
        width: 1,
        color: this.edgeAutoPanEnabled ? PAN_MODE_ACTIVE_COLOR : this.themeBorderColor(),
      })
      .borderRadius(6)
      .enabled(this.inputMode === INPUT_MODE_MOUSE)
      .opacity(this.inputMode === INPUT_MODE_MOUSE ? 1 : 0.55)
      .onClick(() => {
        this.setEdgeAutoPanEnabled(!this.edgeAutoPanEnabled);
      })
  }

  @Builder
  buildInputModeIcon(mode: string, size: number, selected: boolean) {
    Stack() {
      if (mode === INPUT_MODE_MOUSE) {
        Path()
          .commands('M 2 1 L 2 18 L 6.5 13.5 L 10 21 L 13 19.5 L 9.5 12.5 L 16 12.5 Z')
          .fill(selected ? Color.White : this.primaryTextColor())
          .stroke(selected ? '#B3000000' : this.themeBorderColor())
          .strokeWidth(1.2)
      } else {
        Path()
          .commands('M 8 11 L 8 4 C 8 2.7 9 2 10 2 C 11.1 2 12 2.8 12 4 L 12 10 L 13 6.8 C 13.3 5.8 14.2 5.3 15.1 5.6 C 16 5.9 16.4 6.8 16.1 7.7 L 15.3 10.5 L 17 8.2 C 17.6 7.4 18.6 7.3 19.3 7.9 C 20 8.5 20.1 9.5 19.5 10.2 L 16.2 15.5 C 15.1 17.2 13.3 18.2 11.3 18.2 L 9.5 18.2 C 7.8 18.2 6.3 17.4 5.3 16.1 L 2.7 12.7 C 2 11.8 2.1 10.6 3 9.9 C 3.8 9.3 4.9 9.4 5.6 10.1 Z')
          .fill(selected ? Color.White : this.primaryTextColor())
          .stroke(selected ? '#B3000000' : this.themeBorderColor())
          .strokeWidth(1.1)
      }
    }
    .width(size)
    .height(size)
  }

  @Builder
  buildInputModeButton(buttonWidth: number, vertical: boolean) {
    Button() {
      if (vertical) {
        Column({ space: 1 }) {
          this.buildInputModeIcon(this.inputMode, 20, true)
          Text(this.inputMode === INPUT_MODE_MOUSE ? '鼠标' : '触摸')
            .fontSize(11)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(Color.White)
        }
        .justifyContent(FlexAlign.Center)
      } else {
        Row({ space: 4 }) {
          this.buildInputModeIcon(this.inputMode, 19, true)
          Text(this.inputMode === INPUT_MODE_MOUSE ? '鼠标' : '触摸')
            .fontSize(12)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(Color.White)
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width(buttonWidth)
    .height(vertical ? 48 : 40)
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
    .backgroundColor(RustDeskTheme.ACCENT)
    .borderRadius(7)
    .onClick(() => {
      this.toggleInputMode();
    })
  }

  @Builder
  buildGestureHelpOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('触屏操作方式')
          .fontSize(20)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.primaryTextColor())
          .width('100%')

        Row({ space: 10 }) {
          this.buildInputModeChoice(INPUT_MODE_MOUSE, '鼠标模式')
          this.buildInputModeChoice(INPUT_MODE_TOUCH, '触摸模式')
        }
        .width('100%')

        Row() {
          Column({ space: 3 }) {
            Text('显示本地鼠标指针')
              .fontSize(14)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
              .fontColor(this.primaryTextColor())
              .width('100%')
            Text(this.inputMode === INPUT_MODE_MOUSE ? '仅控制本机物理鼠标指针，远端真实光标始终显示' : '仅在鼠标模式下生效')
              .fontSize(11)
              .fontColor(this.secondaryTextColor())
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.showLocalCursor })
            .enabled(this.inputMode === INPUT_MODE_MOUSE)
            .onChange((isOn: boolean) => {
              this.setLocalCursorPreference(isOn);
            })
        }
        .width('100%')
        .padding({ left: 2, right: 2, top: 2, bottom: 2 })

        Row() {
          Column({ space: 3 }) {
            Text('边缘自动平移')
              .fontSize(14)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
              .fontColor(this.primaryTextColor())
              .width('100%')
            Text(this.inputMode === INPUT_MODE_MOUSE ?
              '画面超出可视区域时，鼠标靠近边缘即可平滑跟随；越靠近边缘移动越快' : '仅在鼠标模式下生效')
              .fontSize(11)
              .fontColor(this.secondaryTextColor())
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.edgeAutoPanEnabled })
            .enabled(this.inputMode === INPUT_MODE_MOUSE)
            .onChange((isOn: boolean) => {
              this.setEdgeAutoPanEnabled(isOn);
            })
        }
        .width('100%')
        .padding({ left: 2, right: 2, top: 2, bottom: 2 })

        if (this.inputMode === INPUT_MODE_MOUSE) {
          Text('适合控制电脑：\n• 单指滑动：移动鼠标\n• 单击：左键\n• 双击后按住移动：拖拽\n• 长按或双指轻点：右键\n• 双指平行滑动：滚动\n• 双指捏合：缩放画面\n• 边缘跟随开启后：画面超出可视区域时，鼠标靠近边缘会自动平移，越靠边越快\n• 放大后点“移动画面”：按钮变蓝，单指平移视野且远端鼠标保持显示\n• 移动画面模式下，双指滚动和捏合缩放仍可使用\n• 全屏三指上滑：调出系统键盘，输入直达远端')
            .fontSize(14)
            .lineHeight(24)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        } else {
          Text('适合直接点按：\n• 点按位置：左键\n• 按住移动：拖拽\n• 双指轻点：右键\n• 双指平行滑动：滚动\n• 双指捏合：缩放画面\n• 放大后点“移动画面”：按钮变绿，单指平移视野且不点击远端\n• 移动画面模式下，双指滚动和捏合缩放仍可使用\n• 全屏三指上滑：调出系统键盘，输入直达远端')
            .fontSize(14)
            .lineHeight(24)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        }

        Button('知道了')
          .width('100%')
          .height(42)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(8)
          .onClick(() => {
            this.dismissGestureHelp();
          })
      }
      .width(this.isLargeLayout() ? 420 : '88%')
      .padding(20)
      .backgroundColor(this.panelColor())
      .border({ width: 1, color: this.themeBorderColor() })
      .borderRadius(12)
      .shadow({ radius: 28, color: '#66000000', offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .onHover((isHovering: boolean) => {
      this.handleNonRemoteHover(isHovering);
    })
  }

  sendMobileAction(action: number, label: string): void {
    const result: number = RustDeskNapi.sendMobileAction(action);
    if (result !== 0) {
      this.showFileToast(`${label}发送失败 (${result})`);
      return;
    }
    RustDeskNapi.appendDiagnosticLog('mobile-action', `sent action=${action} label=${label}`);
    this.showMobileActions = false;
  }

  @Builder
  buildMobileActionButton(label: string, action: number, danger: boolean = false) {
    Button(label)
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
      .fontColor(danger ? RustDeskTheme.ERROR : this.primaryTextColor())
      .backgroundColor(danger ? (this.isDarkMode ? RustDeskTheme.DANGER_SOFT_DARK : '#FDECEC') :
        this.mutedSurfaceColor())
      .border({ width: 1, color: danger ? RustDeskTheme.ERROR : this.themeBorderColor() })
      .borderRadius(8)
      .onClick(() => {
        this.sendMobileAction(action, label);
      })
  }

  @Builder
  buildMobileActionsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Row() {
          Column({ space: 3 }) {
            Text('安卓手机操作')
              .fontSize(20)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
              .fontColor(this.primaryTextColor())
            Text('通过被控端的无障碍服务执行系统操作')
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button('关闭')
            .height(36)
            .fontSize(13)
            .fontColor(this.primaryTextColor())
            .backgroundColor(this.mutedSurfaceColor())
            .borderRadius(7)
            .onClick(() => {
              this.showMobileActions = false;
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          this.buildMobileActionButton('返回', MOBILE_ACTION_BACK)
          this.buildMobileActionButton('主页', MOBILE_ACTION_HOME)
          this.buildMobileActionButton('最近任务', MOBILE_ACTION_RECENTS)
        }
        .width('100%')

        Row({ space: 10 }) {
          this.buildMobileActionButton('音量 −', MOBILE_ACTION_VOLUME_DOWN)
          this.buildMobileActionButton('音量 +', MOBILE_ACTION_VOLUME_UP)
          this.buildMobileActionButton('电源菜单', MOBILE_ACTION_POWER, true)
        }
        .width('100%')

        Text('若按钮无响应，请在安卓被控端开启 RustDesk 的“输入控制/无障碍服务”。')
          .fontSize(12)
          .lineHeight(19)
          .fontColor(this.secondaryTextColor())
          .width('100%')
      }
      .width(this.isLargeLayout() ? 460 : '92%')
      .padding(20)
      .backgroundColor(this.panelColor())
      .border({ width: 1, color: this.themeBorderColor() })
      .borderRadius(12)
      .shadow({ radius: 28, color: '#66000000', offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .onHover((isHovering: boolean) => {
      this.handleNonRemoteHover(isHovering);
    })
  }

  @Builder
  buildInputModeChoice(mode: string, label: string) {
    Button() {
      Row({ space: 6 }) {
        this.buildInputModeIcon(mode, 20, this.inputMode === mode)
        Text(label)
          .fontSize(13)
          .fontWeight(this.inputMode === mode ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
          .fontColor(this.inputMode === mode ? Color.White : this.primaryTextColor())
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(42)
    .backgroundColor(this.inputMode === mode ? RustDeskTheme.ACCENT : this.mutedSurfaceColor())
    .border({ width: 1, color: this.inputMode === mode ? RustDeskTheme.ACCENT : this.themeBorderColor() })
    .borderRadius(8)
    .onClick(() => {
      this.setInputMode(mode);
    })
  }

  @Builder
  buildKeyboardCapture() {
    TextInput({ text: this.keyboardInput })
      .id('remoteKeyboardCapture')
      .width(2)
      .height(2)
      .padding(0)
      .fontSize(1)
      .fontColor(Color.Transparent)
      .caretColor(Color.Transparent)
      .backgroundColor(Color.Transparent)
      .border({ width: 0 })
      .opacity(0.01)
      .focusable(true)
      .defaultFocus(true)
      .enablePreviewText(true)
      .onChange((value: string, previewText?: PreviewText) => {
        this.handleDirectKeyboardChange(value, previewText);
      })
      .onSubmit(() => {
        this.sendControlKey(13);
        this.keyboardInput = '';
        this.directKeyboardCommittedText = '';
      })
      .position({ x: 0, y: 0 })
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
            .fontColor(this.primaryTextColor())
        }
        Text(this.routeText)
          .fontSize(11)
          .fontColor(this.secondaryTextColor())
        Text(this.codecText)
          .fontSize(11)
          .fontColor(this.secondaryTextColor())
        Text(this.speedText)
          .fontSize(11)
          .fontColor(this.secondaryTextColor())
        Text(this.fpsText)
          .fontSize(11)
          .fontColor(this.secondaryTextColor())
      }
      .height(44)
      .padding({ left: 14, right: 14 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(44)
    .backgroundColor(this.panelColor())
    .border({ width: { bottom: 1 }, color: this.themeBorderColor() })
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .onHover((isHovering: boolean) => {
      this.handleNonRemoteHover(isHovering);
    });
  }

  @Builder
  buildCursorOverlay() {
    Stack() {
      if (this.cursorPixelMap !== undefined) {
        Image(this.cursorPixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Fill)
          .interpolation(ImageInterpolation.None)
      } else {
        Path()
          .commands('M 1 1 L 1 21 L 6.5 15.5 L 10.5 24 L 14 22.2 L 10 14.5 L 18 14.5 Z')
          .fill(Color.White)
          .stroke('#E6000000')
          .strokeWidth(1.4)
      }
    }
    .width(this.cursorImageWidth)
    .height(this.cursorImageHeight)
    .hitTestBehavior(HitTestMode.None)
    .position({ x: this.cursorX, y: this.cursorY });
  }

  enterFullScreen(): void {
    if (this.isFullScreen) {
      return;
    }
    this.showKeyboardPanel = false;
    this.showGestureHelp = false;
    this.isFullScreen = true;
    this.applyFullscreenWindow(true);
    this.scheduleSurfaceRebindIfSizeChanged();
  }

  exitFullScreen(): void {
    if (!this.isFullScreen) {
      return;
    }
    this.closeRemoteKeyboard();
    this.isFullScreen = false;
    this.applyFullscreenWindow(false);
    this.scheduleSurfaceRebindIfSizeChanged();
  }

  applyFullscreenWindow(enabled: boolean): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((mainWindow: window.Window) => {
        let bars: Array<'status' | 'navigation'> = enabled ? [] : ['status', 'navigation'];
        mainWindow.setWindowLayoutFullScreen(enabled).catch((_e: BusinessError) => {
        });
        mainWindow.setWindowSystemBarEnable(bars).catch((_e: BusinessError) => {
        });
      }).catch((_e: BusinessError) => {
      });
    } catch (_e) {
    }
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

  inputModeOptionKey(): string {
    let peerKey: string = this.connectedPeerId.replace(/[^0-9A-Za-z_-]/g, '');
    return peerKey.length > 0 ? `mobile-input-mode-${peerKey}` : 'mobile-input-mode-default';
  }

  loadInputMode(): void {
    let savedMode: string = RustDeskNapi.getOption(this.inputModeOptionKey());
    this.inputMode = savedMode === INPUT_MODE_TOUCH ? INPUT_MODE_TOUCH : INPUT_MODE_MOUSE;
  }

  loadLocalCursorPreference(): void {
    this.showLocalCursor = RustDeskNapi.getOption('show-local-cursor') !== '0';
  }

  loadEdgeAutoPanPreference(): void {
    this.edgeAutoPanEnabled = RustDeskNapi.getOption('edge-auto-pan-enabled') === '1';
  }

  setEdgeAutoPanEnabled(enabled: boolean): void {
    this.edgeAutoPanEnabled = enabled;
    RustDeskNapi.setOption('edge-auto-pan-enabled', enabled ? '1' : '0');
    if (!enabled) {
      this.stopEdgeAutoPan();
    }
    RustDeskNapi.appendDiagnosticLog('input', `edge_auto_pan enabled=${enabled}`);
  }

  setLocalCursorPreference(show: boolean): void {
    this.showLocalCursor = show;
    RustDeskNapi.setOption('show-local-cursor', show ? '1' : '0');
    RustDeskNapi.appendDiagnosticLog('input', `show_local_cursor enabled=${show}`);
    if (this.inputMode === INPUT_MODE_MOUSE) {
      this.ensurePointerInitialized();
    }
    this.updateSystemPointerVisibility();
  }

  updateSystemPointerVisibility(): void {
    const shouldHide: boolean = this.connectionStatus === ConnectionStatus.CONNECTED &&
      this.inputMode === INPUT_MODE_MOUSE && !this.showLocalCursor && this.pointerOverRemoteViewport;
    this.setSystemPointerHidden(shouldHide);
  }

  setSystemPointerHidden(hidden: boolean): void {
    if (this.systemPointerHidden === hidden) {
      return;
    }
    try {
      pointer.setPointerVisibleSync(!hidden);
      this.systemPointerHidden = hidden;
      let actualVisible: boolean = pointer.isPointerVisibleSync();
      RustDeskNapi.appendDiagnosticLog('input',
        `system_pointer requested_hidden=${hidden} actual_visible=${actualVisible}`);
    } catch (error) {
      const message: string = (error as BusinessError).message ?? '';
      hilog.warn(LOG_DOMAIN, 'StarRustDesk', `Set pointer visibility failed: ${message}`);
    }
  }

  handleRemoteHover(isHovering: boolean): void {
    if (isHovering) {
      this.cancelPointerHoverExit();
      this.pointerOverRemoteViewport = true;
      this.updateSystemPointerVisibility();
      return;
    }
    if (this.systemPointerHidden) {
      // On HarmonyOS PC, hiding the system pointer emits a synthetic hover
      // exit. Keep it hidden until the preference/mode/session changes.
      return;
    }
    // Hiding the HarmonyOS system cursor can itself emit a transient hover-exit
    // on PC. Confirm the exit after a short delay so that synthetic exit/enter
    // pairs do not immediately make the local cursor visible again.
    this.cancelPointerHoverExit();
    this.pointerHoverExitTimer = setTimeout(() => {
      this.pointerHoverExitTimer = -1;
      this.pointerOverRemoteViewport = false;
      this.stopEdgeAutoPan();
      this.releaseHeldMouseButtons('hover_exit');
      this.updateSystemPointerVisibility();
    }, 140);
  }

  handleNonRemoteHover(isHovering: boolean): void {
    if (!isHovering) {
      return;
    }
    this.cancelPointerHoverExit();
    this.pointerOverRemoteViewport = false;
    this.stopEdgeAutoPan();
    this.releaseHeldMouseButtons('non_remote_hover');
    this.updateSystemPointerVisibility();
  }

  cancelPointerHoverExit(): void {
    if (this.pointerHoverExitTimer !== -1) {
      clearTimeout(this.pointerHoverExitTimer);
      this.pointerHoverExitTimer = -1;
    }
  }

  toggleInputMode(): void {
    this.setInputMode(this.inputMode === INPUT_MODE_MOUSE ? INPUT_MODE_TOUCH : INPUT_MODE_MOUSE);
  }

  setInputMode(mode: string): void {
    if (mode !== INPUT_MODE_MOUSE && mode !== INPUT_MODE_TOUCH) {
      return;
    }
    this.cancelActiveTouchGesture();
    this.stopEdgeAutoPan();
    this.inputMode = mode;
    RustDeskNapi.setOption(this.inputModeOptionKey(), mode);
    if (mode === INPUT_MODE_MOUSE) {
      this.ensurePointerInitialized();
    } else {
      this.showCursor = false;
    }
    this.updateSystemPointerVisibility();
  }

  dismissGestureHelp(): void {
    this.showGestureHelp = false;
    RustDeskNapi.setOption('mobile-gesture-help-shown', '1');
  }

  cancelActiveTouchGesture(): void {
    this.stopEdgeAutoPan();
    this.edgePanTouchActive = false;
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.releaseHeldMouseButtons('gesture_cancelled');
    this.multiTouchActive = false;
    this.multiTouchGesture = 0;
    this.multiTouchStartedAt = 0;
    this.multiTouchMoved = false;
    this.threeFingerGestureActive = false;
    this.threeFingerStartedAt = 0;
    this.threeFingerStartCenterX = 0;
    this.threeFingerStartCenterY = 0;
    this.threeFingerLastCenterX = 0;
    this.threeFingerLastCenterY = 0;
    this.isPinching = false;
    this.pinchStartDistance = 0;
    this.touchMoved = false;
    this.longPressTriggered = false;
    this.touchpadDragCandidate = false;
    this.ignoreTouchUntilNextDown = false;
    this.viewportPanActive = false;
    this.viewportPanLastX = 0;
    this.viewportPanLastY = 0;
    this.endLocalPointerGesture();
  }

  handleRemoteTouch(event: TouchEvent): void {
    this.lastTouchEventAt = Date.now();
    const pointerCompatibilityEvent: boolean = event.source === SourceType.Mouse ||
      event.sourceTool === SourceTool.MOUSE || event.sourceTool === SourceTool.TOUCHPAD;
    if (pointerCompatibilityEvent) {
      this.handlePointerCompatibilityTouch(event);
      return;
    }

    if (this.threeFingerGestureActive) {
      this.stopEdgeAutoPan();
      if (event.touches.length < 3) {
        this.finishThreeFingerGesture();
      } else {
        this.handleThreeFingerGesture(event);
      }
      return;
    }

    if (this.isFullScreen && event.touches.length >= 3) {
      this.stopEdgeAutoPan();
      this.handleThreeFingerGesture(event);
      return;
    }

    if (this.multiTouchActive && event.touches.length < 2) {
      this.finishMultiTouchGesture();
      return;
    }

    if (event.touches.length <= 0) {
      if (this.isPanMode) {
        this.finishViewportPan();
      } else {
        this.finishSingleTouch(event.type === TouchType.Cancel);
      }
      this.ignoreTouchUntilNextDown = false;
      return;
    }

    if (event.touches.length >= 2) {
      this.stopEdgeAutoPan();
      this.handleMultiTouch(event);
      return;
    }

    if (this.ignoreTouchUntilNextDown) {
      if (event.type === TouchType.Down) {
        this.ignoreTouchUntilNextDown = false;
      } else {
        return;
      }
    }

    if (Date.now() - this.lastPinchEndedAt < 90) {
      return;
    }

    if (this.isPanMode) {
      this.handleViewportPan(event);
      return;
    }

    if (this.inputMode === INPUT_MODE_MOUSE) {
      this.handleTouchpadTouch(event);
    } else {
      this.handleDirectTouch(event);
    }
  }

  handlePointerCompatibilityTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down || event.type === TouchType.Up || event.type === TouchType.Cancel) {
      RustDeskNapi.appendDiagnosticLog('input',
        `pointer_touch type=${event.type} source=${event.source} tool=${event.sourceTool}`);
    }
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel ||
      this.remoteWidth <= 0 || this.remoteHeight <= 0) {
      return;
    }
    let touchCount: number = event.touches.length;
    let changedCount: number = event.changedTouches.length;
    if (touchCount <= 0 && changedCount <= 0) {
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.sendLeftUp(this.lastAbsX, this.lastAbsY, true);
      }
      return;
    }
    let x: number = touchCount > 0 ? event.touches[0].x : event.changedTouches[0].x;
    let y: number = touchCount > 0 ? event.touches[0].y : event.changedTouches[0].y;
    let localX: number = x - this.getDisplayLeft();
    let localY: number = y - this.getDisplayTop();
    let remotePoint: RemotePoint = this.updatePointerFromLocal(localX, localY);
    this.lastMouseEventAt = Date.now();
    this.handleRemoteHover(true);
    this.requestRemoteInputFocus();
    if (event.type === TouchType.Down) {
      this.sendLeftDown(remotePoint.x, remotePoint.y);
      RustDeskNapi.appendDiagnosticLog('input', 'pointer_touch_forwarded action=1');
    } else if (event.type === TouchType.Move) {
      if (this.lastMouseEventAt - this.lastMoveSentAt > 8) {
        this.lastMoveSentAt = this.lastMouseEventAt;
        ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 0);
      }
    } else if (event.type === TouchType.Up) {
      this.sendLeftUp(remotePoint.x, remotePoint.y, true);
      this.lastMappedPhysicalLeftUpAt = this.lastMouseEventAt;
      RustDeskNapi.appendDiagnosticLog('input', 'pointer_touch_forwarded action=2');
    } else if (event.type === TouchType.Cancel) {
      this.releaseHeldMouseButtons('pointer_touch_cancel');
    }
    event.stopPropagation();
  }

  handleTouchpadTouch(event: TouchEvent): void {
    let touch = event.touches[0];

    if (event.type === TouchType.Down) {
      this.edgePanTouchActive = true;
      this.beginLocalPointerGesture();
      this.requestRemoteInputFocus();
      this.ensurePointerInitialized();
      this.touchStartX = touch.x;
      this.touchStartY = touch.y;
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      this.touchMoved = false;
      this.longPressTriggered = false;
      const secondTap: boolean = this.isSecondTapNear(touch.x, touch.y);
      this.touchpadDragCandidate = secondTap;
      RustDeskNapi.appendDiagnosticLog('input',
        `touchpad_down second_tap=${secondTap ? 1 : 0} pending=${this.tapTimer !== -1 ? 1 : 0}`);
      if (secondTap) {
        this.clearTapTimer();
        this.sendLeftDown(this.lastAbsX, this.lastAbsY);
      } else {
        this.flushPendingTap();
        this.startRightClickTimer(this.lastAbsX, this.lastAbsY);
      }
      this.showToolbar = true;
      this.resetToolbarTimer();
    } else if (event.type === TouchType.Move) {
      let movedX: number = touch.x - this.touchStartX;
      let movedY: number = touch.y - this.touchStartY;
      if (Math.sqrt(movedX * movedX + movedY * movedY) >= TOUCH_MOVE_THRESHOLD) {
        this.touchMoved = true;
        this.clearLongPressTimer();
        if (this.touchpadDragCandidate && !this.leftButtonHeld) {
          this.sendLeftDown(this.lastAbsX, this.lastAbsY);
          RustDeskNapi.appendDiagnosticLog('input', 'touchpad_drag left_down_recovered_on_move');
        }
      }
      let deltaX: number = touch.x - this.lastTouchX;
      let deltaY: number = touch.y - this.lastTouchY;
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      let remotePoint: RemotePoint = this.updatePointerFromDelta(deltaX, deltaY);
      this.updateEdgeAutoPan(remotePoint.x, remotePoint.y, true);
      let now: number = Date.now();
      if (now - this.lastMoveSentAt > 16) {
        this.lastMoveSentAt = now;
        ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 0);
      }
    } else if (event.type === TouchType.Up) {
      this.finishTouchpadTouch(touch.x, touch.y, false);
    } else if (event.type === TouchType.Cancel) {
      this.finishTouchpadTouch(touch.x, touch.y, true);
    }
  }

  handleDirectTouch(event: TouchEvent): void {
    let touch = event.touches[0];
    let remotePoint: RemotePoint = this.updatePointerFromLocal(touch.x, touch.y);

    if (event.type === TouchType.Down) {
      this.beginLocalPointerGesture();
      this.requestRemoteInputFocus();
      this.touchStartX = touch.x;
      this.touchStartY = touch.y;
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      this.pendingTapRemoteX = remotePoint.x;
      this.pendingTapRemoteY = remotePoint.y;
      this.touchMoved = false;
      this.longPressTriggered = false;
      this.startRightClickTimer(remotePoint.x, remotePoint.y);
      this.showToolbar = true;
      this.resetToolbarTimer();
    } else if (event.type === TouchType.Move) {
      let movedX: number = touch.x - this.touchStartX;
      let movedY: number = touch.y - this.touchStartY;
      if (Math.sqrt(movedX * movedX + movedY * movedY) >= TOUCH_MOVE_THRESHOLD) {
        this.touchMoved = true;
        this.clearLongPressTimer();
        if (!this.leftButtonHeld && !this.longPressTriggered) {
          this.sendLeftDown(this.pendingTapRemoteX, this.pendingTapRemoteY);
        }
      }
      let now: number = Date.now();
      if (now - this.lastMoveSentAt > 16) {
        this.lastMoveSentAt = now;
        ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 0);
      }
    } else if (event.type === TouchType.Up) {
      this.finishDirectTouch(remotePoint.x, remotePoint.y, false);
    } else if (event.type === TouchType.Cancel) {
      this.finishDirectTouch(remotePoint.x, remotePoint.y, true);
    }
  }

  finishSingleTouch(cancelled: boolean): void {
    if (this.inputMode === INPUT_MODE_MOUSE) {
      this.finishTouchpadTouch(this.lastTouchX, this.lastTouchY, cancelled);
    } else {
      this.finishDirectTouch(this.lastAbsX, this.lastAbsY, cancelled);
    }
  }

  finishTouchpadTouch(localX: number, localY: number, cancelled: boolean): void {
    const wasDragCandidate: boolean = this.touchpadDragCandidate;
    this.edgePanTouchActive = false;
    this.stopEdgeAutoPan();
    this.clearLongPressTimer();
    if (this.leftButtonHeld) {
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
      if (wasDragCandidate && !cancelled && !this.touchMoved) {
        // The first tap is intentionally held back while deciding whether this
        // is a drag. Complete a normal double-click only when the second tap
        // is released without movement; a drag must remain a clean
        // left-down -> move -> left-up sequence for desktop marquee selection.
        this.sendLeftClick(this.lastAbsX, this.lastAbsY);
      }
    } else if (!cancelled && !this.longPressTriggered && !this.touchMoved) {
      this.queueTouchpadTap(this.lastAbsX, this.lastAbsY, localX, localY);
    }
    if (wasDragCandidate) {
      RustDeskNapi.appendDiagnosticLog('input',
        `touchpad_drag finished cancelled=${cancelled ? 1 : 0} moved=${this.touchMoved ? 1 : 0}`);
    }
    this.touchpadDragCandidate = false;
    this.longPressTriggered = false;
    this.touchMoved = false;
    this.endLocalPointerGesture();
  }

  finishDirectTouch(remoteX: number, remoteY: number, cancelled: boolean): void {
    this.clearLongPressTimer();
    if (this.leftButtonHeld) {
      ConnectionService.sendMouseEvent(remoteX, remoteY, 0);
      this.sendLeftUp(remoteX, remoteY);
    } else if (!cancelled && !this.longPressTriggered && !this.touchMoved) {
      this.sendLeftClick(remoteX, remoteY);
    }
    this.longPressTriggered = false;
    this.touchMoved = false;
    this.endLocalPointerGesture();
  }

  isSecondTapNear(localX: number, localY: number): boolean {
    if (this.tapTimer === -1) {
      return false;
    }
    let dx: number = localX - this.pendingTapLocalX;
    let dy: number = localY - this.pendingTapLocalY;
    return Math.sqrt(dx * dx + dy * dy) <= TOUCHPAD_DOUBLE_TAP_DISTANCE;
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

  queueTouchpadTap(remoteX: number, remoteY: number, localX: number, localY: number): void {
    this.clearTapTimer();
    this.pendingTapRemoteX = remoteX;
    this.pendingTapRemoteY = remoteY;
    this.pendingTapLocalX = localX;
    this.pendingTapLocalY = localY;
    this.tapTimer = setTimeout(() => {
      this.sendLeftClick(this.pendingTapRemoteX, this.pendingTapRemoteY);
      this.tapTimer = -1;
    }, TOUCHPAD_DOUBLE_TAP_TIMEOUT_MS);
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
    if (this.leftButtonHeld) {
      ConnectionService.sendMouseEvent(remoteX, remoteY, 2);
      this.leftButtonHeld = false;
      this.leftButtonHeldAt = 0;
      this.showLeftButtonHoldIndicator = false;
    }
    ConnectionService.sendMouseEvent(remoteX, remoteY, 1);
    ConnectionService.sendMouseEvent(remoteX, remoteY, 2);
  }

  sendLeftDown(remoteX: number, remoteY: number): void {
    if (this.leftButtonHeld) {
      return;
    }
    ConnectionService.sendMouseEvent(remoteX, remoteY, 1);
    this.leftButtonHeld = true;
    this.leftButtonHeldAt = Date.now();
    this.preferAuthoritativeCursor = false;
    this.showLeftButtonHoldIndicator = this.inputMode === INPUT_MODE_MOUSE;
  }

  sendLeftUp(remoteX: number, remoteY: number, force: boolean = false): void {
    if (!this.leftButtonHeld && !force) {
      return;
    }
    ConnectionService.sendMouseEvent(remoteX, remoteY, 2);
    this.leftButtonHeld = false;
    this.leftButtonHeldAt = 0;
    this.showLeftButtonHoldIndicator = false;
  }

  sendRightDown(remoteX: number, remoteY: number): void {
    if (this.rightButtonHeld) {
      return;
    }
    ConnectionService.sendMouseEvent(remoteX, remoteY, 3);
    this.rightButtonHeld = true;
  }

  sendRightUp(remoteX: number, remoteY: number, force: boolean = false): void {
    if (!this.rightButtonHeld && !force) {
      return;
    }
    ConnectionService.sendMouseEvent(remoteX, remoteY, 4);
    this.rightButtonHeld = false;
  }

  releaseHeldMouseButtons(reason: string): void {
    let released: boolean = false;
    if (this.leftButtonHeld) {
      ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 2);
      this.leftButtonHeld = false;
      this.leftButtonHeldAt = 0;
      released = true;
    }
    this.showLeftButtonHoldIndicator = false;
    if (this.rightButtonHeld) {
      ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 4);
      this.rightButtonHeld = false;
      released = true;
    }
    if (released) {
      RustDeskNapi.appendDiagnosticLog('input', `mouse_buttons_released reason=${reason}`);
    }
  }

  reconcilePhysicalMouseButtons(event: MouseEvent, remoteX: number, remoteY: number): void {
    if (event.action !== MouseAction.Move || event.pressedButtons === undefined) {
      return;
    }
    let leftPressed: boolean = event.pressedButtons.indexOf(MouseButton.Left) >= 0;
    let rightPressed: boolean = event.pressedButtons.indexOf(MouseButton.Right) >= 0;
    if (!this.leftButtonHeld && leftPressed) {
      this.sendLeftDown(remoteX, remoteY);
      RustDeskNapi.appendDiagnosticLog('input', 'mouse_left_down recovered_from_move');
    } else if (this.leftButtonHeld && !leftPressed) {
      this.sendLeftUp(remoteX, remoteY, true);
      RustDeskNapi.appendDiagnosticLog('input', 'mouse_left_up recovered_from_move');
    }
    if (!this.rightButtonHeld && rightPressed) {
      this.sendRightDown(remoteX, remoteY);
      RustDeskNapi.appendDiagnosticLog('input', 'mouse_right_down recovered_from_move');
    } else if (this.rightButtonHeld && !rightPressed) {
      this.sendRightUp(remoteX, remoteY, true);
      RustDeskNapi.appendDiagnosticLog('input', 'mouse_right_up recovered_from_move');
    }
  }

  handleRemoteClickFallback(event: ClickEvent, coordinatesFromSurface: boolean = false): void {
    let now: number = Date.now();
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel || this.isPanMode ||
      now - this.lastTouchEventAt < 320 || now - this.lastMappedPhysicalLeftUpAt < 160 ||
      this.remoteWidth <= 0 || this.remoteHeight <= 0) {
      return;
    }
    this.syncModifiersFromPointerEvent(event);
    let localX: number = this.inputMode === INPUT_MODE_MOUSE && !coordinatesFromSurface ?
      event.x - this.getDisplayLeft() : event.x;
    let localY: number = this.inputMode === INPUT_MODE_MOUSE && !coordinatesFromSurface ?
      event.y - this.getDisplayTop() : event.y;
    let remotePoint: RemotePoint = this.updatePointerFromLocal(localX, localY);
    this.sendLeftClick(remotePoint.x, remotePoint.y);
    RustDeskNapi.appendDiagnosticLog('input',
      `physical_mouse_click_fallback origin=${coordinatesFromSurface ? 'surface' : 'overlay'} ` +
      `source=${event.source} tool=${event.sourceTool}`);
  }

  handleRemoteMouse(event: MouseEvent, coordinatesFromSurface: boolean = false): void {
    if (event.action !== MouseAction.Move && event.action !== MouseAction.Hover) {
      RustDeskNapi.appendDiagnosticLog('input',
        `raw_mouse origin=${coordinatesFromSurface ? 'surface' : 'overlay'} action=${event.action} ` +
        `button=${event.button} source=${event.source} tool=${event.sourceTool}`);
    }
    // ArkUI can emit compatibility mouse events for finger/stylus input. Those
    // events must stay on the touch path, otherwise absolute mouse coordinates
    // fight with the relative touchpad coordinates and the cursor jumps.
    if (event.source === SourceType.TouchScreen ||
      (event.source !== SourceType.Mouse &&
        (event.sourceTool === SourceTool.Finger || event.sourceTool === SourceTool.Pen))) {
      return;
    }
    // Read the modifier state from the mouse event itself. This remains valid
    // even if ArkUI routes Ctrl/Shift key events to another focused component.
    this.syncModifiersFromPointerEvent(event);
    // The Native XComponent callback is authoritative on HarmonyOS PC. Avoid
    // forwarding the compatibility ArkUI event a second time when both paths
    // report the same physical mouse input.
    if (Date.now() - this.lastNativeMouseEventAt < 80) {
      return;
    }
    this.lastMouseEventAt = Date.now();
    this.pointerOverRemoteViewport = true;
    this.updateSystemPointerVisibility();
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();

    let action: number = this.mapMouseAction(event);
    let localX: number = this.inputMode === INPUT_MODE_MOUSE && !coordinatesFromSurface ?
      event.x - this.getDisplayLeft() : event.x;
    let localY: number = this.inputMode === INPUT_MODE_MOUSE && !coordinatesFromSurface ?
      event.y - this.getDisplayTop() : event.y;
    let remotePoint: RemotePoint = this.updatePointerFromLocal(localX, localY);
    this.edgePanTouchActive = false;
    if (event.action === MouseAction.Move || event.action === MouseAction.Hover) {
      this.updateEdgeAutoPan(remotePoint.x, remotePoint.y, false);
    } else {
      this.stopEdgeAutoPan();
    }
    this.reconcilePhysicalMouseButtons(event, remotePoint.x, remotePoint.y);
    if (action < 0) {
      return;
    }

    let now: number = Date.now();
    if (action === 0 && now - this.lastMoveSentAt <= 8) {
      return;
    }
    if (action === 0) {
      this.lastMoveSentAt = now;
    }
    if (action === 1) {
      this.sendLeftDown(remotePoint.x, remotePoint.y);
    } else if (action === 2) {
      this.sendLeftUp(remotePoint.x, remotePoint.y, true);
      this.lastMappedPhysicalLeftUpAt = now;
    } else if (action === 3) {
      this.sendRightDown(remotePoint.x, remotePoint.y);
    } else if (action === 4) {
      this.sendRightUp(remotePoint.x, remotePoint.y, true);
    } else {
      ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, action);
    }
    if (action > 0) {
      RustDeskNapi.appendDiagnosticLog('input',
        `physical_mouse action=${action} button=${event.button} source=${event.source}`);
    }
    event.stopPropagation();
  }

  handleRemoteAxis(event: AxisEvent): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel) {
      return;
    }
    if (event.action !== AxisAction.UPDATE && event.action !== AxisAction.BEGIN) {
      return;
    }
    this.syncModifiersFromPointerEvent(event);

    let deltaX: number = this.scaleRemoteWheelDeltaX(event.getHorizontalAxisValue());
    let deltaY: number = this.scaleRemoteWheelDeltaY(event.getVerticalAxisValue());
    if (Math.abs(deltaX) < 0.01 && Math.abs(deltaY) < 0.01) {
      return;
    }

    this.stopEdgeAutoPan();
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
    if (event.action === MouseAction.Release && event.button === MouseButton.None) {
      if (this.leftButtonHeld) {
        RustDeskNapi.appendDiagnosticLog('input', 'mouse_left_up recovered_from_none_button');
        return 2;
      }
      if (this.rightButtonHeld) {
        RustDeskNapi.appendDiagnosticLog('input', 'mouse_right_up recovered_from_none_button');
        return 4;
      }
    }
    if (event.action === MouseAction.Press && event.button === MouseButton.None &&
      event.pressedButtons !== undefined) {
      if (event.pressedButtons.indexOf(MouseButton.Left) >= 0) {
        RustDeskNapi.appendDiagnosticLog('input', 'mouse_left_down recovered_from_none_button');
        return 1;
      }
      if (event.pressedButtons.indexOf(MouseButton.Right) >= 0) {
        RustDeskNapi.appendDiagnosticLog('input', 'mouse_right_down recovered_from_none_button');
        return 3;
      }
    }
    return -1;
  }

  updatePointerFromLocal(localX: number, localY: number): RemotePoint {
    this.markLocalPointerInput();
    let displayWidth: number = this.getDisplayWidth();
    let displayHeight: number = this.getDisplayHeight();
    let clampedX: number = Math.max(0, Math.min(displayWidth, localX));
    let clampedY: number = Math.max(0, Math.min(displayHeight, localY));
    let remoteX: number = Math.max(0, Math.min(this.remoteWidth - 1, clampedX * this.remoteWidth / displayWidth));
    let remoteY: number = Math.max(0, Math.min(this.remoteHeight - 1, clampedY * this.remoteHeight / displayHeight));
    this.lastAbsX = remoteX;
    this.lastAbsY = remoteY;
    this.pointerInitialized = true;
    this.remoteCursorAbsX = remoteX;
    this.remoteCursorAbsY = remoteY;
    // The peer deliberately does not echo our own cursor motion immediately.
    // Local prediction is therefore required even after an authoritative
    // remote position has already been received.
    this.updateCursorOverlayFromPosition(remoteX, remoteY);
    return { x: remoteX, y: remoteY };
  }

  ensurePointerInitialized(): void {
    if (!this.pointerInitialized) {
      this.lastAbsX = Math.max(0, (this.remoteWidth - 1) / 2);
      this.lastAbsY = Math.max(0, (this.remoteHeight - 1) / 2);
      this.pointerInitialized = true;
    }
    if (this.hasAuthoritativeRemoteCursor) {
      this.updateCursorOverlayFromPosition(this.remoteCursorAbsX, this.remoteCursorAbsY);
    } else {
      this.updateCursorOverlayFromRemote();
    }
  }

  updatePointerFromDelta(deltaX: number, deltaY: number): RemotePoint {
    this.markLocalPointerInput();
    this.ensurePointerInitialized();
    let displayWidth: number = Math.max(1, this.getDisplayWidth());
    let displayHeight: number = Math.max(1, this.getDisplayHeight());
    let remoteDeltaX: number = deltaX * this.remoteWidth / displayWidth * TOUCHPAD_POINTER_SPEED;
    let remoteDeltaY: number = deltaY * this.remoteHeight / displayHeight * TOUCHPAD_POINTER_SPEED;
    this.lastAbsX = Math.max(0, Math.min(this.remoteWidth - 1, this.lastAbsX + remoteDeltaX));
    this.lastAbsY = Math.max(0, Math.min(this.remoteHeight - 1, this.lastAbsY + remoteDeltaY));
    if (!this.preferAuthoritativeCursor) {
      this.remoteCursorAbsX = this.lastAbsX;
      this.remoteCursorAbsY = this.lastAbsY;
      this.updateCursorOverlayFromRemote();
    }
    return { x: this.lastAbsX, y: this.lastAbsY };
  }

  updateCursorOverlayFromRemote(): void {
    this.updateCursorOverlayFromPosition(this.lastAbsX, this.lastAbsY);
  }

  updateCursorOverlayFromPosition(remoteX: number, remoteY: number): void {
    let displayWidth: number = Math.max(1, this.getDisplayWidth());
    let displayHeight: number = Math.max(1, this.getDisplayHeight());
    let scaleX: number = displayWidth / Math.max(1, this.remoteWidth);
    let scaleY: number = displayHeight / Math.max(1, this.remoteHeight);
    let imageWidth: number = this.remoteCursorImageWidth > 0 ? this.remoteCursorImageWidth * scaleX : 20;
    let imageHeight: number = this.remoteCursorImageHeight > 0 ? this.remoteCursorImageHeight * scaleY : 25;
    let hotX: number = this.remoteCursorImageWidth > 0 ? this.remoteCursorHotX * scaleX : 0;
    let hotY: number = this.remoteCursorImageHeight > 0 ? this.remoteCursorHotY * scaleY : 0;
    this.cursorImageWidth = Math.max(1, imageWidth);
    this.cursorImageHeight = Math.max(1, imageHeight);
    this.cursorX = this.getDisplayLeft() + remoteX * scaleX - hotX;
    this.cursorY = this.getDisplayTop() + remoteY * scaleY - hotY;
    this.showCursor = true;
  }

  beginLocalPointerGesture(): void {
    this.localPointerGestureActive = true;
    this.preferAuthoritativeCursor = false;
    this.markLocalPointerInput();
  }

  endLocalPointerGesture(): void {
    if (this.localPointerGestureActive) {
      this.localPointerGestureActive = false;
      if (!this.preferAuthoritativeCursor) {
        this.markLocalPointerInput();
      }
    }
  }

  markLocalPointerInput(): void {
    this.lastLocalPointerInputAt = Date.now();
    if (this.remoteCursorEmbedded && !this.embeddedCursorOverlayFallback) {
      this.embeddedCursorOverlayFallback = true;
      RustDeskNapi.appendDiagnosticLog('input',
        `embedded_cursor_overlay_fallback display=${this.currentDisplay}`);
    }
  }

  handleRemoteKey(event: KeyEvent): boolean {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return false;
    }

    let controlCode: number = this.mapControlKeyCode(event.keyCode);
    let action: number = event.type === KeyType.Down ? 0 : 1;
    if (controlCode === 20) {
      ConnectionService.sendCapsLockEvent(action, event.isCapsLockOn);
      return true;
    }
    if (!this.isModifierControlCode(controlCode)) {
      this.syncModifiersFromKeyEvent(event);
      if (event.isCapsLockOn !== undefined) {
        ConnectionService.syncCapsLockState(event.isCapsLockOn);
      }
    }
    if (this.showKeyboardPanel) {
      if (this.isModifierControlCode(controlCode)) {
        ConnectionService.sendKeyEvent(controlCode, action);
        return true;
      }
      return false;
    }
    if (controlCode > 0) {
      ConnectionService.sendKeyEvent(controlCode, action);
      return true;
    }

    let text: string = this.getKeyEventText(event);
    let physicalScanCode: number = this.mapHarmonyKeyCodeToWindowsScanCode(event.keyCode);
    if (physicalScanCode > 0) {
      let letter: string = this.mapHarmonyKeyCodeToLetter(event.keyCode);
      if (letter.length > 0) {
        ConnectionService.sendLetterKeyEvent(letter, physicalScanCode, action);
      } else {
        ConnectionService.sendPhysicalKeyEvent(physicalScanCode, action);
      }
      return true;
    }

    if (text.length > 0) {
      let scanCode: number = this.mapAsciiToWindowsScanCode(text);
      if (scanCode > 0) {
        ConnectionService.sendPhysicalKeyEvent(scanCode, action);
      } else if (event.type === KeyType.Down) {
        ConnectionService.sendText(text);
      }
      return true;
    }
    return false;
  }

  syncModifiersFromKeyEvent(event: KeyEvent): void {
    if (event.getModifierKeyState === undefined) {
      return;
    }
    try {
      ConnectionService.syncHeldModifierState(
        event.getModifierKeyState(['Ctrl']),
        event.getModifierKeyState(['Shift']),
        event.getModifierKeyState(['Alt'])
      );
    } catch (_e) {
    }
  }

  syncModifiersFromPointerEvent(event: BaseEvent): void {
    if (event.getModifierKeyState === undefined) {
      return;
    }
    try {
      ConnectionService.syncHeldModifierState(
        event.getModifierKeyState(['Ctrl']),
        event.getModifierKeyState(['Shift']),
        event.getModifierKeyState(['Alt'])
      );
    } catch (_e) {
    }
  }

  requestRemoteInputFocus(): void {
    try {
      this.getUIContext()?.getFocusController().requestFocus('remoteNativeInputCapture');
    } catch (_e) {
      try {
        this.getUIContext()?.getFocusController().requestFocus('remoteInputCapture');
      } catch (_ignored) {
        // Some windows reject focus while relayout or navigation is in progress.
      }
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

  mapHarmonyKeyCodeToWindowsScanCode(keyCode: number): number {
    if (keyCode >= 2017 && keyCode <= 2042) {
      return this.mapAsciiToWindowsScanCode('abcdefghijklmnopqrstuvwxyz'.charAt(keyCode - 2017));
    }
    if (keyCode >= 2000 && keyCode <= 2009) {
      return this.mapAsciiToWindowsScanCode((keyCode - 2000).toString());
    }
    switch (keyCode) {
      case 2043: return 0x33;
      case 2044: return 0x34;
      case 2056: return 0x29;
      case 2057: return 0x0C;
      case 2058: return 0x0D;
      case 2059: return 0x1A;
      case 2060: return 0x1B;
      case 2061: return 0x2B;
      case 2062: return 0x27;
      case 2063: return 0x28;
      case 2064: return 0x35;
      default: return 0;
    }
  }

  mapHarmonyKeyCodeToLetter(keyCode: number): string {
    if (keyCode >= 2017 && keyCode <= 2042) {
      return 'abcdefghijklmnopqrstuvwxyz'.charAt(keyCode - 2017);
    }
    return '';
  }

  mapControlKeyCode(keyCode: number): number {
    switch (keyCode) {
      case 2045:
      case 2046:
        return 18;
      case 2047:
      case 2048:
        return 16;
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
      case 2072:
      case 2073:
        return 17;
      case 2074:
        return 20;
      case 2076:
      case 2077:
        return 91;
      default:
        return 0;
    }
  }

  isModifierControlCode(controlCode: number): boolean {
    return controlCode === 16 || controlCode === 17 || controlCode === 18 || controlCode === 91;
  }

  handleMultiTouch(event: TouchEvent): void {
    let first = event.touches[0];
    let second = event.touches[1];
    let dx: number = first.x - second.x;
    let dy: number = first.y - second.y;
    let distance: number = Math.sqrt(dx * dx + dy * dy);
    let centerX: number = (first.x + second.x) / 2;
    let centerY: number = (first.y + second.y) / 2;
    if (!this.multiTouchActive) {
      this.endLocalPointerGesture();
      this.multiTouchActive = true;
      this.multiTouchGesture = 0;
      this.multiTouchStartedAt = Date.now();
      this.multiTouchStartCenterX = centerX;
      this.multiTouchStartCenterY = centerY;
      this.multiTouchLastCenterX = centerX;
      this.multiTouchLastCenterY = centerY;
      this.multiTouchMoved = false;
      this.clearLongPressTimer();
      this.flushPendingTap();
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
      this.pinchStartDistance = distance;
      this.pinchStartScale = this.zoomScale;
      this.lastPinchCenterX = centerX;
      this.lastPinchCenterY = centerY;
      this.lastPinchUpdateAt = Date.now();
      if (this.inputMode === INPUT_MODE_TOUCH) {
        let remotePoint: RemotePoint = this.updatePointerFromLocal(centerX, centerY);
        this.multiTouchRemoteX = remotePoint.x;
        this.multiTouchRemoteY = remotePoint.y;
      } else {
        this.ensurePointerInitialized();
        this.multiTouchRemoteX = this.lastAbsX;
        this.multiTouchRemoteY = this.lastAbsY;
      }
      return;
    }

    if (event.type === TouchType.Move) {
      let distanceChange: number = Math.abs(distance - this.pinchStartDistance);
      let centerMoveX: number = centerX - this.multiTouchStartCenterX;
      let centerMoveY: number = centerY - this.multiTouchStartCenterY;
      let centerMove: number = Math.sqrt(centerMoveX * centerMoveX + centerMoveY * centerMoveY);
      if (distanceChange >= PINCH_DISTANCE_THRESHOLD || centerMove >= MULTI_TOUCH_MOVE_THRESHOLD) {
        this.multiTouchMoved = true;
      }
      if (this.multiTouchGesture === 0) {
        if (distanceChange >= PINCH_DISTANCE_THRESHOLD) {
          this.multiTouchGesture = 2;
          this.isPinching = true;
        } else if (centerMove >= MULTI_TOUCH_MOVE_THRESHOLD) {
          this.multiTouchGesture = 1;
        }
      }

      let now: number = Date.now();
      if (now - this.lastPinchUpdateAt < 16) {
        return;
      }
      let deltaX: number = centerX - this.lastPinchCenterX;
      let deltaY: number = centerY - this.lastPinchCenterY;
      this.lastPinchUpdateAt = now;
      this.lastPinchCenterX = centerX;
      this.lastPinchCenterY = centerY;
      this.multiTouchLastCenterX = centerX;
      this.multiTouchLastCenterY = centerY;

      if (this.multiTouchGesture === 2 && this.pinchStartDistance > 0) {
        let nextScale: number = Math.max(0.5,
          Math.min(5.0, this.pinchStartScale * distance / this.pinchStartDistance));
        let displayLocalX: number = this.inputMode === INPUT_MODE_MOUSE ? centerX - this.getDisplayLeft() : centerX;
        let displayLocalY: number = this.inputMode === INPUT_MODE_MOUSE ? centerY - this.getDisplayTop() : centerY;
        this.applyPinchTransform(displayLocalX, displayLocalY, nextScale, deltaX, deltaY);
      } else if (this.multiTouchGesture === 1) {
        this.sendTouchScroll(deltaX, deltaY);
      }
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.finishMultiTouchGesture();
    }
  }

  finishMultiTouchGesture(): void {
    if (!this.multiTouchActive) {
      return;
    }
    let isTwoFingerTap: boolean = this.multiTouchGesture === 0 && !this.multiTouchMoved &&
      Date.now() - this.multiTouchStartedAt <= 500;
    if (isTwoFingerTap) {
      ConnectionService.sendMouseEvent(this.multiTouchRemoteX, this.multiTouchRemoteY, 3);
      ConnectionService.sendMouseEvent(this.multiTouchRemoteX, this.multiTouchRemoteY, 4);
    }
    this.multiTouchActive = false;
    this.multiTouchGesture = 0;
    this.multiTouchStartedAt = 0;
    this.multiTouchMoved = false;
    this.isPinching = false;
    this.pinchStartDistance = 0;
    this.lastPinchCenterX = 0;
    this.lastPinchCenterY = 0;
    this.lastPinchUpdateAt = 0;
    this.lastPinchEndedAt = Date.now();
    this.ignoreTouchUntilNextDown = true;
    this.clampViewportOffset();
  }

  sendTouchScroll(deltaX: number, deltaY: number): void {
    this.wheelRemainderX += -deltaX * TOUCH_SCROLL_SCALE;
    this.wheelRemainderY += -deltaY * TOUCH_SCROLL_SCALE;
    let stepX: number = this.takeWholeWheelStep(this.wheelRemainderX);
    let stepY: number = this.takeWholeWheelStep(this.wheelRemainderY);
    this.wheelRemainderX -= stepX;
    this.wheelRemainderY -= stepY;
    if (stepX !== 0 || stepY !== 0) {
      ConnectionService.sendMouseWheel(stepX, stepY);
    }
  }

  updateEdgeAutoPan(remoteX: number, remoteY: number, fromTouch: boolean): void {
    if (!this.edgeAutoPanEnabled || this.inputMode !== INPUT_MODE_MOUSE || !this.canPanViewport() ||
      this.isPanMode || this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel ||
      this.componentWidth <= 0 || this.componentHeight <= 0) {
      this.stopEdgeAutoPan();
      return;
    }

    let visualPoint: RemotePoint = this.remotePointToVisual(remoteX, remoteY);
    let edgeZone: number = Math.max(32, Math.min(56,
      Math.min(this.componentWidth, this.componentHeight) * 0.065));
    let vectorX: number = 0;
    let vectorY: number = 0;
    if (visualPoint.x <= edgeZone) {
      vectorX = -Math.min(1, Math.max(0, (edgeZone - visualPoint.x) / edgeZone));
    } else if (visualPoint.x >= this.componentWidth - edgeZone) {
      vectorX = Math.min(1, Math.max(0,
        (visualPoint.x - (this.componentWidth - edgeZone)) / edgeZone));
    }
    if (visualPoint.y <= edgeZone) {
      vectorY = -Math.min(1, Math.max(0, (edgeZone - visualPoint.y) / edgeZone));
    } else if (visualPoint.y >= this.componentHeight - edgeZone) {
      vectorY = Math.min(1, Math.max(0,
        (visualPoint.y - (this.componentHeight - edgeZone)) / edgeZone));
    }

    // Ignore the outermost soft edge of the trigger band. The pointer must be
    // deliberately close to the border before the dwell timer starts.
    if (Math.abs(vectorX) < 0.18) vectorX = 0;
    if (Math.abs(vectorY) < 0.18) vectorY = 0;
    let panLimitX: number = this.getHorizontalPanLimit(this.zoomScale);
    let panLimitY: number = this.getVerticalPanLimit(this.zoomScale);
    if ((vectorX < 0 && this.offsetX >= panLimitX - 0.5) ||
      (vectorX > 0 && this.offsetX <= -panLimitX + 0.5)) {
      vectorX = 0;
    }
    if ((vectorY < 0 && this.offsetY >= panLimitY - 0.5) ||
      (vectorY > 0 && this.offsetY <= -panLimitY + 0.5)) {
      vectorY = 0;
    }
    if (vectorX === 0 && vectorY === 0) {
      this.stopEdgeAutoPan();
      return;
    }

    let oldSignX: number = Math.sign(this.edgePanVectorX);
    let oldSignY: number = Math.sign(this.edgePanVectorY);
    let newSignX: number = Math.sign(vectorX);
    let newSignY: number = Math.sign(vectorY);
    if (oldSignX !== newSignX || oldSignY !== newSignY || this.edgePanEnteredAt === 0) {
      this.edgePanEnteredAt = Date.now();
      this.edgePanLastTickAt = this.edgePanEnteredAt;
      this.edgePanMoving = false;
    }
    this.edgePanVectorX = vectorX;
    this.edgePanVectorY = vectorY;
    this.edgePanTargetVisualX = Math.max(0, Math.min(this.componentWidth, visualPoint.x));
    this.edgePanTargetVisualY = Math.max(0, Math.min(this.componentHeight, visualPoint.y));
    this.edgePanFromTouch = fromTouch;
    if (fromTouch) {
      this.edgePanTouchActive = true;
    }
    this.scheduleEdgeAutoPan();
  }

  remotePointToVisual(remoteX: number, remoteY: number): RemotePoint {
    let displayWidth: number = Math.max(1, this.getDisplayWidth());
    let displayHeight: number = Math.max(1, this.getDisplayHeight());
    let scaleX: number = displayWidth / Math.max(1, this.remoteWidth);
    let scaleY: number = displayHeight / Math.max(1, this.remoteHeight);
    let baseX: number = this.getDisplayLeft() + remoteX * scaleX;
    let baseY: number = this.getDisplayTop() + remoteY * scaleY;
    let centerX: number = this.componentWidth / 2;
    let centerY: number = this.componentHeight / 2;
    return {
      x: centerX + (baseX - centerX) * this.zoomScale + this.offsetX,
      y: centerY + (baseY - centerY) * this.zoomScale + this.offsetY
    };
  }

  visualPointToRemote(visualX: number, visualY: number): RemotePoint {
    let displayWidth: number = Math.max(1, this.getDisplayWidth());
    let displayHeight: number = Math.max(1, this.getDisplayHeight());
    let centerX: number = this.componentWidth / 2;
    let centerY: number = this.componentHeight / 2;
    let baseX: number = centerX + (visualX - centerX - this.offsetX) / Math.max(0.01, this.zoomScale);
    let baseY: number = centerY + (visualY - centerY - this.offsetY) / Math.max(0.01, this.zoomScale);
    let remoteX: number = (baseX - this.getDisplayLeft()) * this.remoteWidth / displayWidth;
    let remoteY: number = (baseY - this.getDisplayTop()) * this.remoteHeight / displayHeight;
    return {
      x: Math.max(0, Math.min(this.remoteWidth - 1, remoteX)),
      y: Math.max(0, Math.min(this.remoteHeight - 1, remoteY))
    };
  }

  scheduleEdgeAutoPan(): void {
    if (this.edgePanTimer !== -1) {
      return;
    }
    this.edgePanTimer = setTimeout(() => {
      this.edgePanTimer = -1;
      this.runEdgeAutoPanFrame();
    }, EDGE_AUTO_PAN_FRAME_MS);
  }

  runEdgeAutoPanFrame(): void {
    if (!this.edgeAutoPanEnabled || this.inputMode !== INPUT_MODE_MOUSE || !this.canPanViewport() ||
      this.isPanMode || this.connectionStatus !== ConnectionStatus.CONNECTED || this.showKeyboardPanel ||
      (this.edgePanFromTouch && !this.edgePanTouchActive) ||
      (this.edgePanVectorX === 0 && this.edgePanVectorY === 0)) {
      this.stopEdgeAutoPan();
      return;
    }

    let now: number = Date.now();
    let dwellMs: number = this.edgePanFromTouch ? EDGE_AUTO_PAN_TOUCH_DWELL_MS : EDGE_AUTO_PAN_MOUSE_DWELL_MS;
    if (now - this.edgePanEnteredAt < dwellMs) {
      this.scheduleEdgeAutoPan();
      return;
    }
    if (!this.edgePanMoving) {
      this.edgePanMoving = true;
      this.edgePanLastTickAt = now;
      RustDeskNapi.appendDiagnosticLog('input',
        `edge_auto_pan_started x=${this.edgePanVectorX.toFixed(2)} y=${this.edgePanVectorY.toFixed(2)} ` +
        `zoom=${this.zoomScale.toFixed(2)} dwell=${dwellMs}`);
    }

    let elapsedSeconds: number = Math.max(0.008,
      Math.min(0.05, (now - this.edgePanLastTickAt) / 1000));
    this.edgePanLastTickAt = now;
    let speedX: number = this.edgePanSpeed(this.edgePanVectorX);
    let speedY: number = this.edgePanSpeed(this.edgePanVectorY);
    let nextOffsetX: number = this.clampHorizontalOffset(
      this.offsetX - Math.sign(this.edgePanVectorX) * speedX * elapsedSeconds, this.zoomScale);
    let nextOffsetY: number = this.clampVerticalOffset(
      this.offsetY - Math.sign(this.edgePanVectorY) * speedY * elapsedSeconds, this.zoomScale);
    let moved: boolean = Math.abs(nextOffsetX - this.offsetX) > 0.01 ||
      Math.abs(nextOffsetY - this.offsetY) > 0.01;
    this.offsetX = nextOffsetX;
    this.offsetY = nextOffsetY;
    if (!moved) {
      this.stopEdgeAutoPan();
      return;
    }

    // Keep the remote cursor under the stationary local edge pointer while
    // the viewport moves beneath it. This prevents cursor/view divergence.
    let remotePoint: RemotePoint = this.visualPointToRemote(
      this.edgePanTargetVisualX, this.edgePanTargetVisualY);
    this.lastAbsX = remotePoint.x;
    this.lastAbsY = remotePoint.y;
    this.remoteCursorAbsX = remotePoint.x;
    this.remoteCursorAbsY = remotePoint.y;
    this.pointerInitialized = true;
    this.markLocalPointerInput();
    this.updateCursorOverlayFromPosition(remotePoint.x, remotePoint.y);
    if (now - this.lastMoveSentAt >= EDGE_AUTO_PAN_FRAME_MS) {
      this.lastMoveSentAt = now;
      ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 0);
    }
    this.scheduleEdgeAutoPan();
  }

  edgePanSpeed(vector: number): number {
    let strength: number = Math.min(1, Math.abs(vector));
    if (strength <= 0) {
      return 0;
    }
    return EDGE_AUTO_PAN_MIN_SPEED +
      (EDGE_AUTO_PAN_MAX_SPEED - EDGE_AUTO_PAN_MIN_SPEED) * strength * strength;
  }

  stopEdgeAutoPan(): void {
    if (this.edgePanTimer !== -1) {
      clearTimeout(this.edgePanTimer);
      this.edgePanTimer = -1;
    }
    if (this.edgePanMoving) {
      RustDeskNapi.appendDiagnosticLog('input', 'edge_auto_pan_stopped');
    }
    this.edgePanEnteredAt = 0;
    this.edgePanLastTickAt = 0;
    this.edgePanVectorX = 0;
    this.edgePanVectorY = 0;
    this.edgePanTargetVisualX = 0;
    this.edgePanTargetVisualY = 0;
    this.edgePanFromTouch = false;
    this.edgePanMoving = false;
  }

  canPanViewport(): boolean {
    return this.getHorizontalPanLimit(this.zoomScale) > 0.5 ||
      this.getVerticalPanLimit(this.zoomScale) > 0.5;
  }

  setPanMode(enabled: boolean): void {
    this.cancelActiveTouchGesture();
    if (enabled) {
      this.stopEdgeAutoPan();
    }
    this.isPanMode = enabled;
    if (enabled && this.inputMode === INPUT_MODE_MOUSE) {
      this.ensurePointerInitialized();
      if (this.hasAuthoritativeRemoteCursor) {
        this.updateCursorOverlayFromPosition(this.remoteCursorAbsX, this.remoteCursorAbsY);
      } else {
        this.updateCursorOverlayFromRemote();
      }
    }
    this.updateSystemPointerVisibility();
  }

  handleViewportPan(event: TouchEvent): void {
    if (event.touches.length <= 0) {
      this.finishViewportPan();
      return;
    }
    let touch = event.touches[0];
    if (event.type === TouchType.Down) {
      this.clearLongPressTimer();
      this.clearTapTimer();
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
      this.viewportPanActive = true;
      this.viewportPanLastX = touch.x;
      this.viewportPanLastY = touch.y;
      return;
    }
    if (event.type === TouchType.Move && this.viewportPanActive) {
      let deltaX: number = (touch.x - this.viewportPanLastX) * VIEWPORT_PAN_SPEED;
      let deltaY: number = (touch.y - this.viewportPanLastY) * VIEWPORT_PAN_SPEED;
      this.viewportPanLastX = touch.x;
      this.viewportPanLastY = touch.y;
      this.offsetX = this.clampHorizontalOffset(this.offsetX + deltaX, this.zoomScale);
      this.offsetY = this.clampVerticalOffset(this.offsetY + deltaY, this.zoomScale);
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.finishViewportPan();
    }
  }

  finishViewportPan(): void {
    this.viewportPanActive = false;
    this.viewportPanLastX = 0;
    this.viewportPanLastY = 0;
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
    this.offsetX = this.clampHorizontalOffset(nextOffsetX, nextScale);
    this.offsetY = this.clampVerticalOffset(nextOffsetY, nextScale);
    if (!this.canPanViewport() && this.isPanMode) {
      this.isPanMode = false;
      this.viewportPanActive = false;
      this.updateSystemPointerVisibility();
    }
    if (!this.canPanViewport()) {
      this.stopEdgeAutoPan();
    }
  }

  adjustZoom(delta: number): void {
    let nextScale: number = Math.max(0.5, Math.min(5.0, this.zoomScale + delta));
    this.applyZoomAt(this.componentWidth / 2, this.componentHeight / 2, nextScale);
  }

  applyZoomAt(localX: number, localY: number, nextScale: number): void {
    if (nextScale === this.zoomScale) {
      return;
    }
    this.stopEdgeAutoPan();
    let anchorX: number = this.getDisplayLeft() + localX;
    let anchorY: number = this.getDisplayTop() + localY;
    let centerX: number = this.componentWidth / 2;
    let centerY: number = this.componentHeight / 2;
    this.offsetX += (anchorX - centerX) * (this.zoomScale - nextScale);
    this.offsetY += (anchorY - centerY) * (this.zoomScale - nextScale);
    this.zoomScale = nextScale;
    this.clampViewportOffset();
    if (!this.canPanViewport() && this.isPanMode) {
      this.setPanMode(false);
    }
  }

  clampViewportOffset(): void {
    this.offsetX = this.clampHorizontalOffset(this.offsetX, this.zoomScale);
    this.offsetY = this.clampVerticalOffset(this.offsetY, this.zoomScale);
  }

  getHorizontalPanLimit(scale: number): number {
    return this.getPanLimit(this.getDisplayWidth(), this.componentWidth, scale);
  }

  getVerticalPanLimit(scale: number): number {
    return this.getPanLimit(this.getDisplayHeight(), this.componentHeight, scale);
  }

  getPanLimit(displaySize: number, viewportSize: number, scale: number): number {
    if (displaySize <= 0 || viewportSize <= 0 || scale <= 0) {
      return 0;
    }
    return Math.max(0, (displaySize * scale - viewportSize) / 2);
  }

  clampHorizontalOffset(value: number, scale: number): number {
    return this.clampOffsetToLimit(value, this.getHorizontalPanLimit(scale));
  }

  clampVerticalOffset(value: number, scale: number): number {
    return this.clampOffsetToLimit(value, this.getVerticalPanLimit(scale));
  }

  clampOffsetToLimit(value: number, limit: number): number {
    if (limit <= 0) {
      return 0;
    }
    return Math.max(-limit, Math.min(limit, value));
  }

  sendKeyboardText(text: string): void {
    if (text.length <= 0) {
      return;
    }
    ConnectionService.sendText(text);
  }

  toggleRemoteKeyboard(): void {
    if (this.showKeyboardPanel) {
      this.closeRemoteKeyboard();
    } else {
      this.openRemoteKeyboard();
    }
  }

  openRemoteKeyboard(): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    this.keyboardInput = '';
    this.directKeyboardCommittedText = '';
    this.showKeyboardPanel = true;
    setTimeout(() => {
      try {
        this.getUIContext()?.getFocusController().requestFocus('remoteKeyboardCapture');
      } catch (_e) {
      }
    }, 80);
  }

  closeRemoteKeyboard(): void {
    this.showKeyboardPanel = false;
    this.keyboardInput = '';
    this.directKeyboardCommittedText = '';
    setTimeout(() => {
      this.requestRemoteInputFocus();
    }, 60);
  }

  handleDirectKeyboardChange(value: string, previewText?: PreviewText): void {
    this.keyboardInput = value;
    if (previewText !== undefined && previewText.value.length > 0) {
      return;
    }

    let previous: string = this.directKeyboardCommittedText;
    let commonLength: number = 0;
    let maxCommonLength: number = Math.min(previous.length, value.length);
    while (commonLength < maxCommonLength && previous.charAt(commonLength) === value.charAt(commonLength)) {
      commonLength++;
    }

    let removedLength: number = previous.length - commonLength;
    for (let index: number = 0; index < removedLength; index++) {
      this.sendControlKey(8);
    }
    let addedText: string = value.substring(commonLength);
    if (addedText.length > 0) {
      this.sendKeyboardText(addedText);
    }
    this.directKeyboardCommittedText = value;

    if (value.length >= 80) {
      this.keyboardInput = '';
      this.directKeyboardCommittedText = '';
    }
  }

  handleThreeFingerGesture(event: TouchEvent): void {
    if (!this.threeFingerGestureActive) {
      this.threeFingerGestureActive = true;
      this.threeFingerStartedAt = Date.now();
      this.multiTouchActive = false;
      this.multiTouchGesture = 0;
      this.multiTouchMoved = false;
      this.isPinching = false;
      this.clearLongPressTimer();
      this.flushPendingTap();
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
    }

    let count: number = Math.min(3, event.touches.length);
    let centerX: number = 0;
    let centerY: number = 0;
    for (let index: number = 0; index < count; index++) {
      centerX += event.touches[index].x;
      centerY += event.touches[index].y;
    }
    centerX /= Math.max(1, count);
    centerY /= Math.max(1, count);

    if (this.threeFingerStartCenterY === 0) {
      this.threeFingerStartCenterX = centerX;
      this.threeFingerStartCenterY = centerY;
    }
    this.threeFingerLastCenterX = centerX;
    this.threeFingerLastCenterY = centerY;

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.finishThreeFingerGesture();
    }
  }

  finishThreeFingerGesture(): void {
    if (!this.threeFingerGestureActive) {
      return;
    }
    let moveX: number = this.threeFingerLastCenterX - this.threeFingerStartCenterX;
    let moveY: number = this.threeFingerLastCenterY - this.threeFingerStartCenterY;
    let duration: number = Date.now() - this.threeFingerStartedAt;
    let shouldOpenKeyboard: boolean = moveY <= -THREE_FINGER_SWIPE_THRESHOLD &&
      Math.abs(moveX) <= THREE_FINGER_HORIZONTAL_LIMIT && duration <= THREE_FINGER_MAX_DURATION;

    this.threeFingerGestureActive = false;
    this.threeFingerStartedAt = 0;
    this.threeFingerStartCenterX = 0;
    this.threeFingerStartCenterY = 0;
    this.threeFingerLastCenterX = 0;
    this.threeFingerLastCenterY = 0;
    this.ignoreTouchUntilNextDown = true;

    if (shouldOpenKeyboard) {
      this.openRemoteKeyboard();
    }
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
      this.remoteFileBrowserMode = 'upload';
      this.selectedRemoteDownloads = [];
      this.showRemoteFileBrowser = true;
      this.openRemoteDirectory('/');
    } catch (_e) {
      this.showFileToast('未选择文件或无法读取文件');
    }
  }

  openRemoteDirectory(path: string): void {
    this.remoteDirectoryLoading = true;
    this.remoteDirectoryEntries = [];
    if (this.remoteFileBrowserMode === 'download') {
      this.selectedRemoteDownloads = [];
    }
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

  openRemoteDownloadBrowser(): void {
    if (this.transferActive) return;
    this.remoteFileBrowserMode = 'download';
    this.selectedRemoteDownloads = [];
    this.showRemoteFileBrowser = true;
    this.openRemoteDirectory('/');
  }

  getVisibleRemoteEntries(): RemoteDirectoryEntry[] {
    if (this.remoteFileBrowserMode === 'download') {
      return this.remoteDirectoryEntries;
    }
    return this.remoteDirectoryEntries.filter((entry: RemoteDirectoryEntry) => {
      return this.isRemoteDirectory(entry);
    });
  }

  getSelectableRemoteEntries(): RemoteDirectoryEntry[] {
    return this.remoteDirectoryEntries.filter((entry: RemoteDirectoryEntry) => entry.entryType !== 3);
  }

  isRemoteDirectory(entry: RemoteDirectoryEntry): boolean {
    return entry.entryType === 0 || entry.entryType === 2 || entry.entryType === 3;
  }

  remoteEntryTypeLabel(entry: RemoteDirectoryEntry): string {
    if (entry.entryType === 3) return '磁盘';
    if (entry.entryType === 0 || entry.entryType === 2) return '文件夹';
    let extension: string = this.remoteFileExtension(entry.name);
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'bmp':
        return '图片';
      case 'mp4':
      case 'mkv':
      case 'mov':
      case 'avi':
      case 'webm':
        return '视频';
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
        return '音频';
      case 'zip':
      case '7z':
      case 'rar':
      case 'tar':
      case 'gz':
        return '压缩包';
      case 'pdf':
        return 'PDF 文档';
      case 'doc':
      case 'docx':
        return 'Word 文档';
      case 'xls':
      case 'xlsx':
      case 'csv':
        return '表格';
      case 'ppt':
      case 'pptx':
        return '演示文稿';
      case 'txt':
      case 'md':
      case 'log':
        return '文本';
      case 'exe':
      case 'msi':
      case 'hap':
      case 'app':
      case 'apk':
        return '安装包';
      default:
        return extension.length > 0 ? `${extension.toUpperCase()} 文件` : '文件';
    }
  }

  remoteEntryBadge(entry: RemoteDirectoryEntry): string {
    if (entry.entryType === 3) return '盘';
    if (entry.entryType === 0 || entry.entryType === 2) return '夹';
    let extension: string = this.remoteFileExtension(entry.name).toUpperCase();
    return extension.length > 0 ? extension.substring(0, 4) : '文件';
  }

  remoteFileExtension(name: string): string {
    let dotIndex: number = name.lastIndexOf('.');
    if (dotIndex <= 0 || dotIndex >= name.length - 1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  remoteEntryMetadata(entry: RemoteDirectoryEntry): string {
    let typeText: string = this.remoteEntryTypeLabel(entry);
    let sizeText: string = this.isRemoteDirectory(entry) ? '目录' : this.formatFileSize(entry.size);
    let modifiedText: string = this.formatRemoteModifiedTime(entry.modifiedTime);
    return `${typeText} · ${sizeText} · ${modifiedText}`;
  }

  formatRemoteModifiedTime(timestamp: number): string {
    if (timestamp <= 0) return '时间未知';
    let milliseconds: number = timestamp > 100000000000 ? timestamp : timestamp * 1000;
    let date: Date = new Date(milliseconds);
    let pad = (value: number): string => value.toString().padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  formatFileSize(bytes: number): string {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return `${Math.floor(bytes)} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  formatTransferSpeed(bytesPerSecond: number): string {
    return bytesPerSecond > 0 ? `${this.formatFileSize(bytesPerSecond)}/s` : '等待数据';
  }

  remoteEntryKey(entry: RemoteDirectoryEntry): string {
    return this.joinRemotePath(entry.name);
  }

  isRemoteEntrySelected(entry: RemoteDirectoryEntry): boolean {
    let key: string = this.remoteEntryKey(entry);
    return this.selectedRemoteDownloads.some((item: RemoteDownloadSelection) => item.key === key);
  }

  toggleRemoteDownloadEntry(entry: RemoteDirectoryEntry): void {
    if (entry.entryType === 3) return;
    let key: string = this.remoteEntryKey(entry);
    if (this.isRemoteEntrySelected(entry)) {
      this.selectedRemoteDownloads = this.selectedRemoteDownloads.filter(
        (item: RemoteDownloadSelection) => item.key !== key);
      return;
    }
    let selection: RemoteDownloadSelection = {
      key: key,
      remotePath: key,
      localName: entry.name,
      isDirectory: this.isRemoteDirectory(entry),
      size: this.isRemoteDirectory(entry) ? 0 : entry.size
    };
    this.selectedRemoteDownloads = [...this.selectedRemoteDownloads, selection];
  }

  areAllRemoteEntriesSelected(): boolean {
    let entries: RemoteDirectoryEntry[] = this.getSelectableRemoteEntries();
    return entries.length > 0 && entries.every((entry: RemoteDirectoryEntry) => this.isRemoteEntrySelected(entry));
  }

  toggleSelectAllRemoteEntries(): void {
    if (this.areAllRemoteEntriesSelected()) {
      this.selectedRemoteDownloads = [];
      return;
    }
    let selections: RemoteDownloadSelection[] = [];
    this.getSelectableRemoteEntries().forEach((entry: RemoteDirectoryEntry) => {
      let key: string = this.remoteEntryKey(entry);
      selections.push({
        key: key,
        remotePath: key,
        localName: entry.name,
        isDirectory: this.isRemoteDirectory(entry),
        size: this.isRemoteDirectory(entry) ? 0 : entry.size
      });
    });
    this.selectedRemoteDownloads = selections;
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

  prepareCurrentRemoteFolderDownload(): void {
    if (this.remoteDirectoryPath.length === 0 || this.remoteDirectoryPath === '/') return;
    let name: string = this.remoteFolderDisplayName(this.remoteDirectoryPath);
    let selection: RemoteDownloadSelection = {
      key: this.remoteDirectoryPath,
      remotePath: this.remoteDirectoryPath,
      localName: name,
      isDirectory: true,
      size: 0
    };
    this.prepareRemoteDownload([selection]);
  }

  remoteFolderDisplayName(path: string): string {
    let value: string = path;
    while (value.length > 1 && (value.endsWith('\\') || value.endsWith('/'))) {
      value = value.substring(0, value.length - 1);
    }
    if (/^[A-Za-z]:$/.test(value)) return value.substring(0, 1);
    let index: number = Math.max(value.lastIndexOf('\\'), value.lastIndexOf('/'));
    return index >= 0 ? value.substring(index + 1) : value;
  }

  safeDownloadName(name: string): string {
    let safeName: string = name.replace(/[\\/:*?"<>|]/g, '_').replace(/[. ]+$/g, '').trim();
    if (safeName.length === 0 || safeName === '.' || safeName === '..') {
      safeName = `远端文件-${Date.now()}`;
    }
    return safeName.substring(0, 180);
  }

  async prepareRemoteDownload(items: RemoteDownloadSelection[]): Promise<void> {
    if (items.length <= 0 || this.transferActive) return;
    try {
      let context = getContext(this) as common.UIAbilityContext;
      let requests: FileDownloadRequest[] = [];
      let usedNames: Map<string, number> = new Map<string, number>();
      items.forEach((item: RemoteDownloadSelection) => {
        let baseName: string = this.safeDownloadName(item.localName);
        let count: number = usedNames.get(baseName) ?? 0;
        usedNames.set(baseName, count + 1);
        let localName: string = count === 0 ? baseName : `${baseName}-${count + 1}`;
        requests.push({
          remotePath: item.remotePath,
          localName: localName,
          isDirectory: item.isDirectory
        });
      });

      let documentPicker = new picker.DocumentViewPicker(context);
      let options = new picker.DocumentSaveOptions();
      let singleFile: boolean = requests.length === 1 && !requests[0].isDirectory;
      let asArchive: boolean = !singleFile;
      let archiveName: string = requests.length === 1 ?
        `${requests[0].localName}.zip` : `StarRustDesk-批量取回-${this.downloadTimestamp()}.zip`;
      if (singleFile) {
        options.newFileNames = [requests[0].localName];
      } else {
        options.newFileNames = [archiveName];
      }
      let uris: string[] = await documentPicker.save(options);
      if (uris.length <= 0) return;

      this.cleanupPendingDownloadFiles();
      let localRoot: string = `${context.cacheDir}/StarRustDesk-取回-${Date.now()}`;
      fileIo.mkdirSync(localRoot);
      this.pendingDownloadRoot = localRoot;
      this.pendingDownloadDestinationUri = uris[0];
      this.pendingDownloadItems = requests;
      this.pendingDownloadSingleFile = singleFile;
      this.pendingDownloadAsArchive = asArchive;
      this.pendingDownloadArchivePath = asArchive ? `${localRoot}.zip` : '';

      let estimatedBytes: number = 0;
      items.forEach((item: RemoteDownloadSelection) => {
        estimatedBytes += item.size;
      });
      this.beginFileTransferHistory(
        'download',
        singleFile ? requests[0].localName : archiveName,
        asArchive ? 'ZIP 压缩包' : this.fileTypeFromName(requests[0].localName),
        requests.length,
        estimatedBytes
      );

      let result: number = RustDeskNapi.startFileDownloadBatch(requests, localRoot);
      if (result !== 0) {
        this.finishFileTransferHistory('failed', `无法启动取回任务 (${result})`);
        this.cleanupPendingDownloadFiles();
        this.showFileToast(`取回文件失败 (${result})`);
        return;
      }
      this.transferDirection = 'download';
      this.transferActive = true;
      RemoteSessionBackgroundTask.setDataTransferActive(true);
      this.resetTransferTracking(requests.length);
      this.closeRemoteFileBrowser(false);
      this.showFileToast(asArchive ? `开始取回，完成后将生成 ${archiveName}` : '开始取回文件');
    } catch (_e) {
      this.cleanupPendingDownloadFiles();
      this.showFileToast('未选择保存位置或无法创建下载任务');
    }
  }

  downloadTimestamp(): string {
    let now: Date = new Date();
    let pad = (value: number): string => value.toString().padStart(2, '0');
    return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  }

  async exportDownloadedItems(): Promise<void> {
    if (this.pendingDownloadRoot.length === 0 || this.pendingDownloadDestinationUri.length === 0) {
      this.finishFileTransferHistory('failed', '下载完成，但保存位置无效');
      this.showFileToast('下载完成，但保存位置无效');
      return;
    }
    let itemCount: number = this.pendingDownloadItems.length;
    let asArchive: boolean = this.pendingDownloadAsArchive;
    try {
      if (asArchive) {
        let archiveOptions: zlib.Options = {
          level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
          memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
          strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY
        };
        RustDeskNapi.appendDiagnosticLog('file-download', `archive_start items=${itemCount}`);
        await zlib.compressFile(this.pendingDownloadRoot, this.pendingDownloadArchivePath, archiveOptions);
        let archiveSize: number = this.copyDownloadedFileToDestination(
          this.pendingDownloadArchivePath, this.pendingDownloadDestinationUri);
        if (archiveSize <= 0) {
          throw new Error('archive is empty');
        }
        RustDeskNapi.appendDiagnosticLog(
          'file-download', `archive_saved items=${itemCount} bytes=${archiveSize}`);
      } else {
        let item: FileDownloadRequest = this.pendingDownloadItems[0];
        let source: DownloadedFileCandidate = this.resolveSingleDownloadedFile(
          this.pendingDownloadRoot, item.localName);
        let directPath: string = `${this.pendingDownloadRoot}/${item.localName}`;
        RustDeskNapi.appendDiagnosticLog(
          'file-download',
          `single_source layout=${source.path === directPath ? 'direct' : 'nested'} bytes=${source.size}`
        );
        let savedSize: number = this.copyDownloadedFileToDestination(
          source.path, this.pendingDownloadDestinationUri);
        RustDeskNapi.appendDiagnosticLog('file-download', `single_saved bytes=${savedSize}`);
      }
      this.finishFileTransferHistory('completed', '');
      this.cleanupPendingDownloadFiles();
      this.showFileToast(asArchive ?
        `${itemCount} 项已压缩并保存` : '文件已保存到所选位置');
    } catch (error) {
      this.logDownloadExportError(asArchive ? 'archive' : 'single-file', error);
      this.finishFileTransferHistory('failed', asArchive ?
        '文件已取回，但压缩或保存 ZIP 失败' : '文件已取回，但保存到所选位置失败');
      this.showFileToast(asArchive ?
        '文件已取回，但压缩或保存 ZIP 失败' : '文件已取回，但保存到所选位置失败');
    }
  }

  resolveSingleDownloadedFile(root: string, localName: string): DownloadedFileCandidate {
    let directPath: string = `${root}/${localName}`;
    try {
      let directStat: fileIo.Stat = fileIo.statSync(directPath);
      if (directStat.isFile() && directStat.size > 0) {
        return { path: directPath, size: directStat.size };
      }
    } catch (_e) {
    }

    let candidates: DownloadedFileCandidate[] = [];
    this.collectDownloadedFiles(root, candidates, 0);
    if (candidates.length <= 0) {
      throw new Error('downloaded source file is missing');
    }
    candidates.sort((left: DownloadedFileCandidate, right: DownloadedFileCandidate) => right.size - left.size);
    if (candidates[0].size <= 0) {
      throw new Error('downloaded source file is empty');
    }
    return candidates[0];
  }

  collectDownloadedFiles(path: string, candidates: DownloadedFileCandidate[], depth: number): void {
    if (depth > 32) return;
    let stat: fileIo.Stat = fileIo.statSync(path);
    if (stat.isDirectory()) {
      fileIo.listFileSync(path).forEach((name: string) => {
        if (!name.endsWith('.digest')) {
          this.collectDownloadedFiles(`${path}/${name}`, candidates, depth + 1);
        }
      });
      return;
    }
    if (stat.isFile()) {
      candidates.push({ path: path, size: stat.size });
    }
  }

  copyDownloadedFileToDestination(sourcePath: string, destinationUri: string): number {
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    try {
      source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      let sourceSize: number = fileIo.statSync(source.fd).size;
      if (sourceSize <= 0) {
        throw new Error('downloaded source file is empty');
      }
      destination = fileIo.openSync(
        destinationUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(source.fd, destination.fd);
      fileIo.fsyncSync(destination.fd);
      let destinationSize: number = fileIo.statSync(destination.fd).size;
      if (destinationSize !== sourceSize) {
        throw new Error(`saved file size mismatch source=${sourceSize} destination=${destinationSize}`);
      }
      return destinationSize;
    } finally {
      if (destination !== undefined) {
        fileIo.closeSync(destination);
      }
      if (source !== undefined) {
        fileIo.closeSync(source);
      }
    }
  }

  logDownloadExportError(name: string, error: Object): void {
    let businessError: BusinessError = error as BusinessError;
    RustDeskNapi.appendDiagnosticLog(
      'file-download',
      `export_error name=${name} code=${businessError.code ?? -1} message=${businessError.message ?? 'unknown'}`
    );
  }

  cleanupPendingDownloadFiles(): void {
    let root: string = this.pendingDownloadRoot;
    let archivePath: string = this.pendingDownloadArchivePath;
    this.pendingDownloadRoot = '';
    this.pendingDownloadDestinationUri = '';
    this.pendingDownloadItems = [];
    this.pendingDownloadSingleFile = false;
    this.pendingDownloadAsArchive = false;
    this.pendingDownloadArchivePath = '';
    if (root.length > 0) {
      this.removeSandboxTree(root);
    }
    if (archivePath.length > 0) {
      try {
        fileIo.unlinkSync(archivePath);
      } catch (_e) {
      }
    }
  }

  removeSandboxTree(path: string): void {
    try {
      let stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.isDirectory()) {
        fileIo.listFileSync(path).forEach((name: string) => {
          this.removeSandboxTree(`${path}/${name}`);
        });
        fileIo.rmdirSync(path);
      } else {
        fileIo.unlinkSync(path);
      }
    } catch (_e) {
    }
  }

  startPendingFileUpload(): void {
    if (this.pendingUploadPath.length === 0 || this.pendingUploadName.length === 0) return;
    let uploadSize: number = 0;
    try {
      uploadSize = fileIo.statSync(this.pendingUploadPath).size;
    } catch (_e) {
    }
    this.beginFileTransferHistory(
      'upload', this.pendingUploadName, this.fileTypeFromName(this.pendingUploadName), 1, uploadSize);
    let result: number = RustDeskNapi.startFileUpload(
      this.pendingUploadPath,
      this.pendingUploadName,
      this.remoteDirectoryPath
    );
    if (result !== 0) {
      this.finishFileTransferHistory('failed', `无法启动发送任务 (${result})`);
      this.showFileToast(`发送文件失败 (${result})`);
      return;
    }
    this.transferActive = true;
    RemoteSessionBackgroundTask.setDataTransferActive(true);
    this.transferDirection = 'upload';
    this.resetTransferTracking(1);
    this.closeRemoteFileBrowser(false);
    this.showFileToast('文件开始传输');
  }

  resetTransferTracking(totalItems: number): void {
    this.transferProgress = 0;
    this.transferTransferredBytes = 0;
    this.transferTotalBytes = 0;
    this.transferSpeedBytesPerSecond = 0;
    this.transferCompletedItems = 0;
    this.transferTotalItems = totalItems;
    this.transferCancelling = false;
    this.lastTransferSampleAt = Date.now();
    this.lastTransferSampleBytes = 0;
  }

  beginFileTransferHistory(direction: string, displayName: string, fileType: string,
    itemCount: number, estimatedBytes: number): void {
    this.transferTransferredBytes = 0;
    this.transferTotalBytes = 0;
    this.transferHistoryStartedAt = Date.now();
    this.transferHistoryDirection = direction;
    this.transferHistoryDisplayName = displayName;
    this.transferHistoryFileType = fileType;
    this.transferHistoryItemCount = itemCount;
    this.transferHistoryEstimatedBytes = estimatedBytes;
  }

  finishFileTransferHistory(status: string, error: string): void {
    if (this.transferHistoryStartedAt <= 0) return;
    let finishedAt: number = Date.now();
    let durationMs: number = Math.max(1, finishedAt - this.transferHistoryStartedAt);
    let totalBytes: number = Math.max(
      this.transferHistoryEstimatedBytes, this.transferTotalBytes, this.transferTransferredBytes);
    let record: FileTransferHistoryRecord = {
      id: `${this.transferHistoryStartedAt}-${finishedAt}`,
      direction: this.transferHistoryDirection,
      peerId: this.connectedPeerId,
      displayName: this.transferHistoryDisplayName,
      fileType: this.transferHistoryFileType,
      totalBytes: totalBytes,
      itemCount: Math.max(1, this.transferHistoryItemCount),
      startedAt: this.transferHistoryStartedAt,
      finishedAt: finishedAt,
      durationMs: durationMs,
      averageSpeed: totalBytes > 0 ? totalBytes * 1000 / durationMs : 0,
      status: status,
      error: error
    };
    FileTransferHistoryService.add(record);
    this.transferHistoryStartedAt = 0;
    this.transferHistoryDisplayName = '';
    this.transferHistoryFileType = '';
    this.transferHistoryItemCount = 0;
    this.transferHistoryEstimatedBytes = 0;
  }

  fileTypeFromName(name: string): string {
    let extension: string = this.remoteFileExtension(name);
    return extension.length > 0 ? `${extension.toUpperCase()} 文件` : '文件';
  }

  cancelActiveFileTransfer(): void {
    if (!this.transferActive || this.transferCancelling) return;
    let result: number = RustDeskNapi.cancelFileTransfer();
    if (result !== 0) {
      this.showFileToast(`无法取消文件传输 (${result})`);
      return;
    }
    this.transferCancelling = true;
    RustDeskNapi.appendDiagnosticLog('file-transfer', `cancel_requested direction=${this.transferDirection}`);
  }

  closeRemoteFileBrowser(removePendingFile: boolean): void {
    this.showRemoteFileBrowser = false;
    this.remoteDirectoryLoading = false;
    this.selectedRemoteDownloads = [];
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
      this.transferDirection = status.direction ?? this.transferDirection;
      this.updateTransferMetrics(status);
      this.transferProgress = status.total > 0 ? Math.min(100, status.transferred * 100 / status.total) : 0;
      if (status.state === 'completed') {
        this.transferActive = false;
        RemoteSessionBackgroundTask.setDataTransferActive(false);
        this.transferCancelling = false;
        this.transferSpeedBytesPerSecond = 0;
        this.transferProgress = 100;
        if (this.transferDirection === 'download') {
          this.showFileToast(this.pendingDownloadAsArchive ?
            '取回完成，正在生成 ZIP 文件' : '取回完成，正在保存到所选位置');
          this.exportDownloadedItems();
        } else {
          this.finishFileTransferHistory('completed', '');
          this.cleanupPendingUploadFile();
          this.pendingUploadName = '';
          this.showFileToast('文件传输完成');
        }
      } else if (status.state === 'failed') {
        this.transferActive = false;
        RemoteSessionBackgroundTask.setDataTransferActive(false);
        this.transferCancelling = false;
        this.transferSpeedBytesPerSecond = 0;
        this.finishFileTransferHistory('failed', status.error.length > 0 ? status.error : '文件传输失败');
        if (this.transferDirection === 'download') {
          this.cleanupPendingDownloadFiles();
        }
        this.showFileToast(status.error.length > 0 ? `文件传输失败：${status.error}` : '文件传输失败');
      } else if (status.state === 'cancelled') {
        this.transferActive = false;
        RemoteSessionBackgroundTask.setDataTransferActive(false);
        this.transferCancelling = false;
        this.transferSpeedBytesPerSecond = 0;
        this.finishFileTransferHistory('cancelled', '用户取消了文件传输');
        if (this.transferDirection === 'download') {
          this.cleanupPendingDownloadFiles();
        } else {
          this.cleanupPendingUploadFile();
          this.pendingUploadName = '';
        }
        this.showFileToast('文件传输已取消');
      }
    } catch (_e) {
    }
  }

  updateTransferMetrics(status: FileTransferStatus): void {
    let now: number = Date.now();
    let elapsed: number = now - this.lastTransferSampleAt;
    if (status.transferred < this.lastTransferSampleBytes) {
      this.lastTransferSampleBytes = status.transferred;
      this.lastTransferSampleAt = now;
      this.transferSpeedBytesPerSecond = 0;
    } else if (elapsed >= 500) {
      let delta: number = status.transferred - this.lastTransferSampleBytes;
      let instantSpeed: number = delta * 1000 / elapsed;
      this.transferSpeedBytesPerSecond = this.transferSpeedBytesPerSecond > 0 ?
        this.transferSpeedBytesPerSecond * 0.4 + instantSpeed * 0.6 : instantSpeed;
      this.lastTransferSampleBytes = status.transferred;
      this.lastTransferSampleAt = now;
    }
    this.transferTransferredBytes = status.transferred;
    this.transferTotalBytes = status.total;
    this.transferCompletedItems = status.completedItems ?? 0;
    this.transferTotalItems = status.totalItems ?? this.transferTotalItems;
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
    if (this.transferHistoryStartedAt > 0) {
      this.finishFileTransferHistory('cancelled', '远控连接已断开');
    }
    this.stopEdgeAutoPan();
    this.releaseHeldMouseButtons('disconnect');
    ConnectionService.releaseModifiers();
    if (this.isFullScreen) {
      this.isFullScreen = false;
      this.applyFullscreenWindow(false);
    }
    if (this.statusTimer !== -1) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
    this.stopFramePolling();
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
      this.surfaceRebindTimer = -1;
    }
    this.hasVideo = false;
    this.showRemoteSurface = false;
    this.surfaceEpoch += 1;
    this.connectionStatus = ConnectionStatus.DISCONNECTED;
    this.showKeyboardPanel = false;
    this.showMobileActions = false;
    this.isPeerAndroid = false;
    this.showCursor = false;
    this.pointerOverRemoteViewport = false;
    this.setSystemPointerHidden(false);
    this.stopClipboardSync();
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.pinchStartDistance = 0;
    this.isPinching = false;
    RustDeskNapi.setSurfaceId('');
    ConnectionService.disconnect();
    // XComponent owns a separate native surface layer. Let ArkUI remove that
    // layer before starting the router transition, otherwise the old video
    // surface can remain above the connection page for one animation frame.
    setTimeout(() => {
      try {
        router.back();
      } catch (_e) {
        this.isLeavingAfterDisconnect = false;
      }
    }, 80);
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
    this.cancelActiveTouchGesture();
    this.stopEdgeAutoPan();
    this.currentDisplay = display;
    this.showCursor = false;
    this.remoteCursorEmbedded = false;
    this.embeddedCursorOverlayFallback = false;
    this.lastRemoteCursorSequence = -1;
    this.lastRemoteCursorImageSequence = -1;
    this.hasAuthoritativeRemoteCursor = false;
    this.remoteCursorAbsX = 0;
    this.remoteCursorAbsY = 0;
    this.lastAbsX = 0;
    this.lastAbsY = 0;
    this.pointerInitialized = false;
    this.localPointerGestureActive = false;
    this.lastLocalPointerInputAt = 0;
    this.preferAuthoritativeCursor = false;
    this.lastStatsTime = 0;
    RustDeskNapi.appendDiagnosticLog('input', `display_cursor_state_reset display=${display}`);
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

  scheduleSurfaceRebindIfSizeChanged(force: boolean = false): void {
    if (this.componentWidth <= 0 || this.componentHeight <= 0 || this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    let widthDelta: number = Math.abs(this.componentWidth - this.lastSurfaceWidth);
    let heightDelta: number = Math.abs(this.componentHeight - this.lastSurfaceHeight);
    if (!force && this.lastSurfaceWidth > 0 && this.lastSurfaceHeight > 0 && widthDelta < 24 && heightDelta < 24) {
      return;
    }
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
    } else {
      RustDeskNapi.appendDiagnosticLog('surface',
        `layout_change_prepare width=${Math.round(this.componentWidth)} height=${Math.round(this.componentHeight)} force=${force}`)
      RustDeskNapi.prepareSurfaceRebind();
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
    let reboundSurfaceId: string = this.surfaceId;
    try {
      let currentSurfaceId: string = this.xComponentController.getXComponentSurfaceId();
      if (currentSurfaceId.length > 0) {
        reboundSurfaceId = currentSurfaceId;
      }
    } catch (_e) {
      RustDeskNapi.appendDiagnosticLog('surface', 'layout_rebind_using_cached_surface_id')
    }
    if (reboundSurfaceId.length <= 0) {
      RustDeskNapi.appendDiagnosticLog('surface', 'layout_rebind_empty_surface_id')
      RustDeskNapi.setSurfaceId('');
      return;
    }
    this.surfaceId = reboundSurfaceId;
    RustDeskNapi.rebindSurface(reboundSurfaceId);
    this.lastSurfaceWidth = this.componentWidth;
    this.lastSurfaceHeight = this.componentHeight;
    this.requestVideoRefreshAfterSurfaceRebind();
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
    this.codecText = this.videoCodecStatus(frame.codec ?? 0, frame.decoderMode ?? 0);
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

  videoCodecName(codec: number): string {
    if (codec === 1) {
      return 'H.264';
    }
    if (codec === 2) {
      return 'VP9';
    }
    if (codec === 3) {
      return 'H.265';
    }
    if (codec === 4) {
      return 'VP8';
    }
    if (codec === 5) {
      return 'AV1';
    }
    return '等待视频';
  }

  videoCodecStatus(codec: number, decoderMode: number): string {
    const codecName: string = this.videoCodecName(codec);
    if (codec <= 0) {
      return codecName;
    }
    if (decoderMode === 1) {
      return `${codecName} · 硬解`;
    }
    if (decoderMode === 2) {
      return `${codecName} · 软解`;
    }
    return `${codecName} · 检测中`;
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
