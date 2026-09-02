import { common } from '@kit.AbilityKit'
import { avSession } from '@kit.AVSessionKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { RustDeskNapi } from './RustDeskNapi'

export class RemoteAudioSession {
  private static context: common.UIAbilityContext | undefined = undefined
  private static session: avSession.AVSession | undefined = undefined
  private static active: boolean = false
  private static desiredActive: boolean = false
  private static reconciling: boolean = false
  private static peerId: string = ''

  static initialize(context: common.UIAbilityContext): void {
    RemoteAudioSession.context = context
  }

  static setActive(active: boolean, peerId: string = ''): void {
    RemoteAudioSession.desiredActive = active
    if (peerId.length > 0) {
      RemoteAudioSession.peerId = peerId
    }
    RemoteAudioSession.reconcile()
  }

  static shutdown(): void {
    RemoteAudioSession.desiredActive = false
    RemoteAudioSession.destroyInternal()
  }

  private static reconcile(): void {
    if (RemoteAudioSession.reconciling) {
      return
    }
    RemoteAudioSession.reconciling = true
    RemoteAudioSession.reconcileInternal()
  }

  private static async reconcileInternal(): Promise<void> {
    try {
      while (RemoteAudioSession.active !== RemoteAudioSession.desiredActive) {
        if (RemoteAudioSession.desiredActive) {
          await RemoteAudioSession.activateInternal()
        } else {
          await RemoteAudioSession.deactivateInternal()
        }
      }
    } finally {
      RemoteAudioSession.reconciling = false
      if (RemoteAudioSession.active !== RemoteAudioSession.desiredActive) {
        RemoteAudioSession.reconcile()
      }
    }
  }

  private static async activateInternal(): Promise<void> {
    const context: common.UIAbilityContext | undefined = RemoteAudioSession.context
    if (context === undefined) {
      RemoteAudioSession.desiredActive = false
      return
    }
    try {
      let session: avSession.AVSession | undefined = RemoteAudioSession.session
      if (session === undefined) {
        session = await avSession.createAVSession(context, 'StarRustDeskRemoteAudio', 'audio')
        RemoteAudioSession.session = session
      }
      await session.setAVMetadata({
        assetId: 'starrustdesk-remote-audio',
        title: RemoteAudioSession.peerId.length > 0 ?
          `远端设备 ${RemoteAudioSession.peerId}` : '远端设备声音',
        artist: 'StarRustDesk',
      })
      await session.activate()
      await session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        speed: 1,
      })
      RemoteAudioSession.active = true
      RustDeskNapi.appendDiagnosticLog('avsession', 'remote_audio_session_activated')
    } catch (error) {
      const businessError: BusinessError = error as BusinessError
      RemoteAudioSession.desiredActive = false
      RustDeskNapi.appendDiagnosticLog('avsession',
        `remote_audio_session_activate_failed code=${businessError.code} message=${businessError.message}`)
    }
  }

  private static async deactivateInternal(): Promise<void> {
    const session: avSession.AVSession | undefined = RemoteAudioSession.session
    if (session === undefined) {
      RemoteAudioSession.active = false
      return
    }
    try {
      await session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_PAUSE })
      await session.deactivate()
      RustDeskNapi.appendDiagnosticLog('avsession', 'remote_audio_session_deactivated')
    } catch (error) {
      const businessError: BusinessError = error as BusinessError
      RustDeskNapi.appendDiagnosticLog('avsession',
        `remote_audio_session_deactivate_failed code=${businessError.code} message=${businessError.message}`)
    } finally {
      RemoteAudioSession.active = false
    }
  }

  private static async destroyInternal(): Promise<void> {
    const session: avSession.AVSession | undefined = RemoteAudioSession.session
    RemoteAudioSession.session = undefined
    RemoteAudioSession.active = false
    if (session === undefined) {
      return
    }
    try {
      await session.destroy()
      RustDeskNapi.appendDiagnosticLog('avsession', 'remote_audio_session_destroyed')
    } catch (error) {
      const businessError: BusinessError = error as BusinessError
      RustDeskNapi.appendDiagnosticLog('avsession',
        `remote_audio_session_destroy_failed code=${businessError.code} message=${businessError.message}`)
    }
  }
}
