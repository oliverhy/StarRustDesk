import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { RustDeskNapi } from '../service/RustDeskNapi';

interface ExtendedDisplayParameters { remoteDisplay: number }

export default class ExtendedDisplayAbility extends UIAbility {
  private remoteDisplay: number = -1;
  private displayStorage?: LocalStorage;

  onCreate(want: Want, _launch: AbilityConstant.LaunchParam): void {
    const id = want.parameters?.remoteDisplay;
    this.remoteDisplay = typeof id === 'number' && Number.isInteger(id) && id >= 0 ? id : -1;
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    if (this.remoteDisplay < 0) { this.context.terminateSelf(); return; }
    const values: ExtendedDisplayParameters = { remoteDisplay: this.remoteDisplay };
    this.displayStorage = new LocalStorage(values);
    stage.loadContent('pages/ExtendedDisplayPage', this.displayStorage).catch(() => {
      RustDeskNapi.appendDiagnosticLog('multi-display', 'secondary_page_load_failed');
      this.context.terminateSelf();
    });
  }

  onNewWant(want: Want, _launch: AbilityConstant.LaunchParam): void {
    const id = want.parameters?.remoteDisplay;
    if (typeof id !== 'number' || !Number.isInteger(id) || id < 0 || id === this.remoteDisplay) return;
    this.remoteDisplay = id;
    if (this.displayStorage) this.displayStorage.setOrCreate('remoteDisplay', id);
  }

}
