import { ButtonShapeModifier } from '../theme/ButtonShapeModifier'
import { inputCompatibilityKey, selectedKeyboardMode, selectedCursorMode, shouldSuppressCursor } from '../model/InputCompatibility';
import { isNavigationControlKey, navigationKeyName, NAVIGATION_LOCAL, RemoteNavigationKeys } from '../model/RemoteNavigationKeys';
﻿import { router } from '@kit.ArkUI';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { CommunicationService } from '../service/CommunicationService';
import { CommunicationPanel } from '../widget/CommunicationPanel';
import { FrameCallback, KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError, deviceInfo, zlib } from '@kit.BasicServicesKit';
import { translate } from '../utils/I18n';
import { ConnectionStatus } from '../model/ConnectionModel';
import { ConnectionService } from '../service/ConnectionService';
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask';
import { FileDownloadRequest, FileTransferStatus, HardwareKeyState, NativeInputEvent, NativeKeyInputEvent, NativeMouseInputEvent, RemoteCursorPosition, RemoteDirectoryEntry, RemoteDirectoryResult, RustDeskNapi, VideoFrameInfo } from '../service/RustDeskNapi';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import pointer from '@ohos.multimodalInput.pointer';
import { FileTransferHistoryRecord, FileTransferHistoryService } from '../service/FileTransferHistoryService';
import { FileTransferHistoryDialog } from '../widget/FileTransferHistoryDialog';
import { NameInputDialog } from '../widget/NameInputDialog';
import { SessionRecording } from '../service/SessionRecording';
import { OperationDiagnostic } from '../service/OperationDiagnostic';
import { RecordingDialog } from '../widget/RecordingDialog';
import { sortRemoteFiles } from '../utils/RemoteFileSort';
import { RemoteDisplayPolicy } from '../service/RemoteDisplayPolicy';
import { RemoteFullscreenPolicy } from '../service/RemoteFullscreenPolicy';
import { followTouchMouseAxis } from '../utils/TouchMouseFollow';

class ViewportFrameCallback extends FrameCallback {
  private apply: () => void;
  constructor(apply: () => void) { super(); this.apply = apply; }
  onFrame(_frameTimeInNano: number): void { this.apply(); }
}

interface UploadQueueItem { path: string; name: string; size: number; }
interface FileOperationResult { id: number; ok: boolean; }
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
const TOUCHPAD_DOUBLE_TAP_TIMEOUT_MS: number = 340;
const TOUCHPAD_DOUBLE_TAP_DISTANCE: number = 40;
const TOUCHPAD_DRAG_START_THRESHOLD: number = 18;
const MULTI_TOUCH_MOVE_THRESHOLD: number = 8;
const PINCH_DISTANCE_THRESHOLD: number = 12;
const THREE_FINGER_SWIPE_THRESHOLD: number = 70;
const THREE_FINGER_HORIZONTAL_LIMIT: number = 120;
const THREE_FINGER_MAX_DURATION: number = 1500;
// RustDesk's controlled side suppresses cursor-position echoes to the input
// origin for roughly 300 ms. Keep the locally predicted cursor during that
// window so touchpad and physical-mouse movement remain visually responsive.
const LOCAL_CURSOR_ECHO_GUARD_MS: number = 360;
const EDGE_AUTO_PAN_MOUSE_DWELL_MS: number = 90;
const EDGE_AUTO_PAN_TOUCH_DWELL_MS: number = 260;
const EDGE_AUTO_PAN_FRAME_MS: number = 16;
const EDGE_AUTO_PAN_MIN_SPEED: number = 88;
const EDGE_AUTO_PAN_MAX_SPEED: number = 640;
const VIEWPORT_PAN_SPEED: number = 1.5;
const VIRTUAL_MOUSE_WIDTH: number = 112;
const VIRTUAL_MOUSE_HEIGHT: number = 138;
const VIRTUAL_MOUSE_RIGHT_OUTSIDE_MARGIN: number = VIRTUAL_MOUSE_WIDTH * 2 + 32;
const VIRTUAL_MOUSE_BOTTOM_OUTSIDE_MARGIN: number = VIRTUAL_MOUSE_HEIGHT * 2 + 32;
const VIRTUAL_MOUSE_POINTER_HOT_X: number = 1;
const VIRTUAL_MOUSE_POINTER_HOT_Y: number = 1;
const VIRTUAL_MOUSE_BUTTON_DRAG_THRESHOLD: number = 8;
const VIRTUAL_MOUSE_WHEEL_BUTTON_STEP: number = 3;
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
const VIRTUAL_MODIFIER_CTRL: number = 17;
const VIRTUAL_MODIFIER_SHIFT: number = 16;
const VIRTUAL_MODIFIER_ALT: number = 18;
const VIRTUAL_MODIFIER_META: number = 91;
const MODIFIER_MASK_CTRL: number = 1;
const MODIFIER_MASK_SHIFT: number = 2;
const MODIFIER_MASK_ALT: number = 4;
const MODIFIER_MASK_META: number = 8;
const KEYBOARD_CAPTURE_SENTINEL: string =
  '1111111111111111111111111111111111111111111111111111111111111111';
const CONTROL_TOOLBAR_DEFAULT_ORDER: string[] = [
  'displays', 'input', 'virtualMouse', 'edgePan', 'keyboard', 'mobileActions', 'gestureHelp',
  'pan', 'chat', 'upload', 'uploadFolder', 'download', 'recording', 'recordings', 'clipboard', 'privacy', 'zoomIn', 'zoomOut', 'fullscreen', 'orientation', 'disconnect'
];
const KEYBOARD_TOOLBAR_DEFAULT_ORDER: string[] = [
  'ctrl', 'alt', 'shift', 'meta', 'function', 'more', 'release'
];
const KEYBOARD_MORE_DEFAULT_ORDER: string[] = [
  'Left', 'Up', 'Down', 'Right',
  'Esc', 'Tab', 'Home', 'End', 'Ins', 'Del', 'PgUp', 'PgDn',
  'Ctrl+Shift+Esc', 'Ctrl+Shift+Del', 'Alt+F4', 'Ctrl+Alt+Del'
];
const LOG_DOMAIN: number = 0x0000;

@Component
struct ConnectionQualityRow {
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @Prop label: string;
  @Prop value: string;
  @Prop valueColor: ResourceColor = Color.White;

  build() {
    Row() {
      Text(this.label)
        .width(76)
        .fontSize(11)
        .fontColor('#FFD2D2D2')
        .textAlign(TextAlign.End)
        .maxLines(1)
      Text(this.value)
        .width(96)
        .fontSize(11)
        .fontColor(this.valueColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(17)
  }
}

@Entry
@Component
struct RemotePage {
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('remoteLandscapeLocked') remoteLandscapeLocked: boolean = false;
  @StorageLink('appForegroundEpoch') @Watch('onAppForegroundEpochChanged') appForegroundEpoch: number = 0;
  @StorageLink('mobileActionsOffsetX') mobileActionsOffsetX: number = 0;
  @StorageLink('mobileActionsOffsetY') mobileActionsOffsetY: number = 0;
  @State connectionStatus: ConnectionStatus = ConnectionStatus.DISCONNECTED;
  @State showToolbar: boolean = true;
  @State showCommunicationPanel: boolean = false;
  @State communicationUnread: number = 0;
  @State communicationCallActive: boolean = false;
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
  @State keyboardViewportHeight: number = 0;
  private keyboardLayoutWidth: number = 0;
  private keyboardLayoutHeight: number = 0;
  @State keyboardToolsCollapsed: boolean = true;
  @State keyboardToolsOffsetX: number = 0;
  @State keyboardToolsOffsetY: number = 0;
  @State remoteToolbarCollapsed: boolean = false;
  @State remoteToolbarOffsetX: number = 0;
  @State remoteToolbarOffsetY: number = 0;
  @State showVirtualMouse: boolean = false;
  @State virtualMouseX: number = 0;
  @State virtualMouseY: number = 0;
  @State virtualMouseLeftDown: boolean = false;
  @State virtualMouseRightDown: boolean = false;
  @State virtualMouseMiddleDown: boolean = false;
  @State showToolbarOrderEditor: boolean = false;
  @State toolbarOrderEditorKind: string = 'control';
  @State controlToolbarOrder: string[] = CONTROL_TOOLBAR_DEFAULT_ORDER.slice();
  @State keyboardToolbarOrder: string[] = KEYBOARD_TOOLBAR_DEFAULT_ORDER.slice();
  @State keyboardMoreOrder: string[] = KEYBOARD_MORE_DEFAULT_ORDER.slice();
  @State showKeyboardFunctionKeys: boolean = false;
  @State showKeyboardMoreKeys: boolean = false;
  @State virtualCtrlSelected: boolean = false;
  @State virtualShiftSelected: boolean = false;
  @State virtualAltSelected: boolean = false;
  @State virtualMetaSelected: boolean = false;
  @State canSendCtrlAltDel: boolean = false;
  @State inputMode: string = INPUT_MODE_MOUSE;
  @State keyboardCompatibilityMode: number = 0;
  @State relativeMouseEnabled: boolean = false;
  @State relativeMouseSupported: boolean = false;
  @State oneKvmPeer: boolean = false;
  @State cursorCompatibilityMode: string = 'auto';
  private inputCompatibilityLoaded: boolean = false;
  @State fileOnly: boolean = false;
  private waylandTextAllowed: boolean = false;
  private waylandPermissionEpoch: number = 0;
  private remotePageVisible: boolean = false;
  private waylandPromptOpen: boolean = false;
  private relativePointerSampleValid: boolean = false;
  private relativePointerX: number = 0;
  private relativePointerY: number = 0;
  @State showGestureHelp: boolean = false;
  @State showMobileActions: boolean = false;
  @State isPeerAndroid: boolean = false;
  @State privacyModeState: number = 0;
  @State showLocalCursor: boolean = true;
  @State showLeftButtonHoldIndicator: boolean = false;
  @State keyboardInput: string = KEYBOARD_CAPTURE_SENTINEL;
  private keyboardComposing: boolean = false;
  private navigationKeys: RemoteNavigationKeys = new RemoteNavigationKeys();
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
  @State delayText: string = '-';
  @State delayMs: number = 0;
  @State targetBitrateText: string = '-';
  @State codecText: string = '等待视频';
  @State codecNameText: string = '等待视频';
  @State decoderText: string = '-';
  @State routeText: string = '未知';
  @State peerSecurityState: number = 0;
  @State showQualityMonitor: boolean = false;
  @State qualityMonitorX: number = -1;
  @State qualityMonitorY: number = -1;
  @State qualityViewportWidth: number = 0;
  @State qualityViewportHeight: number = 0;
  private qualityDragStartX: number = 0;
  private qualityDragStartY: number = 0;
  private qualityLastDragAt: number = 0;
  private videoSessionGeneration: number = -1;
  private directLoginStartedAt: number = 0;
  private videoDecoderRestartRequested: boolean = false;
  @State pageWidth: number = 0;
  @State pageHeight: number = 0;
  @State clipboardSyncEnabled: boolean = true;
  @State showRemoteFileBrowser: boolean = false;
  @State remoteDirectoryPath: string = '';
  @State remoteDirectoryEntries: RemoteDirectoryEntry[] = [];
  @State remoteDirectoryLoading: boolean = false;
  @State remoteFileSortField: string = 'name';
  @State remoteFileSortDescending: boolean = false;
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
  private insecureFallbackPromptShown: boolean = false;
  @State isFullScreen: boolean = false;
  @State fullscreenTransitioning: boolean = false;
  private fullscreenRequestId: number = 0;
  @State isPanMode: boolean = false;
  @State edgeAutoPanEnabled: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private toolbarTimer: number = -1;
  private remoteToolbarDragStartX: number = 0;
  private remoteToolbarDragStartY: number = 0;
  private virtualMouseDragStartX: number = 0;
  private virtualMouseDragStartY: number = 0;
  private virtualMouseLastPanX: number = 0;
  private virtualMouseLastPanY: number = 0;
  private virtualMouseWheelLastY: number = 0;
  private virtualMouseDragActive: boolean = false;
  private virtualMouseInitialized: boolean = false;
  private virtualMouseButtonTouchActive: boolean = false;
  private virtualMouseButtonTouchName: string = '';
  private virtualMouseButtonTouchStartX: number = 0;
  private virtualMouseButtonTouchStartY: number = 0;
  private virtualMouseWheelTouchActive: boolean = false;
  private virtualMouseWheelTouchMoved: boolean = false;
  private virtualMouseWheelTouchStartY: number = 0;
  private virtualMouseLastTouchResolvedAt: number = 0;
  private lastHandheldLandscape: boolean = false;
  private handheldLayoutInitialized: boolean = false;
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
  private surfaceRebindForced: boolean = false;
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
  private firstVideoWaitStartedAt: number = 0;
  private firstVideoRecoveryStage: number = 0;
  @State videoWaitingHint: string = '等待远端视频画面';
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
  private mobileActionsDragStartX: number = 0;
  private mobileActionsDragStartY: number = 0;
  private keyboardToolsDragStartX: number = 0;
  private keyboardToolsDragStartY: number = 0;
  private lastSurfaceWidth: number = 0;
  private lastSurfaceHeight: number = 0;
  private lastBoundSurfaceId: string = '';
  private lastLayoutViewportWidth: number = 0;
  private lastLayoutViewportHeight: number = 0;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private touchMoved: boolean = false;
  private pointerInitialized: boolean = false;
  private leftButtonHeld: boolean = false;
  private rightButtonHeld: boolean = false;
  private multiTouchActive: boolean = false;
  private touchSequenceDraining: boolean = false;
  private touchSequenceMaxFingers: number = 0;
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
  private viewportPanFramePending: boolean = false;
  private viewportPanFrameGeneration: number = 0;
  private viewportPanTargetX: number = 0;
  private viewportPanTargetY: number = 0;
  private viewportPanLastX: number = 0;
  private viewportPanLastY: number = 0;
  private directKeyboardCommittedText: string = KEYBOARD_CAPTURE_SENTINEL;
  private clipboardPolling: boolean = false;
  private lastLocalClipboardText: string = '';
  private lastRemoteClipboardText: string = '';
  private suppressClipboardText: string = '';
  private clipboardBaselineInitialized: boolean = false;
  private isLeavingAfterDisconnect: boolean = false;
  private pendingUploadPath: string = '';
  @State recordingActive: boolean = false;
  private recordingDialog: CustomDialogController = new CustomDialogController({ builder: RecordingDialog(), customStyle: true });
  private uploadQueue: UploadQueueItem[] = [];
  @State uploadStaging: boolean = false;
  @State uploadPreparationCancelled: boolean = false;
  private uploadGeneration: number = 0;
  private uploadQueueDirectory: string = '';
  private fileOperationTimer: number = -1;
  private fileOperationTrace?: OperationDiagnostic;
  private transferTrace?: OperationDiagnostic;
  private transferLastDiagnosticAt: number = 0;
  @State fileOperationBusy: boolean = false;
  private nameDialog?: CustomDialogController;
  private pendingUploadName: string = '';
  private uploadFolderBytes: number = 0;
  private uploadFolderFiles: number = 0;
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
  private keyboardAvoidModeBeforePanel: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private keyboardAvoidModeChanged: boolean = false;

  aboutToAppear(): void {
    this.remotePageVisible = true;
    this.fileOnly = ConnectionService.isFileOnly();
    RemoteDisplayPolicy.setActive(!this.fileOnly);
    RustDeskNapi.appendDiagnosticLog('remote-page', 'about_to_appear')
    this.resetRemoteViewportForSession();
    this.showRemoteSurface = true;
    this.connectedPeerId = AppStorage.get<string>('connectedPeerId') ?? '';
    this.insecureFallbackPromptShown = false;
    this.loadInputMode();
    this.loadLocalCursorPreference();
    this.loadEdgeAutoPanPreference();
    this.loadVirtualMousePreference();
    this.loadToolbarOrderPreferences();
    this.remoteAudioEnabled = RustDeskNapi.getOption('remote-audio-enabled') !== '0';
    RustDeskNapi.setRemoteAudioEnabled(this.remoteAudioEnabled);
    this.showGestureHelp = RustDeskNapi.getOption('mobile-gesture-help-shown') !== '1';
    let status: number = RustDeskNapi.getConnectionStatus();
    this.connectionStatus = status as ConnectionStatus;
    if (status === ConnectionStatus.CONNECTED) this.loadInputCompatibility();
    this.connectingStartedAt = status === ConnectionStatus.CONNECTING ? Date.now() : 0;
    if (status === ConnectionStatus.WAITING_2FA) {
      this.enableTrustedDevices = RustDeskNapi.getEnableTrustedDevices();
    }
    this.startPolling();
    if (this.fileOnly) { this.showGestureHelp = false; return; }
    this.startRemoteCursorPolling();
    this.startNativeMousePolling();
    CommunicationService.start(() => {
      this.communicationUnread = CommunicationService.unread;
      this.communicationCallActive = CommunicationService.callState === 1 || CommunicationService.callState === 2;
    });
  }

  aboutToDisappear(): void {
    this.remotePageVisible = false;
    this.waylandPermissionEpoch++;
    this.uploadGeneration++;
    SessionRecording.stop(1);
    if (this.fileOperationTimer !== -1) clearTimeout(this.fileOperationTimer);
    this.fileOperationTrace?.end('cancelled');
    this.transferTrace?.end('cancelled', { bytes: this.transferTransferredBytes });
    RustDeskNapi.cancelFileOperation();
    this.clearUploadQueue();
    RemoteDisplayPolicy.setActive(false);
    CommunicationService.dispose();
    RustDeskNapi.appendDiagnosticLog('remote-page', 'about_to_disappear')
    if (this.toolbarTimer !== -1) { clearTimeout(this.toolbarTimer); }
    if (this.statusTimer !== -1) { clearTimeout(this.statusTimer); }
    this.stopFramePolling();
    if (this.cursorTimer !== -1) { clearTimeout(this.cursorTimer); }
    this.stopNativeMousePolling();
    this.cancelPointerHoverExit();
    this.stopEdgeAutoPan();
    this.releaseVirtualMouseButtons();
    this.releaseHeldMouseButtons('page_disappear');
    this.releaseRemoteNavigationKeys('page_disappear');
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
    this.restoreKeyboardAvoidMode();
    this.pointerOverRemoteViewport = false;
    this.setSystemPointerHidden(false);
    this.restoreFullscreenOnLeave();
  }

  onBackPress(): boolean {
    if (this.fullscreenTransitioning) return true;
    if (this.showCommunicationPanel) {
      this.closeCommunication();
      return true;
    }
    if (this.showToolbarOrderEditor) {
      this.showToolbarOrderEditor = false;
      return true;
    }
    if (this.showKeyboardPanel) {
      this.closeRemoteKeyboard();
      return true;
    }
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
      this.removeSandboxTree(this.pendingUploadPath);
    } catch (_e) {
    }
    this.pendingUploadPath = '';
  }

  startPolling(): void {
    let poll = () => {
      if (this.recordingActive && (!SessionRecording.active() || RustDeskNapi.getConnectionStatus() !== ConnectionStatus.CONNECTED)) {
        SessionRecording.stop(2); this.recordingActive = false;
        this.showFileToast('录像已停止，可在录像列表中导出；若未收到关键帧则无有效画面');
      }
      let status: number = RustDeskNapi.getConnectionStatus();
      let now: number = Date.now();
      if (status === ConnectionStatus.CONNECTING && RustDeskNapi.getConnectionRoute() === 1 &&
        !RemoteSessionBackgroundTask.isAppBackground()) {
        if (this.directLoginStartedAt === 0) this.directLoginStartedAt = now;
        if (now - this.directLoginStartedAt >= 10000 && this.retryStalledDirectConnection('login_timeout')) {
          status = ConnectionStatus.CONNECTING;
        }
      } else {
        this.directLoginStartedAt = 0;
      }
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
      if (status === ConnectionStatus.FAILED) {
        const failedMessage: string = ConnectionService.getLastConnectionError();
        if (ConnectionService.recoverInterruptedSession(failedMessage)) {
          this.videoWaitingHint = '网络传输中断，正在安全重连…';
          this.resetRemoteViewportForSession();
          this.displayStateInitialized = false;
          status = ConnectionStatus.CONNECTING;
        }
        const recoveryHint: string = ConnectionService.retryRecoverableConnectionFailure(failedMessage);
        if (recoveryHint.length > 0) {
          this.resetRemoteViewportForSession();
          this.displayStateInitialized = false;
          this.directLoginStartedAt = 0;
          this.connectingStartedAt = now;
          this.connectionError = '';
          this.videoWaitingHint = recoveryHint;
          status = ConnectionStatus.CONNECTING;
        }
      }
      this.connectionStatus = status as ConnectionStatus;
      ConnectionService.observeSession(status);
      if (status === ConnectionStatus.CONNECTED && !this.inputCompatibilityLoaded && !this.fileOnly) {
        this.loadInputCompatibility();
      } else if (status !== ConnectionStatus.CONNECTED) {
        this.inputCompatibilityLoaded = false;
        this.waylandTextAllowed = false;
        this.waylandPermissionEpoch++;
        this.relativePointerSampleValid = false;
      }
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
        if (!this.insecureFallbackPromptShown && ConnectionService.canRetryWithoutEncryption()) {
          this.insecureFallbackPromptShown = true;
          this.showInsecureFallbackPrompt();
        }
      }
      if (status === ConnectionStatus.CONNECTED && !this.fileOnly && now - this.lastDisplayPollAt > 2000) {
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
        this.canSendCtrlAltDel = ConnectionService.canSendCtrlAltDel();
        const nextPrivacyState: number = RustDeskNapi.getPrivacyModeState();
        if (nextPrivacyState === -2 && this.privacyModeState !== -2) {
          this.showFileToast('隐私屏未启用：被控端不支持、未授权或启用失败');
        }
        this.privacyModeState = nextPrivacyState;
      }
      if (status === ConnectionStatus.CONNECTED) {
        if (!this.fileOnly) this.ensureClipboardSyncRunning();
        this.pollFileTransferStatus();
      }
      if (status !== ConnectionStatus.CONNECTED) {
        this.navigationKeys.reset();
        this.keyboardComposing = false;
        this.displayStateInitialized = false;
        this.isPeerAndroid = false;
        this.privacyModeState = 0;
        this.canSendCtrlAltDel = false;
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
    this.relativePointerSampleValid = false;
    this.componentWidth = newValue.width as number;
    this.componentHeight = newValue.height as number;
    if (this.lastSurfaceWidth <= 0 || this.lastSurfaceHeight <= 0) {
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
      if (frame.generation !== undefined && frame.generation !== this.videoSessionGeneration) {
        this.videoSessionGeneration = frame.generation;
        this.resetRemoteViewportForSession();
        this.lastStatsTime = 0;
        this.lastStatsFrames = 0;
        this.lastStatsBytes = 0;
        this.smoothFps = 0;
        this.smoothKbps = 0;
      }
      const security: number = frame.security ?? 0;
      if (security === 2 && this.peerSecurityState !== 2) {
        try {
          this.getUIContext().getPromptAction().showToast({
            message: '此连接未启用端到端加密，请仅在可信网络使用', duration: 3000
          });
        } catch (_error) {}
      }
      this.peerSecurityState = security;
      // Quality information is independent from the latest-frame readiness
      // flag. Keep it updating while the native surface is already rendering,
      // including during a short surface/generation rebind.
      this.updateStats(frame);
      this.checkFirstVideoHealth(frame);
      this.checkDecoderHealth(frame);
      if (frame.hasFrame) {
        let firstVideoFrame: boolean = !this.hasVideo;
        if (firstVideoFrame) {
          this.hasVideo = true;
        }
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
    this.relativePointerSampleValid = false;
    ConnectionService.recordNetworkSnapshot();
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
    this.discardViewportPanFrame();
    this.relativePointerSampleValid = false;
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
    this.virtualMouseDragActive = false;
    this.virtualMouseInitialized = false;
    this.decoderHealthInitialized = false;
    this.lastDecoderInputFrames = 0;
    this.lastDecodedFrames = 0;
    this.decoderStallStartedAt = 0;
    this.videoRecoveryRefreshRequested = false;
    this.videoFallbackRequested = false;
    this.videoDecoderRestartRequested = false;
    this.firstVideoWaitStartedAt = 0;
    this.firstVideoRecoveryStage = 0;
    this.videoWaitingHint = '等待远端视频画面';
    this.speedText = '0 KB/s';
    this.fpsText = '0 fps';
    this.delayMs = 0;
    this.delayText = '-';
    this.targetBitrateText = '-';
    this.codecText = '等待视频';
    this.codecNameText = '等待视频';
    this.decoderText = '-';
  }

  checkFirstVideoHealth(frame: VideoFrameInfo): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || frame.hasFrame || this.hasVideo ||
      RemoteSessionBackgroundTask.isAppBackground()) {
      this.firstVideoWaitStartedAt = 0;
      return;
    }
    if (this.firstVideoWaitStartedAt === 0) {
      this.firstVideoWaitStartedAt = Date.now();
    }
    const elapsed: number = Date.now() - this.firstVideoWaitStartedAt;
    if (elapsed >= 4000 && this.firstVideoRecoveryStage === 0) {
      this.firstVideoRecoveryStage = 1;
      const result: number = RustDeskNapi.refreshVideo();
      RustDeskNapi.appendDiagnosticLog('video-recovery',
        `first_frame_missing action=refresh result=${result} input=${frame.totalFrames ?? 0}`);
    }
    if (elapsed >= 10000 && this.firstVideoRecoveryStage === 1) {
      this.firstVideoRecoveryStage = 2;
      if ((frame.totalFrames ?? 0) === 0 && this.retryStalledDirectConnection('first_frame_timeout')) {
        return;
      }
      // Renegotiate only when no encoded frames arrive. Decoder stalls have
      // their own recovery path below, to avoid repeatedly changing codecs.
      if ((frame.totalFrames ?? 0) === 0 && !this.videoFallbackRequested) {
        const result: number = RustDeskNapi.fallbackVideoToVp9();
        this.videoFallbackRequested = result === 0 || result === -3;
        RustDeskNapi.appendDiagnosticLog('video-recovery',
          `first_frame_missing action=negotiate_vp9 result=${result}`);
      }
    }
    if (elapsed >= 20000 && this.firstVideoRecoveryStage === 2) {
      this.firstVideoRecoveryStage = 3;
      this.videoWaitingHint = (frame.totalFrames ?? 0) === 0 ?
        '已连接，但远端未发送画面。请检查远端屏幕录制权限或重连，并导出诊断日志。' :
        '已收到视频，但暂未显示画面。请重连并导出诊断日志。';
      RustDeskNapi.appendDiagnosticLog('video-recovery',
        `first_frame_missing recovery_exhausted input=${frame.totalFrames ?? 0} decoded=${frame.decodedFrames ?? 0}`);
    }
  }

  retryStalledDirectConnection(reason: string): boolean {
    if (!ConnectionService.retryDirectViaRelay(reason)) return false;
    this.resetRemoteViewportForSession();
    this.displayStateInitialized = false;
    this.directLoginStartedAt = 0;
    this.connectingStartedAt = 0;
    this.connectionStatus = ConnectionStatus.CONNECTING;
    this.videoWaitingHint = '直连未收到响应，正在通过中继重试';
    return true;
  }

  checkDecoderHealth(frame: VideoFrameInfo): void {
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || RemoteSessionBackgroundTask.isAppBackground()) {
      this.decoderStallStartedAt = 0;
      return;
    }
    const totalFrames: number = frame.totalFrames ?? 0;
    const decodedFrames: number = frame.renderedFrames ?? frame.decodedFrames ?? 0;
    const codec: number = frame.codec ?? 0;
    if (!this.decoderHealthInitialized) {
      this.decoderHealthInitialized = true;
      this.lastDecoderInputFrames = totalFrames;
      this.lastDecodedFrames = decodedFrames;
      if (totalFrames > 0 && decodedFrames === 0 && codec > 0) {
        this.decoderStallStartedAt = Date.now();
      }
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
      if (stalledFor >= 3500 && !this.videoDecoderRestartRequested) {
        this.videoDecoderRestartRequested = true;
        const result: number = RustDeskNapi.restartVideoDecoder();
        RustDeskNapi.appendDiagnosticLog('video-recovery',
          `codec=${codecName} stalled action=restart_decoder result=${result}`);
      }
      if (codec !== 2 && stalledFor >= 7000) {
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
          if (this.cursorCompatibilityMode === 'separate') cursor.embedded = false;
          this.remoteCursorEmbedded = cursor.embedded;
          const now: number = Date.now();
          if (cursor.embedded && !this.embeddedCursorOverlayFallback && this.lastLocalPointerInputAt > 0 &&
            now - this.lastLocalPointerInputAt < 1000) {
            this.embeddedCursorOverlayFallback = true;
            RustDeskNapi.appendDiagnosticLog('input',
              `embedded_cursor_overlay_fallback display=${this.currentDisplay}`);
          }
          this.applyRemoteCursorPosition(cursor, now);
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

  applyRemoteCursorPosition(cursor: RemoteCursorPosition, now: number): void {
    if (!cursor.valid || cursor.sequence === this.lastRemoteCursorSequence) {
      return;
    }
    // Consume every sample once, including rejected coordinates. Replaying an
    // old off-screen sample would hide each newly predicted physical move.
    this.lastRemoteCursorSequence = cursor.sequence;
    const recentLocalInput: boolean = !this.relativeMouseEnabled && (this.localPointerGestureActive ||
      (this.lastLocalPointerInputAt > 0 && now - this.lastLocalPointerInputAt < LOCAL_CURSOR_ECHO_GUARD_MS));
    const inside: boolean = cursor.x >= 0 && cursor.y >= 0 &&
      cursor.x < this.remoteWidth && cursor.y < this.remoteHeight;
    if (!inside) {
      this.hasAuthoritativeRemoteCursor = false;
      if (!recentLocalInput) {
        this.showCursor = false;
      }
      RustDeskNapi.appendDiagnosticLog('input',
        `cursor_outside_display display=${this.currentDisplay} x=${cursor.x} y=${cursor.y} ` +
        `size=${this.remoteWidth}x${this.remoteHeight} local_guard=${recentLocalInput ? 1 : 0}`);
      return;
    }
    const dragReadyForRemoteSync: boolean = this.leftButtonHeld && this.leftButtonHeldAt > 0 &&
      now - this.leftButtonHeldAt >= LOCAL_CURSOR_ECHO_GUARD_MS;
    if (!this.preferAuthoritativeCursor && !dragReadyForRemoteSync && recentLocalInput) {
      return;
    }
    if (dragReadyForRemoteSync && !this.preferAuthoritativeCursor) {
      this.preferAuthoritativeCursor = true;
      RustDeskNapi.appendDiagnosticLog('input', 'cursor_prediction switched_to_remote_during_drag');
    }
    this.remoteCursorAbsX = cursor.x;
    this.remoteCursorAbsY = cursor.y;
    this.hasAuthoritativeRemoteCursor = true;
    this.updateCursorOverlayFromPosition(cursor.x, cursor.y);
    this.lastAbsX = cursor.x;
    this.lastAbsY = cursor.y;
    this.pointerInitialized = true;
    if (!this.virtualMouseDragActive) {
      this.alignVirtualMouseToRemotePosition(cursor.x, cursor.y);
    }
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
        this.drainNativeInputEvents();
        const now: number = Date.now();
        if (now - this.lastHardwareKeySyncAt >= 500) {
          this.lastHardwareKeySyncAt = now;
          this.syncHardwareKeyState();
        }
      } catch (_e) {
      }
      this.nativeMouseTimer = setTimeout(poll, 16);
    };
    this.nativeMouseTimer = setTimeout(poll, 16);
  }

  drainNativeInputEvents(): void {
    const events: NativeInputEvent[] = RustDeskNapi.takeNativeInputEvents();
    for (const event of events) {
      if (event.reset) {
        this.releaseHeldMouseButtons('input_queue_reset');
        this.releaseRemoteNavigationKeys('input_queue_reset');
        ConnectionService.releaseModifiers();
      } else if (event.key !== undefined) {
        this.handleNativeKeyInput(event.key);
      } else if (event.mouse !== undefined) {
        this.handleNativeMouseInput(event.mouse);
      }
    }
  }

  syncHardwareKeyState(): void {
    if (this.showCommunicationPanel) return;
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
        (state.modifierMask & 4) !== 0,
        (state.modifierMask & 8) !== 0
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
    if (this.showCommunicationPanel) return;
    if (event.hover >= 0) {
      this.handleRemoteHover(event.hover === 1);
      return;
    }
    this.lastNativeMouseEventAt = Date.now();
    if (event.modifierValid) {
      ConnectionService.syncNativeModifierState(event.modifierMask);
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
    if (this.showCommunicationPanel) return;
    if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    if (event.action !== 0 && event.action !== 1) {
      return;
    }
    if (event.capsLockValid) {
      ConnectionService.syncCapsLockState(event.capsLockOn);
    }
    const action: number = event.action === 0 ? 0 : 1;
    const controlCode: number = this.mapControlKeyCode(event.keyCode);
    if (isNavigationControlKey(controlCode)) {
      if (event.modifierValid) ConnectionService.syncNativeModifierState(event.modifierMask);
      this.forwardRemoteNavigationKey(controlCode, action === 0, 'native');
      return;
    }
    if (this.showKeyboardPanel) return;
    if (controlCode === 20) {
      ConnectionService.sendCapsLockEvent(action, event.capsLockValid ? event.capsLockOn : undefined);
      return;
    }
    if (controlCode > 0) {
      ConnectionService.sendKeyEvent(controlCode, action, event.keyCode);
      return;
    }
    if (event.modifierValid) {
      ConnectionService.syncNativeModifierState(event.modifierMask);
    }
    const hidCode: number = this.mapHarmonyKeyCodeToUsbHidCode(event.keyCode);
    if (hidCode > 0) {
      const eventModifierMask: number | undefined = event.modifierValid ? event.modifierMask : undefined;
      const letter: string = this.mapHarmonyKeyCodeToLetter(event.keyCode);
      if (letter.length > 0) {
        ConnectionService.sendLetterKeyEvent(letter, hidCode, action, eventModifierMask);
      } else {
        ConnectionService.sendPhysicalKeyEvent(hidCode, action, eventModifierMask);
      }
      if (action === 0) {
        RustDeskNapi.appendDiagnosticLog('input',
          `native_key_forwarded code=${event.keyCode} hid=${hidCode} modifiers=${event.modifierMask} ` +
          `modifier_valid=${event.modifierValid ? 1 : 0}`);
      }
    }
  }

  pollRemoteCursorImage(): void {
    let cursorData = RustDeskNapi.getRemoteCursorData(this.lastRemoteCursorImageSequence);
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

  controlSelectedBackgroundColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG;
  }

  controlSelectedTextColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT;
  }

  controlSelectedBorderColor(): ResourceColor {
    return this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER;
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
          if (this.fileOnly) { this.buildFileOnlySession(); }
          else { this.buildRemoteScreen(); }
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
      if (this.uploadStaging) {
        Column({ space: 12 }) {
          LoadingProgress().width(28).height(28)
          Text(this.uploadPreparationCancelled ? '正在取消准备…' : '正在准备发送文件…')
            .fontSize(14).fontColor(this.primaryTextColor())
          Button('取消').enabled(!this.uploadPreparationCancelled).onClick(() => {
            this.uploadPreparationCancelled = true;
            this.uploadGeneration++;
            this.clearUploadQueue();
          })
        }.padding(20).borderRadius(16).backgroundColor(this.isDarkMode ? '#202B3A' : '#FFFFFF')
      }
      if (this.connectionStatus === ConnectionStatus.CONNECTED && !this.fileOnly) {
        this.buildKeyboardShortcutOverlay();
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
      if (this.showToolbarOrderEditor && this.connectionStatus === ConnectionStatus.CONNECTED) {
        this.buildToolbarOrderEditorOverlay();
      }
      if (this.connectionStatus === ConnectionStatus.CONNECTED && !this.fileOnly &&
        (this.isHandheldDevice() || this.isFullScreen || !this.isLargeLayout())) {
        this.buildFloatingToolbar();
      }
      if (this.connectionStatus === ConnectionStatus.CONNECTED && !this.fileOnly &&
        this.isFullScreen && !this.isHandheldDevice()) {
        this.buildPcFullscreenExitButton();
      }
      if (this.showCommunicationPanel) {
        CommunicationPanel({ onClose: () => { this.closeCommunication(); } });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : '#E7EEF8')
    .focusable(true)
    .onKeyEventDispatch((event: KeyEvent) => {
      return this.fileOnly ? false : this.handleRemoteKey(event);
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.relativePointerSampleValid = false;
      this.pageWidth = newValue.width as number;
      this.pageHeight = newValue.height as number;
      // A real rotation/window resize invalidates the pre-IME canvas snapshot.
      if (this.showKeyboardPanel && this.keyboardLayoutWidth > 0 &&
        Math.abs(this.pageWidth - this.keyboardLayoutWidth) > 32) {
        this.closeRemoteKeyboard();
      }
      this.handleHandheldLayoutChange();
      this.mobileActionsOffsetX = this.clampMobileActionsOffsetX(this.mobileActionsOffsetX);
      this.mobileActionsOffsetY = this.clampMobileActionsOffsetY(this.mobileActionsOffsetY);
      this.keyboardToolsOffsetX = this.clampKeyboardToolsOffsetX(this.keyboardToolsOffsetX);
      this.keyboardToolsOffsetY = this.clampKeyboardToolsOffsetY(this.keyboardToolsOffsetY);
      this.remoteToolbarOffsetX = this.clampRemoteToolbarOffsetX(this.remoteToolbarOffsetX);
      this.remoteToolbarOffsetY = this.clampRemoteToolbarOffsetY(this.remoteToolbarOffsetY);
      this.scheduleSurfaceRebindIfSizeChanged();
    });
  }

  @Builder
  buildFileOnlySession() {
    Column({ space: 20 }) {
      Text('文件传输').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
      Text('独立文件会话 · 不采集远端画面，不发送键鼠输入')
        .fontSize(13).fontColor(this.secondaryTextColor())
      Button('浏览 / 取回远端文件').enabled(!this.transferActive).onClick(() => { this.openRemoteDownloadBrowser(); })
      Button('发送本地文件（可多选）').enabled(!this.transferActive).onClick(() => { this.pickFileForUpload(); })
      Button(this.uploadStaging ? '正在准备文件…' : '发送整个文件夹').enabled(!this.transferActive && !this.uploadStaging)
        .onClick(() => { this.pickFolderForUpload(); })
      Button('断开').onClick(() => { this.disconnectSession(); })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(24)
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
        .onClick(() => { this.disconnectSession(); })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 6, ButtonType.Capsule));
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
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule));
        Button('验证')
          .layoutWeight(1)
          .height(44)
          .enabled(this.isTwoFactorCodeReady())
          .fontColor(Color.White)
          .backgroundColor(this.isTwoFactorCodeReady() ? RustDeskTheme.ACCENT : '#94A3B8')
          .borderRadius(8)
          .onClick(() => {
            this.submitTwoFactor();
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule));
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
      // Keep the viewport and XComponent in one stable branch. Only the
      // toolbar siblings change when entering/exiting immersive mode.
      Stack({ alignContent: Alignment.Bottom }) {
        Row() {
        Column() {
          this.buildRemoteViewportWithQualityMonitor();
        }
        .layoutWeight(1)
        .height('100%')
        if (!this.isFullScreen && this.isLargeLayout() && !this.isHandheldDevice()) {
          this.buildSideToolbar();
        }
        }
        .width('100%').height('100%')

      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.isFullScreen ? '#090D14' : (this.isDarkMode ? RustDeskTheme.BG_DARK : '#DCE5F2'));
  }

  @Builder
  buildPcFullscreenExitButton() {
    Button(this.fullscreenTransitioning ? '切换中…' : '退出全屏')
      .width(88)
      .height(36)
      .fontSize(12)
      .fontColor(Color.White)
      .backgroundColor('#99000000')
      .border({ width: 1, color: '#66FFFFFF' })
      .borderRadius(18)
      .enabled(!this.fullscreenTransitioning)
      .onClick(() => {
        this.exitFullScreen();
      })
      .onHover((isHovering: boolean) => {
        this.handleNonRemoteHover(isHovering);
      })
      .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 18, ButtonType.Capsule))
      .position({ x: Math.max(12, this.pageWidth - 100), y: 12 })
      .zIndex(70)
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 7, ButtonType.Capsule))
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
          Button('新建').height(36).fontSize(12)
            .enabled(!this.fileOperationBusy && !this.transferActive && !this.remoteDirectoryLoading && this.remoteDirectoryPath !== '/')
            .onClick(() => { this.editRemoteFileName(); })
          Button('刷新').height(36).fontSize(12).enabled(!this.remoteDirectoryLoading && !this.fileOperationBusy)
            .onClick(() => { this.openRemoteDirectory(this.remoteDirectoryPath); })
          Text(this.remoteDirectoryPath === '/' ? '此电脑' : this.remoteDirectoryPath)
            .layoutWeight(1)
            .fontSize(15)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row({ space: 6 }) {
          Text(this.remoteDirectoryLoading ? '读取中…' : `${this.getVisibleRemoteEntries().length} 项 · 文件夹优先`)
            .layoutWeight(1)
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
          Button(`排序：${this.remoteFileSortLabel()}`)
            .height(32)
            .padding({ left: 10, right: 10 })
            .fontSize(12)
            .fontColor(this.controlSelectedTextColor())
            .backgroundColor(this.controlSelectedBackgroundColor())
            .borderRadius(8)
            .bindMenu([
              { value: `${this.remoteFileSortField === 'name' ? '✓ ' : ''}名称`,
                action: () => { this.remoteFileSortField = 'name'; } },
              { value: `${this.remoteFileSortField === 'type' ? '✓ ' : ''}类型（扩展名）`,
                action: () => { this.remoteFileSortField = 'type'; } },
              { value: `${this.remoteFileSortField === 'size' ? '✓ ' : ''}大小`,
                action: () => { this.remoteFileSortField = 'size'; } },
              { value: `${this.remoteFileSortField === 'modified' ? '✓ ' : ''}修改时间`,
                action: () => { this.remoteFileSortField = 'modified'; } }
            ], { placement: Placement.BottomRight, enableArrow: true })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
          Button(this.remoteFileSortDescending ? '降序 ↓' : '升序 ↑')
            .height(32)
            .padding({ left: 8, right: 8 })
            .fontSize(12)
            .fontColor(this.primaryTextColor())
            .backgroundColor(this.mutedSurfaceColor())
            .borderRadius(8)
            .onClick(() => { this.remoteFileSortDescending = !this.remoteFileSortDescending; })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
        } else if (this.getVisibleRemoteEntries().length === 0) {
          Column({ space: 8 }) {
            Text(this.remoteFileBrowserMode === 'download' ? '此文件夹为空' : '没有子文件夹')
              .fontSize(15)
              .fontColor(this.secondaryTextColor())
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
                      .maxLines(3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.remoteEntryMetadata(entry))
                      .width('100%')
                      .fontSize(12)
                      .fontColor(this.secondaryTextColor())
                      .maxLines(2)
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
                  if (entry.entryType !== 3) {
                    Button('⋯').height(36).width(40).fontSize(20)
                      .enabled(!this.fileOperationBusy && !this.transferActive)
                      .bindMenu([
                        { value: '重命名', action: () => { this.editRemoteFileName(entry); } },
                        { value: '删除', action: () => { this.deleteRemoteEntry(entry); } }
                      ])
                  }
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

        if (this.fileOperationBusy) { Text('等待远端确认操作…').fontSize(12).fontColor(this.secondaryTextColor()) }
        if (this.remoteFileBrowserMode === 'upload') {
          Text(`待发送 ${this.uploadQueue.length + 1} 个项目 · 同名文件将覆盖；文件夹递归发送文件内容，空文件夹不保留`)
            .fontSize(12).fontColor(this.secondaryTextColor())
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
          } else {
            Button('发送到这里')
              .layoutWeight(1)
              .height(42)
              .borderRadius(8)
              .enabled(this.remoteDirectoryPath.length > 0 && this.remoteDirectoryPath !== '/' && !this.remoteDirectoryLoading)
              .backgroundColor(RustDeskTheme.ACCENT)
              .onClick(() => {
                AlertDialog.show({ title: '确认发送文件',
                  message: `即将发送 ${this.uploadQueue.length + 1} 个文件。同名远端文件会被覆盖，请确认目录正确。`,
                  primaryButton: { value: '取消', action: () => {} },
                  secondaryButton: { value: '发送', action: () => { this.startPendingFileUpload(); } } });
              })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
  buildRemoteViewportWithQualityMonitor() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // Only the containing visible area shrinks for the IME. Keep the canvas
      // and both cursor layers at their old size, centered in the visible area.
      Stack({ alignContent: Alignment.TopEnd }) {
        this.buildRemoteViewport();
        if (this.showVirtualMouse && this.isHandheldDevice()) {
          this.buildVirtualMousePointer();
          this.buildVirtualMouseOverlay();
        }
      }
      .width('100%')
      .height(this.getRemoteCanvasHeight())
      .constraintSize({ minHeight: this.keyboardViewportHeight })
      .align(Alignment.Center)
      .backgroundColor('#090D14')
      this.buildDraggableQualityMonitor();
    }
    .width('100%')
    .layoutWeight(1)
    .clip(true)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.qualityViewportWidth = Number(newValue.width);
      this.qualityViewportHeight = Number(newValue.height);
    })
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
          this.releaseRemoteNavigationKeys('input_blur');
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
          .onBlur(() => { this.releaseRemoteNavigationKeys('native_input_blur'); })
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
          Text(this.videoWaitingHint)
            .fontSize(12)
            .fontColor('#C3CBD5')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      }

      if (!this.suppressCompatibilityCursor() && (!this.relativeMouseEnabled || this.hasAuthoritativeRemoteCursor) &&
        this.showCursor && (!this.remoteCursorEmbedded || this.embeddedCursorOverlayFallback || this.isPanMode) &&
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
        .backgroundColor(RustDeskTheme.ACCENT)
        .position({ x: 12, y: 12 })
        .zIndex(30)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
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
        this.syncVirtualMouseToCurrentPointer();
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
        .onClick(() => { this.disconnectSession(); })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule));
      Button(translate('Back')).fontColor(this.primaryTextColor()).backgroundColor(this.mutedSurfaceColor()).borderRadius(8)
        .onClick(() => { this.disconnectSession(); })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule));
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  floatingPanelTransition(): TransitionEffect {
    return TransitionEffect.OPACITY.combine(
      TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: 0, centerY: 0 }));
  }

  setFloatingPanelCollapsed(keyboard: boolean, collapsed: boolean): void {
    // Keep the same top-left anchor and never refocus the IME or release modifiers.
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      if (keyboard) {
        this.keyboardToolsCollapsed = collapsed;
      } else {
        this.remoteToolbarCollapsed = collapsed;
      }
    });
  }

  @Builder
  buildFloatingCollapseButton(keyboard: boolean) {
    Button(this.isHandheldLandscape() || (!keyboard && this.isFullScreen && !this.isHandheldDevice()) ? '⌃' : '‹')
      .width(34)
      .height(38)
      .padding(0)
      .fontSize(24)
      .fontColor(this.primaryTextColor())
      .backgroundColor(this.isDarkMode ? '#991C222D' : '#99F7F9FD')
      .border({ width: 1, color: this.themeBorderColor() })
      .borderRadius(8)
      .focusable(false)
      .accessibilityText('收起')
      .onClick(() => {
        this.setFloatingPanelCollapsed(keyboard, true);
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  @Builder
  buildFloatingDragHandle(keyboard: boolean) {
    Button('⋮')
      .width(this.isHandheldLandscape() ? 42 : (keyboard ? 24 : 20))
      .height(38)
      .padding(0)
      .fontSize(18)
      .fontColor(this.secondaryTextColor())
      .backgroundColor(Color.Transparent)
      .focusable(false)
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 4 })
          .onActionStart(() => {
            if (keyboard) this.beginKeyboardToolsDrag(); else this.beginRemoteToolbarDrag();
          })
          .onActionUpdate((event: GestureEvent) => {
            if (keyboard) {
              this.updateKeyboardToolsDrag(event.offsetX, event.offsetY);
            } else {
              this.updateRemoteToolbarDrag(event.offsetX, event.offsetY);
            }
          })
      )
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
  }

  @Builder
  buildControlToolbarItems(vertical: boolean) {
    ForEach(this.controlToolbarOrder, (item: string) => {
      this.buildControlToolbarItem(item, vertical)
    }, (item: string) =>
      `control-${item}-${this.currentDisplay}-${this.displayCount}-${this.showVirtualMouse ? 1 : 0}`)
  }

  @Builder
  buildControlToolbarItem(item: string, vertical: boolean) {
    if (item === 'displays' && this.displayCount > 1) {
      ForEach(this.makeDisplayIndexes(), (display: number) => {
        Button(`屏${display + 1}`)
          .width(vertical ? 80 : 44)
          .height(40)
          .padding({ left: 2, right: 2 })
          .fontSize(12)
          .fontWeight(display === this.currentDisplay ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
          .fontColor(display === this.currentDisplay ?
            this.controlSelectedTextColor() : this.primaryTextColor())
          .backgroundColor(display === this.currentDisplay ?
            this.controlSelectedBackgroundColor() : this.mutedSurfaceColor())
          .border({ width: 1, color: display === this.currentDisplay ?
            this.controlSelectedBorderColor() : this.themeBorderColor() })
          .borderRadius(8)
          .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => {
            this.openToolbarOrderEditor('control', 'displays');
          }))
          .onClick(() => { this.switchDisplay(display); })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
      }, (display: number) => `${display}-${this.currentDisplay}`)
    } else if (item === 'input') {
      this.buildInputModeButton(vertical ? 80 : 56, vertical, item)
    } else if (item === 'virtualMouse' && this.isHandheldDevice()) {
      this.buildToolbarButton(this.showVirtualMouse ? '关闭虚拟鼠标' : '虚拟鼠标', vertical ? 80 : 82,
        this.showVirtualMouse, false, true, () => {
          this.setVirtualMouseEnabled(!this.showVirtualMouse);
        }, item)
    } else if (item === 'edgePan' && this.canPanViewport()) {
      this.buildEdgeAutoPanButton(vertical ? 80 : 78, item)
    } else if (item === 'keyboard') {
      this.buildToolbarButton('键盘', vertical ? 80 : 56, this.showKeyboardPanel, false, true, () => {
        this.toggleRemoteKeyboard();
      }, item)
    } else if (item === 'mobileActions' && this.isPeerAndroid) {
      this.buildToolbarButton('手机操作', vertical ? 80 : 76, this.showMobileActions, false, true, () => {
        this.showMobileActions = true;
      }, item)
    } else if (item === 'gestureHelp') {
      this.buildToolbarButton(vertical ? '手势说明' : '手势', vertical ? 80 : 54, false, false, true, () => {
        this.showGestureHelp = true;
      }, item)
    } else if (item === 'pan' && this.canPanViewport()) {
      this.buildToolbarButton(this.isPanMode ? '结束移动' : '移动画面', vertical ? 80 : 78,
        this.isPanMode, false, true, () => { this.setPanMode(!this.isPanMode); }, item)
    } else if (item === 'chat') {
      this.buildToolbarButton(this.chatToolbarLabel(), vertical ? 80 : 76,
        this.communicationCallActive, false, true, () => { this.openCommunication(); }, item)
    } else if (item === 'upload') {
      this.buildToolbarButton('发送文件', vertical ? 80 : 82, false, false, !this.transferActive, () => {
        this.pickFileForUpload();
      }, item)
    } else if (item === 'download') {
      this.buildToolbarButton('取回文件', vertical ? 80 : 82, false, false, !this.transferActive, () => {
        this.openRemoteDownloadBrowser();
      }, item)
    } else if (item === 'uploadFolder') {
      this.buildToolbarButton('发送文件夹', 92, false, false, !this.transferActive && !this.uploadStaging,
        () => { this.pickFolderForUpload(); }, item)
    } else if (item === 'recording') {
      this.buildToolbarButton(this.recordingActive ? '停止录像' : '录像', 80, this.recordingActive, false, true, () => {
        if (this.recordingActive) { SessionRecording.stop(); this.recordingActive = false; this.recordingDialog.open(); }
        else AlertDialog.show({ title: '开始远控录像', message: '录像仅包含远端画面，不含音频。期间将请求 VP9 编码；请确认已获得必要授权。最长保存到约 4GB，切换显示器或分辨率后可能自动停止。',
          primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '开始', action: () => {
            this.recordingActive = SessionRecording.begin(getContext(this) as common.UIAbilityContext);
            if (!this.recordingActive) this.showFileToast('无法开始录像，请检查连接和可用空间');
          } } });
      }, item)
    } else if (item === 'recordings') {
      this.buildToolbarButton('录像列表', 80, false, false, true, () => { this.recordingDialog.open(); }, item)
    } else if (item === 'clipboard') {
      this.buildToolbarButton(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关', vertical ? 80 : 82,
        this.clipboardSyncEnabled, false, true, () => { this.toggleClipboardSync(); }, item)
    } else if (item === 'privacy' && !this.isPeerAndroid) {
      this.buildToolbarButton(this.privacyModeState === 2 ? '关闭隐私屏' :
        (this.privacyModeState === 1 ? '隐私屏处理中' : '隐私屏'), vertical ? 80 : 96,
        this.privacyModeState === 2, false, this.privacyModeState !== 1, () => {
          this.togglePrivacyMode();
        }, item)
    } else if (item === 'zoomIn') {
      this.buildToolbarButton('+', vertical ? 80 : 40, false, false, true, () => {
        this.adjustZoom(0.25);
      }, item)
    } else if (item === 'zoomOut') {
      this.buildToolbarButton('-', vertical ? 80 : 40, false, false, true, () => {
        this.adjustZoom(-0.25);
      }, item)
    } else if (item === 'fullscreen') {
      this.buildFullscreenButton(vertical ? 80 : 68, item)
    } else if (item === 'orientation' && this.isHandheldDevice()) {
      this.buildToolbarButton(this.remoteLandscapeLocked ? '自动旋转' : '横屏', 88,
        this.remoteLandscapeLocked, false, true, () => {
          RemoteDisplayPolicy.toggleLandscape();
        }, item)
    } else if (item === 'disconnect') {
      this.buildToolbarButton('断开', vertical ? 80 : 64, false, true, true, () => {
        this.disconnectSession();
      }, item)
    }
  }

  openToolbarOrderEditor(kind: string, _item: string): void {
    this.toolbarOrderEditorKind = kind;
    this.showToolbarOrderEditor = true;
  }

  chatToolbarLabel(): string {
    if (this.communicationUnread > 0) return `聊天 ${this.communicationUnread}`;
    return this.communicationCallActive ? '通话中' : '聊天';
  }

  openCommunication(): void {
    this.closeRemoteKeyboard();
    this.releaseHeldMouseButtons('open_chat');
    this.releaseVirtualMouseButtons();
    this.stopEdgeAutoPan();
    ConnectionService.releaseModifiers();
    this.showCommunicationPanel = true;
    this.setSystemPointerHidden(false);
    this.applyKeyboardResizeMode();
  }

  closeCommunication(): void {
    RustDeskNapi.takeNativeInputEvents();
    this.showCommunicationPanel = false;
    this.restoreKeyboardAvoidMode();
    this.requestRemoteInputFocus();
  }

  toolbarOrderLabel(item: string): string {
    switch (item) {
      case 'displays': return '屏幕切换';
      case 'input': return '鼠标 / 触摸模式';
      case 'virtualMouse': return '虚拟鼠标';
      case 'edgePan': return '边缘跟随';
      case 'keyboard': return '键盘';
      case 'mobileActions': return '手机操作';
      case 'gestureHelp': return '手势说明';
      case 'pan': return '移动画面';
      case 'chat': return '聊天与语音';
      case 'upload': return '发送文件';
      case 'download': return '取回文件';
      case 'clipboard': return '剪贴板';
      case 'privacy': return '隐私屏';
      case 'recording': return '开始 / 停止录像';
      case 'uploadFolder': return '发送整个文件夹';
      case 'recordings': return '录像列表';
      case 'zoomIn': return '放大';
      case 'zoomOut': return '缩小';
      case 'fullscreen': return '全屏';
      case 'orientation': return '横屏 / 自动旋转';
      case 'disconnect': return '断开';
      case 'ctrl': return 'Ctrl';
      case 'alt': return 'Alt';
      case 'shift': return 'Shift';
      case 'meta': return 'Win / Cmd';
      case 'function': return 'Fn 功能键';
      case 'more': return '更多按键';
      case 'release': return '释放修饰键';
      case 'Left': return '← 向左';
      case 'Up': return '↑ 向上';
      case 'Down': return '↓ 向下';
      case 'Right': return '→ 向右';
      default: return item;
    }
  }

  moveToolbarOrderItem(kind: string, index: number, target: number): void {
    const source: string[] = kind === 'keyboardMore' ? this.keyboardMoreOrder :
      (kind === 'keyboard' ? this.keyboardToolbarOrder : this.controlToolbarOrder);
    if (!Number.isInteger(index) || !Number.isInteger(target) || index === target ||
      index < 0 || index >= source.length || target < 0 || target >= source.length) return;
    const updated: string[] = source.slice();
    const item: string = updated[index];
    updated.splice(index, 1);
    updated.splice(target, 0, item);
    if (kind === 'keyboardMore') this.keyboardMoreOrder = updated;
    else if (kind === 'keyboard') this.keyboardToolbarOrder = updated;
    else this.controlToolbarOrder = updated;
    this.saveToolbarOrder(kind);
  }

  resetToolbarOrder(kind: string): void {
    if (kind === 'keyboardMore') {
      this.keyboardMoreOrder = KEYBOARD_MORE_DEFAULT_ORDER.slice();
    } else if (kind === 'keyboard') {
      this.keyboardToolbarOrder = KEYBOARD_TOOLBAR_DEFAULT_ORDER.slice();
    } else {
      this.controlToolbarOrder = CONTROL_TOOLBAR_DEFAULT_ORDER.slice();
    }
    this.saveToolbarOrder(kind);
  }

  @Builder
  buildToolbarOrderEditorOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text(this.toolbarOrderEditorKind === 'keyboardMore' ? '调整“更多”按键顺序' :
              (this.toolbarOrderEditorKind === 'keyboard' ? '调整“键”按钮顺序' : '调整“控”按钮顺序'))
              .fontSize(20)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
              .fontColor(this.primaryTextColor())
            Text('长按条目上下拖动，松手自动保存顺序')
              .fontSize(11)
              .fontColor(this.secondaryTextColor())
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button('完成')
            .height(34)
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor(RustDeskTheme.ACCENT)
            .borderRadius(8)
            .onClick(() => { this.showToolbarOrderEditor = false; })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
        }
        .width('100%')

        List({ space: 6 }) {
            ForEach(this.toolbarOrderEditorKind === 'keyboardMore' ? this.keyboardMoreOrder :
              (this.toolbarOrderEditorKind === 'keyboard' ? this.keyboardToolbarOrder : this.controlToolbarOrder),
              (item: string, index: number) => {
              ListItem() {
              Row({ space: 8 }) {
                Text(`${index + 1}`)
                  .width(28)
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
                  .textAlign(TextAlign.Center)
                Text(this.toolbarOrderLabel(item))
                  .layoutWeight(1)
                  .fontSize(14)
                  .fontColor(this.primaryTextColor())
                Column({ space: 4 }) {
                  Blank().width(16).height(1.5).backgroundColor(this.secondaryTextColor()).borderRadius(1)
                  Blank().width(16).height(1.5).backgroundColor(this.secondaryTextColor()).borderRadius(1)
                  Blank().width(16).height(1.5).backgroundColor(this.secondaryTextColor()).borderRadius(1)
                }
                .width(36)
                .height(42)
                .justifyContent(FlexAlign.Center)
                .opacity(0.65)
                .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .height(48)
              .padding({ left: 6, right: 8 })
              .backgroundColor(this.mutedSurfaceColor())
              .borderRadius(12)
              }
              .accessibilityText(`${this.toolbarOrderLabel(item)}，长按拖动调整顺序`)
            }, (item: string) => `order-${this.toolbarOrderEditorKind}-${item}`)
            .onMove((from: number, to: number) => {
              this.moveToolbarOrderItem(this.toolbarOrderEditorKind, from, to);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)

        Button('恢复默认排序')
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor(RustDeskTheme.ACCENT)
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(8)
          .onClick(() => { this.resetToolbarOrder(this.toolbarOrderEditorKind); })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
      }
      .width(this.isHandheldLandscape() ? 420 : '88%')
      .height(this.isHandheldLandscape() ? '86%' : '72%')
      .padding(16)
      .backgroundColor(this.panelColor())
      .border({ width: 1, color: this.themeBorderColor() })
      .borderRadius(16)
      .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .zIndex(95)
  }

  @Builder
  buildFloatingToolbar() {
    Stack({ alignContent: Alignment.TopStart }) {
    if (this.remoteToolbarCollapsed) {
      Button() {
        Text('控')
          .fontSize(16)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.controlSelectedTextColor())
      }
      .width(56)
      .height(this.getRemoteToolbarCollapsedSize())
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(16)
      .transition(this.floatingPanelTransition())
      .focusable(false)
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 4 })
          .onActionStart(() => {
            this.beginRemoteToolbarDrag();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updateRemoteToolbarDrag(event.offsetX, event.offsetY);
          })
      )
      .onClick(() => {
        this.setFloatingPanelCollapsed(false, false);
      })
      .onHover((isHovering: boolean) => {
        this.handleNonRemoteHover(isHovering);
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 16, ButtonType.Capsule))
    } else {
      if (this.isHandheldLandscape() || (this.isFullScreen && !this.isHandheldDevice())) {
        Column({ space: 5 }) {
          Row({ space: 4 }) {
            this.buildFloatingDragHandle(false)
            Blank()
            this.buildFloatingCollapseButton(false)
          }
          .width('100%')
          .height(38)
          Scroll() {
            Column({ space: 6 }) {
              this.buildControlToolbarItems(true)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
        }
        .width(this.getRemoteToolbarWidth())
        .height(this.getRemoteToolbarHeight())
        .padding(7)
        .transition(this.floatingPanelTransition())
        .onHover((isHovering: boolean) => {
          this.handleNonRemoteHover(isHovering);
        })
      } else {
        Row({ space: 4 }) {
          this.buildFloatingDragHandle(false)
          Scroll() {
            Row({ space: 6 }) {
              this.buildControlToolbarItems(false)
            }
            .height(40)
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .height(40)
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          this.buildFloatingCollapseButton(false)
        }
        .width(this.getRemoteToolbarWidth())
        .height(this.getRemoteToolbarHeight())
        .padding(7)
        .transition(this.floatingPanelTransition())
        .onHover((isHovering: boolean) => {
          this.handleNonRemoteHover(isHovering);
        })
      }
    }
    }
    .width(this.getRemoteToolbarCurrentWidth())
    .height(this.getRemoteToolbarCurrentHeight())
    .backgroundColor(this.isDarkMode ? '#A61B2638' : '#A6FFFFFF')
    .border({ width: 1, color: this.isDarkMode ? '#805C93E6' : '#80518BDD' })
    .borderRadius(16)
    .clip(true)
    .shadow({ radius: 12, color: '#26000000', offsetX: 0, offsetY: 4 })
    .position({ x: this.getRemoteToolbarX(), y: this.getRemoteToolbarY() })
    .zIndex(60)
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
              .fontColor(display === this.currentDisplay ?
                this.controlSelectedTextColor() : this.primaryTextColor())
              .backgroundColor(display === this.currentDisplay ?
                this.controlSelectedBackgroundColor() : this.mutedSurfaceColor())
              .border({
                width: 1,
                color: display === this.currentDisplay ?
                  this.controlSelectedBorderColor() : this.themeBorderColor(),
              })
              .borderRadius(8)
              .onClick(() => {
                this.switchDisplay(display);
              })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
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
        this.buildToolbarButton(this.chatToolbarLabel(), 80, this.communicationCallActive, false, true, () => {
          this.openCommunication();
        });
        this.buildToolbarButton('发送文件', 80, false, false, !this.transferActive, () => {
          this.pickFileForUpload();
        })
        this.buildToolbarButton('取回文件', 80, false, false, !this.transferActive, () => {
          this.openRemoteDownloadBrowser();
        })
        this.buildToolbarButton(this.clipboardSyncEnabled ? '剪贴板开' : '剪贴板关', 80, this.clipboardSyncEnabled, false, true, () => {
          this.toggleClipboardSync();
        })
        if (!this.isPeerAndroid) {
          this.buildToolbarButton(this.privacyModeState === 2 ? '关闭隐私屏' : '隐私屏', 80,
            this.privacyModeState === 2, false, this.privacyModeState !== 1, () => { this.togglePrivacyMode(); })
        }
        this.buildToolbarButton('+', 80, false, false, true, () => {
          this.adjustZoom(0.25);
        })
        this.buildToolbarButton('-', 80, false, false, true, () => {
          this.adjustZoom(-0.25);
        })
        this.buildFullscreenButton(80)
        this.buildToolbarButton('断开', 80, false, true, true, () => {
          this.disconnectSession();
        })
      }
      .width(80)
      .alignItems(HorizontalAlign.Center)
    }
    .width(104)
    .height('96%')
    .margin({ top: 8, right: 8, bottom: 8 })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.isDarkMode ? '#F21B2638' : '#F7FFFFFF')
    .border({ width: 1, color: this.isDarkMode ? '#805C93E6' : '#80518BDD' })
    .borderRadius(15)
    .shadow({ radius: 18, color: '#44000000', offsetX: 0, offsetY: 6 })
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .onHover((isHovering: boolean) => {
      this.handleNonRemoteHover(isHovering);
    });
  }

  @Builder
  buildFullscreenButton(buttonWidth: number, orderKey: string = '') {
    // Read state in the Button observer, not through @Builder value parameters.
    Button(this.fullscreenTransitioning ? '切换中…' : (this.isFullScreen ? '退出全屏' : '全屏'))
      .width(buttonWidth)
      .height(40)
      .padding({ left: 2, right: 2 })
      .fontSize(12)
      .fontWeight(this.isFullScreen ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
      .fontColor(this.isFullScreen ? this.controlSelectedTextColor() : this.primaryTextColor())
      .backgroundColor(this.isFullScreen ? this.controlSelectedBackgroundColor() : this.mutedSurfaceColor())
      .border({ width: 1, color: this.isFullScreen ? this.controlSelectedBorderColor() : this.themeBorderColor() })
      .borderRadius(8)
      .enabled(!this.fullscreenTransitioning)
      .opacity(this.fullscreenTransitioning ? 0.6 : 1)
      .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => {
        if (orderKey.length > 0) this.openToolbarOrderEditor('control', orderKey);
      }))
      .onClick(() => {
        if (this.isFullScreen) this.exitFullScreen(); else this.enterFullScreen();
      })
      .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  @Builder
  buildToolbarButton(label: string, buttonWidth: number, selected: boolean, danger: boolean,
    enabled: boolean, onClick: () => void, orderKey: string = '') {
    Button(label)
      .width(buttonWidth)
      .height(40)
      .padding({ left: 2, right: 2 })
      .fontSize(label === '+' || label === '-' ? 18 : (buttonWidth <= 40 ? 11 : 12))
      .fontWeight(selected ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
      .fontColor(danger ? RustDeskTheme.ERROR :
        (selected ? this.controlSelectedTextColor() : this.primaryTextColor()))
      .backgroundColor(danger ? (this.isDarkMode ? RustDeskTheme.DANGER_SOFT_DARK : '#FDECEC') :
        (selected ? this.controlSelectedBackgroundColor() : this.mutedSurfaceColor()))
      .border({
        width: 1,
        color: selected ? this.controlSelectedBorderColor() :
          (danger ? (this.isDarkMode ? '#805C3B45' : '#F3C6CC') : this.themeBorderColor()),
      })
      .borderRadius(8)
      .enabled(enabled)
      .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => {
        if (orderKey.length > 0) this.openToolbarOrderEditor('control', orderKey);
      }))
      .onClick(() => {
        onClick();
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  @Builder
  buildEdgeAutoPanButton(buttonWidth: number, orderKey: string = '') {
    Button(this.edgeAutoPanEnabled ? '边缘跟随开' : '边缘跟随')
      .width(buttonWidth)
      .height(40)
      .padding({ left: 2, right: 2 })
      .fontSize(12)
      .fontWeight(this.edgeAutoPanEnabled ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
      .fontColor(this.edgeAutoPanEnabled ? this.controlSelectedTextColor() : this.primaryTextColor())
      .backgroundColor(this.edgeAutoPanEnabled ? this.controlSelectedBackgroundColor() : this.mutedSurfaceColor())
      .border({
        width: 1,
        color: this.edgeAutoPanEnabled ? this.controlSelectedBorderColor() : this.themeBorderColor(),
      })
      .borderRadius(8)
      .enabled(this.inputMode === INPUT_MODE_MOUSE)
      .opacity(this.inputMode === INPUT_MODE_MOUSE ? 1 : 0.55)
      .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => {
        if (orderKey.length > 0) this.openToolbarOrderEditor('control', orderKey);
      }))
      .onClick(() => {
        this.setEdgeAutoPanEnabled(!this.edgeAutoPanEnabled);
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  @Builder
  buildInputModeIcon(mode: string, size: number, selected: boolean) {
    Shape() {
      if (mode === INPUT_MODE_MOUSE) {
        Path()
          .commands('M 2 1 L 2 18 L 6.5 13.5 L 10 21 L 13 19.5 L 9.5 12.5 L 16 12.5 Z')
          .fill(selected ? this.controlSelectedTextColor() : this.primaryTextColor())
          .stroke(selected ? this.controlSelectedBorderColor() : this.themeBorderColor())
          .strokeWidth(1.2)
      } else {
        Path()
          .commands('M 8 11 L 8 4 C 8 2.7 9 2 10 2 C 11.1 2 12 2.8 12 4 L 12 10 L 13 6.8 C 13.3 5.8 14.2 5.3 15.1 5.6 C 16 5.9 16.4 6.8 16.1 7.7 L 15.3 10.5 L 17 8.2 C 17.6 7.4 18.6 7.3 19.3 7.9 C 20 8.5 20.1 9.5 19.5 10.2 L 16.2 15.5 C 15.1 17.2 13.3 18.2 11.3 18.2 L 9.5 18.2 C 7.8 18.2 6.3 17.4 5.3 16.1 L 2.7 12.7 C 2 11.8 2.1 10.6 3 9.9 C 3.8 9.3 4.9 9.4 5.6 10.1 Z')
          .fill(selected ? this.controlSelectedTextColor() : this.primaryTextColor())
          .stroke(selected ? this.controlSelectedBorderColor() : this.themeBorderColor())
          .strokeWidth(1.1)
      }
    }
    .viewPort({ x: 0, y: 0, width: 22, height: 22 })
    .width(size)
    .height(size)
  }

  @Builder
  buildInputModeButton(buttonWidth: number, vertical: boolean, orderKey: string = '') {
    Button() {
      if (vertical) {
        Column({ space: 1 }) {
          this.buildInputModeIcon(this.inputMode, 20, true)
          Text(this.inputMode === INPUT_MODE_MOUSE ? '鼠标' : '触摸')
            .fontSize(11)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.controlSelectedTextColor())
        }
        .justifyContent(FlexAlign.Center)
      } else {
        Text(this.inputMode === INPUT_MODE_MOUSE ? '鼠标' : '触摸')
          .width('100%')
          .fontSize(12)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.controlSelectedTextColor())
          .maxLines(1)
          .textAlign(TextAlign.Center)
      }
    }
    .width(buttonWidth)
    .height(vertical ? 48 : 40)
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
    .backgroundColor(this.controlSelectedBackgroundColor())
    .border({ width: 1, color: this.controlSelectedBorderColor() })
    .borderRadius(8)
    .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => {
      if (orderKey.length > 0) this.openToolbarOrderEditor('control', orderKey);
    }))
    .onClick(() => {
      this.toggleInputMode();
    })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  initializeVirtualMousePosition(force: boolean = false): void {
    if (this.virtualMouseInitialized && !force) return;
    const width: number = this.componentWidth > 0 ? this.componentWidth : 360;
    const height: number = this.componentHeight > 0 ? this.componentHeight : 640;
    this.virtualMouseX = this.clampVirtualMouseX((width - VIRTUAL_MOUSE_WIDTH) / 2);
    this.virtualMouseY = this.clampVirtualMouseY((height - VIRTUAL_MOUSE_HEIGHT) / 2);
    this.virtualMouseInitialized = true;
    this.syncVirtualMouseToCurrentPointer();
  }

  clampVirtualMouseX(value: number): number {
    const width: number = this.componentWidth > 0 ? this.componentWidth : 360;
    const controlMaxX: number = Math.max(0, width - VIRTUAL_MOUSE_WIDTH);
    const centerX: number = width / 2;
    const displayLeft: number = centerX + (this.getDisplayLeft() - centerX) * this.zoomScale + this.offsetX;
    const displayRight: number = centerX +
      (this.getDisplayLeft() + this.getDisplayWidth() - centerX) * this.zoomScale + this.offsetX;
    const minPointerX: number = Math.max(0, Math.min(width - 1, displayLeft));
    const maxPointerX: number = Math.max(minPointerX, Math.min(width - 1, displayRight - 1));
    return Math.max(0, Math.min(controlMaxX,
      Math.max(minPointerX - VIRTUAL_MOUSE_POINTER_HOT_X,
        Math.min(maxPointerX - VIRTUAL_MOUSE_POINTER_HOT_X, value))));
  }

  clampVirtualMouseY(value: number): number {
    const height: number = this.componentHeight > 0 ? this.componentHeight : 640;
    const controlMaxY: number = Math.max(0, height - VIRTUAL_MOUSE_HEIGHT);
    const centerY: number = height / 2;
    const displayTop: number = centerY + (this.getDisplayTop() - centerY) * this.zoomScale + this.offsetY;
    const displayBottom: number = centerY +
      (this.getDisplayTop() + this.getDisplayHeight() - centerY) * this.zoomScale + this.offsetY;
    const minPointerY: number = Math.max(0, Math.min(height - 1, displayTop));
    const maxPointerY: number = Math.max(minPointerY, Math.min(height - 1, displayBottom - 1));
    return Math.max(0, Math.min(controlMaxY,
      Math.max(minPointerY - VIRTUAL_MOUSE_POINTER_HOT_Y,
        Math.min(maxPointerY - VIRTUAL_MOUSE_POINTER_HOT_Y, value))));
  }

  alignVirtualMouseToRemotePosition(remoteX: number, remoteY: number): void {
    if (!this.showVirtualMouse || !this.isHandheldDevice() || this.componentWidth <= 0 ||
      this.componentHeight <= 0 || this.remoteWidth <= 0 || this.remoteHeight <= 0) {
      return;
    }
    if (this.offsetX < -this.getHorizontalPanLimit(this.zoomScale) ||
      this.offsetY < -this.getVerticalPanLimit(this.zoomScale)) {
      // In the black margin the control and its local arrow stay together;
      // a delayed remote cursor echo must not pull either back onto the image.
      return;
    }
    const visualPoint: RemotePoint = this.remotePointToVisual(remoteX, remoteY);
    this.virtualMouseX = this.clampVirtualMouseX(visualPoint.x - VIRTUAL_MOUSE_POINTER_HOT_X);
    this.virtualMouseY = this.clampVirtualMouseY(visualPoint.y - VIRTUAL_MOUSE_POINTER_HOT_Y);
    this.virtualMouseInitialized = true;
  }

  syncVirtualMouseToCurrentPointer(): void {
    if (!this.showVirtualMouse || this.virtualMouseDragActive || !this.pointerInitialized) return;
    if (this.hasAuthoritativeRemoteCursor) {
      this.alignVirtualMouseToRemotePosition(this.remoteCursorAbsX, this.remoteCursorAbsY);
    } else {
      this.alignVirtualMouseToRemotePosition(this.lastAbsX, this.lastAbsY);
    }
  }

  updatePointerFromVirtualMouse(): RemotePoint {
    this.markLocalPointerInput();
    const remotePoint: RemotePoint = this.visualPointToRemote(
      this.virtualMouseX + VIRTUAL_MOUSE_POINTER_HOT_X,
      this.virtualMouseY + VIRTUAL_MOUSE_POINTER_HOT_Y);
    const remoteRight: number = this.remotePointToVisual(this.remoteWidth, 0).x;
    if (this.remoteWidth > 0 && remoteRight <= this.componentWidth + 0.01 &&
      this.virtualMouseX + VIRTUAL_MOUSE_POINTER_HOT_X >= remoteRight - 1) {
      remotePoint.x = this.remoteWidth - 1;
    }
    const remoteBottom: number = this.remotePointToVisual(0, this.remoteHeight).y;
    if (this.remoteHeight > 0 && remoteBottom <= this.componentHeight + 0.01 &&
      this.virtualMouseY + VIRTUAL_MOUSE_POINTER_HOT_Y >= remoteBottom - 1) {
      remotePoint.y = this.remoteHeight - 1;
    }
    this.lastAbsX = remotePoint.x;
    this.lastAbsY = remotePoint.y;
    this.pointerInitialized = true;
    if (!this.preferAuthoritativeCursor) {
      this.remoteCursorAbsX = remotePoint.x;
      this.remoteCursorAbsY = remotePoint.y;
    }
    this.updateCursorOverlayFromPosition(remotePoint.x, remotePoint.y);
    return remotePoint;
  }

  beginVirtualMouseMove(): void {
    this.ensurePointerInitialized();
    this.initializeVirtualMousePosition();
    this.syncVirtualMouseToCurrentPointer();
    this.virtualMouseDragStartX = this.virtualMouseX;
    this.virtualMouseDragStartY = this.clampVirtualMouseY(this.virtualMouseY);
    this.virtualMouseLastPanX = 0;
    this.virtualMouseLastPanY = 0;
    this.virtualMouseDragActive = true;
    this.beginLocalPointerGesture();
  }

  updateVirtualMouseMove(offsetX: number, offsetY: number): void {
    const deltaX: number = offsetX - this.virtualMouseLastPanX;
    const deltaY: number = offsetY - this.virtualMouseLastPanY;
    this.virtualMouseLastPanX = offsetX;
    this.virtualMouseLastPanY = offsetY;
    if (Math.abs(deltaX) < 0.01 && Math.abs(deltaY) < 0.01) return;
    const follow: boolean = this.shouldFollowTouchMouse();
    const absoluteVirtual: boolean = !follow && !this.relativeMouseEnabled;
    const panLimitX: number = this.getHorizontalPanLimit(this.zoomScale);
    const panLimitY: number = this.getVerticalPanLimit(this.zoomScale);
    if (!this.relativeMouseEnabled) {
      // The mouse control and arrow are one visual unit. Once the entire
      // control reaches the viewport edge, consume further drag by panning
      // the image immediately; do not keep moving the arrow on its own.
      const controlMaxX: number = Math.max(0, this.componentWidth - VIRTUAL_MOUSE_WIDTH);
      const controlMaxY: number = Math.max(0, this.componentHeight - VIRTUAL_MOUSE_HEIGHT);
      this.virtualMouseX = Math.max(0, Math.min(this.virtualMouseX, controlMaxX));
      this.virtualMouseY = Math.max(0, Math.min(this.virtualMouseY, controlMaxY));
      if (deltaX > 0) {
        const cursorTravel: number = Math.min(deltaX, controlMaxX - this.virtualMouseX);
        this.virtualMouseX += cursorTravel;
        this.offsetX = Math.max(-panLimitX - VIRTUAL_MOUSE_RIGHT_OUTSIDE_MARGIN,
          this.offsetX - (deltaX - cursorTravel));
      } else if (deltaX < 0) {
        const blackMargin: number = Math.max(0, -panLimitX - this.offsetX);
        const retract: number = Math.min(-deltaX, blackMargin);
        this.offsetX += retract;
        this.virtualMouseX = Math.max(0, this.virtualMouseX + deltaX + retract);
      }
      if (deltaY > 0) {
        const cursorTravel: number = Math.min(deltaY, controlMaxY - this.virtualMouseY);
        this.virtualMouseY += cursorTravel;
        this.offsetY = Math.max(-panLimitY - VIRTUAL_MOUSE_BOTTOM_OUTSIDE_MARGIN,
          this.offsetY - (deltaY - cursorTravel));
      } else if (deltaY < 0) {
        const blackMargin: number = Math.max(0, -panLimitY - this.offsetY);
        const retract: number = Math.min(-deltaY, blackMargin);
        this.offsetY += retract;
        this.virtualMouseY = Math.max(0, this.virtualMouseY + deltaY + retract);
      }
      const groupedPoint: RemotePoint = this.updatePointerFromVirtualMouse();
      ConnectionService.sendMouseEvent(groupedPoint.x, groupedPoint.y, 0);
      if (!follow) this.updateEdgeAutoPan(groupedPoint.x, groupedPoint.y, true);
      return;
    }
    let cursorDeltaX: number = deltaX;
    if ((follow || absoluteVirtual) && cursorDeltaX < 0 && panLimitX > 0 && this.offsetX < -panLimitX) {
      // Retract the black area before moving the actual remote cursor left.
      const retracted: number = Math.min(-cursorDeltaX, -panLimitX - this.offsetX);
      this.offsetX += retracted;
      cursorDeltaX += retracted;
      this.alignVirtualMouseToRemotePosition(this.lastAbsX, this.lastAbsY);
    }
    const previousRemoteX: number = this.lastAbsX;
    let remotePoint: RemotePoint;
    if (absoluteVirtual) {
      const wantedX: number = this.virtualMouseX + cursorDeltaX;
      this.virtualMouseX = this.clampVirtualMouseX(wantedX);
      this.virtualMouseY = this.clampVirtualMouseY(this.virtualMouseY + deltaY);
      if (cursorDeltaX > 0 && panLimitX > 0) {
        let excess: number = Math.max(0, wantedX - this.virtualMouseX);
        const normalPan: number = Math.min(excess, Math.max(0, this.offsetX + panLimitX));
        this.offsetX -= normalPan;
        excess -= normalPan;
        this.offsetX = Math.max(-panLimitX - VIRTUAL_MOUSE_RIGHT_OUTSIDE_MARGIN, this.offsetX - excess);
        this.virtualMouseX = this.clampVirtualMouseX(wantedX);
      }
      remotePoint = this.updatePointerFromVirtualMouse();
      if (this.offsetX < -panLimitX) {
        this.alignVirtualMouseToRemotePosition(remotePoint.x, remotePoint.y);
      }
    } else {
      this.virtualMouseX = this.clampVirtualMouseX(this.virtualMouseDragStartX + offsetX);
      this.virtualMouseY = this.clampVirtualMouseY(this.virtualMouseDragStartY + offsetY);
      remotePoint = follow ? this.updateCenterFollowPointer(cursorDeltaX, deltaY, 1) :
        this.updatePointerFromDelta(deltaX, deltaY);
    }
    if (follow) {
      if (panLimitX > 0 && cursorDeltaX > 0 && remotePoint.x >= this.remoteWidth - 1) {
        const remotePixelScale: number = this.getDisplayWidth() * this.zoomScale / this.remoteWidth;
        const cursorTravel: number = Math.max(0, remotePoint.x - previousRemoteX) * remotePixelScale;
        const outsideTravel: number = Math.max(0, cursorDeltaX - cursorTravel);
        this.offsetX = Math.max(-panLimitX - VIRTUAL_MOUSE_RIGHT_OUTSIDE_MARGIN,
          this.offsetX - outsideTravel);
      }
      // The virtual mouse arrow remains at the remote edge, but the control
      // body extends into the newly exposed black area on its right.
      this.alignVirtualMouseToRemotePosition(remotePoint.x, remotePoint.y);
      this.virtualMouseDragStartX = this.virtualMouseX - offsetX;
      this.virtualMouseDragStartY = this.virtualMouseY - offsetY;
    }
    ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 0);
    if (!follow) this.updateEdgeAutoPan(remotePoint.x, remotePoint.y, true);
  }

  finishVirtualMouseMove(): void {
    this.virtualMouseLastPanX = 0;
    this.virtualMouseLastPanY = 0;
    this.virtualMouseDragActive = false;
    this.stopEdgeAutoPan();
    this.endLocalPointerGesture();
  }

  clickVirtualMouseButton(button: string): void {
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();
    this.ensurePointerInitialized();
    this.initializeVirtualMousePosition();
    const remotePoint: RemotePoint = this.updatePointerFromVirtualMouse();
    if (button === 'left') {
      this.sendLeftClick(remotePoint.x, remotePoint.y);
    } else if (button === 'right') {
      this.sendRightDown(remotePoint.x, remotePoint.y);
      this.sendRightUp(remotePoint.x, remotePoint.y, true);
    } else if (button === 'middle') {
      ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 5);
      ConnectionService.sendMouseEvent(remotePoint.x, remotePoint.y, 6);
    }
    RustDeskNapi.appendDiagnosticLog('input',
      `virtual_mouse_click button=${button} x=${Math.round(remotePoint.x)} y=${Math.round(remotePoint.y)}`);
  }

  beginVirtualMouseButtonDrag(button: string): void {
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();
    this.beginVirtualMouseMove();
    const remotePoint: RemotePoint = this.updatePointerFromVirtualMouse();
    if (button === 'left') {
      this.virtualMouseLeftDown = true;
      this.sendLeftDown(remotePoint.x, remotePoint.y);
    } else if (button === 'right') {
      this.virtualMouseRightDown = true;
      this.sendRightDown(remotePoint.x, remotePoint.y);
    }
    RustDeskNapi.appendDiagnosticLog('input',
      `virtual_mouse_drag_start button=${button} x=${Math.round(remotePoint.x)} y=${Math.round(remotePoint.y)}`);
  }

  finishVirtualMouseButtonDrag(button: string, cancelled: boolean = false): void {
    if (button === 'left' && this.virtualMouseLeftDown) {
      this.virtualMouseLeftDown = false;
      this.sendLeftUp(this.lastAbsX, this.lastAbsY, true);
    } else if (button === 'right' && this.virtualMouseRightDown) {
      this.virtualMouseRightDown = false;
      this.sendRightUp(this.lastAbsX, this.lastAbsY, true);
    }
    this.finishVirtualMouseMove();
    RustDeskNapi.appendDiagnosticLog('input',
      `virtual_mouse_drag_end button=${button} cancelled=${cancelled ? 1 : 0}`);
  }

  resetVirtualMouseButtonTouch(): void {
    this.virtualMouseButtonTouchActive = false;
    this.virtualMouseButtonTouchName = '';
    this.virtualMouseButtonTouchStartX = 0;
    this.virtualMouseButtonTouchStartY = 0;
  }

  clickVirtualMouseButtonFallback(button: string): void {
    if (Date.now() - this.virtualMouseLastTouchResolvedAt < 240) return;
    this.clickVirtualMouseButton(button);
  }

  handleVirtualMouseButtonTouch(button: string, event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Down && event.touches.length > 0) {
      this.resetVirtualMouseButtonTouch();
      this.virtualMouseButtonTouchActive = true;
      this.virtualMouseButtonTouchName = button;
      this.virtualMouseButtonTouchStartX = event.touches[0].x;
      this.virtualMouseButtonTouchStartY = event.touches[0].y;
      return;
    }
    if (!this.virtualMouseButtonTouchActive || this.virtualMouseButtonTouchName !== button) return;
    if (event.type === TouchType.Move && event.touches.length > 0) {
      const offsetX: number = event.touches[0].x - this.virtualMouseButtonTouchStartX;
      const offsetY: number = event.touches[0].y - this.virtualMouseButtonTouchStartY;
      if (!this.virtualMouseDragActive &&
        Math.sqrt(offsetX * offsetX + offsetY * offsetY) >= VIRTUAL_MOUSE_BUTTON_DRAG_THRESHOLD) {
        this.beginVirtualMouseButtonDrag(button);
      }
      if (this.virtualMouseDragActive) this.updateVirtualMouseMove(offsetX, offsetY);
      return;
    }
    if (event.type === TouchType.Up) {
      this.virtualMouseLastTouchResolvedAt = Date.now();
      if (this.virtualMouseDragActive) {
        this.finishVirtualMouseButtonDrag(button);
      } else {
        this.clickVirtualMouseButton(button);
      }
      this.resetVirtualMouseButtonTouch();
    } else if (event.type === TouchType.Cancel) {
      this.virtualMouseLastTouchResolvedAt = Date.now();
      if (this.virtualMouseDragActive) this.finishVirtualMouseButtonDrag(button, true);
      this.resetVirtualMouseButtonTouch();
    }
  }

  resetVirtualMouseWheelTouch(): void {
    this.virtualMouseWheelTouchActive = false;
    this.virtualMouseWheelTouchMoved = false;
    this.virtualMouseWheelTouchStartY = 0;
    this.virtualMouseWheelLastY = 0;
  }

  handleVirtualMouseWheelTouch(event: TouchEvent): void {
    event.stopPropagation();
    if (event.type === TouchType.Down && event.touches.length > 0) {
      this.resetVirtualMouseWheelTouch();
      this.virtualMouseWheelTouchActive = true;
      this.virtualMouseWheelTouchStartY = event.touches[0].y;
      this.virtualMouseWheelLastY = event.touches[0].y;
      return;
    }
    if (!this.virtualMouseWheelTouchActive) return;
    if (event.type === TouchType.Move && event.touches.length > 0) {
      const currentY: number = event.touches[0].y;
      const totalOffset: number = currentY - this.virtualMouseWheelTouchStartY;
      if (Math.abs(totalOffset) >= 6) this.virtualMouseWheelTouchMoved = true;
      const delta: number = currentY - this.virtualMouseWheelLastY;
      if (Math.abs(delta) >= 8) {
        this.sendVirtualMouseWheel(delta > 0 ? 1 : -1);
        this.virtualMouseWheelLastY = currentY;
      }
      return;
    }
    if (event.type === TouchType.Up) {
      this.virtualMouseLastTouchResolvedAt = Date.now();
      if (!this.virtualMouseWheelTouchMoved) this.clickVirtualMouseButton('middle');
      this.resetVirtualMouseWheelTouch();
    } else if (event.type === TouchType.Cancel) {
      this.virtualMouseLastTouchResolvedAt = Date.now();
      this.resetVirtualMouseWheelTouch();
    }
  }

  releaseVirtualMouseButtons(): void {
    if (this.virtualMouseLeftDown) {
      this.virtualMouseLeftDown = false;
      this.sendLeftUp(this.lastAbsX, this.lastAbsY, true);
    }
    if (this.virtualMouseRightDown) {
      this.virtualMouseRightDown = false;
      this.sendRightUp(this.lastAbsX, this.lastAbsY);
    }
    if (this.virtualMouseMiddleDown) {
      this.virtualMouseMiddleDown = false;
      ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 6);
    }
  }

  sendVirtualMouseWheel(delta: number): void {
    if (delta === 0) return;
    this.clearLongPressTimer();
    this.clearTapTimer();
    this.requestRemoteInputFocus();
    ConnectionService.sendMouseWheel(0, delta);
    RustDeskNapi.appendDiagnosticLog('input', `virtual_mouse_wheel delta=${delta}`);
  }

  virtualMouseOverlayX(): number {
    return Math.max(0, Math.min(this.virtualMouseX,
      Math.max(0, this.componentWidth - VIRTUAL_MOUSE_WIDTH)));
  }

  virtualMouseOverlayY(): number {
    return Math.max(0, Math.min(this.virtualMouseY,
      Math.max(0, this.componentHeight - VIRTUAL_MOUSE_HEIGHT)));
  }

  virtualMousePointerX(): number {
    return this.virtualMouseOverlayX();
  }

  virtualMousePointerY(): number {
    return this.virtualMouseOverlayY();
  }

  @Builder
  buildVirtualMousePointer() {
    Shape() {
      Path()
        .commands('M 1 1 L 1 20 L 6 15 L 10 23 L 14 21 L 10 14 L 18 14 Z')
        .fill('#E6DCEBFF')
        .stroke('#E6243B57')
        .strokeWidth(1)
    }
    .viewPort({ x: 0, y: 0, width: 24, height: 24 })
    .width(24)
    .height(24)
    .position({ x: this.virtualMousePointerX(), y: this.virtualMousePointerY() })
    .zIndex(76)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  buildVirtualMouseOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Button('×')
        .width(18)
        .height(18)
        .padding(0)
        .fontSize(13)
        .fontColor(Color.White)
        .backgroundColor('#A62B3C52')
        .border({ width: 0.7, color: '#99DCEBFF' })
        .borderRadius(9)
        .position({ x: 94, y: 0 })
        .onClick(() => { this.setVirtualMouseEnabled(false); })

      Stack({ alignContent: Alignment.TopStart }) {
        Button('左键', { type: ButtonType.Normal })
          .width(29)
          .height(67)
          .padding(0)
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.virtualMouseLeftDown ? '#183D69' : '#F2F7FF')
          .backgroundColor(this.virtualMouseLeftDown ? '#E6DCEBFF' : '#405B7697')
          .border({ width: 0.6, color: '#80DCEBFF' })
          .borderRadius({ topLeft: 27, topRight: 8, bottomLeft: 8, bottomRight: 8 })
          .position({ x: 0, y: 0 })
          .onTouch((event: TouchEvent) => { this.handleVirtualMouseButtonTouch('left', event); })
          .onClick(() => { this.clickVirtualMouseButtonFallback('left'); })

        Button('右键', { type: ButtonType.Normal })
          .width(29)
          .height(67)
          .padding(0)
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.virtualMouseRightDown ? '#183D69' : '#F2F7FF')
          .backgroundColor(this.virtualMouseRightDown ? '#E6DCEBFF' : '#405B7697')
          .border({ width: 0.6, color: '#80DCEBFF' })
          .borderRadius({ topLeft: 8, topRight: 27, bottomLeft: 8, bottomRight: 8 })
          .position({ x: 51, y: 0 })
          .onTouch((event: TouchEvent) => { this.handleVirtualMouseButtonTouch('right', event); })
          .onClick(() => { this.clickVirtualMouseButtonFallback('right'); })

        Column({ space: 1 }) {
          Button('⌃')
            .width(22).height(18).padding(0).fontSize(12).fontColor('#CCFFFFFF')
            .backgroundColor(Color.Transparent)
            .onClick(() => { this.sendVirtualMouseWheel(-VIRTUAL_MOUSE_WHEEL_BUTTON_STEP); })
          Button('≡')
            .width(22).height(28).padding(0).fontSize(12).fontColor('#CCFFFFFF')
            .backgroundColor(Color.Transparent)
            .onTouch((event: TouchEvent) => { this.handleVirtualMouseWheelTouch(event); })
            .onClick(() => { this.clickVirtualMouseButtonFallback('middle'); })
          Button('⌄')
            .width(22).height(18).padding(0).fontSize(12).fontColor('#CCFFFFFF')
            .backgroundColor(Color.Transparent)
            .onClick(() => { this.sendVirtualMouseWheel(VIRTUAL_MOUSE_WHEEL_BUTTON_STEP); })
        }
        .width(22)
        .height(67)
        .padding({ top: 1, bottom: 1 })
        .backgroundColor('#59202E42')
        .border({ width: 0.6, color: '#66DCEBFF' })
        .borderRadius(12)
        .position({ x: 29, y: 0 })
        .zIndex(2)

        Button({ type: ButtonType.Normal }) {
          Column({ space: 2 }) {
            Text('⠿')
              .fontSize(18)
              .fontColor('#BFDCEBFF')
              .hitTestBehavior(HitTestMode.None)
            Text('移动')
              .fontSize(9)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F7FF')
              .hitTestBehavior(HitTestMode.None)
          }
          .hitTestBehavior(HitTestMode.None)
        }
          .width(80)
          .height(51)
          .padding(0)
          .backgroundColor('#263E5674')
          .border({ width: 0.6, color: '#80DCEBFF' })
          .borderRadius({ topLeft: 8, topRight: 8, bottomLeft: 28, bottomRight: 28 })
          .position({ x: 0, y: 69 })
          .gesture(PanGesture({ fingers: 1, direction: PanDirection.All, distance: 2 })
            .onActionStart(() => { this.beginVirtualMouseMove(); })
            .onActionUpdate((event: GestureEvent) => {
              this.updateVirtualMouseMove(event.offsetX, event.offsetY);
            })
            .onActionEnd(() => { this.finishVirtualMouseMove(); }))
      }
      .width(80)
      .height(120)
      .backgroundColor('#73213146')
      .backdropBlur(8)
      .borderRadius(28)
      .border({ width: 0.8, color: '#B3DCEBFF' })
      .clip(true)
      .shadow({ radius: 5, color: '#33000000', offsetX: 0, offsetY: 2 })
      .position({ x: 14, y: 18 })
    }
    .width(VIRTUAL_MOUSE_WIDTH)
    .height(VIRTUAL_MOUSE_HEIGHT)
    .position({ x: this.virtualMouseOverlayX(), y: this.virtualMouseOverlayY() })
    .zIndex(75)
    .onAppear(() => { this.initializeVirtualMousePosition(); })
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

        Scroll() {
          Column({ space: 14 }) {
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
            Text(this.suppressCompatibilityCursor() ? '当前使用画面中的远端光标，不叠加本地指针' : '仅控制本机物理鼠标指针，不影响远端画面')
              .fontSize(11)
              .fontColor(this.secondaryTextColor())
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.showLocalCursor })
            .enabled(this.inputMode === INPUT_MODE_MOUSE && !this.suppressCompatibilityCursor())
            .onChange((isOn: boolean) => {
              this.setLocalCursorPreference(isOn);
            })
        }
        .width('100%')
        .padding({ left: 2, right: 2, top: 2, bottom: 2 })

        this.buildInputCompatibilityOptions()

        if (this.isHandheldDevice()) {
          Row() {
            Column({ space: 3 }) {
              Text('显示虚拟鼠标')
                .fontSize(14)
                .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
                .fontColor(this.primaryTextColor())
                .width('100%')
              Text('显示与 RustDesk 官方一致的左右键、滚轮和拖动区；默认关闭')
                .fontSize(11)
                .fontColor(this.secondaryTextColor())
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.showVirtualMouse })
              .onChange((isOn: boolean) => {
                this.setVirtualMouseEnabled(isOn);
              })
          }
          .width('100%')
          .padding({ left: 2, right: 2, top: 2, bottom: 2 })
        }

        Row() {
          Column({ space: 3 }) {
            Text('鼠标画面跟随')
              .fontSize(14)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
              .fontColor(this.primaryTextColor())
              .width('100%')
            Text(this.inputMode === INPUT_MODE_MOUSE ?
              '放大后，手指移动鼠标到可视区域中心附近，画面即随手势平移，停手即停；实体鼠标仍在边缘停留后自动平移' : '仅在鼠标模式下生效')
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
          Text('适合控制电脑：\n• 单指滑动：移动鼠标\n• 单击：左键\n• 轻点一次，第二次按住并移动：拖拽，松手结束\n• 长按或双指轻点：右键\n• 双指平行滑动：滚动\n• 双指捏合：缩放画面\n• 虚拟鼠标：左右键、中键和滚轮与实体鼠标一致，按住鼠标拖动区即可移动远端指针\n• 虚拟鼠标开启且画面放大后：单指拖动画面其他区域直接平移视野\n• 边缘跟随开启后：手机/平板放大画面，手指移动鼠标到可视区域中心附近，视野立即跟随；停手即停，抬手再滑无需等待\n• 虚拟鼠标拖动区同样支持中心跟随；到达远端桌面边界后，鼠标继续移动\n• 实体鼠标：靠近画面边缘并短暂停留后自动平移，越靠边越快\n• 全屏三指上滑：调出系统键盘，输入直达远端')
            .fontSize(14)
            .lineHeight(24)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        } else {
          Text('适合直接点按：\n• 点按位置：左键\n• 按住移动：拖拽\n• 双指轻点：右键\n• 双指平行滑动：滚动\n• 双指捏合：缩放画面\n• 放大后点“移动画面”：按钮变为淡蓝色，单指平移视野且不点击远端\n• 移动画面模式下，双指滚动和捏合缩放仍可使用\n• 全屏三指上滑：调出系统键盘，输入直达远端')
            .fontSize(14)
            .lineHeight(24)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        }

        this.buildGestureHelpSection('手机 / 平板单独投屏',
          '先通过系统控制中心连接无线投屏，再打开顶部投屏胶囊，按系统提示将 StarRustDesk 单独投屏。是否提供该入口取决于设备、系统版本和接收端。\n投屏后画面仍竖向时，可在“控”中点“横屏”；点“自动旋转”恢复默认策略。横向外接屏被识别后会自动采用横屏。这里只调整本地窗口，不更改远端 Windows 分辨率。')
        this.buildGestureHelpSection('拖拽与框选',
          '鼠标模式：先将远端指针移到起点，轻点一次，第二次按住并拖动，松手结束。框选文件时请从文件列表或桌面的空白处开始；从文件上开始通常是拖动文件。\n触摸模式：在目标位置按住并移动，松手结束。')
        this.buildGestureHelpSection('组合键与本地键盘',
          '连接后默认显示折叠的“键”按钮，点击展开；“键”和“控”及其拖动柄均可移动到屏幕任意位置。\n横屏时“键”默认位于左上角，“控”默认位于右上角，两个面板都向下展开。长按任意功能按钮可调整排序。\nCtrl、Alt、Shift、Win/Cmd：点一下选中，相当于按住；再点一下释放，不需要手指一直按着。可以同时选中多个。\n例如 Ctrl+C：点亮 Ctrl，再输入 C，最后再次点击 Ctrl 取消选中。Mac 常用 Cmd+C。Ctrl/Shift 也可配合鼠标多选文件，用完记得释放。\nCtrl+Shift+Esc 等完整组合键按钮：点一次发送整组按键，不会自动弹出本地键盘。\n横屏打开键盘时画面会随可用区域上移和缩放，避免被键盘遮挡。')
        this.buildGestureHelpSection('悬浮功能栏与移动画面',
          '竖屏时“控”保持底部横向工具栏；横屏时默认移动到右上角并向下展开。点击收起后保留“控”按钮。\n未开启虚拟鼠标时，画面放大后可使用“移动画面”模式；开启虚拟鼠标后，直接单指拖动画面空白区域即可平移，鼠标本体专门控制远端指针。\n全屏三指上滑用于打开本地键盘，不是滚动手势；滚动请使用双指平行滑动。')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)

        Button('知道了')
          .width('100%')
          .height(42)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(8)
          .onClick(() => {
            this.dismissGestureHelp();
          })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
      }
      .width(this.isLargeLayout() ? 420 : '88%')
      .height(Math.min(760, Math.max(180, (this.pageHeight > 0 ? this.pageHeight : 640) - 24)))
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
  buildGestureHelpSection(title: string, details: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.primaryTextColor())
        .width('100%')
      Text(details)
        .fontSize(13)
        .lineHeight(22)
        .fontColor(this.secondaryTextColor())
        .width('100%')
    }
    .width('100%')
  }

  sendMobileAction(action: number, label: string): void {
    const result: number = RustDeskNapi.sendMobileAction(action);
    if (result !== 0) {
      this.showFileToast(`${label}发送失败 (${result})`);
      return;
    }
    RustDeskNapi.appendDiagnosticLog('mobile-action', `sent action=${action} label=${label}`);
  }

  getMobileActionsWidth(): number {
    const availableWidth: number = (this.pageWidth > 0 ? this.pageWidth : 360) - 16;
    return Math.min(this.isLargeLayout() ? 430 : 352, Math.max(272, availableWidth));
  }

  getMobileActionsHeight(): number {
    return 54;
  }

  getMobileActionsBottomInset(): number {
    return this.isFullScreen ? 62 : 68;
  }

  getMobileActionsBaseX(): number {
    return Math.max(8, ((this.pageWidth > 0 ? this.pageWidth : 360) - this.getMobileActionsWidth()) / 2);
  }

  getMobileActionsBaseY(): number {
    const height: number = this.pageHeight > 0 ? this.pageHeight : 640;
    return Math.max(8, height - this.getMobileActionsHeight() - this.getMobileActionsBottomInset());
  }

  clampMobileActionsOffsetX(offset: number): number {
    const width: number = this.pageWidth > 0 ? this.pageWidth : 360;
    const baseX: number = this.getMobileActionsBaseX();
    const minOffset: number = 8 - baseX;
    const maxOffset: number = width - this.getMobileActionsWidth() - 8 - baseX;
    return Math.max(minOffset, Math.min(maxOffset, offset));
  }

  clampMobileActionsOffsetY(offset: number): number {
    const height: number = this.pageHeight > 0 ? this.pageHeight : 640;
    const baseY: number = this.getMobileActionsBaseY();
    const minOffset: number = 8 - baseY;
    const maxOffset: number = height - this.getMobileActionsHeight() - 8 - baseY;
    return Math.max(minOffset, Math.min(maxOffset, offset));
  }

  beginMobileActionsDrag(): void {
    this.mobileActionsDragStartX = this.clampMobileActionsOffsetX(this.mobileActionsOffsetX);
    this.mobileActionsDragStartY = this.clampMobileActionsOffsetY(this.mobileActionsOffsetY);
  }

  updateMobileActionsDrag(offsetX: number, offsetY: number): void {
    this.mobileActionsOffsetX = this.clampMobileActionsOffsetX(this.mobileActionsDragStartX + offsetX);
    this.mobileActionsOffsetY = this.clampMobileActionsOffsetY(this.mobileActionsDragStartY + offsetY);
  }

  @Builder
  buildMobileActionButton(label: string, action: number, danger: boolean = false) {
    Button(label)
      .layoutWeight(1)
      .height(40)
      .padding({ left: 1, right: 1 })
      .fontSize(11)
      .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
      .fontColor(danger ? RustDeskTheme.ERROR : this.primaryTextColor())
      .backgroundColor(danger ? (this.isDarkMode ? RustDeskTheme.DANGER_SOFT_DARK : '#FFF3F3') :
        Color.Transparent)
      .borderRadius(9)
      .onClick(() => {
        this.sendMobileAction(action, label);
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 9, ButtonType.Capsule))
  }

  @Builder
  buildMobileActionsOverlay() {
    Row({ space: 2 }) {
      Text('⋮')
        .width(14)
        .fontSize(19)
        .fontColor(this.secondaryTextColor())
        .textAlign(TextAlign.Center)
      this.buildMobileActionButton('返回', MOBILE_ACTION_BACK)
      this.buildMobileActionButton('主页', MOBILE_ACTION_HOME)
      this.buildMobileActionButton('任务', MOBILE_ACTION_RECENTS)
      this.buildMobileActionButton('音量−', MOBILE_ACTION_VOLUME_DOWN)
      this.buildMobileActionButton('音量+', MOBILE_ACTION_VOLUME_UP)
      this.buildMobileActionButton('电源', MOBILE_ACTION_POWER, true)
      Button('⌄')
        .width(34)
        .height(40)
        .padding(0)
        .fontSize(20)
        .fontColor(this.primaryTextColor())
        .backgroundColor(this.mutedSurfaceColor())
        .borderRadius(9)
        .onClick(() => {
          this.showMobileActions = false;
        })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 9, ButtonType.Capsule))
    }
    .width(this.getMobileActionsWidth())
    .height(this.getMobileActionsHeight())
    .padding({ left: 5, right: 5, top: 7, bottom: 7 })
    .backgroundColor(this.isDarkMode ? '#F21B2638' : '#F7FFFFFF')
    .border({ width: 1, color: this.isDarkMode ? '#805C93E6' : '#80518BDD' })
    .borderRadius(15)
    .shadow({ radius: 20, color: '#55000000', offsetX: 0, offsetY: 7 })
    .position({
      x: this.getMobileActionsBaseX() + this.clampMobileActionsOffsetX(this.mobileActionsOffsetX),
      y: this.getMobileActionsBaseY() + this.clampMobileActionsOffsetY(this.mobileActionsOffsetY)
    })
    .zIndex(50)
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 4 })
        .onActionStart(() => {
          this.beginMobileActionsDrag();
        })
        .onActionUpdate((event: GestureEvent) => {
          this.updateMobileActionsDrag(event.offsetX, event.offsetY);
        })
    )
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
          .fontColor(this.inputMode === mode ? this.controlSelectedTextColor() : this.primaryTextColor())
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(42)
    .backgroundColor(this.inputMode === mode ? this.controlSelectedBackgroundColor() : this.mutedSurfaceColor())
    .border({
      width: 1,
      color: this.inputMode === mode ? this.controlSelectedBorderColor() : this.themeBorderColor(),
    })
    .borderRadius(8)
    .onClick(() => {
      this.setInputMode(mode);
    })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  @Builder
  buildKeyboardToolButton(label: string, buttonWidth: number, selected: boolean,
    danger: boolean, enabled: boolean, onClick: () => void, refocusAfterClick: boolean = true,
    orderKey: string = '', orderKind: string = 'keyboard') {
    Button(label)
      .width(buttonWidth)
      .height(38)
      .padding({ left: 3, right: 3 })
      .fontSize(label === '←' || label === '↑' || label === '↓' || label === '→' ? 20 :
        (label === '释放' ? 11 : (label.length > 10 ? 10 : 12)))
      .fontWeight(this.keyboardToolSelected(label, selected) ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
      .fontColor(danger ? RustDeskTheme.ERROR : (this.keyboardToolSelected(label, selected) ?
        this.controlSelectedTextColor() : this.primaryTextColor()))
      .backgroundColor(danger ? (this.isDarkMode ? RustDeskTheme.DANGER_SOFT_DARK : '#FFF1F2') :
        (this.keyboardToolSelected(label, selected) ? this.controlSelectedBackgroundColor() :
          (this.isDarkMode ? '#991C222D' : '#99F7F9FD')))
      .border({ width: 1, color: this.keyboardToolSelected(label, selected) ?
        this.controlSelectedBorderColor() : this.themeBorderColor() })
      .borderRadius(8)
      .enabled(enabled)
      .opacity(enabled ? 1 : 0.5)
      .focusable(false)
      .accessibilityText(orderKey.length > 0 ? this.toolbarOrderLabel(orderKey) : label)
      .gesture(LongPressGesture({ repeat: false, duration: 550 }).onAction(() => {
        if (orderKey.length > 0) this.openToolbarOrderEditor(orderKind, orderKey);
      }))
      .onClick(() => {
        onClick();
        if (refocusAfterClick) {
          this.refocusRemoteKeyboard();
        }
      })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
  }

  @Builder
  buildKeyboardToolbarItems(vertical: boolean) {
    ForEach(this.keyboardToolbarOrder, (item: string) => {
      this.buildKeyboardToolbarItem(item, vertical)
    }, (item: string) => `keyboard-${item}`)
  }

  @Builder
  buildKeyboardToolbarItem(item: string, vertical: boolean) {
    if (item === 'ctrl') {
      this.buildKeyboardToolButton('Ctrl', vertical ? 96 : this.keyboardMainButtonWidth(58, 46),
        this.virtualCtrlSelected, false, true, () => {
          this.toggleVirtualModifier(VIRTUAL_MODIFIER_CTRL);
        }, true, item)
    } else if (item === 'alt') {
      this.buildKeyboardToolButton('Alt', vertical ? 96 : this.keyboardMainButtonWidth(54, 44),
        this.virtualAltSelected, false, true, () => {
          this.toggleVirtualModifier(VIRTUAL_MODIFIER_ALT);
        }, true, item)
    } else if (item === 'shift') {
      this.buildKeyboardToolButton('Shift', vertical ? 96 : this.keyboardMainButtonWidth(62, 52),
        this.virtualShiftSelected, false, true, () => {
          this.toggleVirtualModifier(VIRTUAL_MODIFIER_SHIFT);
        }, true, item)
    } else if (item === 'meta') {
      this.buildKeyboardToolButton('Win/Cmd', vertical ? 96 : this.keyboardMainButtonWidth(76, 68),
        this.virtualMetaSelected, false, true, () => {
          this.toggleVirtualModifier(VIRTUAL_MODIFIER_META);
        }, true, item)
    } else if (item === 'function') {
      this.buildKeyboardToolButton('Fn', vertical ? 96 : this.keyboardMainButtonWidth(48, 42),
        this.showKeyboardFunctionKeys, false, true, () => {
          this.showKeyboardFunctionKeys = !this.showKeyboardFunctionKeys;
          if (this.showKeyboardFunctionKeys) this.showKeyboardMoreKeys = false;
        }, true, item)
    } else if (item === 'more') {
      this.buildKeyboardToolButton('更多', vertical ? 96 : this.keyboardMainButtonWidth(54, 46),
        this.showKeyboardMoreKeys, false, true, () => {
          this.showKeyboardMoreKeys = !this.showKeyboardMoreKeys;
          if (this.showKeyboardMoreKeys) this.showKeyboardFunctionKeys = false;
        }, true, item)
    } else if (item === 'release') {
      this.buildKeyboardToolButton('释放', vertical ? 96 : 48, false, false, true, () => {
        this.releaseVirtualModifiers();
      }, false, item)
    }
  }

  @Builder
  buildKeyboardSupplementalItems(vertical: boolean) {
    if (this.showKeyboardFunctionKeys) {
      if (vertical) {
        ForEach(this.makeFunctionKeyCodes(), (code: number) => {
          this.buildKeyboardToolButton(`F${code - 111}`, 96, false, false, true, () => {
            this.sendVirtualControlKey(code, `F${code - 111}`);
          })
        }, (code: number) => `function-${code}`)
      } else {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.makeFunctionKeyCodes(), (code: number) => {
              this.buildKeyboardToolButton(`F${code - 111}`, 48, false, false, true, () => {
                this.sendVirtualControlKey(code, `F${code - 111}`);
              })
            }, (code: number) => `function-${code}`)
          }
          .height(38)
        }
        .width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      }
    }
    if (this.showKeyboardMoreKeys) {
      if (vertical) {
        this.buildKeyboardMoreItems(true)
      } else {
        Scroll() {
          Row({ space: 6 }) { this.buildKeyboardMoreItems(false) }
          .height(38)
        }
        .width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      }
    }
  }

  @Builder
  buildKeyboardMoreItems(vertical: boolean) {
    ForEach(this.keyboardMoreOrder, (item: string) => {
      this.buildKeyboardMoreItem(item, vertical)
    }, (item: string) => `keyboard-more-${item}-${this.canSendCtrlAltDel ? 1 : 0}`)
  }

  @Builder
  buildKeyboardMoreItem(item: string, vertical: boolean) {
    if (item === 'Left') {
      this.buildKeyboardToolButton('←', vertical ? 96 : 48, false, false, true, () => {
        this.sendVirtualControlKey(37, 'Left');
      }, false, item, 'keyboardMore')
    } else if (item === 'Up') {
      this.buildKeyboardToolButton('↑', vertical ? 96 : 48, false, false, true, () => {
        this.sendVirtualControlKey(38, 'Up');
      }, false, item, 'keyboardMore')
    } else if (item === 'Down') {
      this.buildKeyboardToolButton('↓', vertical ? 96 : 48, false, false, true, () => {
        this.sendVirtualControlKey(40, 'Down');
      }, false, item, 'keyboardMore')
    } else if (item === 'Right') {
      this.buildKeyboardToolButton('→', vertical ? 96 : 48, false, false, true, () => {
        this.sendVirtualControlKey(39, 'Right');
      }, false, item, 'keyboardMore')
    } else if (item === 'Esc') {
    this.buildKeyboardToolButton('Esc', vertical ? 96 : 50, false, false, true, () => {
      this.sendVirtualControlKey(27, 'Esc');
    }, true, item, 'keyboardMore')
    } else if (item === 'Tab') {
    this.buildKeyboardToolButton('Tab', vertical ? 96 : 50, false, false, true, () => {
      this.sendVirtualControlKey(9, 'Tab');
    }, true, item, 'keyboardMore')
    } else if (item === 'Home') {
    this.buildKeyboardToolButton('Home', vertical ? 96 : 58, false, false, true, () => {
      this.sendVirtualControlKey(36, 'Home');
    }, true, item, 'keyboardMore')
    } else if (item === 'End') {
    this.buildKeyboardToolButton('End', vertical ? 96 : 50, false, false, true, () => {
      this.sendVirtualControlKey(35, 'End');
    }, true, item, 'keyboardMore')
    } else if (item === 'Ins') {
    this.buildKeyboardToolButton('Ins', vertical ? 96 : 48, false, false, true, () => {
      this.sendVirtualControlKey(45, 'Insert');
    }, true, item, 'keyboardMore')
    } else if (item === 'Del') {
    this.buildKeyboardToolButton('Del', vertical ? 96 : 48, false, false, true, () => {
      this.sendVirtualControlKey(46, 'Delete');
    }, true, item, 'keyboardMore')
    } else if (item === 'PgUp') {
    this.buildKeyboardToolButton('PgUp', vertical ? 96 : 58, false, false, true, () => {
      this.sendVirtualControlKey(33, 'PageUp');
    }, true, item, 'keyboardMore')
    } else if (item === 'PgDn') {
    this.buildKeyboardToolButton('PgDn', vertical ? 96 : 58, false, false, true, () => {
      this.sendVirtualControlKey(34, 'PageDown');
    }, true, item, 'keyboardMore')
    } else if (item === 'Ctrl+Shift+Esc') {
    this.buildKeyboardToolButton('Ctrl+Shift+Esc', vertical ? 96 : 112, false, false, true, () => {
      this.sendPresetShortcut(27, MODIFIER_MASK_CTRL | MODIFIER_MASK_SHIFT, 'Ctrl+Shift+Esc');
    }, false, item, 'keyboardMore')
    } else if (item === 'Ctrl+Shift+Del') {
    this.buildKeyboardToolButton('Ctrl+Shift+Del', vertical ? 96 : 112, false, false, true, () => {
      this.sendPresetShortcut(46, MODIFIER_MASK_CTRL | MODIFIER_MASK_SHIFT, 'Ctrl+Shift+Del');
    }, false, item, 'keyboardMore')
    } else if (item === 'Alt+F4') {
    this.buildKeyboardToolButton('Alt+F4', vertical ? 96 : 72, false, false, true, () => {
      this.sendPresetShortcut(115, MODIFIER_MASK_ALT, 'Alt+F4');
    }, false, item, 'keyboardMore')
    } else if (item === 'Ctrl+Alt+Del') {
    if (this.canSendCtrlAltDel) {
      this.buildKeyboardToolButton('Ctrl+Alt+Del', vertical ? 96 : 104, false, true, true, () => {
        this.sendCtrlAltDel();
      }, false, item, 'keyboardMore')
    }
    }
  }

  @Builder
  buildKeyboardShortcutOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.keyboardToolsCollapsed) {
        Button() {
          Row({ space: 3 }) {
            Text('键')
              .fontSize(16)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
              .fontColor(this.controlSelectedTextColor())
            if (this.virtualCtrlSelected || this.virtualAltSelected ||
              this.virtualShiftSelected || this.virtualMetaSelected) {
              Circle().width(5).height(5).fill(this.controlSelectedTextColor())
            }
          }
        }
        .width(56)
        .height(this.getKeyboardToolsCollapsedSize())
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(16)
        .transition(this.floatingPanelTransition())
        .focusable(false)
        .gesture(PanGesture({ fingers: 1, direction: PanDirection.All, distance: 4 })
          .onActionStart(() => { this.beginKeyboardToolsDrag(); })
          .onActionUpdate((event: GestureEvent) => {
            this.updateKeyboardToolsDrag(event.offsetX, event.offsetY);
          }))
        .onClick(() => { this.setFloatingPanelCollapsed(true, false); })
        .onHover((isHovering: boolean) => { this.handleNonRemoteHover(isHovering); })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 16, ButtonType.Capsule))
      } else if (this.isHandheldLandscape()) {
        Column({ space: 5 }) {
          Row({ space: 4 }) {
            this.buildFloatingDragHandle(true)
            Blank()
            this.buildFloatingCollapseButton(true)
          }
          .width('100%')
          .height(38)
          Scroll() {
            Column({ space: 6 }) {
              this.buildKeyboardToolbarItems(true)
              this.buildKeyboardSupplementalItems(true)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
        }
        .width(this.getKeyboardToolsWidth())
        .height(this.getKeyboardToolsHeight())
        .padding(8)
        .transition(this.floatingPanelTransition())
      } else {
        Column({ space: 6 }) {
          Row({ space: 4 }) {
            this.buildFloatingDragHandle(true)
            Scroll() {
              Row({ space: 6 }) {
                this.buildKeyboardToolbarItems(false)
              }
              .height(38)
              .alignItems(VerticalAlign.Center)
            }
            .layoutWeight(1)
            .height(38)
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            this.buildFloatingCollapseButton(true)
          }
          .width('100%')
          .height(38)
          .alignItems(VerticalAlign.Center)
          this.buildKeyboardSupplementalItems(false)
        }
        .width(this.getKeyboardToolsWidth())
        .height(this.getKeyboardToolsHeight())
        .padding(8)
        .transition(this.floatingPanelTransition())
      }
    }
    .width(this.getKeyboardToolsCurrentWidth())
    .height(this.getKeyboardToolsCurrentHeight())
    .backgroundColor(this.isDarkMode ? '#A61B2638' : '#A6FFFFFF')
    .border({ width: 1, color: this.isDarkMode ? '#805C93E6' : '#80518BDD' })
    .borderRadius(16)
    .clip(true)
    .shadow({ radius: 12, color: '#26000000', offsetX: 0, offsetY: 4 })
    .position({ x: this.getKeyboardToolsX(), y: this.getKeyboardToolsY() })
    .zIndex(65)
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
      .onKeyPreIme((event: KeyEvent) => {
        // Only navigation bypasses the hidden text field. Letters, Enter and
        // Backspace retain the IME's composition/commit path.
        if (!isNavigationControlKey(this.mapControlKeyCode(event.keyCode))) return false;
        return this.handleRemoteKey(event);
      })
      .onBlur(() => {
        this.releaseRemoteNavigationKeys('keyboard_blur');
        this.keyboardComposing = false;
      })
      .onChange((value: string, previewText?: PreviewText) => {
        this.handleDirectKeyboardChange(value, previewText);
      })
      .onSubmit(() => {
        this.sendControlKey(13);
        this.resetKeyboardCaptureBuffer();
      })
      .position({ x: 0, y: 0 })
  }

  @Builder
  buildDraggableQualityMonitor() {
    Scroll() {
      if (this.showQualityMonitor) {
        this.buildStatsPanel();
      } else {
        this.buildStatsPanelRestoreButton();
      }
    }
    .width(this.getQualityMonitorWidth())
    .height(this.getQualityMonitorHeight())
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.None)
    .clip(true)
    .borderRadius(this.showQualityMonitor ? 6 : 15)
    .position({ x: this.getQualityMonitorX(), y: this.getQualityMonitorY() })
    .zIndex(40)
    .gesture(PanGesture({ fingers: 1, direction: PanDirection.All, distance: 6 })
      .onActionStart(() => {
        this.qualityDragStartX = this.getQualityMonitorX();
        this.qualityDragStartY = this.getQualityMonitorY();
        this.qualityLastDragAt = Date.now();
      })
      .onActionUpdate((event: GestureEvent) => {
        this.updateQualityMonitorDrag(event.offsetX, event.offsetY);
      })
      .onActionEnd(() => { this.qualityLastDragAt = Date.now(); })
      .onActionCancel(() => { this.qualityLastDragAt = Date.now(); }))
  }

  getQualityMonitorWidth(): number {
    return Math.min(this.showQualityMonitor ? 194 : 64,
      Math.max(1, this.qualityViewportWidth - 16));
  }

  getQualityMonitorHeight(): number {
    return Math.min(this.showQualityMonitor ? 190 : 30,
      Math.max(1, this.qualityViewportHeight - 16));
  }

  getQualityMonitorX(): number {
    const max: number = Math.max(0, this.qualityViewportWidth - this.getQualityMonitorWidth() - 8);
    return Math.max(Math.min(8, max), Math.min(max,
      this.qualityMonitorX < 0 ? (this.isFullScreen && !this.isHandheldDevice() ? 8 : max - 2) :
        this.qualityMonitorX));
  }

  getQualityMonitorY(): number {
    const max: number = Math.max(0, this.qualityViewportHeight - this.getQualityMonitorHeight() - 8);
    return Math.max(Math.min(8, max), Math.min(max,
      this.qualityMonitorY < 0 ? (this.isFullScreen ? 58 : 10) : this.qualityMonitorY));
  }

  updateQualityMonitorDrag(x: number, y: number): void {
    this.qualityMonitorX = Math.max(0, this.qualityDragStartX + x);
    this.qualityMonitorY = Math.max(0, this.qualityDragStartY + y);
    this.qualityMonitorX = this.getQualityMonitorX();
    this.qualityMonitorY = this.getQualityMonitorY();
    this.qualityLastDragAt = Date.now();
  }

  setQualityMonitorExpanded(expanded: boolean): void {
    if (Date.now() - this.qualityLastDragAt < 250) return;
    this.qualityMonitorX = this.getQualityMonitorX();
    this.qualityMonitorY = this.getQualityMonitorY();
    this.showQualityMonitor = expanded;
  }

  @Builder
  buildStatsPanel() {
    Column({ space: 2 }) {
      Row() {
        Text('连接信息')
          .fontSize(11)
          .fontWeight(600)
          .fontColor('#FFF2F2F2')
        Blank()
        Text('×')
          .width(24)
          .height(22)
          .fontSize(18)
          .fontColor('#FFD2D2D2')
          .textAlign(TextAlign.Center)
          .borderRadius(11)
          .onClick(() => {
            this.setQualityMonitorExpanded(false);
          })
      }
      .width('100%')
      .height(22)

      ConnectionQualityRow({ label: '速度', value: this.speedText })
      ConnectionQualityRow({ label: 'FPS', value: this.fpsText })
      ConnectionQualityRow({ label: '延迟', value: this.delayText, valueColor: this.delayTextColor() })
      ConnectionQualityRow({ label: '连接', value: this.routeText })
      ConnectionQualityRow({ label: '目标码率', value: this.targetBitrateText })
      ConnectionQualityRow({ label: '编码', value: this.codecNameText })
      ConnectionQualityRow({ label: '解码', value: this.decoderText })
      ConnectionQualityRow({ label: '安全', value: this.securityText(), valueColor: this.securityTextColor() })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .backgroundColor('#96000000')
    .borderRadius(6)
    .zIndex(40)
  }

  @Builder
  buildStatsPanelRestoreButton() {
    Row({ space: 4 }) {
      Text('ⓘ')
        .fontSize(13)
        .fontColor('#FFF2F2F2')
      Text('信息')
        .fontSize(11)
        .fontColor('#FFF2F2F2')
    }
    .height(30)
    .width('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor('#80000000')
    .borderRadius(15)
    .zIndex(40)
    .onClick(() => {
      this.setQualityMonitorExpanded(true);
    })
  }

  delayTextColor(): ResourceColor {
    if (this.delayMs <= 0) return Color.White
    if (this.delayMs < 80) return '#FF5DDF91'
    if (this.delayMs <= 180) return '#FFFFC857'
    return '#FFFF6B6B'
  }

  securityText(): string {
    if (this.peerSecurityState === 1) return '端到端加密'
    if (this.peerSecurityState === 2) return '未加密'
    if (this.peerSecurityState === 3) return '验证失败'
    return '检测中'
  }

  securityTextColor(): ResourceColor {
    if (this.peerSecurityState === 1) return '#FF5DDF91'
    if (this.peerSecurityState === 2 || this.peerSecurityState === 3) return '#FFFFC857'
    return Color.White
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
    if (this.isFullScreen || this.fullscreenTransitioning) return;
    this.releaseRemoteNavigationKeys('fullscreen');
    this.resetKeyboardCaptureBuffer();
    this.showKeyboardPanel = false;
    this.restoreKeyboardAvoidMode();
    this.showGestureHelp = false;
    this.requestFullscreen(true);
  }

  exitFullScreen(): void {
    if (!this.isFullScreen || this.fullscreenTransitioning) return;
    this.closeRemoteKeyboard();
    this.requestFullscreen(false);
  }

  requestFullscreen(enabled: boolean): void {
    if (this.fullscreenTransitioning || !this.remotePageVisible || this.isLeavingAfterDisconnect ||
      this.isFullScreen === enabled) return;
    const previous = this.isFullScreen;
    const previousToolbarCollapsed = this.remoteToolbarCollapsed;
    const previousToolbarOffsetX = this.remoteToolbarOffsetX;
    const previousToolbarOffsetY = this.remoteToolbarOffsetY;
    const requestId = ++this.fullscreenRequestId;
    const started = Date.now();
    this.fullscreenTransitioning = true;
    if (enabled && !this.isHandheldDevice()) {
      this.remoteToolbarCollapsed = true;
      this.remoteToolbarOffsetX = 0;
      this.remoteToolbarOffsetY = 0;
    }
    this.isFullScreen = enabled;
    RustDeskNapi.appendDiagnosticLog('fullscreen',
      `switch_requested id=${requestId} from=${previous} to=${enabled} viewport=${Math.round(this.componentWidth)}x${Math.round(this.componentHeight)}`);
    RemoteFullscreenPolicy.apply(enabled).then(() => {
      if (requestId !== this.fullscreenRequestId || !this.remotePageVisible || this.isLeavingAfterDisconnect) return;
      RustDeskNapi.appendDiagnosticLog('fullscreen',
        `switch_completed id=${requestId} enabled=${enabled} elapsed_ms=${Date.now() - started} surface=${Math.round(this.getDisplayWidth())}x${Math.round(this.getDisplayHeight())}`);
      this.scheduleSurfaceRebindIfSizeChanged();
    }).catch((error: BusinessError) => {
      if (requestId !== this.fullscreenRequestId || !this.remotePageVisible || this.isLeavingAfterDisconnect) return;
      this.isFullScreen = previous;
      this.remoteToolbarCollapsed = previousToolbarCollapsed;
      this.remoteToolbarOffsetX = previousToolbarOffsetX;
      this.remoteToolbarOffsetY = previousToolbarOffsetY;
      RustDeskNapi.appendDiagnosticLog('fullscreen',
        `switch_failed id=${requestId} restored=${previous} code=${error.code ?? -1} elapsed_ms=${Date.now() - started}`);
      this.showFileToast('全屏切换失败，请稍后重试');
    }).finally(() => {
      if (requestId === this.fullscreenRequestId) this.fullscreenTransitioning = false;
    });
  }

  restoreFullscreenOnLeave(): void {
    if (!this.isFullScreen && !this.fullscreenTransitioning) return;
    ++this.fullscreenRequestId;
    this.isFullScreen = false;
    this.fullscreenTransitioning = false;
    RustDeskNapi.appendDiagnosticLog('fullscreen', 'leave_restore_requested');
    // Queued after any in-flight operation. Never roll cleanup back to fullscreen.
    RemoteFullscreenPolicy.apply(false, false).then(() => {
      RustDeskNapi.appendDiagnosticLog('fullscreen', 'leave_restore_completed');
    }).catch((error: BusinessError) => {
      RustDeskNapi.appendDiagnosticLog('fullscreen', `leave_restore_failed code=${error.code ?? -1}`);
    });
  }

  @Builder
  buildDisplaySwitcher() {
    if (this.displayCount > 1) {
      Row({ space: 6 }) {
        ForEach(this.makeDisplayIndexes(), (display: number) => {
          Button(`屏幕 ${display + 1}`)
            .height(34)
            .fontSize(12)
            .fontColor(display === this.currentDisplay ? this.controlSelectedTextColor() : Color.White)
            .backgroundColor(display === this.currentDisplay ?
              this.controlSelectedBackgroundColor() : '#80000000')
            .border({
              width: 1,
              color: display === this.currentDisplay ? this.controlSelectedBorderColor() : '#66FFFFFF',
            })
            .borderRadius(17)
            .onClick(() => {
              this.switchDisplay(display);
            })
        .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 17, ButtonType.Capsule))
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

  isHandheldDevice(): boolean {
    return deviceInfo.deviceType === 'phone' || deviceInfo.deviceType === 'tablet';
  }

  isHandheldLandscape(): boolean {
    const height: number = this.showKeyboardPanel && this.keyboardLayoutHeight > 0 ?
      this.keyboardLayoutHeight : this.pageHeight;
    return this.isHandheldDevice() && this.pageWidth > height && height > 0;
  }

  getRemoteCanvasHeight(): number | string {
    return this.keyboardViewportHeight > 0 ? this.keyboardViewportHeight : '100%';
  }

  handleHandheldLayoutChange(): void {
    if (!this.isHandheldDevice() || this.pageWidth <= 0 || this.pageHeight <= 0) return;
    const landscape: boolean = this.isHandheldLandscape();
    if (!this.handheldLayoutInitialized || landscape !== this.lastHandheldLandscape) {
      this.handheldLayoutInitialized = true;
      this.lastHandheldLandscape = landscape;
      this.keyboardToolsCollapsed = !landscape;
      if (landscape) this.remoteToolbarCollapsed = false;
      this.keyboardToolsOffsetX = 0;
      this.keyboardToolsOffsetY = 0;
      this.remoteToolbarOffsetX = 0;
      this.remoteToolbarOffsetY = 0;
      this.virtualMouseInitialized = false;
      if (this.showVirtualMouse) this.initializeVirtualMousePosition(true);
      RustDeskNapi.appendDiagnosticLog('remote-ui',
        `handheld_orientation=${landscape ? 'landscape' : 'portrait'} floating_positions_reset=1`);
    }
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

  compatibilityOptionKey(name: string): string {
    return inputCompatibilityKey(RustDeskNapi.getOption('custom-rendezvous-server'), this.connectedPeerId, name);
  }

  loadInputCompatibility(): void {
    const capabilities: number = RustDeskNapi.getInputCapabilities();
    this.oneKvmPeer = (capabilities & 1) !== 0;
    this.relativeMouseSupported = (capabilities & 2) !== 0;
    this.keyboardCompatibilityMode = selectedKeyboardMode(RustDeskNapi.getOption(this.compatibilityOptionKey('keyboard')));
    this.cursorCompatibilityMode = selectedCursorMode(RustDeskNapi.getOption(this.compatibilityOptionKey('cursor')));
    const savedMouse: string = RustDeskNapi.getOption(this.compatibilityOptionKey('relative'));
    this.relativeMouseEnabled = this.relativeMouseSupported &&
      (savedMouse === '1' || (savedMouse === '' && this.oneKvmPeer));
    if (this.relativeMouseEnabled) this.inputMode = INPUT_MODE_MOUSE;
    this.applyInputCompatibility();
    this.inputCompatibilityLoaded = true;
  }

  applyInputCompatibility(): void {
    this.releaseHeldMouseButtons('input_mode_change');
    this.stopEdgeAutoPan();
    this.relativePointerSampleValid = false;
    ConnectionService.configureInputModes(this.keyboardCompatibilityMode, this.relativeMouseEnabled);
    this.updateSystemPointerVisibility();
    RustDeskNapi.appendDiagnosticLog('input', `compatibility keyboard=${this.keyboardCompatibilityMode} ` +
      `one_kvm=${this.oneKvmPeer} relative=${this.relativeMouseEnabled} cursor=${this.cursorCompatibilityMode}`);
  }

  suppressCompatibilityCursor(): boolean {
    return shouldSuppressCursor(this.cursorCompatibilityMode, this.oneKvmPeer);
  }

  setRelativeMouse(enabled: boolean): void {
    this.releaseHeldMouseButtons('relative_mode_change');
    this.relativeMouseEnabled = enabled && this.relativeMouseSupported;
    if (this.relativeMouseEnabled) this.setInputMode(INPUT_MODE_MOUSE);
    RustDeskNapi.setOption(this.compatibilityOptionKey('relative'), this.relativeMouseEnabled ? '1' : '0');
    this.applyInputCompatibility();
  }

  @Builder
  buildInputCompatibilityOptions() {
    Text(this.oneKvmPeer ? 'One-KVM 键鼠兼容' : '键鼠兼容（仅当前设备）')
      .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.primaryTextColor()).width('100%')
    Row() {
      Text('键盘模式').fontSize(14).fontColor(this.primaryTextColor()).layoutWeight(1)
      Select([{ value: '自动' }, { value: '1:1 映射' }, { value: '传统' }])
        .selected(this.keyboardCompatibilityMode)
        .value(this.keyboardCompatibilityMode === 1 ? '1:1 映射' : (this.keyboardCompatibilityMode === 2 ? '传统' : '自动'))
        .onSelect((index: number) => {
          this.releaseRemoteNavigationKeys('keyboard_mode');
          ConnectionService.releaseModifiers();
          this.keyboardCompatibilityMode = index;
          RustDeskNapi.setOption(this.compatibilityOptionKey('keyboard'), index.toString());
          this.applyInputCompatibility();
        })
    }.width('100%')
    Text('自动：One-KVM 使用传统键盘，其他设备保持原有输入方式；输入法文字仍由本地输入法提交。')
      .fontSize(11).fontColor(this.secondaryTextColor()).width('100%')
    Row() {
      Text('相对鼠标').fontSize(14).fontColor(this.primaryTextColor()).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.relativeMouseEnabled })
        .enabled(this.relativeMouseSupported)
        .onChange((value: boolean) => { this.setRelativeMouse(value); })
    }.width('100%')
    Text(this.relativeMouseSupported ?
      '发送真实移动增量，仅显示远端光标。触屏可反复滑动；实体鼠标可移出画面操作本地按钮，重新进入不会跳位。关闭此开关恢复绝对模式。' :
      '当前远端未声明支持相对鼠标；需要兼容的 Windows/One-KVM 端及 RustDesk 1.4.5 或以上协议。')
      .fontSize(11).fontColor(this.secondaryTextColor()).width('100%')
    Row() {
      Text('远端光标来源').fontSize(14).fontColor(this.primaryTextColor()).layoutWeight(1)
      Select([{ value: '自动' }, { value: '画面内嵌' }, { value: '独立光标' }])
        .selected(this.cursorCompatibilityMode === 'embedded' ? 1 : (this.cursorCompatibilityMode === 'separate' ? 2 : 0))
        .value(this.cursorCompatibilityMode === 'embedded' ? '画面内嵌' : (this.cursorCompatibilityMode === 'separate' ? '独立光标' : '自动'))
        .onSelect((index: number) => {
          this.cursorCompatibilityMode = index === 1 ? 'embedded' : (index === 2 ? 'separate' : 'auto');
          RustDeskNapi.setOption(this.compatibilityOptionKey('cursor'), this.cursorCompatibilityMode);
          this.updateSystemPointerVisibility();
        })
    }.width('100%')
    Text('自动识别 One-KVM 的画面内嵌光标；若出现双鼠标可选择“画面内嵌”，停止额外绘制。相对模式始终隐藏本地指针。')
      .fontSize(11).fontColor(this.secondaryTextColor()).width('100%')
  }

  loadVirtualMousePreference(): void {
    this.showVirtualMouse = RustDeskNapi.getOption('show-virtual-mouse') === '1';
  }

  setVirtualMouseEnabled(enabled: boolean): void {
    this.releaseVirtualMouseButtons();
    this.showVirtualMouse = enabled;
    RustDeskNapi.setOption('show-virtual-mouse', enabled ? '1' : '0');
    if (enabled) {
      this.ensurePointerInitialized();
      this.initializeVirtualMousePosition(true);
      this.syncVirtualMouseToCurrentPointer();
    } else {
      this.virtualMouseDragActive = false;
      this.virtualMouseInitialized = false;
      this.virtualMouseLastTouchResolvedAt = 0;
      this.resetVirtualMouseButtonTouch();
      this.resetVirtualMouseWheelTouch();
      this.stopEdgeAutoPan();
      this.clampViewportOffset();
    }
    RustDeskNapi.appendDiagnosticLog('input', `virtual_mouse enabled=${enabled ? 1 : 0}`);
  }

  loadToolbarOrderPreferences(): void {
    this.controlToolbarOrder = this.readToolbarOrder(
      'remote-control-toolbar-order', CONTROL_TOOLBAR_DEFAULT_ORDER);
    this.keyboardToolbarOrder = this.readToolbarOrder(
      'remote-keyboard-toolbar-order', KEYBOARD_TOOLBAR_DEFAULT_ORDER);
    this.keyboardMoreOrder = this.readToolbarOrder(
      'remote-keyboard-more-order', KEYBOARD_MORE_DEFAULT_ORDER);
  }

  togglePrivacyMode(): void {
    const enable: boolean = this.privacyModeState !== 2;
    const result: number = RustDeskNapi.setPrivacyMode(enable);
    RustDeskNapi.appendDiagnosticLog('remote-security',
      `privacy_user_toggle on=${enable} result=${result}`);
    if (result === 0) {
      this.privacyModeState = 1;
    } else {
      this.showFileToast(result === -3 ? '请先切换到屏1再开启隐私屏' :
        (result === -2 ? '被控端不支持或未允许隐私屏' : '隐私屏切换失败'));
    }
  }

  readToolbarOrder(optionKey: string, defaults: string[]): string[] {
    const saved: string = RustDeskNapi.getOption(optionKey);
    if (saved.length === 0) return defaults.slice();
    const parts: string[] = saved.split(',').filter((item: string) => defaults.indexOf(item) >= 0);
    for (const item of defaults) {
      if (parts.indexOf(item) < 0) parts.push(item);
    }
    return parts.length === defaults.length ? parts : defaults.slice();
  }

  saveToolbarOrder(kind: string): void {
    const order: string[] = kind === 'keyboardMore' ? this.keyboardMoreOrder :
      (kind === 'keyboard' ? this.keyboardToolbarOrder : this.controlToolbarOrder);
    const option: string = kind === 'keyboardMore' ? 'remote-keyboard-more-order' :
      (kind === 'keyboard' ? 'remote-keyboard-toolbar-order' : 'remote-control-toolbar-order');
    RustDeskNapi.setOption(option, order.join(','));
  }

  setEdgeAutoPanEnabled(enabled: boolean): void {
    this.edgeAutoPanEnabled = enabled;
    RustDeskNapi.setOption('edge-auto-pan-enabled', enabled ? '1' : '0');
    if (!enabled) {
      this.stopEdgeAutoPan();
      this.clampViewportOffset();
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
      this.inputMode === INPUT_MODE_MOUSE && (!this.showLocalCursor || this.relativeMouseEnabled || this.suppressCompatibilityCursor()) && this.pointerOverRemoteViewport;
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
    if (!isHovering) this.relativePointerSampleValid = false;
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
    if (isHovering) this.relativePointerSampleValid = false;
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
    if (mode === INPUT_MODE_TOUCH && this.relativeMouseEnabled) this.setRelativeMouse(false);
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
    this.discardViewportPanFrame();
    this.relativePointerSampleValid = false;
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

    // An Up may still contain the released finger. Never start another gesture
    // from the remaining fingers of a completed scroll/pinch/three-finger swipe.
    if (event.type === TouchType.Cancel) {
      RustDeskNapi.appendDiagnosticLog('gesture', 'cancel suppress_click=true');
      this.cancelActiveTouchGesture();
      this.touchSequenceDraining = true;
      return;
    }
    if (event.type === TouchType.Down && event.touches.length === 1) {
      this.touchSequenceDraining = false;
      this.touchSequenceMaxFingers = 0;
    }
    if (this.touchSequenceDraining) {
      const remaining: number = event.type === TouchType.Up ? event.touches.filter((point: TouchObject) =>
        !event.changedTouches.some((changed: TouchObject) => changed.id === point.id)).length : event.touches.length;
      if (remaining === 0) {
        this.touchSequenceDraining = false;
        this.touchSequenceMaxFingers = 0;
      }
      return;
    }
    this.touchSequenceMaxFingers = Math.max(this.touchSequenceMaxFingers, event.touches.length);

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
      if (this.isPanMode || (this.showVirtualMouse && this.isHandheldDevice())) {
        this.finishViewportPan();
      } else {
        this.finishSingleTouch(event.type === TouchType.Cancel);
      }
      this.ignoreTouchUntilNextDown = false;
      return;
    }

    if (event.touches.length >= 2) {
      if (this.viewportPanActive) this.finishViewportPan();
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

    // touchSequenceDraining/ignoreTouchUntilNextDown already reject leftover
    // pinch fingers. A genuinely new Down must initialize even immediately
    // after a pinch; swallowing it leaves pan inactive for the entire stroke.

    // RustDesk-style virtual mouse owns pointer movement. Once the canvas is
    // enlarged, a one-finger drag anywhere outside the mouse pans the canvas.
    if ((this.showVirtualMouse && this.isHandheldDevice()) || this.isPanMode) {
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

  touchGesturePoint(touch: TouchObject): RemotePoint {
    // Gesture distances/thresholds belong to the fixed window, not the
    // transformed input component. Absolute remote hit testing still uses x/y.
    if (Number.isFinite(touch.windowX) && Number.isFinite(touch.windowY)) {
      return { x: touch.windowX, y: touch.windowY };
    }
    const centerX: number = this.componentWidth / 2;
    const centerY: number = this.componentHeight / 2;
    const baseX: number = touch.x + (this.inputMode === INPUT_MODE_MOUSE ? 0 : this.getDisplayLeft());
    const baseY: number = touch.y + (this.inputMode === INPUT_MODE_MOUSE ? 0 : this.getDisplayTop());
    return {
      x: centerX + (baseX - centerX) * this.zoomScale + this.offsetX,
      y: centerY + (baseY - centerY) * this.zoomScale + this.offsetY
    };
  }

  handleTouchpadTouch(event: TouchEvent): void {
    const touch = this.touchGesturePoint(event.touches[0]);

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
        `touchpad_down second_tap=${secondTap ? 1 : 0} pending=${this.tapTimer !== -1 ? 1 : 0} ` +
        `zoom=${this.zoomScale.toFixed(2)} distance_space=window_vp`);
      if (secondTap) {
        this.clearTapTimer();
      } else {
        this.flushPendingTap();
        this.startRightClickTimer(this.lastAbsX, this.lastAbsY);
      }
      this.showToolbar = true;
      this.resetToolbarTimer();
    } else if (event.type === TouchType.Move) {
      let movedX: number = touch.x - this.touchStartX;
      let movedY: number = touch.y - this.touchStartY;
      if (Math.sqrt(movedX * movedX + movedY * movedY) >= TOUCHPAD_DRAG_START_THRESHOLD) {
        this.touchMoved = true;
        this.clearLongPressTimer();
        if (this.touchpadDragCandidate && !this.leftButtonHeld) {
          this.sendLeftDown(this.lastAbsX, this.lastAbsY);
          RustDeskNapi.appendDiagnosticLog('input', 'touchpad_drag confirmed left_down');
        }
      }
      let deltaX: number = touch.x - this.lastTouchX;
      let deltaY: number = touch.y - this.lastTouchY;
      this.lastTouchX = touch.x;
      this.lastTouchY = touch.y;
      const follow: boolean = this.shouldFollowTouchMouse();
      let remotePoint: RemotePoint = follow ?
        this.updateCenterFollowPointer(deltaX, deltaY, TOUCHPAD_POINTER_SPEED) :
        this.updatePointerFromDelta(deltaX / Math.max(0.01, this.zoomScale),
          deltaY / Math.max(0.01, this.zoomScale));
      if (!follow) this.updateEdgeAutoPan(remotePoint.x, remotePoint.y, true);
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
    const localTouch = event.touches[0];
    const touch = this.touchGesturePoint(localTouch);
    let remotePoint: RemotePoint = this.updatePointerFromLocal(localTouch.x, localTouch.y);

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
    if (!cancelled && this.touchMoved && this.shouldFollowTouchMouse()) {
      // Flush the final sample that may have fallen inside the move throttle.
      // The peer cursor must end at the same point as our followed viewport.
      ConnectionService.sendMouseEvent(this.lastAbsX, this.lastAbsY, 0);
    }
    if (this.leftButtonHeld) {
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
    } else if (wasDragCandidate && !cancelled && !this.longPressTriggered && !this.touchMoved) {
      // The first tap is held back while waiting for a possible drag. A second
      // tap released without enough movement is a normal double-click; only a
      // confirmed move sends a left-down packet.
      this.sendLeftClick(this.lastAbsX, this.lastAbsY);
      this.sendLeftClick(this.lastAbsX, this.lastAbsY);
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
    if (this.relativeMouseEnabled) {
      if (this.relativePointerSampleValid) {
        ConnectionService.sendRelativeMouseDelta(
          (localX - this.relativePointerX) * this.remoteWidth / Math.max(1, this.getDisplayWidth()),
          (localY - this.relativePointerY) * this.remoteHeight / Math.max(1, this.getDisplayHeight()));
      }
      this.relativePointerX = localX;
      this.relativePointerY = localY;
      this.relativePointerSampleValid = true;
      return { x: this.lastAbsX, y: this.lastAbsY };
    }
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
    if (this.relativeMouseEnabled) {
      // Do not clamp to our predicted cursor or throttle away movement: KVM does not echo position.
      ConnectionService.sendRelativeMouseDelta(remoteDeltaX, remoteDeltaY);
      return { x: this.lastAbsX, y: this.lastAbsY };
    }
    this.lastAbsX = Math.max(0, Math.min(this.remoteWidth - 1, this.lastAbsX + remoteDeltaX));
    this.lastAbsY = Math.max(0, Math.min(this.remoteHeight - 1, this.lastAbsY + remoteDeltaY));
    if (!this.preferAuthoritativeCursor) {
      this.remoteCursorAbsX = this.lastAbsX;
      this.remoteCursorAbsY = this.lastAbsY;
      this.updateCursorOverlayFromRemote();
    }
    return { x: this.lastAbsX, y: this.lastAbsY };
  }

  shouldFollowTouchMouse(): boolean {
    return this.isHandheldDevice() && this.edgeAutoPanEnabled && this.inputMode === INPUT_MODE_MOUSE &&
      !this.relativeMouseEnabled && !this.isPanMode && !this.showKeyboardPanel &&
      this.connectionStatus === ConnectionStatus.CONNECTED && this.canPanViewport() &&
      this.componentWidth > 0 && this.componentHeight > 0 && this.remoteWidth > 0 && this.remoteHeight > 0;
  }

  updateCenterFollowPointer(deltaX: number, deltaY: number, gain: number): RemotePoint {
    // No dwell, inertia or timer-generated mouse packets on the touch path.
    this.stopEdgeAutoPan();
    this.markLocalPointerInput();
    this.ensurePointerInitialized();
    const origin: RemotePoint = this.remotePointToVisual(0, 0);
    const scaleX: number = this.getDisplayWidth() * this.zoomScale / this.remoteWidth;
    const scaleY: number = this.getDisplayHeight() * this.zoomScale / this.remoteHeight;
    const x = followTouchMouseAxis(this.lastAbsX, deltaX * gain, scaleX, this.remoteWidth,
      this.componentWidth, origin.x, this.offsetX, this.getHorizontalPanLimit(this.zoomScale));
    const y = followTouchMouseAxis(this.lastAbsY, deltaY * gain, scaleY, this.remoteHeight,
      this.componentHeight, origin.y, this.offsetY, this.getVerticalPanLimit(this.zoomScale));
    // Pointer and viewport are updated in the same input callback; do not
    // request a video refresh or feed viewport motion back as extra input.
    this.offsetX = x.offset;
    this.offsetY = y.offset;
    this.lastAbsX = x.pointer;
    this.lastAbsY = y.pointer;
    this.remoteCursorAbsX = x.pointer;
    this.remoteCursorAbsY = y.pointer;
    this.updateCursorOverlayFromPosition(x.pointer, y.pointer);
    return { x: x.pointer, y: y.pointer };
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
    if (this.showCommunicationPanel) return false;
    this.drainNativeInputEvents();
    if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return false;
    }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) return false;

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
    if (isNavigationControlKey(controlCode)) {
      return this.forwardRemoteNavigationKey(controlCode, action === 0, 'ark');
    }
    if (this.showKeyboardPanel) {
      if (this.isModifierControlCode(controlCode)) {
        ConnectionService.sendKeyEvent(controlCode, action, event.keyCode);
        return true;
      }
      return false;
    }
    if (controlCode > 0) {
      ConnectionService.sendKeyEvent(controlCode, action, event.keyCode);
      return true;
    }

    let text: string = this.getKeyEventText(event);
    let physicalHidCode: number = this.mapHarmonyKeyCodeToUsbHidCode(event.keyCode);
    if (physicalHidCode > 0) {
      let letter: string = this.mapHarmonyKeyCodeToLetter(event.keyCode);
      if (letter.length > 0) {
        ConnectionService.sendLetterKeyEvent(letter, physicalHidCode, action);
      } else {
        ConnectionService.sendPhysicalKeyEvent(physicalHidCode, action);
      }
      return true;
    }

    if (text.length > 0) {
      let hidCode: number = this.mapAsciiToUsbHidCode(text);
      if (hidCode > 0) {
        ConnectionService.sendPhysicalKeyEvent(hidCode, action);
      } else if (event.type === KeyType.Down) {
        ConnectionService.sendText(text);
      }
      return true;
    }
    return false;
  }

  forwardRemoteNavigationKey(controlCode: number, down: boolean, source: string): boolean {
    const composing: boolean = this.showKeyboardPanel && this.keyboardComposing;
    const action: number = this.navigationKeys.route(controlCode, down, source, composing);
    if (action >= 0) {
      ConnectionService.sendKeyEvent(controlCode, action);
    }
    // Navigation names contain no typed text, passwords or candidate contents.
    RustDeskNapi.appendDiagnosticLog('input-navigation',
      `key=${navigationKeyName(controlCode)} source=${source} action=${action} ` +
      `ime=${composing ? 1 : 0} panel=${this.showKeyboardPanel ? 1 : 0}`);
    return action !== NAVIGATION_LOCAL;
  }

  releaseRemoteNavigationKeys(reason: string): void {
    const held: number[] = this.navigationKeys.reset();
    for (const code of held) ConnectionService.sendKeyEvent(code, 1);
    if (held.length > 0) {
      RustDeskNapi.appendDiagnosticLog('input-navigation', `release reason=${reason} count=${held.length}`);
    }
  }

  syncModifiersFromKeyEvent(event: KeyEvent): void {
    if (event.getModifierKeyState === undefined) {
      return;
    }
    let meta: boolean = false;
    try {
      meta = event.getModifierKeyState(['Meta']);
    } catch (_ignored) {
    }
    try {
      ConnectionService.syncHeldModifierState(
        event.getModifierKeyState(['Ctrl']),
        event.getModifierKeyState(['Shift']),
        event.getModifierKeyState(['Alt']),
        meta
      );
    } catch (_e) {
    }
  }

  syncModifiersFromPointerEvent(event: BaseEvent): void {
    this.drainNativeInputEvents();
    if (event.getModifierKeyState === undefined) {
      return;
    }
    let meta: boolean = false;
    try {
      meta = event.getModifierKeyState(['Meta']);
    } catch (_ignored) {
    }
    try {
      ConnectionService.syncHeldModifierState(
        event.getModifierKeyState(['Ctrl']),
        event.getModifierKeyState(['Shift']),
        event.getModifierKeyState(['Alt']),
        meta
      );
    } catch (_e) {
    }
  }

  requestRemoteInputFocus(): void {
    if (this.showCommunicationPanel) return;
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

  mapAsciiToUsbHidCode(text: string): number {
    if (text.length !== 1) {
      return 0;
    }
    const normalized: string = text.toLowerCase();
    const codePoint: number = normalized.charCodeAt(0);
    if (codePoint >= 97 && codePoint <= 122) {
      return 0x04 + codePoint - 97;
    }
    if (codePoint >= 49 && codePoint <= 57) {
      return 0x1E + codePoint - 49;
    }
    if (codePoint === 48) {
      return 0x27;
    }
    return 0;
  }

  mapHarmonyKeyCodeToUsbHidCode(keyCode: number): number {
    if (keyCode >= 2017 && keyCode <= 2042) {
      return 0x04 + keyCode - 2017;
    }
    if (keyCode >= 2000 && keyCode <= 2009) {
      const digit: number = keyCode - 2000;
      return digit === 0 ? 0x27 : 0x1D + digit;
    }
    switch (keyCode) {
      case 2043: return 0x36;
      case 2044: return 0x37;
      case 2056: return 0x35;
      case 2057: return 0x2D;
      case 2058: return 0x2E;
      case 2059: return 0x2F;
      case 2060: return 0x30;
      case 2061: return 0x31;
      case 2062: return 0x33;
      case 2063: return 0x34;
      case 2064: return 0x38;
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
    if (keyCode >= 2090 && keyCode <= 2101) {
      // HarmonyOS KEYCODE_F1..KEYCODE_F12 -> the stable virtual-key range
      // consumed by the native RustDesk protocol mapping.
      return 112 + keyCode - 2090;
    }
    switch (keyCode) {
      case 2045:
        return 18;
      case 2046:
        return 165;
      case 2047:
        return 16;
      case 2048:
        return 161;
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
      case 2068:
        return 33;
      case 2069:
        return 34;
      case 2070:
        return 27;
      case 2071:
        return 46;
      case 2072:
        return 17;
      case 2073:
        return 163;
      case 2074:
        return 20;
      case 2076:
        return 91;
      case 2077:
        return 92;
      case 2081:
        return 36;
      case 2082:
        return 35;
      case 2083:
        return 45;
      default:
        return 0;
    }
  }

  isModifierControlCode(controlCode: number): boolean {
    return controlCode === 16 || controlCode === 161 || controlCode === 17 || controlCode === 163 ||
      controlCode === 18 || controlCode === 165 || controlCode === 91 || controlCode === 92;
  }

  handleMultiTouch(event: TouchEvent): void {
    const first = this.touchGesturePoint(event.touches[0]);
    const second = this.touchGesturePoint(event.touches[1]);
    let dx: number = first.x - second.x;
    let dy: number = first.y - second.y;
    let distance: number = Math.sqrt(dx * dx + dy * dy);
    let centerX: number = (first.x + second.x) / 2;
    let centerY: number = (first.y + second.y) / 2;
    if (!this.multiTouchActive) {
      // A release cannot be the beginning of a new two-finger tap.
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.touchSequenceDraining = true;
        return;
      }
      this.endLocalPointerGesture();
      this.multiTouchActive = true;
      this.multiTouchGesture = 0;
      this.multiTouchStartedAt = Date.now();
      this.multiTouchStartCenterX = centerX;
      this.multiTouchStartCenterY = centerY;
      this.multiTouchLastCenterX = centerX;
      this.multiTouchLastCenterY = centerY;
      this.multiTouchMoved = false;
      RustDeskNapi.appendDiagnosticLog('gesture',
        `multi_begin fingers=${this.touchSequenceMaxFingers} zoom=${this.zoomScale.toFixed(2)} distance_space=window_vp`);
      this.clearLongPressTimer();
      this.flushPendingTap();
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
      this.pinchStartDistance = distance;
      this.pinchStartScale = this.zoomScale;
      this.lastPinchCenterX = centerX;
      this.lastPinchCenterY = centerY;
      this.lastPinchUpdateAt = Date.now();
      if (this.inputMode === INPUT_MODE_TOUCH) {
        let remotePoint: RemotePoint = this.updatePointerFromLocal(
          (event.touches[0].x + event.touches[1].x) / 2,
          (event.touches[0].y + event.touches[1].y) / 2);
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
        // Anchor the previous centroid, then translate by the real window
        // movement. Local coordinates are used only for this inverse mapping.
        const localCenterX: number = (event.touches[0].x + event.touches[1].x) / 2 - deltaX / this.zoomScale;
        const localCenterY: number = (event.touches[0].y + event.touches[1].y) / 2 - deltaY / this.zoomScale;
        let displayLocalX: number = this.inputMode === INPUT_MODE_MOUSE ? localCenterX - this.getDisplayLeft() : localCenterX;
        let displayLocalY: number = this.inputMode === INPUT_MODE_MOUSE ? localCenterY - this.getDisplayTop() : localCenterY;
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
    let isTwoFingerTap: boolean = this.touchSequenceMaxFingers === 2 &&
      this.multiTouchGesture === 0 && !this.multiTouchMoved &&
      Date.now() - this.multiTouchStartedAt <= 500;
    RustDeskNapi.appendDiagnosticLog('gesture',
      `multi_end kind=${this.multiTouchGesture} max_fingers=${this.touchSequenceMaxFingers} ` +
      `moved=${this.multiTouchMoved} right_click=${isTwoFingerTap}`);
    this.touchSequenceDraining = true;
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
    if (this.relativeMouseEnabled) { this.stopEdgeAutoPan(); return; }
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
    const touch = this.touchGesturePoint(event.touches[0]);
    if (event.type === TouchType.Down) {
      this.clearLongPressTimer();
      this.clearTapTimer();
      this.sendLeftUp(this.lastAbsX, this.lastAbsY);
      this.viewportPanActive = true;
      this.discardViewportPanFrame();
      this.viewportPanLastX = touch.x;
      this.viewportPanLastY = touch.y;
      RustDeskNapi.appendDiagnosticLog('gesture',
        `viewport_pan_begin zoom=${this.zoomScale.toFixed(2)} gain=${VIEWPORT_PAN_SPEED} distance_space=window_vp`);
      return;
    }
    if (event.type === TouchType.Move && this.viewportPanActive) {
      let deltaX: number = (touch.x - this.viewportPanLastX) * VIEWPORT_PAN_SPEED;
      let deltaY: number = (touch.y - this.viewportPanLastY) * VIEWPORT_PAN_SPEED;
      this.viewportPanLastX = touch.x;
      this.viewportPanLastY = touch.y;
      this.queueViewportPanFrame(deltaX, deltaY);
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.finishViewportPan();
    }
  }

  finishViewportPan(): void {
    this.flushViewportPanFrame();
    this.viewportPanActive = false;
    this.viewportPanLastX = 0;
    this.viewportPanLastY = 0;
    this.clampViewportOffset();
  }

  discardViewportPanFrame(): void {
    this.viewportPanFrameGeneration += 1;
    this.viewportPanFramePending = false;
  }

  flushViewportPanFrame(): void {
    if (!this.viewportPanFramePending) return;
    this.offsetX = this.clampHorizontalOffset(this.viewportPanTargetX, this.zoomScale);
    this.offsetY = this.clampVerticalOffset(this.viewportPanTargetY, this.zoomScale);
    this.discardViewportPanFrame();
    this.syncVirtualMouseToCurrentPointer();
  }

  queueViewportPanFrame(deltaX: number, deltaY: number): void {
    this.viewportPanTargetX = this.clampHorizontalOffset(
      (this.viewportPanFramePending ? this.viewportPanTargetX : this.offsetX) + deltaX, this.zoomScale);
    this.viewportPanTargetY = this.clampVerticalOffset(
      (this.viewportPanFramePending ? this.viewportPanTargetY : this.offsetY) + deltaY, this.zoomScale);
    if (this.viewportPanFramePending) return;
    this.viewportPanFramePending = true;
    const generation: number = this.viewportPanFrameGeneration;
    this.getUIContext().postFrameCallback(new ViewportFrameCallback(() => {
      if (generation === this.viewportPanFrameGeneration) this.flushViewportPanFrame();
    }));
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
    this.syncVirtualMouseToCurrentPointer();
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
    this.syncVirtualMouseToCurrentPointer();
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

  allowWaylandText(onAllowed?: () => void): boolean {
    if ((RustDeskNapi.getInputCapabilities() & 4) === 0 || this.waylandTextAllowed) return true;
    if (!this.waylandPromptOpen) {
      this.waylandPromptOpen = true;
      RustDeskNapi.appendDiagnosticLog('input-wayland', 'text_permission_prompt scope=session');
      const epoch = this.waylandPermissionEpoch;
      AlertDialog.show({ title: '允许 Wayland 文本输入？',
        message: '远端为 Wayland 桌面。软键盘和文本粘贴可能借助远端剪贴板，可能覆盖其内容。允许仅对本次连接生效，物理键盘不受影响。',
        primaryButton: { value: '暂不允许', action: () => { this.waylandPromptOpen = false;
          RustDeskNapi.appendDiagnosticLog('input-wayland', 'text_permission_denied scope=session'); } },
        secondaryButton: { value: '本次允许', action: () => {
          this.waylandPromptOpen = false;
          if (!this.remotePageVisible || this.connectionStatus !== ConnectionStatus.CONNECTED || epoch !== this.waylandPermissionEpoch) return;
          this.waylandTextAllowed = true;
          RustDeskNapi.appendDiagnosticLog('input-wayland', 'text_permission_granted scope=session');
          if (onAllowed) onAllowed();
        } }, cancel: () => { this.waylandPromptOpen = false;
          RustDeskNapi.appendDiagnosticLog('input-wayland', 'text_permission_cancelled scope=session'); } });
    }
    return false;
  }

  sendKeyboardText(text: string): void {
    if (!this.allowWaylandText()) return;
    if (text.length <= 0) {
      return;
    }
    let segmentStart: number = 0;
    for (let index: number = 0; index < text.length; index++) {
      let character: string = text.charAt(index);
      if (character !== '\n' && character !== '\r') {
        continue;
      }
      if (index > segmentStart) {
        this.sendKeyboardTextSegment(text.substring(segmentStart, index));
      }
      if (character === '\r' && index + 1 < text.length && text.charAt(index + 1) === '\n') {
        index++;
      }
      this.sendControlKey(13);
      segmentStart = index + 1;
    }
    if (segmentStart < text.length) {
      this.sendKeyboardTextSegment(text.substring(segmentStart));
    }
  }

  sendKeyboardTextSegment(text: string): void {
    if (text.length === 1) {
      const modifierMask: number = this.getVirtualModifierMask();
      const keyCode: number = this.getPrintableShortcutKeyCode(text);
      if (modifierMask !== 0 && keyCode > 0) {
        ConnectionService.sendShortcutKey(keyCode, modifierMask);
        RustDeskNapi.appendDiagnosticLog('input-shortcut',
          `soft_key key=${keyCode} modifiers=${modifierMask}`);
        return;
      }
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
    if (!this.allowWaylandText(() => { this.openRemoteKeyboard(); })) return;
    if (this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    this.releaseRemoteNavigationKeys('keyboard_open');
    if (!this.showKeyboardPanel) {
      this.keyboardLayoutWidth = this.pageWidth;
      this.keyboardLayoutHeight = this.pageHeight;
      this.keyboardViewportHeight = this.isHandheldLandscape() ? this.componentHeight : 0;
    }
    this.resetKeyboardCaptureBuffer();
    this.applyKeyboardResizeMode();
    this.showKeyboardPanel = true;
    setTimeout(() => {
      try {
        this.getUIContext()?.getFocusController().requestFocus('remoteKeyboardCapture');
      } catch (_e) {
      }
    }, 80);
  }

  closeRemoteKeyboard(): void {
    this.releaseRemoteNavigationKeys('keyboard_close');
    this.releaseVirtualModifiers();
    this.keyboardToolsCollapsed = !this.isHandheldLandscape();
    this.showKeyboardPanel = false;
    this.showKeyboardFunctionKeys = false;
    this.showKeyboardMoreKeys = false;
    this.resetKeyboardCaptureBuffer();
    this.restoreKeyboardAvoidMode();
    setTimeout(() => {
      this.requestRemoteInputFocus();
    }, 60);
  }

  applyKeyboardResizeMode(): void {
    if (this.keyboardAvoidModeChanged) {
      return;
    }
    try {
      const uiContext = this.getUIContext();
      this.keyboardAvoidModeBeforePanel = uiContext.getKeyboardAvoidMode();
      uiContext.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      this.keyboardAvoidModeChanged = true;
      RustDeskNapi.appendDiagnosticLog('input-shortcut', 'keyboard_avoid_mode=resize');
    } catch (_e) {
      RustDeskNapi.appendDiagnosticLog('input-shortcut', 'keyboard_avoid_mode=resize_failed');
    }
  }

  restoreKeyboardAvoidMode(): void {
    this.keyboardViewportHeight = 0;
    this.keyboardLayoutWidth = 0;
    this.keyboardLayoutHeight = 0;
    if (!this.keyboardAvoidModeChanged) {
      return;
    }
    try {
      this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidModeBeforePanel);
    } catch (_e) {
    }
    this.keyboardAvoidModeChanged = false;
  }

  getRemoteToolbarWidth(): number {
    if (this.isHandheldLandscape() || (this.isFullScreen && !this.isHandheldDevice())) return 104;
    const available: number = Math.max(280, (this.pageWidth > 0 ? this.pageWidth : 360) - 16);
    return Math.min(720, available);
  }

  getRemoteToolbarHeight(): number {
    if (this.isHandheldLandscape() || (this.isFullScreen && !this.isHandheldDevice())) {
      return Math.max(150, Math.min(520, (this.pageHeight > 0 ? this.pageHeight : 360) - 16));
    }
    return 54;
  }

  getRemoteToolbarCollapsedSize(): number {
    return 54;
  }

  getRemoteToolbarCurrentWidth(): number {
    return this.remoteToolbarCollapsed ? 56 : this.getRemoteToolbarWidth();
  }

  getRemoteToolbarCurrentHeight(): number {
    return this.remoteToolbarCollapsed ? this.getRemoteToolbarCollapsedSize() : this.getRemoteToolbarHeight();
  }

  getRemoteToolbarBaseX(): number {
    const width: number = this.pageWidth > 0 ? this.pageWidth : 360;
    if (this.isFullScreen && !this.isHandheldDevice()) {
      return Math.max(8, width - this.getRemoteToolbarCurrentWidth() - 108);
    }
    if (this.isHandheldLandscape()) {
      return Math.max(8, width - this.getRemoteToolbarCurrentWidth() - 8);
    }
    return Math.max(8, (width - this.getRemoteToolbarWidth()) / 2);
  }

  getRemoteToolbarBaseY(): number {
    const height: number = this.pageHeight > 0 ? this.pageHeight : 640;
    if (this.isHandheldLandscape() || (this.isFullScreen && !this.isHandheldDevice())) return 8;
    return Math.max(8, height - this.getRemoteToolbarHeight() - 18);
  }

  clampRemoteToolbarOffsetX(offset: number): number {
    const width: number = this.pageWidth > 0 ? this.pageWidth : 360;
    const baseX: number = this.getRemoteToolbarBaseX();
    const minOffset: number = 8 - baseX;
    const maxOffset: number = width - this.getRemoteToolbarCurrentWidth() - 8 - baseX;
    return Math.max(minOffset, Math.min(maxOffset, offset));
  }

  clampRemoteToolbarOffsetY(offset: number): number {
    const height: number = this.pageHeight > 0 ? this.pageHeight : 640;
    const baseY: number = this.getRemoteToolbarBaseY();
    const minOffset: number = 8 - baseY;
    const maxOffset: number = height - this.getRemoteToolbarCurrentHeight() - 8 - baseY;
    return Math.max(minOffset, Math.min(maxOffset, offset));
  }

  beginRemoteToolbarDrag(): void {
    this.remoteToolbarDragStartX = this.clampRemoteToolbarOffsetX(this.remoteToolbarOffsetX);
    this.remoteToolbarDragStartY = this.clampRemoteToolbarOffsetY(this.remoteToolbarOffsetY);
  }

  updateRemoteToolbarDrag(offsetX: number, offsetY: number): void {
    this.remoteToolbarOffsetX = this.clampRemoteToolbarOffsetX(this.remoteToolbarDragStartX + offsetX);
    this.remoteToolbarOffsetY = this.clampRemoteToolbarOffsetY(this.remoteToolbarDragStartY + offsetY);
  }

  getRemoteToolbarX(): number {
    return this.getRemoteToolbarBaseX() + this.clampRemoteToolbarOffsetX(this.remoteToolbarOffsetX);
  }

  getRemoteToolbarY(): number {
    return this.getRemoteToolbarBaseY() + this.clampRemoteToolbarOffsetY(this.remoteToolbarOffsetY);
  }

  getKeyboardToolsWidth(): number {
    if (this.isHandheldLandscape()) return 112;
    const available: number = Math.max(272, (this.pageWidth > 0 ? this.pageWidth : 360) - 12);
    return Math.min(this.isLargeLayout() ? 720 : 520, available);
  }

  keyboardMainButtonWidth(largeWidth: number, compactWidth: number): number {
    return this.isLargeLayout() ? largeWidth : compactWidth;
  }

  getKeyboardToolsHeight(): number {
    if (this.isHandheldLandscape()) {
      return Math.max(150, Math.min(540, (this.pageHeight > 0 ? this.pageHeight : 360) - 16));
    }
    return this.showKeyboardFunctionKeys || this.showKeyboardMoreKeys ? 98 : 54;
  }

  getKeyboardToolsCollapsedSize(): number {
    return 54;
  }

  getKeyboardToolsCurrentWidth(): number {
    return this.keyboardToolsCollapsed ? 56 : this.getKeyboardToolsWidth();
  }

  getKeyboardToolsCurrentHeight(): number {
    return this.keyboardToolsCollapsed ? this.getKeyboardToolsCollapsedSize() : this.getKeyboardToolsHeight();
  }

  getKeyboardToolsBaseX(): number {
    if (this.isHandheldLandscape()) return 8;
    return Math.max(8, ((this.pageWidth > 0 ? this.pageWidth : 360) - this.getKeyboardToolsWidth()) / 2);
  }

  getKeyboardToolsBaseY(): number {
    return 8;
  }

  clampKeyboardToolsOffsetX(offset: number): number {
    const width: number = this.pageWidth > 0 ? this.pageWidth : 360;
    const baseX: number = this.getKeyboardToolsBaseX();
    const minOffset: number = 8 - baseX;
    const maxOffset: number = width - this.getKeyboardToolsCurrentWidth() - 8 - baseX;
    return Math.max(minOffset, Math.min(maxOffset, offset));
  }

  clampKeyboardToolsOffsetY(offset: number): number {
    const height: number = this.pageHeight > 0 ? this.pageHeight : 640;
    const baseY: number = this.getKeyboardToolsBaseY();
    const minOffset: number = 8 - baseY;
    const maxOffset: number = height - this.getKeyboardToolsCurrentHeight() - 8 - baseY;
    return Math.max(minOffset, Math.min(maxOffset, offset));
  }

  beginKeyboardToolsDrag(): void {
    this.keyboardToolsDragStartX = this.clampKeyboardToolsOffsetX(this.keyboardToolsOffsetX);
    this.keyboardToolsDragStartY = this.clampKeyboardToolsOffsetY(this.keyboardToolsOffsetY);
  }

  updateKeyboardToolsDrag(offsetX: number, offsetY: number): void {
    this.keyboardToolsOffsetX = this.clampKeyboardToolsOffsetX(this.keyboardToolsDragStartX + offsetX);
    this.keyboardToolsOffsetY = this.clampKeyboardToolsOffsetY(this.keyboardToolsDragStartY + offsetY);
  }

  getKeyboardToolsX(): number {
    return this.getKeyboardToolsBaseX() + this.clampKeyboardToolsOffsetX(this.keyboardToolsOffsetX);
  }

  getKeyboardToolsY(): number {
    return this.getKeyboardToolsBaseY() + this.clampKeyboardToolsOffsetY(this.keyboardToolsOffsetY);
  }

  makeFunctionKeyCodes(): number[] {
    return [112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123];
  }

  refocusRemoteKeyboard(): void {
    setTimeout(() => {
      if (!this.showKeyboardPanel) return;
      try {
        this.getUIContext()?.getFocusController().requestFocus('remoteKeyboardCapture');
      } catch (_e) {
      }
    }, 30);
  }

  keyboardToolSelected(label: string, fallback: boolean): boolean {
    // Read reactive state inside the button's style expressions, not only the
    // primitive value captured by the outer @Builder call.
    switch (label) {
      case 'Ctrl': return this.virtualCtrlSelected;
      case 'Shift': return this.virtualShiftSelected;
      case 'Alt': return this.virtualAltSelected;
      case 'Win/Cmd': return this.virtualMetaSelected;
      case 'Fn': return this.showKeyboardFunctionKeys;
      case '更多': return this.showKeyboardMoreKeys;
      default: return fallback;
    }
  }

  toggleVirtualModifier(keyCode: number): void {
    let selected: boolean = !this.isVirtualModifierSelected(keyCode);
    this.setVirtualModifierSelected(keyCode, selected);
    ConnectionService.sendKeyEvent(keyCode, selected ? 0 : 1, 10000 + keyCode);
    RustDeskNapi.appendDiagnosticLog('input-shortcut',
      `modifier_toggle key=${keyCode} selected=${selected ? 1 : 0}`);
  }

  isVirtualModifierSelected(keyCode: number): boolean {
    switch (keyCode) {
      case VIRTUAL_MODIFIER_CTRL: return this.virtualCtrlSelected;
      case VIRTUAL_MODIFIER_SHIFT: return this.virtualShiftSelected;
      case VIRTUAL_MODIFIER_ALT: return this.virtualAltSelected;
      case VIRTUAL_MODIFIER_META: return this.virtualMetaSelected;
      default: return false;
    }
  }

  setVirtualModifierSelected(keyCode: number, selected: boolean): void {
    switch (keyCode) {
      case VIRTUAL_MODIFIER_CTRL: this.virtualCtrlSelected = selected; break;
      case VIRTUAL_MODIFIER_SHIFT: this.virtualShiftSelected = selected; break;
      case VIRTUAL_MODIFIER_ALT: this.virtualAltSelected = selected; break;
      case VIRTUAL_MODIFIER_META: this.virtualMetaSelected = selected; break;
    }
  }

  releaseVirtualModifiers(): void {
    const modifiers: number[] = [VIRTUAL_MODIFIER_META, VIRTUAL_MODIFIER_ALT,
      VIRTUAL_MODIFIER_SHIFT, VIRTUAL_MODIFIER_CTRL];
    for (const keyCode of modifiers) {
      if (!this.isVirtualModifierSelected(keyCode)) continue;
      this.setVirtualModifierSelected(keyCode, false);
      ConnectionService.sendKeyEvent(keyCode, 1, 10000 + keyCode);
    }
  }

  getVirtualModifierMask(): number {
    return (this.virtualCtrlSelected ? MODIFIER_MASK_CTRL : 0) |
      (this.virtualShiftSelected ? MODIFIER_MASK_SHIFT : 0) |
      (this.virtualAltSelected ? MODIFIER_MASK_ALT : 0) |
      (this.virtualMetaSelected ? MODIFIER_MASK_META : 0);
  }

  getPrintableShortcutKeyCode(character: string): number {
    if (character.length !== 1) return 0;
    const code: number = character.charCodeAt(0);
    if (code >= 65 && code <= 90) return code;
    if (code >= 97 && code <= 122) return code - 32;
    if (code >= 48 && code <= 57) return code;
    switch (character) {
      case '!': return 49;
      case '@': return 50;
      case '#': return 51;
      case '$': return 52;
      case '%': return 53;
      case '^': return 54;
      case '&': return 55;
      case '*': return 56;
      case '(': return 57;
      case ')': return 48;
      case ';':
      case ':': return 186;
      case '=':
      case '+': return 187;
      case ',':
      case '<': return 188;
      case '-':
      case '_': return 189;
      case '.':
      case '>': return 190;
      case '/':
      case '?': return 191;
      case '`':
      case '~': return 192;
      case '[':
      case '{': return 219;
      case '\\':
      case '|': return 220;
      case ']':
      case '}': return 221;
      case "'":
      case '"': return 222;
      default: return 0;
    }
  }

  resetKeyboardCaptureBuffer(): void {
    this.keyboardComposing = false;
    this.keyboardInput = KEYBOARD_CAPTURE_SENTINEL;
    this.directKeyboardCommittedText = KEYBOARD_CAPTURE_SENTINEL;
  }

  sendVirtualControlKey(keyCode: number, label: string): void {
    ConnectionService.sendKeyEvent(keyCode, 2);
    RustDeskNapi.appendDiagnosticLog('input-shortcut', `virtual_key=${label} code=${keyCode}`);
  }

  sendPresetShortcut(keyCode: number, modifierMask: number, label: string): void {
    const result: number = ConnectionService.sendShortcutKey(keyCode,
      modifierMask | this.getVirtualModifierMask());
    this.showFileToast(result === 0 ? `已发送 ${label}` : `${label} 发送失败`);
  }

  sendCtrlAltDel(): void {
    this.releaseVirtualModifiers();
    const result: number = ConnectionService.sendCtrlAltDel();
    this.showFileToast(result === 0 ? '已发送 Ctrl+Alt+Del' : 'Ctrl+Alt+Del 发送失败');
  }

  handleDirectKeyboardChange(value: string, previewText?: PreviewText): void {
    this.keyboardInput = value;
    const composing: boolean = previewText !== undefined && previewText.value.length > 0;
    if (composing !== this.keyboardComposing) {
      RustDeskNapi.appendDiagnosticLog('input-navigation', `ime_composition active=${composing ? 1 : 0}`);
    }
    this.keyboardComposing = composing;
    if (composing) {
      return;
    }

    let previous: string = this.directKeyboardCommittedText;
    if (previous.startsWith(KEYBOARD_CAPTURE_SENTINEL) && value.length > 0 && value.charAt(0) !== '1') {
      // Some IMEs replace the whole hidden field when pasting. In that case the
      // missing sentinel is not a request to erase the remote document.
      previous = '';
    }
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

    if (value.length < 16 || value.length >= 160) {
      this.resetKeyboardCaptureBuffer();
    }
  }

  handleThreeFingerGesture(event: TouchEvent): void {
    if (!this.threeFingerGestureActive) {
      this.threeFingerGestureActive = true;
      RustDeskNapi.appendDiagnosticLog('gesture', 'three_begin');
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
      const point = this.touchGesturePoint(event.touches[index]);
      centerX += point.x;
      centerY += point.y;
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
    RustDeskNapi.appendDiagnosticLog('gesture', `three_end duration_ms=${duration} keyboard=${shouldOpenKeyboard}`);

    this.threeFingerGestureActive = false;
    this.touchSequenceDraining = true;
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
    if (!this.allowWaylandText()) return;
    if (text.length <= 0) {
      return;
    }
    let result: number = RustDeskNapi.sendClipboardText(text);
    this.lastLocalClipboardText = text;
    hilog.info(LOG_DOMAIN, 'StarRustDesk', 'Manual clipboard sent result=%{public}d', result);
  }

  async stageUploadFolder(source: string, destination: string, generation: number, depth: number = 0): Promise<void> {
    if (generation !== this.uploadGeneration || depth > 32) throw new Error('已取消或目录层级过深');
    fileIo.mkdirSync(destination);
    const names = await fileIo.listFile(source);
    for (const name of names) {
      if (generation !== this.uploadGeneration) throw new Error('已取消');
      if (!name || name === '.' || name === '..' || /[\\/\u0000]/.test(name)) throw new Error('无效文件名');
      const path = `${source}/${name}`;
      const stat = fileIo.lstatSync(path);
      if (stat.isSymbolicLink()) throw new Error('文件夹含符号链接，请移除链接后重试');
      if (stat.isDirectory()) await this.stageUploadFolder(path, `${destination}/${name}`, generation, depth + 1);
      else if (stat.isFile()) {
        if (++this.uploadFolderFiles > 10000) throw new Error('文件数超过 10000，请分批发送');
        const sourceFile = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
        try { await fileIo.copyFile(sourceFile.fd, `${destination}/${name}`); }
        finally { await fileIo.close(sourceFile); }
        this.uploadFolderBytes += stat.size;
      } else { throw new Error('不支持特殊文件'); }
    }
  }

  async pickFolderForUpload(): Promise<void> {
    if (this.transferActive || this.fileOperationBusy || this.uploadStaging) return;
    this.uploadStaging = true;
    const generation = ++this.uploadGeneration;
    const trace = new OperationDiagnostic('file-transfer', 'prepare_folder');
    let staged = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      trace.event('select');
      const uris = await new picker.DocumentViewPicker(context).select({
        maxSelectNumber: 1, selectMode: picker.DocumentSelectMode.FOLDER });
      if (!uris.length || generation !== this.uploadGeneration) { trace.end('cancelled'); return; }
      const selected = new fileUri.FileUri(uris[0]);
      const name = selected.name.replace(/[\\/:*?"<>|]/g, '_');
      if (!name || !selected.path || !fileIo.statSync(selected.path).isDirectory()) throw new Error('无法读取所选文件夹');
      staged = `${context.cacheDir}/upload-folder-${Date.now()}-${name}`;
      this.uploadFolderBytes = 0; this.uploadFolderFiles = 0;
      trace.event('copy');
      await this.stageUploadFolder(selected.path, staged, generation);
      if (generation !== this.uploadGeneration) throw new Error('已取消');
      if (this.uploadFolderFiles === 0) throw new Error('所选文件夹没有可发送的文件；空文件夹可在远端新建');
      this.clearUploadQueue(); this.cleanupPendingUploadFile();
      this.pendingUploadPath = staged; this.pendingUploadName = name; staged = '';
      this.remoteFileBrowserMode = 'upload'; this.selectedRemoteDownloads = [];
      this.showRemoteFileBrowser = true; this.openRemoteDirectory('/');
      trace.end('ready', { files: this.uploadFolderFiles, bytes: this.uploadFolderBytes });
    } catch (error) {
      if (generation === this.uploadGeneration) trace.fail(error as Object); else trace.end('cancelled');
      if (generation === this.uploadGeneration) this.showFileToast((error as Error).message || '文件夹读取失败');
    } finally {
      if (staged) this.removeSandboxTree(staged);
      this.uploadStaging = false;
      this.uploadPreparationCancelled = false;
    }
  }

  async pickFileForUpload(): Promise<void> {
    if (this.transferActive || this.fileOperationBusy || this.uploadStaging) return;
    this.uploadStaging = true;
    const generation = ++this.uploadGeneration;
    const trace = new OperationDiagnostic('file-transfer', 'prepare_files');
    try {
      let context = getContext(this) as common.UIAbilityContext;
      let documentPicker = new picker.DocumentViewPicker(context);
      let options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 100;
      options.fileSuffixFilters = ['All files (*.*)|.*'];
      trace.event('select');
      let uris: string[] = await documentPicker.select(options);
      if (generation !== this.uploadGeneration) { trace.end('stale'); return; }
      if (uris.length <= 0) {
        trace.end('cancelled');
        return;
      }

      this.clearUploadQueue();
      this.cleanupPendingUploadFile();
      trace.event('copy', { items: uris.length });
      for (let index = 0; index < uris.length; index++) {
        const selected = fileIo.openSync(uris[index], fileIo.OpenMode.READ_ONLY);
        const safeName = selected.name.replace(/[\\/:*?"<>|]/g, '_');
        const path = `${context.cacheDir}/batch-upload-${Date.now()}-${index}-${safeName}`;
        try {
          await fileIo.copyFile(selected.fd, path);
          if (generation !== this.uploadGeneration) {
            trace.end('cancelled');
            fileIo.unlinkSync(path);
            return;
          }
          this.uploadQueue.push({ path: path, name: safeName, size: fileIo.statSync(path).size });
        } catch (error) {
          try { fileIo.unlinkSync(path); } catch (_e) {}
          throw error as Error;
        } finally { fileIo.closeSync(selected); }
      }
      const first = this.uploadQueue.shift();
      if (!first) { trace.end('cancelled'); return; }
      this.pendingUploadPath = first.path;
      this.pendingUploadName = first.name;
      this.remoteFileBrowserMode = 'upload';
      this.selectedRemoteDownloads = [];
      this.showRemoteFileBrowser = true;
      this.openRemoteDirectory('/');
      trace.end('ready', { items: this.uploadQueue.length + 1 });
    } catch (_e) {
      if (generation === this.uploadGeneration) trace.fail(_e as Object); else trace.end('cancelled');
      this.clearUploadQueue();
      this.cleanupPendingUploadFile();
      if (generation === this.uploadGeneration) this.showFileToast('未选择文件或无法读取文件');
    } finally {
      this.uploadStaging = false;
      this.uploadPreparationCancelled = false;
    }
  }

  clearUploadQueue(): void {
    for (const item of this.uploadQueue) {
      try { fileIo.unlinkSync(item.path); } catch (_e) {}
    }
    this.uploadQueue = [];
  }

  editRemoteFileName(entry?: RemoteDirectoryEntry): void {
    if (this.fileOperationBusy || this.transferActive) return;
    if (entry && (entry.entryType === 3 || !this.safeRemoteLeaf(entry.name))) return;
    this.nameDialog = new CustomDialogController({
      builder: NameInputDialog({ title: entry ? '重命名远端项目' : '新建远端文件夹',
        initial: entry ? entry.name : '', onSubmit: (name: string) => {
          if (name === '.' || name === '..' || /[\\/:*?"<>|\u0000-\u001F]/.test(name)) {
            this.showFileToast('名称包含不允许的字符'); return;
          }
          this.runRemoteFileOperation(entry ? 1 : 0, this.joinRemotePath(entry ? entry.name : name), name);
        } }), autoCancel: true, customStyle: true
    });
    this.nameDialog.open();
  }

  deleteRemoteEntry(entry: RemoteDirectoryEntry): void {
    if (entry.entryType === 3 || !this.safeRemoteLeaf(entry.name) || this.fileOperationBusy || this.transferActive) return;
    const path = this.joinRemotePath(entry.name);
    AlertDialog.show({ title: '删除远端项目', message: `确定永久删除“${entry.name}”${this.isRemoteDirectory(entry) ? '及其全部内容' : ''}？此操作不能撤销。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: '#D64545', action: () => {
        this.runRemoteFileOperation(this.isRemoteDirectory(entry) ? 3 : 2, path, '');
      } }
    });
  }

  safeRemoteLeaf(name: string): boolean {
    return name.length > 0 && name !== '.' && name !== '..' && !/[\\/:\u0000-\u001F]/.test(name);
  }

  runRemoteFileOperation(kind: number, path: string, name: string): void {
    if (!this.remotePageVisible || this.connectionStatus !== ConnectionStatus.CONNECTED || this.fileOperationBusy || this.transferActive) return;
    const trace = new OperationDiagnostic('file-operation', 'remote_action');
    this.fileOperationTrace = trace;
    const id = RustDeskNapi.remoteFileOperation(kind, path, name);
    if (id <= 0) { trace.end('rejected', { kind: kind, result: id }); this.showFileToast(`无法发送文件操作 (${id})`); return; }
    trace.event('queued', { kind: kind, job: id });
    this.fileOperationBusy = true;
    const poll = (attempt: number): void => {
      const raw = RustDeskNapi.takeFileOperationResult();
      if (raw) {
        try {
          const result = JSON.parse(raw) as FileOperationResult;
          if (result.id === id) {
            trace.end(result.ok ? 'completed' : 'rejected', { job: id, kind: kind });
            this.fileOperationBusy = false;
            this.showFileToast(result.ok ? '远端操作已完成' : '远端拒绝操作，请检查权限、名称及客户端版本');
            if (this.showRemoteFileBrowser) this.openRemoteDirectory(this.remoteDirectoryPath);
            return;
          }
        } catch (_e) {}
      }
      if (attempt >= 150 || this.connectionStatus !== ConnectionStatus.CONNECTED) {
        trace.end(attempt >= 150 ? 'timeout' : 'cancelled', { job: id, kind: kind });
        this.fileOperationBusy = false;
        RustDeskNapi.cancelFileOperation();
        this.showFileToast('未收到远端确认，请刷新核对结果，不要重复删除');
        return;
      }
      this.fileOperationTimer = setTimeout(() => { poll(attempt + 1); }, 100);
    };
    poll(0);
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
      return sortRemoteFiles(this.remoteDirectoryEntries, this.remoteFileSortField, this.remoteFileSortDescending);
    }
    return sortRemoteFiles(this.remoteDirectoryEntries.filter((entry: RemoteDirectoryEntry) => {
      return this.isRemoteDirectory(entry);
    }), this.remoteFileSortField, this.remoteFileSortDescending);
  }

  remoteFileSortLabel(): string {
    if (this.remoteFileSortField === 'type') return '类型';
    if (this.remoteFileSortField === 'size') return '大小';
    if (this.remoteFileSortField === 'modified') return '修改时间';
    return '名称';
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
    if (this.remoteDirectoryPath === '/') return /^[A-Za-z]:$/.test(name) ? `${name}\\` : `/${name}`;
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
    const trace = new OperationDiagnostic('file-transfer', 'prepare_download');
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
      trace.event('select', { items: requests.length });
      let uris: string[] = await documentPicker.save(options);
      if (uris.length <= 0) { trace.end('cancelled'); return; }

      trace.event('open_target');
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
        trace.end('rejected', { result: result });
        this.finishFileTransferHistory('failed', `无法启动取回任务 (${result})`);
        this.cleanupPendingDownloadFiles();
        this.showFileToast(`取回文件失败 (${result})`);
        return;
      }
      this.transferDirection = 'download';
      this.transferActive = true;
      RemoteSessionBackgroundTask.setDataTransferActive(true);
      this.resetTransferTracking(requests.length);
      trace.end('queued', { items: requests.length, bytes: estimatedBytes });
      this.closeRemoteFileBrowser(false);
      this.showFileToast(asArchive ? `开始取回，完成后将生成 ${archiveName}` : '开始取回文件');
    } catch (_e) {
      trace.fail(_e);
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
        this.transferTrace?.event('archive', { items: itemCount });
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
      this.transferTrace?.event('open_source');
      source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      let sourceSize: number = fileIo.statSync(source.fd).size;
      if (sourceSize <= 0) {
        throw new Error('downloaded source file is empty');
      }
      this.transferTrace?.event('open_target', { source_bytes: sourceSize });
      destination = fileIo.openSync(
        destinationUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      this.transferTrace?.event('copy');
      fileIo.copyFileSync(source.fd, destination.fd);
      fileIo.fsyncSync(destination.fd);
      let destinationSize: number = fileIo.statSync(destination.fd).size;
      this.transferTrace?.event('verify', { source_bytes: sourceSize, written_bytes: destinationSize });
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
    this.transferTrace?.fail(error);
    RustDeskNapi.appendDiagnosticLog(
      'file-download',
      `export_error kind=${name === 'archive' ? 'archive' : 'single-file'} code=${OperationDiagnostic.errorCode(error)}`
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
    this.uploadQueueDirectory = this.remoteDirectoryPath;
    let uploadSize: number = 0;
    let folder: boolean = false;
    try {
      folder = fileIo.statSync(this.pendingUploadPath).isDirectory();
      uploadSize = folder ? this.uploadFolderBytes : fileIo.statSync(this.pendingUploadPath).size;
    } catch (_e) {
    }
    this.beginFileTransferHistory(
      'upload', this.pendingUploadName, folder ? '文件夹' : this.fileTypeFromName(this.pendingUploadName),
      folder ? this.uploadFolderFiles : 1, uploadSize);
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
    this.transferTrace?.end('cancelled');
    this.transferTrace = new OperationDiagnostic('file-transfer', 'transfer');
    this.transferTrace.event('queued', { upload: direction === 'upload', items: itemCount, bytes: estimatedBytes });
    this.transferLastDiagnosticAt = Date.now();
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
    if (status === 'completed' || status === 'cancelled') {
      this.transferTrace?.end(status, { bytes: this.transferTransferredBytes, items: this.transferCompletedItems });
    } else {
      this.transferTrace?.fail(new Error(error), { bytes: this.transferTransferredBytes, items: this.transferCompletedItems });
    }
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
    this.transferTrace?.event('cancel_requested', { result: result });
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
      this.clearUploadQueue();
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
          const next = this.uploadQueue.shift();
          if (next) {
            this.pendingUploadPath = next.path;
            this.pendingUploadName = next.name;
            this.remoteDirectoryPath = this.uploadQueueDirectory;
            this.startPendingFileUpload();
            return;
          }
          this.showFileToast('文件传输完成');
        }
      } else if (status.state === 'failed') {
        this.clearUploadQueue();
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
        this.clearUploadQueue();
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
    if (now - this.transferLastDiagnosticAt >= 10000) {
      this.transferLastDiagnosticAt = now;
      this.transferTrace?.event('progress', { bytes: status.transferred, source_bytes: status.total,
        items: status.completedItems ?? 0, bytes_per_second: Math.round(this.transferSpeedBytesPerSecond) });
    }
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

  showInsecureFallbackPrompt(): void {
    AlertDialog.show({
      title: '服务器密钥不正确',
      message: '无法验证自建服务器密钥。降级后，本次连接将不再验证远端身份，可能存在被冒充或窃听的风险。是否仅对本次连接使用未加密模式？',
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消连接',
        action: () => {
          RustDeskNapi.appendDiagnosticLog('connection-security', 'user_rejected_insecure_fallback');
        },
      },
      secondaryButton: {
        value: '仅本次继续',
        fontColor: RustDeskTheme.ERROR,
        action: () => {
          this.connectionError = '';
          this.connectionStatus = ConnectionStatus.CONNECTING;
          this.connectingStartedAt = Date.now();
          if (!ConnectionService.retryWithoutEncryption()) {
            this.connectionStatus = ConnectionStatus.FAILED;
            this.connectionError = ConnectionService.getLastConnectionError();
          }
        },
      },
    });
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
    this.releaseRemoteNavigationKeys('disconnect');
    ConnectionService.releaseModifiers();
    this.restoreFullscreenOnLeave();
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
    this.restoreKeyboardAvoidMode();
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
    if ((RustDeskNapi.getInputCapabilities() & 4) !== 0 && !this.waylandTextAllowed) {
      this.scheduleClipboardPoll(1000);
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
    this.relativePointerSampleValid = false;
    if (display < 0 || display >= this.displayCount || display === this.currentDisplay) {
      return;
    }
    this.cancelActiveTouchGesture();
    this.stopEdgeAutoPan();
    this.currentDisplay = display;
    this.virtualMouseDragActive = false;
    this.virtualMouseInitialized = false;
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
    // The cached position belongs to the previous display until a fresh peer
    // position or display acknowledgement advances the sequence.
    const cachedCursor: RemoteCursorPosition = RustDeskNapi.getRemoteCursorPosition();
    this.lastRemoteCursorSequence = cachedCursor.sequence;
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
      if (this.lastBoundSurfaceId.length > 0 && this.surfaceId !== this.lastBoundSurfaceId) {
        // A genuinely new XComponent target must also redirect hardware output.
        // Do not overwrite the previous target/size before the safe rebind.
        this.scheduleSurfaceRebindIfSizeChanged(true);
        return;
      }
      if (this.surfaceRebindTimer !== -1) return;
      const result = RustDeskNapi.setSurfaceId(this.surfaceId);
      if (result !== 0) {
        RustDeskNapi.appendDiagnosticLog('surface', `bind_failed result=${result}`);
        return;
      }
      if (this.lastBoundSurfaceId !== this.surfaceId || this.lastSurfaceWidth <= 0 || this.lastSurfaceHeight <= 0) {
        this.lastSurfaceWidth = this.getDisplayWidth();
        this.lastSurfaceHeight = this.getDisplayHeight();
        this.lastBoundSurfaceId = this.surfaceId;
      }
      this.scheduleSurfaceRebindIfSizeChanged();
      this.requestVideoRefreshAfterSurfaceRebind();
    }
  }

  scheduleSurfaceRebindIfSizeChanged(force: boolean = false): void {
    if (this.componentWidth <= 0 || this.componentHeight <= 0 || this.connectionStatus !== ConnectionStatus.CONNECTED) {
      return;
    }
    // Letterbox/container changes are not surface changes. For example,
    // 1318x800 -> 1318x866 still displays 16:9 video at 1318x741.375.
    const width = this.getDisplayWidth();
    const height = this.getDisplayHeight();
    const currentSurfaceId = this.readCurrentSurfaceId();
    if (currentSurfaceId.length === 0 || this.lastBoundSurfaceId.length === 0) return;
    const targetChanged = currentSurfaceId !== this.lastBoundSurfaceId;
    const sizeChanged = Math.abs(width - this.lastSurfaceWidth) > 1 || Math.abs(height - this.lastSurfaceHeight) > 1;
    const viewportChanged = Math.abs(this.componentWidth - this.lastLayoutViewportWidth) > 1 ||
      Math.abs(this.componentHeight - this.lastLayoutViewportHeight) > 1;
    this.lastLayoutViewportWidth = this.componentWidth;
    this.lastLayoutViewportHeight = this.componentHeight;
    if (!force && !targetChanged && !sizeChanged) {
      if (viewportChanged) {
        RustDeskNapi.appendDiagnosticLog('surface',
          `layout_reused reason=viewport_only viewport=${Math.round(this.componentWidth)}x${Math.round(this.componentHeight)} surface=${Math.round(width)}x${Math.round(height)}`);
      }
      return;
    }
    this.surfaceRebindForced = this.surfaceRebindForced || force;
    if (this.surfaceRebindTimer !== -1) {
      clearTimeout(this.surfaceRebindTimer);
    } else {
      RustDeskNapi.appendDiagnosticLog('surface',
        `layout_change_prepare viewport=${Math.round(this.componentWidth)}x${Math.round(this.componentHeight)} surface=${Math.round(width)}x${Math.round(height)} target_changed=${targetChanged} force=${force}`)
      RustDeskNapi.prepareSurfaceRebind();
    }
    this.surfaceRebindTimer = setTimeout(() => {
      this.surfaceRebindTimer = -1;
      this.rebindSurfaceAfterLayoutChange();
    }, 180);
  }

  rebindSurfaceAfterLayoutChange(): void {
    const force = this.surfaceRebindForced;
    this.surfaceRebindForced = false;
    if (this.connectionStatus !== ConnectionStatus.CONNECTED || this.componentWidth <= 0 || this.componentHeight <= 0) {
      return;
    }
    const reboundSurfaceId = this.readCurrentSurfaceId();
    if (reboundSurfaceId.length <= 0) {
      RustDeskNapi.appendDiagnosticLog('surface', 'layout_rebind_empty_surface_id')
      RustDeskNapi.setSurfaceId('');
      return;
    }
    const width = this.getDisplayWidth();
    const height = this.getDisplayHeight();
    // A rapid resize can settle back to the original target while the render
    // writer is paused. Resume it without destroying the decoder/native window.
    if (!force && reboundSurfaceId === this.lastBoundSurfaceId &&
      Math.abs(width - this.lastSurfaceWidth) <= 1 && Math.abs(height - this.lastSurfaceHeight) <= 1) {
      const result = RustDeskNapi.setSurfaceId(reboundSurfaceId);
      RustDeskNapi.appendDiagnosticLog('surface', `layout_reused reason=settled_original result=${result}`);
      return;
    }
    this.surfaceId = reboundSurfaceId;
    const result = RustDeskNapi.rebindSurface(reboundSurfaceId);
    RustDeskNapi.appendDiagnosticLog('surface',
      `layout_rebind_completed result=${result} surface=${Math.round(width)}x${Math.round(height)} force=${force}`);
    if (result === 0) {
      this.lastBoundSurfaceId = reboundSurfaceId;
      this.lastSurfaceWidth = width;
      this.lastSurfaceHeight = height;
    }
    this.requestVideoRefreshAfterSurfaceRebind();
  }

  readCurrentSurfaceId(): string {
    try {
      const current = this.xComponentController.getXComponentSurfaceId();
      if (current.length > 0) return current;
    } catch (_e) {}
    return this.surfaceId;
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
    this.codecNameText = this.videoCodecName(frame.codec ?? 0);
    this.decoderText = this.videoDecoderName(frame.codec ?? 0, frame.decoderMode ?? 0);
    const delayMs: number = frame.delayMs ?? 0;
    const targetBitrateKb: number = frame.targetBitrateKb ?? 0;
    this.delayMs = delayMs;
    this.delayText = delayMs > 0 ? `${delayMs} ms` : '-';
    this.targetBitrateText = targetBitrateKb > 0 ? `${targetBitrateKb} kb` : '-';
    let now: number = Date.now();
    let totalFrames: number = frame.renderedFrames ?? frame.totalFrames ?? this.lastStatsFrames;
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

  videoDecoderName(codec: number, decoderMode: number): string {
    if (codec <= 0) return '-';
    if (decoderMode === 1) return '硬解';
    if (decoderMode === 2) return '软解';
    return '检测中';
  }

  updateConnectionRoute(): void {
    let route: number = ConnectionService.getConnectionRoute();
    let transport: number = ConnectionService.getConnectionTransport();
    let routeLabel: string = '未知';
    let transportLabel: string = '';
    if (route === 1) {
      routeLabel = '直连';
    } else if (route === 2) {
      routeLabel = '中继';
    }
    if (transport === 1) {
      transportLabel = 'TCP';
    } else if (transport === 2) {
      transportLabel = 'UDP/KCP';
    } else if (transport === 3) {
      transportLabel = 'IPv6/KCP';
    } else if (transport === 4) {
      transportLabel = 'WebRTC';
    } else if (transport === 5) {
      transportLabel = 'WebSocket';
    }
    this.routeText = transportLabel.length > 0 ? `${routeLabel} · ${transportLabel}` : routeLabel;
  }
}
