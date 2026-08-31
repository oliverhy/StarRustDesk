import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RustDeskNapi } from '../service/RustDeskNapi';
import { RELEASE_NOTES_BUILD, RELEASE_NOTES_VERSION } from '../widget/ReleaseNotesDialog';
import { ConnectionStatus } from '../model/ConnectionModel';
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    RemoteSessionBackgroundTask.initialize(this.context)
    try {
      const diagnosticLogEnabled: boolean = RustDeskNapi.getOption('diagnostic-log-enabled') === '1'
      RustDeskNapi.setDiagnosticLogEnabled(diagnosticLogEnabled)
      RustDeskNapi.initializeDiagnosticLog(this.context.filesDir)
      RustDeskNapi.appendDiagnosticLog('app',
        `startup version=${RELEASE_NOTES_VERSION} build=${RELEASE_NOTES_BUILD} ` +
        `device_type=${deviceInfo.deviceType} model=${deviceInfo.productModel} ` +
        `market_name=${deviceInfo.marketName} os=${deviceInfo.osFullName} api=${deviceInfo.sdkApiVersion}`)
    } catch (_e) {
    }
    PersistentStorage.persistProp('isDarkModeManual', false);
    PersistentStorage.persistProp('isDarkMode', this.isDarkColorMode(this.context.config.colorMode));
    this.updateColorMode(this.context.config.colorMode);
    AppStorage.setOrCreate('currentTabIndex', 0);
    AppStorage.setOrCreate('connectionStatus', 0);
    AppStorage.setOrCreate('remoteId', '');
    AppStorage.setOrCreate('isServiceRunning', false);
    AppStorage.setOrCreate('deviceId', '');
    AppStorage.setOrCreate('peerList', '[]');
    AppStorage.setOrCreate('appForegroundEpoch', 0);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    RemoteSessionBackgroundTask.stop()
    RustDeskNapi.appendDiagnosticLog('app', 'ability_destroy')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    RustDeskNapi.appendDiagnosticLog('app', 'window_stage_create')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/HomePage', (err) => {
      if (err.code) {
        RustDeskNapi.appendDiagnosticLog('app', `load_content_failed code=${err.code}`)
        hilog.error(DOMAIN, 'testTag', 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading content.');
      RustDeskNapi.appendDiagnosticLog('app', 'load_content_succeeded')
    });
  }

  onWindowStageDestroy(): void {
    RustDeskNapi.appendDiagnosticLog('app', 'window_stage_destroy')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.updateColorMode(newConfig.colorMode);
  }

  onForeground(): void {
    this.updateColorMode(this.context.config.colorMode);
    RemoteSessionBackgroundTask.syncForConnectionStatus(RustDeskNapi.getConnectionStatus() as ConnectionStatus)
    let foregroundEpoch: number = AppStorage.get<number>('appForegroundEpoch') ?? 0
    AppStorage.set<number>('appForegroundEpoch', foregroundEpoch + 1)
    RustDeskNapi.appendDiagnosticLog('app', 'foreground')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    RemoteSessionBackgroundTask.syncForConnectionStatus(RustDeskNapi.getConnectionStatus() as ConnectionStatus)
    RustDeskNapi.appendDiagnosticLog('app', 'background')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private isDarkColorMode(colorMode?: ConfigurationConstant.ColorMode): boolean {
    return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private updateColorMode(colorMode?: ConfigurationConstant.ColorMode): void {
    if (AppStorage.get<boolean>('isDarkModeManual') ?? false) {
      return;
    }
    AppStorage.set<boolean>('isDarkMode', this.isDarkColorMode(colorMode));
  }
}
