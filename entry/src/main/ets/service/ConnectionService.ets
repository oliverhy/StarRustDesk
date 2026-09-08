import { RustDeskNapi } from './RustDeskNapi'
import { ConnectionStatus } from '../model/ConnectionModel'
import { RemoteSessionBackgroundTask } from './RemoteSessionBackgroundTask'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { connection } from '@kit.NetworkKit'
import { BusinessError } from '@kit.BasicServicesKit'

export class ConnectionService {
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
  private static hardwareModifierMask: number = 0
  private static heldModifierMask: number = 0
  private static capsLockEnabled: boolean = false
  private static capsLockKeyHeld: boolean = false
  private static legacyShiftLetterHidCodes: number[] = []
  private static legacyShiftLetterCodes: number[] = []
  private static legacyShiftSymbolHidCodes: number[] = []
  private static heldHidCodes: number[] = []
  private static heldLegacyKeys: number[] = []
  // Retry context lives only in memory and is cleared by an explicit disconnect.
  private static retryPeer: string = ''
  private static retryPassword: string = ''
  private static retryRendezvous: string = ''
  private static retryRelay: string = ''
  private static relayRetryUsed: boolean = false
  private static rendezvousRetryCount: number = 0
  private static relayFailureRetryCount: number = 0
  private static insecureRetryUsed: boolean = false

  static connect(remoteId: string, password: string, performancePreset: string = 'smooth'): ConnectionStatus {
    ConnectionService.resetTransientInputState()
    ConnectionService.recordNetworkSnapshot()
    let peerId: string = remoteId.replace(/[\s\u200B-\u200D\uFEFF]+/g, '')
    let rendezvousServer: string = RustDeskNapi.getOption('custom-rendezvous-server').trim()
    let relayServer: string = RustDeskNapi.getOption('relay-server').trim()
    ConnectionService.retryPeer = peerId
    ConnectionService.retryPassword = password
    ConnectionService.retryRendezvous = rendezvousServer
    ConnectionService.retryRelay = relayServer
    ConnectionService.relayRetryUsed = false
    ConnectionService.rendezvousRetryCount = 0
    ConnectionService.relayFailureRetryCount = 0
    ConnectionService.insecureRetryUsed = false
    RustDeskNapi.setPerformancePreset(performancePreset)
    let result: number
    if (rendezvousServer.length > 0) {
      result = RustDeskNapi.connectWithServer(peerId, password, rendezvousServer, relayServer)
    } else {
      result = RustDeskNapi.connect(peerId, password)
    }
    let status: ConnectionStatus = result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED
    RemoteSessionBackgroundTask.syncForConnectionStatus(status)
    return status
  }

  static async recordNetworkSnapshot(): Promise<void> {
    if (RustDeskNapi.getOption('diagnostic-log-enabled') !== '1') {
      return
    }
    try {
      const net: connection.NetHandle = await connection.getDefaultNet()
      const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(net)
      RustDeskNapi.appendDiagnosticLog('network',
        `connect_snapshot net=${net.netId} wifi=${capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)} ` +
        `cellular=${capabilities.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)} ` +
        `ethernet=${capabilities.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)}`)
    } catch (error) {
      RustDeskNapi.appendDiagnosticLog('network', `snapshot_failed code=${(error as BusinessError).code}`)
    }
  }

  static disconnect(): void {
    ConnectionService.retryPeer = ''
    ConnectionService.retryPassword = ''
    ConnectionService.relayRetryUsed = true
    ConnectionService.rendezvousRetryCount = 2
    ConnectionService.relayFailureRetryCount = 1
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
      ConnectionService.retryPassword, ConnectionService.retryRendezvous, ConnectionService.retryRelay, true)
    ConnectionService.resetTransientInputState()
    RemoteSessionBackgroundTask.syncForConnectionStatus(
      result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED)
    return result === 0
  }

  static retryRecoverableConnectionFailure(message: string): string {
    if (ConnectionService.retryPeer.length === 0 ||
      ConnectionService.isDirectAddress(ConnectionService.retryPeer) ||
      RustDeskNapi.getConnectionStatus() !== ConnectionStatus.FAILED) {
      return ''
    }

    const route: number = RustDeskNapi.getConnectionRoute()
    if (message === 'Peer secure handshake failed' && route === 1 && !ConnectionService.relayRetryUsed) {
      ConnectionService.relayRetryUsed = true
      if (ConnectionService.restartConnection(true, 'direct_secure_handshake_failed', 1, 1)) {
        return '直连安全握手失败，正在通过加密中继重试'
      }
      return ''
    }

    if (message === 'Rendezvous server did not respond' && ConnectionService.rendezvousRetryCount < 2) {
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

    if (message === 'Relay connection failed' && ConnectionService.relayFailureRetryCount < 1) {
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
      `automatic_retry reason=${reason} attempt=${attempt}/${maximum} ` +
      `previous_route=${RustDeskNapi.getConnectionRoute()} force_relay=${forceRelay ? 1 : 0}`)
    RustDeskNapi.disconnect()
    ConnectionService.recordNetworkSnapshot()
    const result: number = RustDeskNapi.connectWithServer(ConnectionService.retryPeer,
      ConnectionService.retryPassword, ConnectionService.retryRendezvous, ConnectionService.retryRelay, forceRelay)
    ConnectionService.resetTransientInputState()
    const status: ConnectionStatus = result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED
    RemoteSessionBackgroundTask.syncForConnectionStatus(status)
    RustDeskNapi.appendDiagnosticLog(result === 0 ? 'connection-recovery' : 'connection',
      `automatic_retry_started reason=${reason} result=${result}`)
    return result === 0
  }

  private static isDirectAddress(peer: string): boolean {
    return /^(\d{1,3}\.){3}\d{1,3}(:\d+)?$/.test(peer) || peer.includes(':')
  }

  static canRetryWithoutEncryption(): boolean {
    return !ConnectionService.insecureRetryUsed && ConnectionService.retryPeer.length > 0 &&
      RustDeskNapi.getConnectionStatus() === ConnectionStatus.FAILED &&
      RustDeskNapi.getLastConnectionError() === 'Server key is invalid'
  }

  static retryWithoutEncryption(): boolean {
    if (!ConnectionService.canRetryWithoutEncryption()) {
      return false
    }
    ConnectionService.insecureRetryUsed = true
    ConnectionService.releaseModifiers()
    RustDeskNapi.appendDiagnosticLog('connection-security',
      'user_approved_insecure_fallback scope=current_attempt_only')
    RustDeskNapi.disconnect()
    ConnectionService.recordNetworkSnapshot()
    let result: number
    if (ConnectionService.retryRendezvous.length > 0) {
      result = RustDeskNapi.connectWithServer(ConnectionService.retryPeer, ConnectionService.retryPassword,
        ConnectionService.retryRendezvous, ConnectionService.retryRelay, false, true)
    } else {
      result = RustDeskNapi.connect(ConnectionService.retryPeer, ConnectionService.retryPassword, true)
    }
    ConnectionService.resetTransientInputState()
    RemoteSessionBackgroundTask.syncForConnectionStatus(
      result === 0 ? ConnectionStatus.CONNECTING : ConnectionStatus.FAILED)
    return result === 0
  }

  static sendKeyEvent(keyCode: number, action: number, physicalKeyCode?: number): void {
    if (keyCode === 20) {
      ConnectionService.sendCapsLockEvent(action)
      return
    }
    let modifierBit: number = ConnectionService.getModifierBit(keyCode)
    if (modifierBit !== 0) {
      const identity: number = physicalKeyCode ?? keyCode
      const index: number = ConnectionService.physicalModifierKeys.indexOf(identity)
      if (action === 0) {
        if (index >= 0) {
          return
        }
        ConnectionService.physicalModifierKeys.push(identity)
        ConnectionService.physicalModifierBits.push(modifierBit)
        ConnectionService.physicalModifierControlCodes.push(keyCode)
        ConnectionService.directModifierMask |= modifierBit
      } else if (action === 1) {
        if (index < 0) {
          return
        }
        ConnectionService.physicalModifierKeys.splice(index, 1)
        ConnectionService.physicalModifierBits.splice(index, 1)
        ConnectionService.physicalModifierControlCodes.splice(index, 1)
        if (!ConnectionService.physicalModifierBits.includes(modifierBit)) {
          // A real key-up is authoritative. Clear stale snapshots from pointer
          // and polling sources as well so a modifier cannot remain stuck.
          ConnectionService.directModifierMask &= ~modifierBit
          ConnectionService.pointerModifierMask &= ~modifierBit
          ConnectionService.nativeModifierMask &= ~modifierBit
          ConnectionService.hardwareModifierMask &= ~modifierBit
        }
      } else {
        return
      }
      ConnectionService.recomputeHeldModifierMask()
      // Keep left/right modifiers as separate protocol events. The aggregate
      // mask remains available for printable keys and mouse packets.
      ConnectionService.sendRawModifierEvent(keyCode, action, 'key')
      return
    }
    ConnectionService.trackHeldKey(ConnectionService.heldLegacyKeys, keyCode, action)
    RustDeskNapi.sendKeyEvent(keyCode, action, ConnectionService.getKeyModifierMask())
  }

  static sendPhysicalKeyEvent(hidCode: number, action: number, eventModifierMask?: number): void {
    let modifierMask: number = ConnectionService.getEffectiveKeyModifierMask(eventModifierMask)
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
        `shifted_number_forwarded hid=${hidCode} repeat=${trackedSymbolIndex >= 0 ? 1 : 0}`)
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
      ConnectionService.sendPhysicalKeyEvent(hidCode, action, modifierMask)
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
      'InputTrace letter char=%{public}s action=%{public}d mask=%{public}d result=%{public}d',
      character, action, modifierMask, result)
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
    const previousMask: number = ConnectionService.heldModifierMask
    ConnectionService.nativeModifierMask = mask & 15
    ConnectionService.recomputeHeldModifierMask()
    ConnectionService.sendModifierTransitions(previousMask, ConnectionService.heldModifierMask, 'native')
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

  static sendText(text: string): void {
    RustDeskNapi.sendText(text)
  }

  static sendCtrlAltDel(): number {
    return RustDeskNapi.sendCtrlAltDel()
  }

  static sendShortcutKey(keyCode: number, modifierMask: number): number {
    const result: number = RustDeskNapi.sendKeyEvent(keyCode, 2, modifierMask)
    RustDeskNapi.appendDiagnosticLog('input-shortcut',
      `key=${keyCode} modifiers=${modifierMask} result=${result}`)
    return result
  }

  static canSendCtrlAltDel(): boolean {
    return RustDeskNapi.canSendCtrlAltDel()
  }

  static send2FA(code: string, trustThisDevice: boolean): number {
    return RustDeskNapi.send2FA(code, trustThisDevice)
  }

  static sendMouseEvent(x: number, y: number, action: number): void {
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
    ConnectionService.heldLegacyKeys = []
    ConnectionService.legacyShiftLetterHidCodes = []
    ConnectionService.legacyShiftLetterCodes = []
    ConnectionService.legacyShiftSymbolHidCodes = []
    let previousMask: number = ConnectionService.heldModifierMask
    let physicalModifierMask: number = 0
    for (let index: number = 0; index < ConnectionService.physicalModifierControlCodes.length; index++) {
      const keyCode: number = ConnectionService.physicalModifierControlCodes[index]
      physicalModifierMask |= ConnectionService.physicalModifierBits[index]
      RustDeskNapi.sendKeyEvent(keyCode, 1, ConnectionService.getKeyModifierMask())
      hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
        'InputTrace physical_modifier_release key=%{public}d previous=%{public}d', keyCode, previousMask)
    }
    ConnectionService.directModifierMask = 0
    ConnectionService.pointerModifierMask = 0
    ConnectionService.nativeModifierMask = 0
    ConnectionService.physicalModifierKeys = []
    ConnectionService.physicalModifierBits = []
    ConnectionService.physicalModifierControlCodes = []
    ConnectionService.hardwareModifierMask = 0
    ConnectionService.heldModifierMask = 0
    let modifiers: number[] = [17, 16, 18, 91]
    for (let keyCode of modifiers) {
      let modifierBit: number = ConnectionService.getModifierBit(keyCode)
      if ((previousMask & modifierBit) === 0 || (physicalModifierMask & modifierBit) !== 0) {
        continue
      }
      RustDeskNapi.sendKeyEvent(keyCode, 1, ConnectionService.getKeyModifierMask())
      hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
        'InputTrace modifier_release key=%{public}d previous=%{public}d', keyCode, previousMask)
    }
    ConnectionService.capsLockKeyHeld = false
  }

  static getConnectionStatus(): ConnectionStatus {
    let status: number = RustDeskNapi.getConnectionStatus()
    return status as ConnectionStatus
  }

  static getConnectionRoute(): number {
    return RustDeskNapi.getConnectionRoute()
  }

  static getPeerId(): string {
    return RustDeskNapi.getOption('last_connected_peer')
  }

  static getLastConnectionError(): string {
    return RustDeskNapi.getLastConnectionError()
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

  private static getEffectiveKeyModifierMask(eventModifierMask?: number): number {
    let modifierMask: number = ConnectionService.getKeyModifierMask()
    if (eventModifierMask !== undefined) {
      // Keep the modifier snapshot captured with this key event. It closes the
      // race where polling observes Shift slightly before/after the letter.
      modifierMask |= eventModifierMask &
        (ConnectionService.MODIFIER_CONTROL | ConnectionService.MODIFIER_SHIFT |
          ConnectionService.MODIFIER_ALT | ConnectionService.MODIFIER_META)
    }
    return modifierMask
  }

  private static resetTransientInputState(): void {
    ConnectionService.directModifierMask = 0
    ConnectionService.pointerModifierMask = 0
    ConnectionService.nativeModifierMask = 0
    ConnectionService.physicalModifierKeys = []
    ConnectionService.physicalModifierBits = []
    ConnectionService.physicalModifierControlCodes = []
    ConnectionService.hardwareModifierMask = 0
    ConnectionService.heldModifierMask = 0
    ConnectionService.capsLockKeyHeld = false
    ConnectionService.legacyShiftLetterHidCodes = []
    ConnectionService.legacyShiftLetterCodes = []
    ConnectionService.legacyShiftSymbolHidCodes = []
    ConnectionService.heldHidCodes = []
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
    let previousMask: number = ConnectionService.heldModifierMask
    if (pointerSource) {
      ConnectionService.pointerModifierMask = snapshot
    } else {
      ConnectionService.hardwareModifierMask = snapshot
    }
    ConnectionService.recomputeHeldModifierMask()
    ConnectionService.sendModifierTransitions(previousMask, ConnectionService.heldModifierMask, source)
  }

  private static recomputeHeldModifierMask(): void {
    ConnectionService.heldModifierMask = ConnectionService.directModifierMask |
      ConnectionService.pointerModifierMask |
      ConnectionService.nativeModifierMask |
      ConnectionService.hardwareModifierMask
  }

  private static sendModifierTransitions(previousMask: number, nextMask: number, source: string): void {
    if (previousMask === nextMask) {
      return
    }
    let keyCodes: number[] = [17, 16, 18, 91]
    for (let keyCode of keyCodes) {
      let bit: number = ConnectionService.getModifierBit(keyCode)
      let wasHeld: boolean = (previousMask & bit) !== 0
      let isHeld: boolean = (nextMask & bit) !== 0
      if (wasHeld === isHeld) {
        continue
      }
      ConnectionService.sendRawModifierEvent(keyCode, isHeld ? 0 : 1, source)
    }
  }

  private static sendRawModifierEvent(keyCode: number, action: number, source: string): void {
    let packetMask: number = ConnectionService.getKeyModifierMask()
    let result: number = RustDeskNapi.sendKeyEvent(keyCode, action, packetMask)
    RustDeskNapi.appendDiagnosticLog('input-modifier',
      `source=${source} key=${keyCode} action=${action} mask=${packetMask} result=${result}`)
    hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
      'InputTrace modifier source=%{public}s key=%{public}d action=%{public}d mask=%{public}d result=%{public}d',
      source, keyCode, action, packetMask, result)
  }
}
