import { common, wantAgent, WantAgent } from '@kit.AbilityKit'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { ConnectionStatus } from '../model/ConnectionModel'
import { RustDeskNapi } from './RustDeskNapi'

export class RemoteSessionBackgroundTask {
  private static context: common.UIAbilityContext | undefined = undefined
  private static running: boolean = false
  private static starting: boolean = false
  private static stopping: boolean = false
  private static desiredRunning: boolean = false

  static initialize(context: common.UIAbilityContext): void {
    RemoteSessionBackgroundTask.context = context
  }

  static syncForConnectionStatus(status: ConnectionStatus): void {
    if (status === ConnectionStatus.CONNECTING || status === ConnectionStatus.CONNECTED ||
      status === ConnectionStatus.WAITING_2FA) {
      RemoteSessionBackgroundTask.start()
      return
    }
    RemoteSessionBackgroundTask.stop()
  }

  static start(): void {
    RemoteSessionBackgroundTask.desiredRunning = true
    if (RemoteSessionBackgroundTask.running || RemoteSessionBackgroundTask.starting ||
      RemoteSessionBackgroundTask.stopping || RemoteSessionBackgroundTask.context === undefined) {
      return
    }
    RemoteSessionBackgroundTask.starting = true
    RemoteSessionBackgroundTask.startInternal()
  }

  private static async startInternal(): Promise<void> {
    const context: common.UIAbilityContext | undefined = RemoteSessionBackgroundTask.context
    if (context === undefined) {
      RemoteSessionBackgroundTask.starting = false
      return
    }
    try {
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name,
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1000903,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      }
      const notificationAgent: WantAgent = await wantAgent.getWantAgent(agentInfo)
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION, notificationAgent)
      RemoteSessionBackgroundTask.running = true
      RustDeskNapi.appendDiagnosticLog('background-task', 'remote_session_keep_alive_started')
    } catch (error) {
      const businessError: BusinessError = error as BusinessError
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_start_failed code=${businessError.code} message=${businessError.message}`)
    } finally {
      RemoteSessionBackgroundTask.starting = false
    }
    if (!RemoteSessionBackgroundTask.desiredRunning) {
      RemoteSessionBackgroundTask.stop()
    }
  }

  static stop(): void {
    RemoteSessionBackgroundTask.desiredRunning = false
    if (RemoteSessionBackgroundTask.starting || RemoteSessionBackgroundTask.stopping ||
      !RemoteSessionBackgroundTask.running || RemoteSessionBackgroundTask.context === undefined) {
      return
    }
    RemoteSessionBackgroundTask.stopping = true
    RemoteSessionBackgroundTask.stopInternal()
  }

  private static async stopInternal(): Promise<void> {
    const context: common.UIAbilityContext | undefined = RemoteSessionBackgroundTask.context
    if (context === undefined) {
      RemoteSessionBackgroundTask.stopping = false
      return
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context)
      RustDeskNapi.appendDiagnosticLog('background-task', 'remote_session_keep_alive_stopped')
    } catch (error) {
      const businessError: BusinessError = error as BusinessError
      RustDeskNapi.appendDiagnosticLog('background-task',
        `remote_session_keep_alive_stop_failed code=${businessError.code} message=${businessError.message}`)
    } finally {
      RemoteSessionBackgroundTask.running = false
      RemoteSessionBackgroundTask.stopping = false
    }
    if (RemoteSessionBackgroundTask.desiredRunning) {
      RemoteSessionBackgroundTask.start()
    }
  }
}
