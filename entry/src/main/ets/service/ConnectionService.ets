import { RustDeskNapi } from './RustDeskNapi'
import { AccountSession } from './RustDeskApiService'
import { ConnectionStatus } from '../model/ConnectionModel'
import { RemoteSessionBackgroundTask } from './RemoteSessionBackgroundTask'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { connection } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { KeyboardRemapConfig, decodeKeyboardRemap, keyboardModifierBit, keyboardRemapRule } from '../model/KeyboardRemapping'
import { KeyboardLayoutBinding } from '../model/PhysicalKeyboardLayout'
import { RemoteSecurityOptions } from './RustDeskNapi'
import { InsecureConsentScope, insecureReasonForError } from '../model/InsecureConsent'
import { RemotePeerPreferences } from './RemotePeerPreferences'

interface MappedHardwarePress {
  identity: number
  deviceId: number
  source: number
  target: number
  modifiers: number
  route: string
}

export class ConnectionService {
  private static keyboardRemap: KeyboardRemapConfig = { version: 1, enabled: false, rules: [] }
  private static hardwareKeyboardLayoutSwap: boolean = false
  private static hardwareKeyboardBindings: KeyboardLayoutBinding[] = []
  private static lastKeyboardLayoutRoute: string = ''
  private static keyboardLayoutRouteLogCount: number = 0
  private static keyboardLayoutSnapshotWarning: boolean = false
  private static mappedHardwarePresses: MappedHardwarePress[] = []
  private static physicalModifierSourceCodes: number[] = []
  private static physicalModifierDeviceIds: number[] = []
  private static keyboardMode: number = 0
  private static relativeMouse: boolean = false
  private static relativeRemainderX: number = 0
  private static relativeRemainderY: number = 0

  static configureInputModes(keyboardMode: number, relativeMouse: boolean): void {
    ConnectionService.releaseModifiers()
    ConnectionService.keyboardMode = keyboardMode
    ConnectionService.relativeMouse = relativeMouse && (RustDeskNapi.getInputCapabilities() & 2) !== 0
    RustDeskNapi.setInputModes(keyboardMode, ConnectionService.relativeMouse)
    // Official activation marker is a zero-delta move; it does not reposition the pointer.
    if (ConnectionService.relativeMouse) RustDeskNapi.sendMouseRelative(0, 0, 0)
    ConnectionService.relativeRemainderX = 0
    ConnectionService.relativeRemainderY = 0
  }

  private static useExplicitKeyboardPath(): boolean {
    // Bit 0: one-KVM legacy HID; bit 3: macOS automatic raw-key mapping.
    // Neither target should use the Windows-only Shift printable fallback.
    return ConnectionService.keyboardMode !== 0 || (RustDeskNapi.getInputCapabilities() & 9) !== 0
  }

  static sendRelativeMouseDelta(dx: number, dy: number): void {
    if (!ConnectionService.relativeMouse || !Number.isFinite(dx) || !Number.isFinite(dy)) return
    ConnectionService.relativeRemainderX += dx
    ConnectionService.relativeRemainderY += dy
    const x: number = Math.trunc(ConnectionService.relativeRemainderX)
    const y: number = Math.trunc(ConnectionService.relativeRemainderY)
    if (x === 0 && y === 0) return
    ConnectionService.relativeRemainderX -= x
    ConnectionService.relativeRemainderY -= y
    RustDeskNapi.sendMouseRelative(x, y, ConnectionService.heldModifierMask)
  }
  private static readonly MODIFIER_CONTROL: number = 1
  private static readonly MODIFIER_SHIFT: number = 2
  private static readonly MODIFIER_ALT: number = 4
  private static readonly MODIFIER_META: number = 8
  private static readonly MODIFIER_CAPS_LOCK: number = 16
  private static readonly LOG_DOMAIN: number = 0x0000
  private static directModifierMask: number = 0
  private static pointerModifierMask: number = 0
  private static nativeModifierMask: number = 0
  private static physicalModifierKeys: number[] = []
  private static physicalModifierBits: number[] = []
  private static physicalModifierControlCodes: number[] = []
  private static sentModifierControlCodes: number[] = []
  private static hardwareModifierMask: number = 0
  private static heldModifierMask: number = 0
  private static capsLockEnabled: boolean = false
  private static capsLockKeyHeld: boolean = false
  private static legacyShiftLetterHidCodes: number[] = []
  private static legacyShiftLetterCodes: number[] = []
  private static legacyShiftSymbolHidCodes: number[] = []
  private static heldHidCodes: number[] = []
  // Keep a gamepad-mapped key held until both the gamepad and ordinary
  // keyboard release it. Keyboard auto-repeat still follows the existing path.
  private static keyboardOwnedHids: number[] = []
  private static gamepadOwnedHids: number[] = []
  private static heldLegacyKeys: number[] = []
  // Retry context lives only in memory and is cleared by an explicit disconnect.
  private static retryPeer: string = ''
  private static retryPassword: string = ''
  private static retrySecurity: RemoteSecurityOptions = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false }
  private static retryOsPassword: string = ''
  private static retryRendezvous: string = ''
  private static retryRelay: string = ''
  private static relayRetryUsed: boolean = false
  private static rendezvousRetryCount: number = 0
  private static relayFailureRetryCount: number = 0
  private static loginTimeoutRetryUsed: boolean = false
  private static insecureRetryUsed: boolean = false
  private static insecureRetryReasons: number[] = []
  private static rememberedInsecureSession: boolean = false
  private static discoveryRequiresConsent: boolean = false
  private static preparationGeneration: number = 0
  private static recoveryTimer: number = -1
  private static recoveryPending: boolean = false
  private static recoveryAwaitingConnected: boolean = false
  private static recoveryAttempts: number = 0
  private static recoveryStartedAt: number = -1
  private static recoveryEpoch: number = 0
  private static recoveryStopped: boolean = false
  private static manualRetryPending: boolean = false
  private static manualRetryError: string = ''
  private static sessionAuthenticated: boolean = false
  private static sessionSettings: string = ''
  private static sessionAccountRevision: number = 0
  // Attempt policy is scoped to the current peer and never persisted as a
  // server or security option: 0 automatic, 1 UDP preferred, 2 TCP fallback.
  private static gameTransportEnabled: boolean = false
  private static gameTransportAttemptPolicy: number = 0
  private static gameTcpFallbackUsed: boolean = false
  private static lastEstablishedTransport: number = 0
  private static fileOnly: boolean = false
  static isFileOnly(): boolean { return ConnectionService.fileOnly }

  static observeSession(status: number): void {
    if (status === ConnectionStatus.CONNECTED && ConnectionService.isReconnecting()) {
      RustDeskNapi.appendDiagnosticLog('connection-recovery', `transport_recovered attempt=${ConnectionService.recoveryAttempts}`)
      ConnectionService.cancelRecovery('session_connected')
    }
    if (status === ConnectionStatus.CONNECTED) {
      ConnectionService.sessionAuthenticated = true
      const actualTransport: number = RustDeskNapi.getConnectionTransport()
      if (ConnectionService.gameTransportEnabled && actualTransport !== ConnectionService.lastEstablishedTransport) {
        RustDeskNapi.appendDiagnosticLog('game-transport',
          `authenticated route=${RustDeskNapi.getConnectionRoute()} transport=${actualTransport} ` +
          `policy=${ConnectionService.gameTransportAttemptPolicy} fallback_used=${ConnectionService.gameTcpFallbackUsed ? 1 : 0}`)
      }
      ConnectionService.lastEstablishedTransport = actualTransport
      ConnectionService.recoveryStartedAt = -1
      ConnectionService.recoveryAttempts = 0
      ConnectionService.recoveryStopped = false
      ConnectionService.manualRetryError = ''
    } else if (status === ConnectionStatus.WAITING_2FA) {
      ConnectionService.cancelRecovery('authentication_required')
    }
  }

  static isRecoveryPending(): boolean { return ConnectionService.recoveryPending }
  static isManualRetryPending(): boolean { return ConnectionService.manualRetryPending }
  static isReconnecting(): boolean {
    return ConnectionService.recoveryPending || ConnectionService.recoveryAwaitingConnected || ConnectionService.manualRetryPending
  }
  static getRecoveryAttempt(): number { return ConnectionService.recoveryAttempts }

  static setGameTransportEnabled(enabled: boolean): void {
    if (enabled && !ConnectionService.gameTransportEnabled) {
      ConnectionService.gameTcpFallbackUsed = false
      ConnectionService.gameTransportAttemptPolicy = 1
    } else if (!enabled) {
      ConnectionService.gameTransportAttemptPolicy = 0
    }
    ConnectionService.gameTransportEnabled = enabled
  }

  static gameTransportDescription(): string {
    if (!ConnectionService.gameTransportEnabled) return '自动'
    if (ConnectionService.isDirectAddress(ConnectionService.retryPeer)) return 'IP 直连（TCP）'
    if (ConnectionService.gameTcpFallbackUsed) return '已回退，优先 TCP'
    return 'UDP 优先'
  }

  private static cancelRecovery(reason: string = 'explicit_session_change'): void {
    if (ConnectionService.isReconnecting() && reason !== 'session_connected') {
      RustDeskNapi.appendDiagnosticLog('connection-recovery', `transport_retry_cancelled reason=${reason}`)
    }
    ConnectionService.recoveryEpoch++
    ConnectionService.manualRetryPending = false
    ConnectionService.recoveryAwaitingConnected = false
    if (ConnectionService.recoveryTimer !== -1) clearTimeout(ConnectionService.recoveryTimer)
    ConnectionService.recoveryTimer = -1
    ConnectionService.recoveryPending = false
  }

  static recoverInterruptedSession(message: string): boolean {
    const reason: string = ConnectionService.sessionRecoveryReason(message)
    if (ConnectionService.fileOnly ||
      !reason || !ConnectionService.sessionAuthenticated || !ConnectionService.retryPeer ||
      ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision() ||
      RemoteSessionBackgroundTask.isAppBackground() || ConnectionService.insecureRetryUsed ||
      ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot()) {
      ConnectionService.cancelRecovery(reason ? 'scope_or_security_changed' : 'not_recoverable')
      return false
    }
    if (ConnectionService.recoveryStopped) return false
    if (ConnectionService.recoveryPending || ConnectionService.manualRetryPending) return true
    if (reason === 'game_udp_failed' && (!ConnectionService.gameTransportEnabled ||
      ConnectionService.gameTcpFallbackUsed || ConnectionService.insecureRetryUsed)) {
      ConnectionService.cancelRecovery('game_udp_fallback_unavailable')
      return false
    }
    if ((reason === 'game_udp_failed' || (reason === 'transport_interrupted' &&
      (ConnectionService.lastEstablishedTransport === 2 || ConnectionService.lastEstablishedTransport === 3))) &&
      ConnectionService.gameTransportEnabled &&
      !ConnectionService.gameTcpFallbackUsed && !ConnectionService.insecureRetryUsed &&
      !ConnectionService.isDirectAddress(ConnectionService.retryPeer)) {
      ConnectionService.gameTcpFallbackUsed = true
      ConnectionService.gameTransportAttemptPolicy = 2
      RustDeskNapi.appendDiagnosticLog('game-transport',
        `fallback reason=${reason === 'game_udp_failed' ? 'udp_punch_failed' : 'udp_transport_interrupted'} ` +
        'next=tcp_renegotiation security=unchanged')
    }
    const now: number = Date.now()
    if (ConnectionService.recoveryStartedAt < 0) ConnectionService.recoveryStartedAt = now
    const remaining: number = 30000 - (now - ConnectionService.recoveryStartedAt)
    if (remaining <= 0) {
      ConnectionService.recoveryStopped = true
      ConnectionService.cancelRecovery('window_elapsed')
      return false
    }
    ConnectionService.recoveryAwaitingConnected = false
    ConnectionService.recoveryPending = true
    const generation = ConnectionService.preparationGeneration
    const epoch = ++ConnectionService.recoveryEpoch
    const attempt = ++ConnectionService.recoveryAttempts
    const wait: number = Math.min(1000 * Math.pow(2, Math.min(attempt - 1, 4)), remaining)
    ConnectionService.releaseModifiers()
    RustDeskNapi.appendDiagnosticLog('connection-recovery',
      `transport_retry_scheduled attempt=${attempt} reason=${reason} wait_ms=${wait} remaining_ms=${remaining}`)
    ConnectionService.recoveryTimer = setTimeout(async () => {
      ConnectionService.recoveryTimer = -1
      try {
        if (epoch !== ConnectionService.recoveryEpoch || generation !== ConnectionService.preparationGeneration || RemoteSessionBackgroundTask.isAppBackground()) {
          RustDeskNapi.appendDiagnosticLog('connection-recovery', 'transport_retry_cancelled reason=stale_or_background'); return
        }
        if (Date.now() - ConnectionService.recoveryStartedAt >= 30000) {
          ConnectionService.recoveryStopped = true
          ConnectionService.cancelRecovery('window_elapsed'); return
        }
        if (!ConnectionService.isDirectAddress(ConnectionService.retryPeer)) await AccountSession.getApi().prepareConnection()
        if (epoch !== ConnectionService.recoveryEpoch || generation !== ConnectionService.preparationGeneration ||
          ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision() ||
          ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot() ||
          RemoteSessionBackgroundTask.isAppBackground()) {
          RustDeskNapi.appendDiagnosticLog('connection-recovery', 'transport_retry_cancelled reason=account_network_or_foreground_changed'); return
        }
        if (Date.now() - ConnectionService.recoveryStartedAt >= 30000) {
          ConnectionService.recoveryStopped = true
          ConnectionService.cancelRecovery('window_elapsed'); return
        }
        RustDeskNapi.appendDiagnosticLog('connection-recovery', `transport_retry_started attempt=${attempt}`)
        ConnectionService.recoveryAwaitingConnected = ConnectionService.restartConnection(
          ConnectionService.relayRetryUsed, reason, attempt, 0)
      } catch (_error) {
        RustDeskNapi.appendDiagnosticLog('connection-recovery', 'transport_retry_cancelled reason=account_gate')
        if (epoch === ConnectionService.recoveryEpoch) ConnectionService.recoveryStopped = true
      } finally {
        if (epoch === ConnectionService.recoveryEpoch && generation === ConnectionService.preparationGeneration) {
          ConnectionService.recoveryPending = false
        }
      }
    }, wait)
    return true
  }

  private static sessionRecoveryReason(message: string): string {
    // Only fixed local messages: arbitrary peer denial text must never trigger retry.
    if (message === '远端传输中断' || message === 'Peer transport interrupted' ||
      message === '远端连接已断开' || message === 'Peer connection closed' || message === 'Reset by the peer') return 'transport_interrupted'
    if (message === 'UDP 直连失败，准备重新协商 TCP') return 'game_udp_failed'
    if (message === '远端设备已离线' || message === 'Remote desktop is offline') return 'peer_temporarily_offline'
    if (message === 'ID 服务器未响应' || message === 'Rendezvous server did not respond' ||
      message === '中继连接失败' || message === 'Relay connection failed' || message === '连接超时' ||
      message === 'Connection timed out' || message === '远端登录超时') return 'session_route_unavailable'
    return ''
  }

  static async retryCurrentSession(): Promise<boolean> {
    if (ConnectionService.isReconnecting() || !ConnectionService.retryPeer ||
      RustDeskNapi.getConnectionStatus() !== ConnectionStatus.FAILED) return false
    ConnectionService.cancelRecovery('manual_retry')
    ConnectionService.recoveryAttempts = 0
    ConnectionService.recoveryStartedAt = -1
    ConnectionService.recoveryStopped = false
    ConnectionService.manualRetryError = ''
    const generation = ++ConnectionService.preparationGeneration
    const epoch = ConnectionService.recoveryEpoch
    ConnectionService.manualRetryPending = true
    RustDeskNapi.appendDiagnosticLog('connection-recovery', `manual_retry_requested generation=${generation}`)
    try {
      if (ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot() ||
        ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision()) {
        ConnectionService.manualRetryError = '服务器配置或账号已改变，请返回首页重新连接'
        return false
      }
      if (!ConnectionService.isDirectAddress(ConnectionService.retryPeer)) await AccountSession.getApi().prepareConnection()
      if (epoch !== ConnectionService.recoveryEpoch || generation !== ConnectionService.preparationGeneration ||
        RemoteSessionBackgroundTask.isAppBackground()) return false
      if (ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot() ||
        ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision()) {
        ConnectionService.manualRetryError = '服务器配置或账号已改变，请返回首页重新连接'
        return false
      }
      // The previous one-time insecure consent never carries into a manual retry.
      ConnectionService.insecureRetryUsed = false
      ConnectionService.insecureRetryReasons = []
      ConnectionService.rememberedInsecureSession = false
      ConnectionService.rendezvousRetryCount = 0
      ConnectionService.relayFailureRetryCount = 0
      ConnectionService.loginTimeoutRetryUsed = false
      ConnectionService.recoveryAwaitingConnected = ConnectionService.restartConnection(
        ConnectionService.relayRetryUsed, 'manual_retry', 1, 1)
      return ConnectionService.recoveryAwaitingConnected
    } catch (_error) {
      if (epoch === ConnectionService.recoveryEpoch) {
        ConnectionService.manualRetryError = '无法重新连接，请检查服务器账号与网络后重试'
        RustDeskNapi.appendDiagnosticLog('connection-recovery', 'manual_retry_failed reason=account_gate')
      }
      return false
    } finally {
      if (epoch === ConnectionService.recoveryEpoch) ConnectionService.manualRetryPending = false
    }
  }

  static async connect(remoteId: string, password: string, performancePreset: string = 'smooth', fileOnly: boolean = false,
    security: RemoteSecurityOptions = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false },
    osPassword: string = '', discoveryRequiresConsent: boolean = false): Promise<ConnectionStatus> {
    ConnectionService.cancelRecovery()
    ConnectionService.recoveryAttempts = 0
    ConnectionService.recoveryStartedAt = -1
    ConnectionService.recoveryStopped = false
    ConnectionService.manualRetryError = ''
    ConnectionService.sessionAuthenticated = false
    const generation: number = ++ConnectionService.preparationGeneration
    const settings: string = ConnectionService.authNetworkSnapshot()
    const started: number = Date.now()
    const direct: boolean = ConnectionService.isDirectAddress(remoteId.replace(/[\s\u200B-\u200D\uFEFF]+/g, ''))
    RustDeskNapi.appendDiagnosticLog('connection-auth', `gate_start generation=${generation} direct_ip=${direct}`)
    if (!direct) {
      try {
        await AccountSession.getApi().prepareConnection()
      } catch (error) {
        RustDeskNapi.appendDiagnosticLog('connection-auth', `gate_failed generation=${generation} reason=account_unavailable elapsed_ms=${Date.now() - started}`)
        throw error as Error
      }
    }
    if (generation !== ConnectionService.preparationGeneration || settings !== ConnectionService.authNetworkSnapshot()) {
      RustDeskNapi.appendDiagnosticLog('connection-auth', `gate_cancelled generation=${generation} cancelled=${generation !== ConnectionService.preparationGeneration} network_changed=${settings !== ConnectionService.authNetworkSnapshot()} elapsed_ms=${Date.now() - started}`)
      throw new Error('连接已取消或服务器配置已改变，请重试')
    }
    RustDeskNapi.appendDiagnosticLog('connection-auth', `gate_ready generation=${generation} elapsed_ms=${Date.now() - started}`)
    ConnectionService.relativeMouse = false
    ConnectionService.keyboardMode = 0
    ConnectionService.resetTransientInputState()
    ConnectionService.recordNetworkSnapshot()
    let peerId: string = remoteId.replace(/[\s\u200B-\u200D\uFEFF]+/g, '')
    let rendezvousServer: string = RustDeskNapi.getOption('custom-rendezvous-server').trim()
    let relayServer: string = RustDeskNapi.getOption('relay-server').trim()
    ConnectionService.retryPeer = peerId
    ConnectionService.retryPassword = password
    ConnectionService.retrySecurity = security
    ConnectionService.retryOsPassword = security.autoUnlock ? osPassword : ''
    ConnectionService.retryRendezvous = rendezvousServer
    ConnectionService.retryRelay = relayServer
    ConnectionService.relayRetryUsed = false
    ConnectionService.rendezvousRetryCount = 0
    ConnectionService.relayFailureRetryCount = 0
    ConnectionService.loginTimeoutRetryUsed = false
    ConnectionService.insecureRetryUsed = false
    ConnectionService.insecureRetryReasons = []
    ConnectionService.rememberedInsecureSession = false
    ConnectionService.discoveryRequiresConsent = discoveryRequiresConsent
    ConnectionService.sessionSettings = ConnectionService.authNetworkSnapshot()
    ConnectionService.sessionAccountRevision = AccountSession.getApi().sessionRevision()
    ConnectionService.fileOnly = fileOnly
    const preferences: RemotePeerPreferences = new RemotePeerPreferences(rendezvousServer, peerId)
    ConnectionService.gameTransportEnabled = !fileOnly && preferences.get('game-mode') === '1'
    preferences.dispose()
    ConnectionService.gameTransportAttemptPolicy = ConnectionService.gameTransportEnabled ? 1 : 0
    ConnectionService.gameTcpFallbackUsed = false
    ConnectionService.lastEstablishedTransport = 0
    RustDeskNapi.appendDiagnosticLog('game-transport',
      `initial_policy=${ConnectionService.gameTransportAttemptPolicy} direct_endpoint=${direct ? 1 : 0}`)
    RustDeskNapi.appendDiagnosticLog('connection', `session_mode=${fileOnly ? 'file_transfer_only' : 'remote_control'} generation=${generation}`)
    RustDeskNapi.appendDiagnosticLog('remote-security',
      `session_options lock=${security.lockAfterDisconnect} privacy=${security.privacyMode} ` +
      `auto_unlock=${security.autoUnlock} os_password_configured=${ConnectionService.retryOsPassword.length > 0}`)
    // Do not carry a previous peer's transient game policy into this session.
    RustDeskNapi.setGameMode(ConnectionService.gameTransportEnabled)
    RustDeskNapi.setHighPerformance(false)
    RustDeskNapi.setPerformancePreset(performancePreset)
    let result: number
    if (rendezvousServer.length > 0) {
      result = RustDeskNapi.connectWithServer(peerId, password, rendezvousServer, relayServer, false, false, fileOnly,
        security, ConnectionService.retryOsPassword, 0, ConnectionService.gameTransportAttemptPolicy)
    } else {
      result = RustDeskNapi.connect(peerId, password, false, fileOnly, security, ConnectionService.retryOsPassword,
        0, ConnectionService.gameTransportAttemptPolicy)
    }
    let status: ConnectionStatus = result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED
    RemoteSessionBackgroundTask.syncForConnectionStatus(status)
    return status
  }

  private static authNetworkSnapshot(): string {
    return JSON.stringify(['api-server', 'custom-rendezvous-server', 'relay-server', 'key']
      .map((key: string) => RustDeskNapi.getOption(key)))
  }

  static cancelPendingConnection(): void {
    ConnectionService.cancelRecovery()
    ConnectionService.preparationGeneration++
  }

  static async recordNetworkSnapshot(source: 'connect' | 'online_state' = 'connect'): Promise<void> {
    if (RustDeskNapi.getOption('diagnostic-log-enabled') !== '1') {
      return
    }
    try {
      const net: connection.NetHandle = await connection.getDefaultNet()
      const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(net)
      RustDeskNapi.appendDiagnosticLog('network',
        `${source === 'online_state' ? 'online_state_snapshot' : 'connect_snapshot'} net=${net.netId} wifi=${capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)} ` +
        `cellular=${capabilities.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)} ` +
        `ethernet=${capabilities.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)}`)
    } catch (error) {
      RustDeskNapi.appendDiagnosticLog('network', `snapshot_failed code=${(error as BusinessError).code}`)
    }
  }

  static disconnect(): void {
    ConnectionService.cancelRecovery()
    ConnectionService.manualRetryError = ''
    ConnectionService.sessionAuthenticated = false
    ConnectionService.gameTransportEnabled = false
    ConnectionService.gameTransportAttemptPolicy = 0
    ConnectionService.gameTcpFallbackUsed = false
    ConnectionService.lastEstablishedTransport = 0
    ConnectionService.preparationGeneration++
    ConnectionService.relativeMouse = false
    ConnectionService.retryPeer = ''
    ConnectionService.retryPassword = ''
    ConnectionService.retryOsPassword = ''
    ConnectionService.retrySecurity = { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false }
    ConnectionService.relayRetryUsed = true
    ConnectionService.rendezvousRetryCount = 2
    ConnectionService.relayFailureRetryCount = 1
    ConnectionService.loginTimeoutRetryUsed = true
    ConnectionService.insecureRetryUsed = true
    ConnectionService.releaseModifiers()
    RemoteSessionBackgroundTask.stop()
    RustDeskNapi.disconnect()
    ConnectionService.resetTransientInputState()
  }

  static retryDirectViaRelay(reason: string): boolean {
    const status: number = RustDeskNapi.getConnectionStatus()
    if (ConnectionService.relayRetryUsed || ConnectionService.retryPeer.length === 0 ||
      /^(\d{1,3}\.){3}\d{1,3}(:\d+)?$/.test(ConnectionService.retryPeer) ||
      ConnectionService.retryPeer.includes(':') ||
      RustDeskNapi.getConnectionRoute() !== 1 ||
      (status !== ConnectionStatus.CONNECTING && status !== ConnectionStatus.CONNECTED)) {
      return false
    }
    ConnectionService.relayRetryUsed = true
    ConnectionService.releaseModifiers()
    RustDeskNapi.appendDiagnosticLog('connection-recovery', `direct_stall retry=relay attempt=1 reason=${reason}`)
    RustDeskNapi.disconnect()
    ConnectionService.recordNetworkSnapshot()
    const result: number = RustDeskNapi.connectWithServer(ConnectionService.retryPeer,
      ConnectionService.retryPassword, ConnectionService.retryRendezvous, ConnectionService.retryRelay, true,
      false, false, ConnectionService.retrySecurity, ConnectionService.retryOsPassword)
    ConnectionService.resetTransientInputState()
    RemoteSessionBackgroundTask.syncForConnectionStatus(
      result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED)
    return result === 0
  }

  static retryRecoverableConnectionFailure(message: string): string {
    // Established-session recovery has its own backoff/window and security gate.
    if (ConnectionService.sessionAuthenticated || ConnectionService.manualRetryPending) return ''
    if (ConnectionService.fileOnly || ConnectionService.retryPeer.length === 0 ||
      ConnectionService.isDirectAddress(ConnectionService.retryPeer) ||
      RustDeskNapi.getConnectionStatus() !== ConnectionStatus.FAILED) {
      return ''
    }

    const route: number = RustDeskNapi.getConnectionRoute()
    if (message === 'UDP 直连失败，准备重新协商 TCP' && ConnectionService.gameTransportEnabled &&
      !ConnectionService.gameTcpFallbackUsed && !ConnectionService.insecureRetryUsed &&
      !RemoteSessionBackgroundTask.isAppBackground() &&
      ConnectionService.sessionAccountRevision === AccountSession.getApi().sessionRevision() &&
      ConnectionService.sessionSettings === ConnectionService.authNetworkSnapshot()) {
      ConnectionService.gameTcpFallbackUsed = true
      ConnectionService.gameTransportAttemptPolicy = 2
      RustDeskNapi.appendDiagnosticLog('game-transport', 'fallback reason=udp_punch_failed next=tcp_renegotiation security=unchanged')
      if (ConnectionService.restartConnection(false, 'game_udp_failed', 1, 1)) {
        return 'UDP 直连失败，正在尝试 TCP 或中继'
      }
      return ''
    }
    if (message === '远端登录超时' && !ConnectionService.loginTimeoutRetryUsed &&
      !ConnectionService.sessionAuthenticated && !ConnectionService.insecureRetryUsed &&
      !RemoteSessionBackgroundTask.isAppBackground()) {
      ConnectionService.loginTimeoutRetryUsed = true
      ConnectionService.relayRetryUsed = true
      if (ConnectionService.restartConnection(true, 'peer_login_timeout', 1, 1)) {
        return '远端登录无响应，正在重新连接（1/1）'
      }
      return ''
    }
    // The native layer already performs one bounded encrypted relay retry for
    // classified transport failures. An unclassified security error can be an
    // invalid identity/signature and must not trigger another automatic retry.

    if ((message === 'ID 服务器未响应' || message === 'Rendezvous server did not respond') &&
      ConnectionService.rendezvousRetryCount < 2) {
      ConnectionService.rendezvousRetryCount++
      const attempt: number = ConnectionService.rendezvousRetryCount
      // Preserve a forced-relay recovery selected after a direct secure
      // handshake failure. A transient hbbs timeout must not send the next
      // attempt back to the direct route that already failed authentication.
      if (ConnectionService.restartConnection(ConnectionService.relayRetryUsed,
        'rendezvous_timeout', attempt, 2)) {
        return `注册服务器未响应，正在重新连接（${attempt}/2）`
      }
      return ''
    }

    if ((message === '中继连接失败' || message === 'Relay connection failed') &&
      ConnectionService.relayFailureRetryCount < 1) {
      ConnectionService.relayFailureRetryCount++
      ConnectionService.relayRetryUsed = true
      if (ConnectionService.restartConnection(true, 'relay_connection_failed', 1, 1)) {
        return '中继连接失败，正在重新申请中继线路'
      }
    }
    return ''
  }

  private static restartConnection(forceRelay: boolean, reason: string, attempt: number, maximum: number): boolean {
    ConnectionService.releaseModifiers()
    RustDeskNapi.appendDiagnosticLog('connection-recovery',
      `automatic_retry reason=${reason} attempt=${attempt} maximum=${maximum > 0 ? maximum.toString() : 'time_window'} ` +
      `previous_route=${RustDeskNapi.getConnectionRoute()} force_relay=${forceRelay ? 1 : 0} ` +
      `transport_policy=${ConnectionService.gameTransportAttemptPolicy}`)
    RustDeskNapi.disconnect()
    ConnectionService.recordNetworkSnapshot()
    const result: number = RustDeskNapi.connectWithServer(ConnectionService.retryPeer,
      ConnectionService.retryPassword, ConnectionService.retryRendezvous, ConnectionService.retryRelay, forceRelay,
      false, ConnectionService.fileOnly, ConnectionService.retrySecurity, ConnectionService.retryOsPassword,
      0, ConnectionService.gameTransportAttemptPolicy)
    ConnectionService.resetTransientInputState()
    const status: ConnectionStatus = result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED
    RemoteSessionBackgroundTask.syncForConnectionStatus(status)
    RustDeskNapi.appendDiagnosticLog(result === 0 ? 'connection-recovery' : 'connection',
      `automatic_retry_started reason=${reason} result=${result}`)
    return result === 0
  }

  static retryUnstableGameUdp(transferActive: boolean, securityState: number, beforeReconnect: () => void): boolean {
    const transport: number = RustDeskNapi.getConnectionTransport()
    if (!ConnectionService.gameTransportEnabled || ConnectionService.gameTcpFallbackUsed ||
      !ConnectionService.sessionAuthenticated || ConnectionService.fileOnly || ConnectionService.insecureRetryUsed ||
      securityState !== 1 || transferActive || ConnectionService.retrySecurity.lockAfterDisconnect ||
      ConnectionService.retrySecurity.privacyMode || RustDeskNapi.getPrivacyModeState() > 0 ||
      RemoteSessionBackgroundTask.isAppBackground() ||
      ConnectionService.isReconnecting() || ConnectionService.isDirectAddress(ConnectionService.retryPeer) ||
      (transport !== 2 && transport !== 3) || RustDeskNapi.getConnectionStatus() !== ConnectionStatus.CONNECTED ||
      ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision() ||
      ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot()) return false
    // Release the page-owned mouse/gamepad buttons while the old session is
    // still alive. If that fails, do not initiate a discretionary reconnect.
    try { beforeReconnect() } catch (_error) {
      RustDeskNapi.appendDiagnosticLog('game-transport', 'fallback_deferred reason=input_release_failed')
      return false
    }
    ConnectionService.gameTcpFallbackUsed = true
    ConnectionService.gameTransportAttemptPolicy = 2
    ConnectionService.recoveryStartedAt = Date.now()
    ConnectionService.recoveryAttempts = 1
    RustDeskNapi.appendDiagnosticLog('game-transport',
      'fallback reason=sustained_high_peer_delay next=tcp_renegotiation security=unchanged')
    ConnectionService.recoveryAwaitingConnected = ConnectionService.restartConnection(false, 'game_udp_unstable', 1, 1)
    return ConnectionService.recoveryAwaitingConnected
  }

  static reconnectForGameMode(beforeReconnect: () => void): boolean {
    if (!ConnectionService.gameTransportEnabled || !ConnectionService.sessionAuthenticated || ConnectionService.fileOnly ||
      ConnectionService.insecureRetryUsed || ConnectionService.retrySecurity.lockAfterDisconnect ||
      ConnectionService.retrySecurity.privacyMode || RustDeskNapi.getPrivacyModeState() > 0 ||
      ConnectionService.isDirectAddress(ConnectionService.retryPeer) || RemoteSessionBackgroundTask.isAppBackground() ||
      ConnectionService.isReconnecting() || RustDeskNapi.getConnectionStatus() !== ConnectionStatus.CONNECTED ||
      ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision() ||
      ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot()) return false
    try { beforeReconnect() } catch (_error) {
      RustDeskNapi.appendDiagnosticLog('game-transport', 'manual_reconnect_cancelled reason=input_release_failed')
      return false
    }
    ConnectionService.gameTcpFallbackUsed = false
    ConnectionService.gameTransportAttemptPolicy = 1
    ConnectionService.recoveryStartedAt = Date.now()
    ConnectionService.recoveryAttempts = 1
    RustDeskNapi.appendDiagnosticLog('game-transport', 'manual_reconnect policy=udp_preferred security=unchanged')
    ConnectionService.recoveryAwaitingConnected = ConnectionService.restartConnection(false, 'game_mode_requested', 1, 1)
    return ConnectionService.recoveryAwaitingConnected
  }

  private static isDirectAddress(peer: string): boolean {
    return /^(\d{1,3}\.){3}\d{1,3}(:\d+)?$/.test(peer) || peer.includes(':')
  }

  static canRetryWithoutEncryption(): boolean {
    const message: string = RustDeskNapi.getLastConnectionError()
    return ConnectionService.retryPeer.length > 0 &&
      RustDeskNapi.getConnectionStatus() === ConnectionStatus.FAILED &&
      insecureReasonForError(message) !== 0 &&
      !ConnectionService.insecureRetryReasons.includes(insecureReasonForError(message))
  }

  static isRememberedInsecureSession(): boolean { return ConnectionService.rememberedInsecureSession }

  static requiresExplicitDiscoveryConsent(): boolean { return ConnectionService.discoveryRequiresConsent }

  static insecureConsentScope(): InsecureConsentScope | undefined {
    if (!ConnectionService.canRetryWithoutEncryption() ||
      ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot() ||
      ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision()) return undefined
    return { peer: ConnectionService.retryPeer, network: ConnectionService.sessionSettings,
      reason: insecureReasonForError(RustDeskNapi.getLastConnectionError()),
      generation: ConnectionService.preparationGeneration }
  }

  static isInsecureConsentScopeCurrent(scope: InsecureConsentScope): boolean {
    const current = ConnectionService.insecureConsentScope()
    return current !== undefined && current.peer === scope.peer && current.network === scope.network &&
      current.reason === scope.reason && current.generation === scope.generation
  }

  static retryWithoutEncryption(expectedReason: number = 0, remembered: boolean = false): boolean {
    if (remembered && ConnectionService.discoveryRequiresConsent) return false
    if (!ConnectionService.canRetryWithoutEncryption()) {
      return false
    }
    const reason: number = insecureReasonForError(RustDeskNapi.getLastConnectionError())
    if (expectedReason !== 0 && expectedReason !== reason) return false
    // Consent applies to the network/account configuration that produced the
    // warning, never to a different server or account selected in the meantime.
    if (ConnectionService.sessionSettings !== ConnectionService.authNetworkSnapshot() ||
      ConnectionService.sessionAccountRevision !== AccountSession.getApi().sessionRevision()) {
      ConnectionService.manualRetryError = '服务器配置或账号已改变，请返回首页重新连接'
      RustDeskNapi.appendDiagnosticLog('connection-security',
        'insecure_fallback_cancelled reason=account_or_network_changed')
      return false
    }
    ConnectionService.insecureRetryUsed = true
    ConnectionService.insecureRetryReasons.push(reason)
    ConnectionService.rememberedInsecureSession = remembered
    ConnectionService.releaseModifiers()
    RustDeskNapi.appendDiagnosticLog('connection-security',
      `insecure_fallback_approved source=${remembered ? 'remembered' : 'explicit'} reason=${reason}`)
    RustDeskNapi.disconnect()
    ConnectionService.recordNetworkSnapshot()
    let result: number
    if (ConnectionService.retryRendezvous.length > 0) {
      result = RustDeskNapi.connectWithServer(ConnectionService.retryPeer, ConnectionService.retryPassword,
        ConnectionService.retryRendezvous, ConnectionService.retryRelay, false, true, ConnectionService.fileOnly,
        ConnectionService.retrySecurity, ConnectionService.retryOsPassword, reason)
    } else {
      result = RustDeskNapi.connect(ConnectionService.retryPeer, ConnectionService.retryPassword, true,
        ConnectionService.fileOnly, ConnectionService.retrySecurity, ConnectionService.retryOsPassword, reason)
    }
    ConnectionService.resetTransientInputState()
    RemoteSessionBackgroundTask.syncForConnectionStatus(
      result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED)
    return result === 0
  }

  static configureKeyboardRemapping(value: string): void {
    ConnectionService.releaseModifiers()
    ConnectionService.keyboardRemap = decodeKeyboardRemap(value)
    RustDeskNapi.appendDiagnosticLog('input-remap',
      `configured enabled=${ConnectionService.keyboardRemap.enabled ? 1 : 0} rules=${ConnectionService.keyboardRemap.rules.length}`)
  }

  static configureHardwareKeyboardLayout(swap: boolean, bindings: KeyboardLayoutBinding[] = []): void {
    const next: KeyboardLayoutBinding[] = bindings.filter((item: KeyboardLayoutBinding) =>
      Number.isSafeInteger(item.deviceId) && item.deviceId >= 0).map((item: KeyboardLayoutBinding): KeyboardLayoutBinding =>
      ({ deviceId: item.deviceId, swap: item.swap && item.calibrated, calibrated: item.calibrated }))
      .sort((a: KeyboardLayoutBinding, b: KeyboardLayoutBinding) => a.deviceId - b.deviceId)
    if (ConnectionService.hardwareKeyboardLayoutSwap === swap &&
      JSON.stringify(ConnectionService.hardwareKeyboardBindings) === JSON.stringify(next)) return
    ConnectionService.releaseModifiers()
    ConnectionService.hardwareKeyboardLayoutSwap = swap
    ConnectionService.hardwareKeyboardBindings = next
    ConnectionService.keyboardLayoutSnapshotWarning = false
    RustDeskNapi.appendDiagnosticLog('input-layout', `policy_applied devices=${next.length} ` +
      `calibrated=${next.filter((item: KeyboardLayoutBinding) => item.calibrated).length} ` +
      `corrected=${next.filter((item: KeyboardLayoutBinding) => item.swap).length} ` +
      `source_required=${next.length > 0 ? 1 : 0}`)
  }

  private static hasHardwareLayoutMapping(): boolean {
    return ConnectionService.hardwareKeyboardLayoutSwap ||
      ConnectionService.hardwareKeyboardBindings.some((item: KeyboardLayoutBinding) => item.swap)
  }

  private static hardwareDeviceSwap(deviceId?: number): boolean {
    if (deviceId !== undefined && Number.isSafeInteger(deviceId) && deviceId >= 0) {
      const binding = ConnectionService.hardwareKeyboardBindings.find((item: KeyboardLayoutBinding) => item.deviceId === deviceId)
      if (binding !== undefined) return binding.swap
      if (ConnectionService.hardwareKeyboardBindings.length > 0) return false
    }
    if (ConnectionService.hardwareKeyboardBindings.length > 0) return false
    return ConnectionService.hardwareKeyboardLayoutSwap
  }

  private static logHardwareLayoutRoute(deviceId: number): void {
    const valid: boolean = Number.isSafeInteger(deviceId) && deviceId >= 0
    const binding = valid ? ConnectionService.hardwareKeyboardBindings.find((item: KeyboardLayoutBinding) =>
      item.deviceId === deviceId) : undefined
    const summary: string = `identity=${valid ? 1 : 0} matched=${binding ? 1 : 0} ` +
      `calibrated=${binding?.calibrated ? 1 : 0} correction=${ConnectionService.hardwareDeviceSwap(deviceId) ? 1 : 0}`
    if (summary === ConnectionService.lastKeyboardLayoutRoute || ConnectionService.keyboardLayoutRouteLogCount >= 24) return
    ConnectionService.lastKeyboardLayoutRoute = summary
    ConnectionService.keyboardLayoutRouteLogCount++
    RustDeskNapi.appendDiagnosticLog('input-layout', `device_route ${summary}`)
  }

  private static modifierIndex(identity: number, deviceId: number): number {
    return ConnectionService.physicalModifierKeys.findIndex((key: number, index: number) =>
      key === identity && (ConnectionService.physicalModifierDeviceIds[index] === deviceId ||
        ConnectionService.physicalModifierDeviceIds[index] < 0 || deviceId < 0))
  }

  private static hardwareControlTarget(source: number, deviceId?: number): number {
    // Explicit raw-source rules win. Never remap a calibrated target again:
    // Ctrl->Command and existing Alt<->Command workarounds remain single-pass.
    const rule = keyboardRemapRule(ConnectionService.keyboardRemap, source)
    if (rule !== undefined) return rule.target
    if (!ConnectionService.hardwareDeviceSwap(deviceId)) return source
    switch (source) {
      case 18: return 91
      case 165: return 92
      case 91: return 18
      case 92: return 165
      default: return source
    }
  }

  static sendHardwareControlKey(source: number, action: number, physicalKeyCode?: number, route: string = 'hardware',
    deviceId: number = -1): void {
    ConnectionService.logHardwareLayoutRoute(deviceId)
    if ((!ConnectionService.keyboardRemap.enabled && !ConnectionService.hardwareDeviceSwap(deviceId)) || source === 20) {
      ConnectionService.sendKeyEvent(source, action, physicalKeyCode, undefined, deviceId)
      return
    }
    const identity: number = physicalKeyCode ?? source
    const rule = keyboardRemapRule(ConnectionService.keyboardRemap, source)
    if (ConnectionService.getModifierBit(source) !== 0) {
      const heldIndex: number = ConnectionService.modifierIndex(identity, deviceId)
      const target: number = action === 1 && heldIndex >= 0 ? ConnectionService.physicalModifierControlCodes[heldIndex] :
        ConnectionService.hardwareControlTarget(source, deviceId)
      ConnectionService.sendKeyEvent(target, action, identity, source, deviceId)
      return
    }
    if (!ConnectionService.keyboardRemap.enabled) {
      ConnectionService.sendKeyEvent(source, action, physicalKeyCode, undefined, deviceId)
      return
    }
    const index: number = ConnectionService.mappedHardwarePresses.findIndex((press: MappedHardwarePress) =>
      press.identity === identity && (press.deviceId === deviceId || press.deviceId < 0 || deviceId < 0))
    let press: MappedHardwarePress | undefined = index >= 0 ? ConnectionService.mappedHardwarePresses[index] : undefined
    if (action === 1) {
      if (press === undefined) return
      ConnectionService.mappedHardwarePresses.splice(index, 1)
      if (press.modifiers === 0 && !ConnectionService.mappedHardwarePresses.some((item: MappedHardwarePress) =>
        item.modifiers === 0 && item.target === press?.target)) ConnectionService.sendKeyEvent(press.target, 1)
      return
    }
    if (action !== 0 && action !== 2) return
    if (press === undefined) {
      press = { identity, deviceId, source, target: rule?.target ?? source, modifiers: rule?.modifiers ?? 0, route }
      if (action === 0) ConnectionService.mappedHardwarePresses.push(press)
      if (press.modifiers !== 0) {
        ConnectionService.sendShortcutKey(press.target, press.modifiers | ConnectionService.getKeyModifierMask())
        RustDeskNapi.appendDiagnosticLog('input-remap', 'shortcut_triggered')
        return
      }
      if (ConnectionService.mappedHardwarePresses.some((item: MappedHardwarePress) =>
        item !== press && item.modifiers === 0 && item.target === press?.target)) return
    } else if (press.modifiers !== 0 || (action === 0 && press.route !== route)) {
      // One physical shortcut fires once; mirrored ArkUI/native reports cannot repeat it.
      return
    }
    ConnectionService.sendKeyEvent(press.target, action)
  }

  static sendKeyEvent(keyCode: number, action: number, physicalKeyCode?: number, originalSourceCode?: number,
    deviceId: number = -1): void {
    if (keyCode === 20) {
      ConnectionService.sendCapsLockEvent(action)
      return
    }
    let modifierBit: number = ConnectionService.getModifierBit(keyCode)
    if (modifierBit !== 0) {
      const identity: number = physicalKeyCode ?? keyCode
      const index: number = ConnectionService.modifierIndex(identity, deviceId)
      if (action === 0) {
        if (index >= 0) {
          return
        }
        ConnectionService.physicalModifierKeys.push(identity)
        ConnectionService.physicalModifierBits.push(modifierBit)
        ConnectionService.physicalModifierControlCodes.push(keyCode)
        ConnectionService.physicalModifierSourceCodes.push(originalSourceCode ?? keyCode)
        ConnectionService.physicalModifierDeviceIds.push(deviceId)
        ConnectionService.directModifierMask |= modifierBit
      } else if (action === 1) {
        if (index < 0) {
          return
        }
        ConnectionService.physicalModifierKeys.splice(index, 1)
        ConnectionService.physicalModifierBits.splice(index, 1)
        ConnectionService.physicalModifierControlCodes.splice(index, 1)
        const original: number = ConnectionService.physicalModifierSourceCodes[index] ?? keyCode
        ConnectionService.physicalModifierSourceCodes.splice(index, 1)
        ConnectionService.physicalModifierDeviceIds.splice(index, 1)
        if (!ConnectionService.physicalModifierBits.includes(modifierBit)) {
          // A real key-up is authoritative. Clear stale snapshots from pointer
          // and polling sources as well so a modifier cannot remain stuck.
          ConnectionService.directModifierMask &= ~modifierBit
          if (!ConnectionService.keyboardRemap.enabled && !ConnectionService.hasHardwareLayoutMapping()) {
            ConnectionService.pointerModifierMask &= ~modifierBit
            ConnectionService.nativeModifierMask &= ~modifierBit
            ConnectionService.hardwareModifierMask &= ~modifierBit
          }
        }
        if ((ConnectionService.keyboardRemap.enabled || ConnectionService.hasHardwareLayoutMapping()) && identity < 10000 &&
          !ConnectionService.physicalModifierSourceCodes.some((code: number, i: number) =>
            ConnectionService.physicalModifierKeys[i] < 10000 && keyboardModifierBit(code) === keyboardModifierBit(original))) {
          const sourceBit: number = keyboardModifierBit(original)
          ConnectionService.pointerModifierMask &= ~sourceBit
          ConnectionService.nativeModifierMask &= ~sourceBit
          ConnectionService.hardwareModifierMask &= ~sourceBit
        }
      } else {
        return
      }
      ConnectionService.recomputeHeldModifierMask()
      // Reconcile source ownership with actual wire state. A polling snapshot
      // followed by the same physical down is one press, not two. Left/right
      // keys and virtual latches still release independently.
      ConnectionService.reconcileModifierEvents('key')
      return
    }
    ConnectionService.trackHeldKey(ConnectionService.heldLegacyKeys, keyCode, action)
    RustDeskNapi.sendKeyEvent(keyCode, action, ConnectionService.getKeyModifierMask())
  }

  static sendPhysicalKeyEvent(hidCode: number, action: number, eventModifierMask?: number,
    maskAlreadyMapped: boolean = false, source: string = 'keyboard'): void {
    const isGamepad: boolean = source === 'gamepad'
    const own: number[] = isGamepad ? ConnectionService.gamepadOwnedHids : ConnectionService.keyboardOwnedHids
    const other: number[] = isGamepad ? ConnectionService.keyboardOwnedHids : ConnectionService.gamepadOwnedHids
    const index: number = own.indexOf(hidCode)
    if (action === 0) {
      if (index >= 0) {
        if (isGamepad) return
      } else {
        own.push(hidCode)
        if (other.includes(hidCode)) return
      }
    } else if (action === 1) {
      if (index >= 0) own.splice(index, 1)
      if (other.includes(hidCode)) return
    }
    let modifierMask: number = ConnectionService.getEffectiveKeyModifierMask(eventModifierMask, maskAlreadyMapped)
    if (ConnectionService.useExplicitKeyboardPath()) {
      ConnectionService.trackHeldKey(ConnectionService.heldHidCodes, hidCode, action)
      RustDeskNapi.sendPhysicalKeyEvent(hidCode, action, modifierMask)
      return
    }
    const trackedSymbolIndex: number = ConnectionService.legacyShiftSymbolHidCodes.indexOf(hidCode)
    const shiftedSymbol: string = ConnectionService.getShiftedNumberSymbol(hidCode)
    const hasShift: boolean = (modifierMask & ConnectionService.MODIFIER_SHIFT) !== 0
    const hasHotkeyModifier: boolean = (modifierMask &
      (ConnectionService.MODIFIER_CONTROL | ConnectionService.MODIFIER_ALT | ConnectionService.MODIFIER_META)) !== 0
    if (action === 0 && shiftedSymbol.length > 0 && hasShift && !hasHotkeyModifier) {
      if (trackedSymbolIndex < 0) {
        ConnectionService.legacyShiftSymbolHidCodes.push(hidCode)
      }
      // Map mode expects modifiers as raw scan codes. HarmonyOS currently sends
      // Shift through the compatible control-key path, so a shifted number can
      // be dropped by Windows peers. Send the already-resolved printable symbol
      // as text, then restore the held Shift state for following input.
      RustDeskNapi.sendText(shiftedSymbol)
      ConnectionService.sendRawModifierEvent(16, 0, 'shift-symbol-restore')
      RustDeskNapi.appendDiagnosticLog('input',
        `shifted_number_forwarded key=redacted repeat=${trackedSymbolIndex >= 0 ? 1 : 0}`)
      return
    }
    if (action === 1 && trackedSymbolIndex >= 0) {
      ConnectionService.legacyShiftSymbolHidCodes.splice(trackedSymbolIndex, 1)
      return
    }
    ConnectionService.trackHeldKey(ConnectionService.heldHidCodes, hidCode, action)
    RustDeskNapi.sendPhysicalKeyEvent(hidCode, action, modifierMask)
  }

  static sendLetterKeyEvent(letter: string, hidCode: number, action: number,
    eventModifierMask?: number): void {
    if (ConnectionService.useExplicitKeyboardPath()) {
      ConnectionService.sendPhysicalKeyEvent(hidCode, action, eventModifierMask)
      return
    }
    if (letter.length !== 1) {
      return
    }
    let modifierMask: number = ConnectionService.getEffectiveKeyModifierMask(eventModifierMask)
    let trackedIndex: number = ConnectionService.legacyShiftLetterHidCodes.indexOf(hidCode)
    const releasedCharacter: number = trackedIndex >= 0 ? ConnectionService.legacyShiftLetterCodes[trackedIndex] : 0
    let useLegacyCharacter: boolean
    if (action === 0) {
      const hasShift: boolean = (modifierMask & ConnectionService.MODIFIER_SHIFT) !== 0
      const hasHotkeyModifier: boolean = (modifierMask &
        (ConnectionService.MODIFIER_CONTROL | ConnectionService.MODIFIER_ALT | ConnectionService.MODIFIER_META)) !== 0
      useLegacyCharacter = hasShift && !hasHotkeyModifier
      if (useLegacyCharacter && trackedIndex < 0) {
        ConnectionService.legacyShiftLetterHidCodes.push(hidCode)
      }
    } else {
      // The key-up must use the same protocol path as its key-down even when
      // Shift was released first.
      useLegacyCharacter = trackedIndex >= 0
      if (trackedIndex >= 0) {
        ConnectionService.legacyShiftLetterHidCodes.splice(trackedIndex, 1)
        ConnectionService.legacyShiftLetterCodes.splice(trackedIndex, 1)
      }
    }
    if (!useLegacyCharacter) {
      ConnectionService.sendPhysicalKeyEvent(hidCode, action, modifierMask, true)
      return
    }
    let lower: string = letter.toLowerCase()
    let shiftEnabled: boolean = (modifierMask & ConnectionService.MODIFIER_SHIFT) !== 0
    let capsEnabled: boolean = (modifierMask & ConnectionService.MODIFIER_CAPS_LOCK) !== 0
    let character: string = shiftEnabled !== capsEnabled ? lower.toUpperCase() : lower
    const characterCode: number = action === 1 && releasedCharacter > 0 ? releasedCharacter : character.charCodeAt(0)
    if (action === 0 && trackedIndex < 0) ConnectionService.legacyShiftLetterCodes.push(characterCode)
    ConnectionService.trackHeldKey(ConnectionService.heldLegacyKeys, characterCode, action)
    let result: number = RustDeskNapi.sendKeyEvent(characterCode, action, modifierMask)
    hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
      'InputTrace letter action=%{public}d mask=%{public}d result=%{public}d',
      action, modifierMask, result)
  }

  static syncHeldModifierState(control: boolean, shift: boolean, alt: boolean, meta: boolean = false): void {
    let snapshot: number =
      (control ? ConnectionService.MODIFIER_CONTROL : 0) |
      (shift ? ConnectionService.MODIFIER_SHIFT : 0) |
      (alt ? ConnectionService.MODIFIER_ALT : 0) |
      (meta ? ConnectionService.MODIFIER_META : 0)
    ConnectionService.applyModifierSnapshot(snapshot, true, 'pointer')
  }

  static syncHardwareModifierState(control: boolean, shift: boolean, alt: boolean, meta: boolean = false): void {
    let snapshot: number =
      (control ? ConnectionService.MODIFIER_CONTROL : 0) |
      (shift ? ConnectionService.MODIFIER_SHIFT : 0) |
      (alt ? ConnectionService.MODIFIER_ALT : 0) |
      (meta ? ConnectionService.MODIFIER_META : 0)
    ConnectionService.applyModifierSnapshot(snapshot, false, 'hardware')
  }

  static syncNativeModifierState(mask: number): void {
    // Native and ArkUI snapshots have different reliability. A native zero
    // only releases native evidence; it must not erase an ArkUI-held key.
    ConnectionService.nativeModifierMask = mask & 15
    ConnectionService.recomputeHeldModifierMask()
    ConnectionService.reconcileModifierEvents('native')
  }

  static syncCapsLockState(enabled: boolean): void {
    if (ConnectionService.capsLockEnabled !== enabled) {
      hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
        'InputTrace caps_snapshot enabled=%{public}d', enabled ? 1 : 0)
    }
    ConnectionService.capsLockEnabled = enabled
  }

  static sendCapsLockEvent(action: number, enabled?: boolean): void {
    if (action === 0) {
      if (ConnectionService.capsLockKeyHeld) {
        return
      }
      ConnectionService.capsLockKeyHeld = true
      ConnectionService.capsLockEnabled = enabled !== undefined ? enabled : !ConnectionService.capsLockEnabled
    } else if (action === 1) {
      if (!ConnectionService.capsLockKeyHeld) {
        return
      }
      ConnectionService.capsLockKeyHeld = false
      if (enabled !== undefined) {
        ConnectionService.capsLockEnabled = enabled
      }
    }
    // RustDesk transports the local CapsLock state in subsequent key-event
    // modifiers. Sending CapsLock itself as well would make the peer synchronize
    // the state and then toggle it a second time.
    hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
      'InputTrace caps_event action=%{public}d enabled=%{public}d',
      action, ConnectionService.capsLockEnabled ? 1 : 0)
  }

  static sendText(text: string): number {
    return RustDeskNapi.sendText(text)
  }

  static sendCtrlAltDel(): number {
    return RustDeskNapi.sendCtrlAltDel()
  }

  static sendShortcutKey(keyCode: number, modifierMask: number): number {
    const result: number = RustDeskNapi.sendKeyEvent(keyCode, 2, modifierMask)
    RustDeskNapi.appendDiagnosticLog('input-shortcut',
      `key=redacted modifiers=${modifierMask} result=${result}`)
    return result
  }

  static sendPrintableShortcutKey(keyCode: number, modifierMask: number): number {
    // keyCode identifies the keyboard key, not an uppercase Unicode character.
    // Keep this separate from control keys (for example lowercase q = F2's VK).
    const result: number = RustDeskNapi.sendPrintableShortcutKey(keyCode, modifierMask)
    RustDeskNapi.appendDiagnosticLog('input-shortcut',
      `printable_key=redacted modifiers=${modifierMask} result=${result}`)
    return result
  }

  static canSendCtrlAltDel(): boolean {
    return RustDeskNapi.canSendCtrlAltDel()
  }

  static send2FA(code: string, trustThisDevice: boolean): number {
    return RustDeskNapi.send2FA(code, trustThisDevice)
  }

  static sendMouseEvent(x: number, y: number, action: number): void {
    // Relative movement is forwarded at its source, before viewport clamping/throttling.
    // Button packets must not reposition the remote cursor.
    if (ConnectionService.relativeMouse) {
      if (action !== 0) RustDeskNapi.sendMouseEvent(0, 0, action, ConnectionService.heldModifierMask)
      return
    }
    RustDeskNapi.sendMouseEvent(x, y, action, ConnectionService.heldModifierMask)
  }

  static sendMouseWheel(deltaX: number, deltaY: number): void {
    RustDeskNapi.sendMouseWheel(deltaX, deltaY, ConnectionService.heldModifierMask)
  }

  static releaseModifiers(): void {
    // Also balance printable/control keys on focus/session loss or queue overflow.
    for (const hid of ConnectionService.heldHidCodes) {
      RustDeskNapi.sendPhysicalKeyEvent(hid, 1, ConnectionService.getKeyModifierMask())
    }
    for (const key of ConnectionService.heldLegacyKeys) {
      RustDeskNapi.sendKeyEvent(key, 1, ConnectionService.getKeyModifierMask())
    }
    ConnectionService.heldHidCodes = []
    ConnectionService.keyboardOwnedHids = []
    ConnectionService.gamepadOwnedHids = []
    ConnectionService.heldLegacyKeys = []
    ConnectionService.legacyShiftLetterHidCodes = []
    ConnectionService.legacyShiftLetterCodes = []
    ConnectionService.legacyShiftSymbolHidCodes = []
    ConnectionService.directModifierMask = 0
    ConnectionService.pointerModifierMask = 0
    ConnectionService.nativeModifierMask = 0
    ConnectionService.physicalModifierKeys = []
    ConnectionService.physicalModifierBits = []
    ConnectionService.physicalModifierControlCodes = []
    ConnectionService.physicalModifierSourceCodes = []
    ConnectionService.physicalModifierDeviceIds = []
    ConnectionService.mappedHardwarePresses = []
    ConnectionService.hardwareModifierMask = 0
    ConnectionService.heldModifierMask = 0
    ConnectionService.reconcileModifierEvents('release')
    ConnectionService.capsLockKeyHeld = false
  }

  static getConnectionStatus(): ConnectionStatus {
    let status: number = RustDeskNapi.getConnectionStatus()
    return status as ConnectionStatus
  }

  static getConnectionRoute(): number {
    return RustDeskNapi.getConnectionRoute()
  }

  static getConnectionTransport(): number {
    return RustDeskNapi.getConnectionTransport()
  }

  static getPeerId(): string {
    return RustDeskNapi.getOption('last_connected_peer')
  }

  static getLastConnectionError(): string {
    return ConnectionService.manualRetryError || RustDeskNapi.getLastConnectionError()
  }

  private static getModifierBit(keyCode: number): number {
    switch (keyCode) {
      case 17: return ConnectionService.MODIFIER_CONTROL
      case 163: return ConnectionService.MODIFIER_CONTROL
      case 16: return ConnectionService.MODIFIER_SHIFT
      case 161: return ConnectionService.MODIFIER_SHIFT
      case 18: return ConnectionService.MODIFIER_ALT
      case 165: return ConnectionService.MODIFIER_ALT
      case 91: return ConnectionService.MODIFIER_META
      case 92: return ConnectionService.MODIFIER_META
      default: return 0
    }
  }

  private static getKeyModifierMask(): number {
    return ConnectionService.heldModifierMask |
      (ConnectionService.capsLockEnabled ? ConnectionService.MODIFIER_CAPS_LOCK : 0)
  }

  private static getEffectiveKeyModifierMask(eventModifierMask?: number, maskAlreadyMapped: boolean = false): number {
    let modifierMask: number = ConnectionService.getKeyModifierMask()
    if (eventModifierMask !== undefined) {
      // Keep the modifier snapshot captured with this key event. It closes the
      // race where polling observes Shift slightly before/after the letter.
      modifierMask |= (maskAlreadyMapped ? eventModifierMask : ConnectionService.mapHardwareModifierMask(eventModifierMask)) &
        (ConnectionService.MODIFIER_CONTROL | ConnectionService.MODIFIER_SHIFT |
          ConnectionService.MODIFIER_ALT | ConnectionService.MODIFIER_META)
    }
    return modifierMask
  }

  private static resetTransientInputState(): void {
    ConnectionService.hardwareKeyboardLayoutSwap = false
    ConnectionService.hardwareKeyboardBindings = []
    ConnectionService.lastKeyboardLayoutRoute = ''
    ConnectionService.keyboardLayoutRouteLogCount = 0
    ConnectionService.keyboardLayoutSnapshotWarning = false
    ConnectionService.keyboardRemap = { version: 1, enabled: false, rules: [] }
    ConnectionService.mappedHardwarePresses = []
    ConnectionService.directModifierMask = 0
    ConnectionService.pointerModifierMask = 0
    ConnectionService.nativeModifierMask = 0
    ConnectionService.physicalModifierKeys = []
    ConnectionService.physicalModifierBits = []
    ConnectionService.physicalModifierControlCodes = []
    ConnectionService.physicalModifierSourceCodes = []
    ConnectionService.physicalModifierDeviceIds = []
    ConnectionService.sentModifierControlCodes = []
    ConnectionService.hardwareModifierMask = 0
    ConnectionService.heldModifierMask = 0
    ConnectionService.capsLockKeyHeld = false
    ConnectionService.legacyShiftLetterHidCodes = []
    ConnectionService.legacyShiftLetterCodes = []
    ConnectionService.legacyShiftSymbolHidCodes = []
    ConnectionService.heldHidCodes = []
    ConnectionService.keyboardOwnedHids = []
    ConnectionService.gamepadOwnedHids = []
    ConnectionService.heldLegacyKeys = []
  }

  private static trackHeldKey(keys: number[], code: number, action: number): void {
    const index: number = keys.indexOf(code)
    if (action === 0 && index < 0) keys.push(code)
    if (action === 1 && index >= 0) keys.splice(index, 1)
  }

  private static getShiftedNumberSymbol(hidCode: number): string {
    switch (hidCode) {
      case 0x1E: return '!'
      case 0x1F: return '@'
      case 0x20: return '#'
      case 0x21: return '$'
      case 0x22: return '%'
      case 0x23: return '^'
      case 0x24: return '&'
      case 0x25: return '*'
      case 0x26: return '('
      case 0x27: return ')'
      default: return ''
    }
  }

  private static applyModifierSnapshot(snapshot: number, pointerSource: boolean, source: string): void {
    if (pointerSource) {
      ConnectionService.pointerModifierMask = snapshot
    } else {
      ConnectionService.hardwareModifierMask = snapshot
    }
    ConnectionService.recomputeHeldModifierMask()
    ConnectionService.reconcileModifierEvents(source)
  }

  private static recomputeHeldModifierMask(): void {
    ConnectionService.heldModifierMask = ConnectionService.directModifierMask |
      ConnectionService.mapHardwareModifierMask(ConnectionService.pointerModifierMask |
        ConnectionService.nativeModifierMask | ConnectionService.hardwareModifierMask)
  }

  private static mapHardwareModifierMask(mask: number): number {
    if (!ConnectionService.keyboardRemap.enabled && !ConnectionService.hasHardwareLayoutMapping()) return mask
    let result: number = mask & ~15
    for (const source of [17, 16, 18, 91]) {
      const bit: number = keyboardModifierBit(source)
      if ((mask & bit) === 0) continue
      let identified: boolean = false
      ConnectionService.physicalModifierSourceCodes.forEach((code: number, index: number) => {
        if (ConnectionService.physicalModifierKeys[index] < 10000 && keyboardModifierBit(code) === bit) {
          result |= keyboardModifierBit(ConnectionService.physicalModifierControlCodes[index])
          identified = true
        }
      })
      if (!identified) {
        // Modifier snapshots are global, not attributable to a particular device.
        // Do not guess which keyboard owns an unattributed Alt/Meta snapshot.
        // Real key events restore the correct per-device state.
        const ambiguous: boolean = ConnectionService.hardwareKeyboardBindings.length > 0 &&
          ConnectionService.hasHardwareLayoutMapping() && (source === 18 || source === 91) &&
          keyboardRemapRule(ConnectionService.keyboardRemap, source) === undefined
        if (!ambiguous) result |= keyboardModifierBit(ConnectionService.hardwareControlTarget(source))
        else if (!ConnectionService.keyboardLayoutSnapshotWarning) {
          ConnectionService.keyboardLayoutSnapshotWarning = true
          RustDeskNapi.appendDiagnosticLog('input-layout', 'snapshot_suppressed reason=unattributed_device')
        }
      }
    }
    return result
  }

  private static reconcileModifierEvents(source: string): void {
    const desired: number[] = []
    for (const code of ConnectionService.physicalModifierControlCodes) {
      if (!desired.includes(code)) desired.push(code)
    }
    // Snapshots have no left/right identity. Use a left-side fallback only
    // until a real key event identifies the side; never add a phantom left
    // modifier alongside a known right-side key.
    for (const code of [17, 16, 18, 91]) {
      const bit: number = ConnectionService.getModifierBit(code)
      if ((ConnectionService.heldModifierMask & bit) !== 0 &&
        (ConnectionService.directModifierMask & bit) === 0) {
        desired.push(code)
      }
    }
    for (const code of ConnectionService.sentModifierControlCodes.slice()) {
      if (!desired.includes(code)) ConnectionService.sendRawModifierEvent(code, 1, source)
    }
    for (const code of desired) {
      ConnectionService.sendRawModifierEvent(code, 0, source)
    }
  }

  private static sendRawModifierEvent(keyCode: number, action: number, source: string): void {
    const index: number = ConnectionService.sentModifierControlCodes.indexOf(keyCode)
    // Text injection can clear Shift remotely, so its explicit restore is the
    // sole intentional replay; ordinary hardware/pointer/native paths dedupe.
    if (action === 0 && index >= 0 && source !== 'shift-symbol-restore') return
    if (action === 1 && index < 0) return
    let packetMask: number = ConnectionService.getKeyModifierMask()
    let result: number = RustDeskNapi.sendKeyEvent(keyCode, action, packetMask)
    if (result === 0) {
      if (action === 0 && index < 0) ConnectionService.sentModifierControlCodes.push(keyCode)
      if (action === 1 && index >= 0) ConnectionService.sentModifierControlCodes.splice(index, 1)
    }
    RustDeskNapi.appendDiagnosticLog('input-modifier',
      `source=${source} kind=modifier action=${action} mask=${packetMask} result=${result}`)
    hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
      'InputTrace modifier source=%{public}s kind=modifier action=%{public}d mask=%{public}d result=%{public}d',
      source, action, packetMask, result)
  }
}
