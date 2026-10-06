import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RustDeskNapi } from '../service/RustDeskNapi';
import { RELEASE_NOTES_BUILD, RELEASE_NOTES_VERSION } from '../widget/ReleaseNotesDialog';
import { ConnectionStatus } from '../model/ConnectionModel';
import { RemoteSessionBackgroundTask } from '../service/RemoteSessionBackgroundTask';
import { CloudSyncService } from '../service/CloudSyncService';
import { CommunicationService } from '../service/CommunicationService';
import { AccountSession } from '../service/RustDeskApiService';
import { RemoteDisplayPolicy } from '../service/RemoteDisplayPolicy';
import { SystemFaultDiagnostic } from '../service/SystemFaultDiagnostic';
import { LanguageService } from '../utils/LanguageService';
import { PeerOnlinePreference } from '../service/PeerOnlinePreference';
import { ThemePreference } from '../service/ThemePreference';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LanguageService.initialize();
    RemoteSessionBackgroundTask.initialize(this.context)
    try {
      const diagnosticLogEnabled: boolean = RustDeskNapi.getOption('diagnostic-log-enabled') === '1'
      RustDeskNapi.setDiagnosticLogEnabled(diagnosticLogEnabled)
      RustDeskNapi.initializeDiagnosticLog(this.context.filesDir)
      SystemFaultDiagnostic.initialize(this.context.filesDir, diagnosticLogEnabled)
      RustDeskNapi.appendDiagnosticLog('app',
        `startup version=${RELEASE_NOTES_VERSION} build=${RELEASE_NOTES_BUILD} ` +
        `device_type=${deviceInfo.deviceType} model=${deviceInfo.productModel} ` +
        `market_name=${deviceInfo.marketName} os=${deviceInfo.osFullName} api=${deviceInfo.sdkApiVersion}`)
    } catch (_e) {
    }
    ThemePreference.initialize(this.context, this.isDarkColorMode(this.context.config.colorMode));
    AppStorage.setOrCreate('roundedRectButtons', RustDeskNapi.getOption('button-shape') !== 'classic');
    this.updateFontScale(this.context.config.fontSizeScale);
    PersistentStorage.persistProp('mobileActionsOffsetX', 0);
    PersistentStorage.persistProp('mobileActionsOffsetY', 0);
    this.updateColorMode(this.context.config.colorMode);
    AppStorage.setOrCreate('currentTabIndex', 0);
    AppStorage.setOrCreate('connectionStatus', 0);
    AppStorage.setOrCreate('remoteId', '');
    AppStorage.setOrCreate('isServiceRunning', false);
    AppStorage.setOrCreate('deviceId', '');
    AppStorage.setOrCreate('peerList', '[]');
    AppStorage.setOrCreate('appForegroundEpoch', 0);
    AppStorage.setOrCreate('serverConfigVersion', 0);
    AppStorage.setOrCreate('savedConnectionsCloudRevision', 0);
    PeerOnlinePreference.initialize();
    // Validate only the locally remembered account; never log credentials or responses.
    AccountSession.getApi().restore().catch(() => {
      RustDeskNapi.appendDiagnosticLog('api-account', 'startup_restore_failed; retry_before_connection=true');
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    SystemFaultDiagnostic.stop();
    CommunicationService.dispose();
    RemoteSessionBackgroundTask.shutdown()
    RustDeskNapi.appendDiagnosticLog('app', 'ability_destroy')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try { RemoteDisplayPolicy.attach(windowStage.getMainWindowSync()); } catch (_e) {}
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
    RemoteDisplayPolicy.detach();
    RustDeskNapi.appendDiagnosticLog('app', 'window_stage_destroy')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    LanguageService.refreshSystemLanguage();
    this.updateColorMode(newConfig.colorMode);
    this.updateFontScale(newConfig.fontSizeScale);
  }

  onForeground(): void {
    LanguageService.refreshSystemLanguage();
    RemoteDisplayPolicy.refresh();
    this.updateColorMode(this.context.config.colorMode);
    this.updateFontScale(this.context.config.fontSizeScale);
    RemoteSessionBackgroundTask.setAppBackground(false)
    RemoteSessionBackgroundTask.syncForConnectionStatus(RustDeskNapi.getConnectionStatus() as ConnectionStatus)
    let foregroundEpoch: number = AppStorage.get<number>('appForegroundEpoch') ?? 0
    AppStorage.set<number>('appForegroundEpoch', foregroundEpoch + 1)
    if (CloudSyncService.isEnabled()) {
      CloudSyncService.syncNow(this.context).then(() => {
      }).catch(() => {
        RustDeskNapi.appendDiagnosticLog('cloud-sync', 'foreground_sync_failed')
      })
    }
    RustDeskNapi.appendDiagnosticLog('app', 'foreground')
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    CommunicationService.onBackground();
    RemoteSessionBackgroundTask.syncForConnectionStatus(RustDeskNapi.getConnectionStatus() as ConnectionStatus)
    RemoteSessionBackgroundTask.setAppBackground(true)
    RustDeskNapi.appendDiagnosticLog('app', 'background')
    if (CloudSyncService.isEnabled()) {
      CloudSyncService.upload(this.context).then(() => {
      }).catch(() => {
        RustDeskNapi.appendDiagnosticLog('cloud-sync', 'background_upload_failed')
      })
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private isDarkColorMode(colorMode?: ConfigurationConstant.ColorMode): boolean {
    return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private updateFontScale(fontSizeScale?: number): void {
    const current: number = AppStorage.get<number>('uiFontScale') ?? 1;
    const scale: number = fontSizeScale !== undefined && Number.isFinite(fontSizeScale) && fontSizeScale > 0 ?
      fontSizeScale : current;
    AppStorage.setOrCreate('uiFontScale', Math.max(1, Math.min(3, scale)));
  }

  private updateColorMode(colorMode?: ConfigurationConstant.ColorMode): void {
    if (colorMode === undefined || colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) return;
    ThemePreference.updateSystem(this.isDarkColorMode(colorMode));
  }
}
