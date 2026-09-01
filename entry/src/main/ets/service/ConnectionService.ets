import { RustDeskNapi } from './RustDeskNapi'
import { ConnectionStatus } from '../model/ConnectionModel'
import { RemoteSessionBackgroundTask } from './RemoteSessionBackgroundTask'
import { hilog } from '@kit.PerformanceAnalysisKit'

export class ConnectionService {
  private static readonly MODIFIER_CONTROL: number = 1
  private static readonly MODIFIER_SHIFT: number = 2
  private static readonly MODIFIER_ALT: number = 4
  private static readonly MODIFIER_META: number = 8
  private static readonly MODIFIER_CAPS_LOCK: number = 16
  private static readonly LOG_DOMAIN: number = 0x0000
  private static directModifierMask: number = 0
  private static pointerModifierMask: number = 0
  private static hardwareModifierMask: number = 0
  private static heldModifierMask: number = 0
  private static capsLockEnabled: boolean = false
  private static capsLockKeyHeld: boolean = false
  private static legacyShiftLetterScanCodes: number[] = []

  static connect(remoteId: string, password: string, performancePreset: string = 'smooth'): ConnectionStatus {
    ConnectionService.resetTransientInputState()
    let peerId: string = remoteId.replace(/[\s\u200B-\u200D\uFEFF]+/g, '')
    let rendezvousServer: string = RustDeskNapi.getOption('custom-rendezvous-server').trim()
    let relayServer: string = RustDeskNapi.getOption('relay-server').trim()
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

  static disconnect(): void {
    ConnectionService.releaseModifiers()
    RemoteSessionBackgroundTask.stop()
    RustDeskNapi.disconnect()
    ConnectionService.resetTransientInputState()
  }

  static sendKeyEvent(keyCode: number, action: number): void {
    if (keyCode === 20) {
      ConnectionService.sendCapsLockEvent(action)
      return
    }
    let modifierBit: number = ConnectionService.getModifierBit(keyCode)
    if (modifierBit !== 0) {
      let previousMask: number = ConnectionService.heldModifierMask
      if (action === 0) {
        ConnectionService.directModifierMask |= modifierBit
      } else if (action === 1) {
        // A real key-up is authoritative. Clear stale snapshots from pointer
        // and polling sources as well so a modifier cannot remain stuck.
        ConnectionService.directModifierMask &= ~modifierBit
        ConnectionService.pointerModifierMask &= ~modifierBit
        ConnectionService.hardwareModifierMask &= ~modifierBit
      }
      ConnectionService.recomputeHeldModifierMask()
      if (previousMask === ConnectionService.heldModifierMask) {
        return
      }
      ConnectionService.sendRawModifierEvent(keyCode, action, 'key')
      return
    }
    RustDeskNapi.sendKeyEvent(keyCode, action, ConnectionService.getKeyModifierMask())
  }

  static sendPhysicalKeyEvent(scanCode: number, action: number, eventModifierMask?: number): void {
    let modifierMask: number = ConnectionService.getEffectiveKeyModifierMask(eventModifierMask)
    RustDeskNapi.sendPhysicalKeyEvent(scanCode, action, modifierMask)
  }

  static sendLetterKeyEvent(letter: string, scanCode: number, action: number,
    eventModifierMask?: number): void {
    if (letter.length !== 1) {
      return
    }
    let modifierMask: number = ConnectionService.getEffectiveKeyModifierMask(eventModifierMask)
    let trackedIndex: number = ConnectionService.legacyShiftLetterScanCodes.indexOf(scanCode)
    let useLegacyCharacter: boolean
    if (action === 0) {
      useLegacyCharacter = (modifierMask & ConnectionService.MODIFIER_SHIFT) !== 0
      if (useLegacyCharacter && trackedIndex < 0) {
        ConnectionService.legacyShiftLetterScanCodes.push(scanCode)
      }
    } else {
      // The key-up must use the same protocol path as its key-down even when
      // Shift was released first.
      useLegacyCharacter = trackedIndex >= 0
      if (trackedIndex >= 0) {
        ConnectionService.legacyShiftLetterScanCodes.splice(trackedIndex, 1)
      }
    }
    if (!useLegacyCharacter) {
      RustDeskNapi.sendPhysicalKeyEvent(scanCode, action, modifierMask)
      return
    }
    let lower: string = letter.toLowerCase()
    let shiftEnabled: boolean = (modifierMask & ConnectionService.MODIFIER_SHIFT) !== 0
    let capsEnabled: boolean = (modifierMask & ConnectionService.MODIFIER_CAPS_LOCK) !== 0
    let character: string = shiftEnabled !== capsEnabled ? lower.toUpperCase() : lower
    let result: number = RustDeskNapi.sendKeyEvent(character.charCodeAt(0), action, modifierMask)
    hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
      'InputTrace letter char=%{public}s action=%{public}d mask=%{public}d result=%{public}d',
      character, action, modifierMask, result)
  }

  static syncHeldModifierState(control: boolean, shift: boolean, alt: boolean): void {
    let snapshot: number =
      (control ? ConnectionService.MODIFIER_CONTROL : 0) |
      (shift ? ConnectionService.MODIFIER_SHIFT : 0) |
      (alt ? ConnectionService.MODIFIER_ALT : 0)
    ConnectionService.applyModifierSnapshot(snapshot, true, 'pointer')
  }

  static syncHardwareModifierState(control: boolean, shift: boolean, alt: boolean): void {
    let snapshot: number =
      (control ? ConnectionService.MODIFIER_CONTROL : 0) |
      (shift ? ConnectionService.MODIFIER_SHIFT : 0) |
      (alt ? ConnectionService.MODIFIER_ALT : 0)
    ConnectionService.applyModifierSnapshot(snapshot, false, 'hardware')
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
    let previousMask: number = ConnectionService.heldModifierMask
    ConnectionService.directModifierMask = 0
    ConnectionService.pointerModifierMask = 0
    ConnectionService.hardwareModifierMask = 0
    ConnectionService.heldModifierMask = 0
    let modifiers: number[] = [17, 16, 18, 91]
    for (let keyCode of modifiers) {
      let modifierBit: number = ConnectionService.getModifierBit(keyCode)
      if ((previousMask & modifierBit) === 0) {
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
      case 16: return ConnectionService.MODIFIER_SHIFT
      case 18: return ConnectionService.MODIFIER_ALT
      case 91: return ConnectionService.MODIFIER_META
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
    ConnectionService.hardwareModifierMask = 0
    ConnectionService.heldModifierMask = 0
    ConnectionService.capsLockKeyHeld = false
    ConnectionService.legacyShiftLetterScanCodes = []
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
    hilog.info(ConnectionService.LOG_DOMAIN, 'StarRustDesk',
      'InputTrace modifier source=%{public}s key=%{public}d action=%{public}d mask=%{public}d result=%{public}d',
      source, keyCode, action, packetMask, result)
  }
}
