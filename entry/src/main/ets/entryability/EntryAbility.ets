import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    PersistentStorage.persistProp('isDarkModeManual', false);
    PersistentStorage.persistProp('isDarkMode', this.isDarkColorMode(this.context.config.colorMode));
    this.updateColorMode(this.context.config.colorMode);
    AppStorage.setOrCreate('currentTabIndex', 0);
    AppStorage.setOrCreate('connectionStatus', 0);
    AppStorage.setOrCreate('remoteId', '');
    AppStorage.setOrCreate('isServiceRunning', false);
    AppStorage.setOrCreate('deviceId', '');
    AppStorage.setOrCreate('peerList', '[]');
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/HomePage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.updateColorMode(newConfig.colorMode);
  }

  onForeground(): void {
    this.updateColorMode(this.context.config.colorMode);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
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
