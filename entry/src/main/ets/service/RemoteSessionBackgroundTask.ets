import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { ConnectionStatus } from '../model/ConnectionModel'
import { RemoteAudioSession } from './RemoteAudioSession'
import { RustDeskNapi } from './RustDeskNapi'

class RemoteTaskRequestError extends Error {
  code: number

  constructor(error: BusinessError) {
    super(error.message)
    this.code = error.code
  }
}

enum RemoteTaskState {
  STOPPED = 'stopped',
  STARTING = 'starting',
  ACTIVE = 'active',
  UPDATING = 'updating',
  SUSPENDED = 'suspended',
  STOPPING = 'stopping',
  CANCELLED = 'cancelled',
  FAILED = 'failed',
}

export class RemoteSessionBackgroundTask {
  private static context: common.UIAbilityContext | undefined = undefined
  private static state: RemoteTaskState = RemoteTaskState.STOPPED
  private static sessionDesired: boolean = false
  private static dataTransferActive: boolean = false
  private static audioPlaybackActive: boolean = false
  private static appBackground: boolean = false
  private static backgroundVideoApplied: boolean = false
  private static taskId: number = -1
  private static currentSignature: string = ''
  private static selectedModeDescription: string = ''
  private static videoBroadcastRejected: boolean = false
  private static operationInFlight: boolean = false
  private static reconcilePending: boolean = false
  private static listenersRegistered: boolean = false
  private static userSuppressed: boolean = false
  private static retryAfter: number = 0
  private static retryTimer: number = -1
  private static cancellationVersion: number = 0
  private static taskSuspended: boolean = false

  private static cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    RemoteSessionBackgroundTask.handleCancel(info)
  }

  private static suspendCallback = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
    if (!RemoteSessionBackgroundTask.acceptsCallback(info.continuousTaskId)) {
      return
    }
    RemoteSessionBackgroundTask.taskId = info.continuousTaskId
    RemoteSessionBackgroundTask.taskSuspended = info.suspendState
    if (RemoteSessionBackgroundTask.state !== RemoteTaskState.STOPPING) {
      RemoteSessionBackgroundTask.state = info.suspendState ?
        RemoteTaskState.SUSPENDED : RemoteTaskState.ACTIVE
    }
    RustDeskNapi.appendDiagnosticLog('background-task',
      `remote_session_keep_alive_suspend id=${info.continuousTaskId} ` +
      `suspended=${info.suspendState} reason=${info.suspendReason} state=${RemoteSessionBackgroundTask.state}`)
  }

  private static activeCallback = (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
    if (!RemoteSessionBackgroundTask.acceptsCallback(info.id)) {
      return
    }
    RemoteSessionBackgroundTask.taskSuspended = false
    if (RemoteSessionBackgroundTask.state !== RemoteTaskState.STOPPING) {
      RemoteSessionBackgroundTask.state = RemoteTaskState.ACTIVE
    }
    RemoteSessionBackgroundTask.taskId = info.id
    RustDeskNapi.appendDiagnosticLog('background-task',
      `remote_session_keep_alive_active id=${info.id} state=${RemoteSessionBackgroundTask.state}`)
  }

  static initialize(context: common.UIAbilityContext): void {
    RemoteSessionBackgroundTask.context = context
    RemoteAudioSession.initialize(context)
    RemoteSessionBackgroundTask.registerListeners()
  }

  static syncForConnectionStatus(status: ConnectionStatus): void {
    const desired: boolean = status === ConnectionStatus.CONNECTING ||
      status === ConnectionStatus.CONNECTED || status === ConnectionStatus.WAITING_2FA
    if (desired && !RemoteSessionBackgroundTask.sessionDesired) {
      RemoteSessionBackgroundTask.userSuppressed = false
      RemoteSessionBackgroundTask.clearRetry()
    }
    if (!desired && RemoteSessionBackgroundTask.sessionDesired) {
      RemoteSessionBackgroundTask.clearRetry()
    }
    RemoteSessionBackgroundTask.sessionDesired = desired
    if (!desired) {
      RemoteSessionBackgroundTask.dataTransferActive = false
      RemoteSessionBackgroundTask.audioPlaybackActive = false
      RemoteAudioSession.setActive(false)
    }
    RemoteSessionBackgroundTask.applyBackgroundVideoMode()
    RemoteSessionBackgroundTask.scheduleReconcile()
  }

  static setAppBackground(background: boolean): void {
    if (RemoteSessionBackgroundTask.appBackground === background) {
      return
    }
    RemoteSessionBackgroundTask.appBackground = background
    const reduceVideo: boolean = background && RemoteSessionBackgroundTask.sessionDesired
    RemoteSessionBackgroundTask.applyBackgroundVideoMode()
    RustDeskNapi.appendDiagnosticLog('background-task',
      `app_background=${background} reduce_video=${reduceVideo}`)
  }

  static isAppBackground(): boolean {
    return RemoteSessionBackgroundTask.appBackground
  }

  static setDataTransferActive(active: boolean): void {
    if (RemoteSessionBackgroundTask.dataTransferActive === active) {
      return
    }
    RemoteSessionBackgroundTask.dataTransferActive = active
    RustDeskNapi.appendDiagnosticLog('background-task', `data_transfer_active=${active}`)
    RemoteSessionBackgroundTask.scheduleReconcile()
  }

  static setAudioPlaybackActive(active: boolean, peerId: string = ''): void {
    if (RemoteSessionBackgroundTask.audioPlaybackActive === active) {
      return
    }
    RemoteSessionBackgroundTask.audioPlaybackActive = active
    RemoteAudioSession.setActive(active, peerId)
    RustDeskNapi.appendDiagnosticLog('background-task', `audio_playback_active=${active}`)
    RemoteSessionBackgroundTask.scheduleReconcile()
  }

  static stop(): void {
    RemoteSessionBackgroundTask.clearRetry()
    RemoteSessionBackgroundTask.sessionDesired = false
    RemoteSessionBackgroundTask.dataTransferActive = false
    RemoteSessionBackgroundTask.audioPlaybackActive = false
    RemoteSessionBackgroundTask.applyBackgroundVideoMode()
    RemoteAudioSession.setActive(false)
    RemoteSessionBackgroundTask.scheduleReconcile()
  }

  static shutdown(): void {
    RemoteSessionBackgroundTask.stop()
    RemoteSessionBackgroundTask.unregisterListeners()
    RemoteAudioSession.shutdown()
  }

  private static registerListeners(): void {
    if (RemoteSessionBackgroundTask.listenersRegistered) {
      return
    }
    try {
      if (deviceInfo.sdkApiVersion >= 15) {
        backgroundTaskManager.on('continuousTaskCancel', RemoteSessionBackgroundTask.cancelCallback)
      }
      if (deviceInfo.sdkApiVersion >= 20) {
        backgroundTaskManager.on('continuousTaskSuspend', RemoteSessionBackgroundTask.suspendCallback)
        backgroundTaskManager.on('continuousTaskActive', RemoteSessionBackgroundTask.activeCallback)
      }
      RemoteSessionBackgroundTask.listenersRegistered = true
      RustDeskNapi.appendDiagnosticLog('background-task', 'continuous_task_listeners_registered')
    } catch (error) {
      const businessError: BusinessError = error as BusinessError
      RustDeskNapi.appendDiagnosticLog('background-task',
        `continuous_task_listeners_failed code=${businessError.code} message=${businessError.message}`)
    }
  }

  private static applyBackgroundVideoMode(): void {
    const reduceVideo: boolean = RemoteSessionBackgroundTask.appBackground &&
      RemoteSessionBackgroundTask.sessionDesired
    if (reduceVideo === RemoteSessionBackgroundTask.backgroundVideoApplied) {
      return
    }
    RemoteSessionBackgroundTask.backgroundVideoApplied = reduceVideo
    RustDeskNapi.setBackgroundVideoMode(reduceVideo)
  }

  private static unregisterListeners(): void {
    if (!RemoteSessionBackgroundTask.listenersRegistered) {
      return
    }
    try {
      if (deviceInfo.sdkApiVersion >= 15) {
        backgroundTaskManager.off('continuousTaskCancel', RemoteSessionBackgroundTask.cancelCallback)
      }
      if (deviceInfo.sdkApiVersion >= 20) {
        backgroundTaskManager.off('continuousTaskSuspend', RemoteSessionBackgroundTask.suspendCallback)
        backgroundTaskManager.off('continuousTaskActive', RemoteSessionBackgroundTask.activeCallback)
      }
    } catch (_error) {
    }
    RemoteSessionBackgroundTask.listenersRegistered = false
  }

  private static acceptsCallback(id: number): boolean {
    return id >= 0 && (RemoteSessionBackgroundTask.taskId >= 0 ?
      id === RemoteSessionBackgroundTask.taskId : RemoteSessionBackgroundTask.state === RemoteTaskState.STARTING)
  }

  private static handleCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
    if (!RemoteSessionBackgroundTask.acceptsCallback(info.id)) {
      return
    }
    RemoteSessionBackgroundTask.cancellationVersion++
    RemoteSessionBackgroundTask.clearRetry()
    RemoteSessionBackgroundTask.state = RemoteTaskState.CANCELLED
    RemoteSessionBackgroundTask.taskSuspended = false
    RemoteSessionBackgroundTask.taskId = -1
    RemoteSessionBackgroundTask.currentSignature = ''
    RustDeskNapi.appendDiagnosticLog('background-task',
      `remote_session_keep_alive_cancelled id=${info.id} reason=${info.reason}`)

    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
      info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION) {
      RemoteSessionBackgroundTask.userSuppressed = true
      return
    }
    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED) {
      RemoteSessionBackgroundTask.dataTransferActive = false
    }
    if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING ||
      info.reason === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_USE_AVSESSION) {
      RemoteSessionBackgroundTask.audioPlaybackActive = false
      RemoteAudioSession.setActive(false)
    }
    if (RemoteSessionBackgroundTask.sessionDesired) RemoteSessionBackgroundTask.setRetry()
    RemoteSessionBackgroundTask.scheduleReconcile()
  }

  private static clearRetry(): void {
    if (RemoteSessionBackgroundTask.retryTimer !== -1) {
      clearTimeout(RemoteSessionBackgroundTask.retryTimer)
      RemoteSessionBackgroundTask.retryTimer = -1
    }
    RemoteSessionBackgroundTask.retryAfter = 0
  }

  private static setRetry(): void {
    RemoteSessionBackgroundTask.clearRetry()
    RemoteSessionBackgroundTask.retryAfter = Date.now() + 30000
    RustDeskNapi.appendDiagnosticLog('background-task',
      `continuous_task_backoff state=${RemoteSessionBackgroundTask.state} retry_after=${RemoteSessionBackgroundTask.retryAfter}`)
    RemoteSessionBackgroundTask.retryTimer = setTimeout(() => {
      RemoteSessionBackgroundTask.retryTimer = -1
      RemoteSessionBackgroundTask.scheduleReconcile()
    }, 30000)
  }

  private static desiredSignature(): string {
    return `remote=1;video=${deviceInfo.sdkApiVersion >= 22 ? 1 : 0};` +
      `audio=${RemoteSessionBackgroundTask.audioPlaybackActive ? 1 : 0};` +
      `transfer=${RemoteSessionBackgroundTask.dataTransferActive ? 1 : 0}`
  }

  private static legacyModes(): string[] {
    let modes: string[] = ['multiDeviceConnection']
    if (RemoteSessionBackgroundTask.audioPlaybackActive) {
      modes.push('audioPlayback')
    }
    if (RemoteSessionBackgroundTask.dataTransferActive) {
      modes.push('dataTransfer')
    }
    RemoteSessionBackgroundTask.selectedModeDescription = `legacy:${modes.join(',')}`
    return modes
  }

  private static createRequest(notificationAgent: WantAgent, update: boolean, videoBroadcast: boolean = false):
    backgroundTaskManager.ContinuousTaskRequest {
    let request = new backgroundTaskManager.ContinuousTaskRequest()
    let modes: backgroundTaskManager.BackgroundTaskMode[] = [
      backgroundTaskManager.BackgroundTaskMode.MODE_MULTI_DEVICE_CONNECTION,
    ]
    let submodes: backgroundTaskManager.BackgroundTaskSubmode[] = [
      videoBroadcast ? backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_VIDEO_BROADCAST_NORMAL_NOTIFICATION :
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION,
    ]
    if (RemoteSessionBackgroundTask.audioPlaybackActive) {
      if (deviceInfo.sdkApiVersion >= 22) {
        modes.push(backgroundTaskManager.BackgroundTaskMode.MODE_AV_PLAYBACK_AND_RECORD)
        submodes.push(backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_AVSESSION_AUDIO_PLAYBACK)
      } else {
        modes.push(backgroundTaskManager.BackgroundTaskMode.MODE_AUDIO_PLAYBACK)
        submodes.push(backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION)
      }
    }
    if (RemoteSessionBackgroundTask.dataTransferActive) {
      modes.push(backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER)
      submodes.push(backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION)
    }
    request.backgroundTaskModes = modes
    request.backgroundTaskSubmodes = submodes
    request.wantAgent = notificationAgent
    request.combinedTaskNotification = true
    if (update && RemoteSessionBackgroundTask.taskId >= 0) {
      request.continuousTaskId = RemoteSessionBackgroundTask.taskId
    }
    return request
  }

  private static supportedRequest(notificationAgent: WantAgent, update: boolean):
    backgroundTaskManager.ContinuousTaskRequest | undefined {
    // Some OS versions map video-broadcast to a different parent mode than the
    // SDK declaration. Probe safely; never request privileged special modes.
    const variants: boolean[] = deviceInfo.sdkApiVersion >= 22 &&
      !RemoteSessionBackgroundTask.videoBroadcastRejected ? [true, false] : [false]
    for (const videoBroadcast of variants) {
      try {
        const request: backgroundTaskManager.ContinuousTaskRequest =
          RemoteSessionBackgroundTask.createRequest(notificationAgent, update, videoBroadcast)
        if (request.isModeSupported()) {
          RemoteSessionBackgroundTask.selectedModeDescription =
            `modes=${request.backgroundTaskModes.join(',')};submodes=${request.backgroundTaskSubmodes.join(',')}`
          RustDeskNapi.appendDiagnosticLog('background-task',
            `continuous_task_request_selected video_broadcast=${videoBroadcast} ` +
            `modes=${request.backgroundTaskModes.join(',')} submodes=${request.backgroundTaskSubmodes.join(',')}`)
          return request
        }
        RustDeskNapi.appendDiagnosticLog('background-task',
          `continuous_task_mode_unsupported video_broadcast=${videoBroadcast}`)
        if (videoBroadcast) RemoteSessionBackgroundTask.videoBroadcastRejected = true
      } catch (error) {
        const businessError: BusinessError = error as BusinessError
        if (businessError.code !== 9800005) {
          throw new RemoteTaskRequestError(businessError)
        }
        if (videoBroadcast) RemoteSessionBackgroundTask.videoBroadcastRejected = true
        RustDeskNapi.appendDiagnosticLog('background-task',
          `continuous_task_mode_rejected video_broadcast=${videoBroadcast} code=${businessError.code}`)
      }
    }
    return undefined
  }

  private static async runCompatibleRequest(context: common.UIAbilityContext, notificationAgent: WantAgent,
    update: boolean): Promise<backgroundTaskManager.ContinuousTaskNotification> {
    const cancellationVersion: number = RemoteSessionBackgroundTask.cancellationVersion
    const operation: string = update ? 'update' : 'start'
    if (deviceInfo.sdkApiVersion >= 21) {
      let request: backgroundTaskManager.ContinuousTaskRequest | undefined =
        RemoteSessionBackgroundTask.supportedRequest(notificationAgent, update)
      while (request !== undefined) {
        try {
          return update ? await backgroundTaskManager.updateBackgroundRunning(context, request) :
            await backgroundTaskManager.startBackgroundRunning(context, request)
        } catch (error) {
          const businessError: BusinessError = error as BusinessError
          RustDeskNapi.appendDiagnosticLog('background-task',
            `continuous_task_${operation}_rejected code=${businessError.code} ` +
            `actual=${RemoteSessionBackgroundTask.selectedModeDescription}`)
          if (businessError.code !== 9800005 ||
            cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion ||
            !RemoteSessionBackgroundTask.sessionDesired || RemoteSessionBackgroundTask.userSuppressed) {
            throw new RemoteTaskRequestError(businessError)
          }
          if (!request.backgroundTaskSubmodes.includes(
            backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_VIDEO_BROADCAST_NORMAL_NOTIFICATION)) {
            break
          }
          // A successful capability probe does not guarantee runtime acceptance.
          // Retry the normal multi-device request before considering the legacy API.
          RemoteSessionBackgroundTask.videoBroadcastRejected = true
          RustDeskNapi.appendDiagnosticLog('background-task', `continuous_task_${operation}_fallback=normal`)
          request = RemoteSessionBackgroundTask.supportedRequest(notificationAgent, update)
        }
      }
    }
    RustDeskNapi.appendDiagnosticLog('background-task', `continuous_task_${operation}_fallback=legacy`)
    return update ? await backgroundTaskManager.updateBackgroundRunning(
      context, RemoteSessionBackgroundTask.legacyModes()) : await backgroundTaskManager.startBackgroundRunning(
      context, RemoteSessionBackgroundTask.legacyModes(), notificationAgent)
  }

  private static scheduleReconcile(): void {
    RemoteSessionBackgroundTask.reconcilePending = true
    if (RemoteSessionBackgroundTask.operationInFlight) {
      return
    }
    RemoteSessionBackgroundTask.reconcileInternal()
  }

  private static async reconcileInternal(): Promise<void> {
    RemoteSessionBackgroundTask.operationInFlight = true
    try {
      while (RemoteSessionBackgroundTask.reconcilePending) {
        RemoteSessionBackgroundTask.reconcilePending = false
        await RemoteSessionBackgroundTask.reconcileOnce()
      }
    } finally {
      RemoteSessionBackgroundTask.operationInFlight = false
      if (RemoteSessionBackgroundTask.reconcilePending) {
        RemoteSessionBackgroundTask.scheduleReconcile()
      }
    }
  }

  private static async reconcileOnce(): Promise<void> {
    const context: common.UIAbilityContext | undefined = RemoteSessionBackgroundTask.context
    if (context === undefined) {
      return
    }
    if (Date.now() < RemoteSessionBackgroundTask.retryAfter) {
      return
    }
    if (!RemoteSessionBackgroundTask.sessionDesired) {
      if (RemoteSessionBackgroundTask.state === RemoteTaskState.ACTIVE ||
        RemoteSessionBackgroundTask.state === RemoteTaskState.SUSPENDED) {
        await RemoteSessionBackgroundTask.stopInternal(context)
      }
      return
    }
    if (RemoteSessionBackgroundTask.userSuppressed || Date.now() < RemoteSessionBackgroundTask.retryAfter) {
      return
    }

    const signature: string = RemoteSessionBackgroundTask.desiredSignature()
    if (RemoteSessionBackgroundTask.state === RemoteTaskState.ACTIVE ||
      RemoteSessionBackgroundTask.state === RemoteTaskState.SUSPENDED) {
      if (signature !== RemoteSessionBackgroundTask.currentSignature) {
        await RemoteSessionBackgroundTask.updateInternal(context, signature)
      }
      return
    }
    await RemoteSessionBackgroundTask.startInternal(context, signature)
  }

  private static async createWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const agentInfo: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001000,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    }
    return wantAgent.getWantAgent(agentInfo)
  }

  private static async startInternal(context: common.UIAbilityContext, signature: string): Promise<void> {
    const cancellationVersion: number = RemoteSessionBackgroundTask.cancellationVersion
    RemoteSessionBackgroundTask.state = RemoteTaskState.STARTING
    RemoteSessionBackgroundTask.taskSuspended = false
    try {
      const notificationAgent: WantAgent = await RemoteSessionBackgroundTask.createWantAgent(context)
      if (!RemoteSessionBackgroundTask.sessionDesired ||
        cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) {
        if (RemoteSessionBackgroundTask.state === RemoteTaskState.STARTING) {
          RemoteSessionBackgroundTask.state = RemoteTaskState.STOPPED
        }
        return
      }
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await RemoteSessionBackgroundTask.runCompatibleRequest(context, notificationAgent, false)
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      RemoteSessionBackgroundTask.taskId = notification.continuousTaskId ?? RemoteSessionBackgroundTask.taskId
      RemoteSessionBackgroundTask.currentSignature = signature
      RemoteSessionBackgroundTask.state = RemoteSessionBackgroundTask.taskSuspended ?
        RemoteTaskState.SUSPENDED : RemoteTaskState.ACTIVE
      RemoteSessionBackgroundTask.clearRetry()
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_started id=${RemoteSessionBackgroundTask.taskId} ` +
        `state=${RemoteSessionBackgroundTask.state} requested=${signature} ` +
        `actual=${RemoteSessionBackgroundTask.selectedModeDescription}`)
    } catch (error) {
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      const businessError: BusinessError = error as BusinessError
      RemoteSessionBackgroundTask.state = RemoteTaskState.FAILED
      RemoteSessionBackgroundTask.taskId = -1
      RemoteSessionBackgroundTask.currentSignature = ''
      if (RemoteSessionBackgroundTask.sessionDesired) RemoteSessionBackgroundTask.setRetry()
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_start_failed code=${businessError.code} message=${businessError.message}`)
    }
  }

  private static async updateInternal(context: common.UIAbilityContext, signature: string): Promise<void> {
    const cancellationVersion: number = RemoteSessionBackgroundTask.cancellationVersion
    RemoteSessionBackgroundTask.state = RemoteTaskState.UPDATING
    try {
      const notificationAgent: WantAgent = await RemoteSessionBackgroundTask.createWantAgent(context)
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      if (!RemoteSessionBackgroundTask.sessionDesired) {
        RemoteSessionBackgroundTask.state = RemoteSessionBackgroundTask.taskSuspended ?
          RemoteTaskState.SUSPENDED : RemoteTaskState.ACTIVE
        return
      }
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await RemoteSessionBackgroundTask.runCompatibleRequest(context, notificationAgent, true)
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      RemoteSessionBackgroundTask.taskId = notification.continuousTaskId ??
        RemoteSessionBackgroundTask.taskId
      RemoteSessionBackgroundTask.currentSignature = signature
      RemoteSessionBackgroundTask.state = RemoteSessionBackgroundTask.taskSuspended ?
        RemoteTaskState.SUSPENDED : RemoteTaskState.ACTIVE
      RemoteSessionBackgroundTask.clearRetry()
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_updated id=${RemoteSessionBackgroundTask.taskId} ` +
        `state=${RemoteSessionBackgroundTask.state} requested=${signature} ` +
        `actual=${RemoteSessionBackgroundTask.selectedModeDescription}`)
    } catch (error) {
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      const businessError: BusinessError = error as BusinessError
      RemoteSessionBackgroundTask.state = RemoteSessionBackgroundTask.taskSuspended ?
        RemoteTaskState.SUSPENDED : RemoteTaskState.ACTIVE
      if (RemoteSessionBackgroundTask.sessionDesired) RemoteSessionBackgroundTask.setRetry()
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_update_failed code=${businessError.code} message=${businessError.message} ` +
        `retained_state=${RemoteSessionBackgroundTask.state} applied=${RemoteSessionBackgroundTask.currentSignature}`)
    }
  }

  private static async stopInternal(context: common.UIAbilityContext): Promise<void> {
    const cancellationVersion: number = RemoteSessionBackgroundTask.cancellationVersion
    RemoteSessionBackgroundTask.state = RemoteTaskState.STOPPING
    try {
      await backgroundTaskManager.stopBackgroundRunning(context)
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      RemoteSessionBackgroundTask.clearRetry()
      RemoteSessionBackgroundTask.state = RemoteTaskState.STOPPED
      RemoteSessionBackgroundTask.taskId = -1
      RemoteSessionBackgroundTask.currentSignature = ''
      RemoteSessionBackgroundTask.taskSuspended = false
      RustDeskNapi.appendDiagnosticLog('background-task', 'remote_session_keep_alive_stopped')
    } catch (error) {
      if (cancellationVersion !== RemoteSessionBackgroundTask.cancellationVersion) return
      const businessError: BusinessError = error as BusinessError
      RemoteSessionBackgroundTask.state = RemoteSessionBackgroundTask.taskSuspended ?
        RemoteTaskState.SUSPENDED : RemoteTaskState.ACTIVE
      RemoteSessionBackgroundTask.setRetry()
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_stop_failed code=${businessError.code} message=${businessError.message} ` +
        `retained_state=${RemoteSessionBackgroundTask.state}`)
    }
  }
}
