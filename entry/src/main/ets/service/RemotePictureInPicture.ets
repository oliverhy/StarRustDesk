import pictureInPicture from '@ohos.PiPWindow';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { RemoteSessionBackgroundTask } from './RemoteSessionBackgroundTask';
import { RustDeskNapi } from './RustDeskNapi';

export type RemotePiPPhase = 'idle' | 'starting' | 'active' | 'stopping';

// The system moves the existing XComponent surface into its PiP window. Do not
// create another decoder, capture the screen, or substitute a floating window.
export class RemotePictureInPicture {
  private static operations: Promise<void> = Promise.resolve();
  private static videoOwner: RemotePictureInPicture | undefined;
  private controller: pictureInPicture.PiPController | undefined;
  private phase: RemotePiPPhase = 'idle';
  private generation: number = 0;
  private disposed: boolean = false;
  private width: number = 0;
  private height: number = 0;
  private onPhase: (phase: RemotePiPPhase) => void;
  private onClosed: () => void;
  private onError: (stage: string, code: number) => void;

  constructor(onPhase: (phase: RemotePiPPhase) => void, onClosed: () => void,
    onError: (stage: string, code: number) => void) {
    this.onPhase = onPhase;
    this.onClosed = onClosed;
    this.onError = onError;
  }

  static isSupported(): boolean {
    try { return pictureInPicture.isPiPEnabled(); } catch (_error) { return false; }
  }

  start(context: common.UIAbilityContext, componentController: XComponentController,
    width: number, height: number): Promise<void> {
    if (this.disposed || this.phase !== 'idle') return Promise.resolve();
    if (!RemotePictureInPicture.isSupported()) {
      RustDeskNapi.appendDiagnosticLog('pip', 'unsupported');
      this.onError('unsupported', 801);
      return Promise.resolve();
    }
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      this.onError('size', 401);
      return Promise.resolve();
    }
    const generation = ++this.generation;
    this.width = Math.round(width);
    this.height = Math.round(height);
    RustDeskNapi.appendDiagnosticLog('pip', `start_requested api=${deviceInfo.sdkApiVersion} size=${this.width}x${this.height}`);
    this.publish('starting');
    return this.enqueue(async () => {
      if (this.disposed || generation !== this.generation) return;
      this.publish('starting'); // Reacquire the video lease after older page cleanup.
      let controller: pictureInPicture.PiPController | undefined;
      let startAttempted: boolean = false;
      try {
        controller = await pictureInPicture.create({ context, componentController,
          templateType: pictureInPicture.PiPTemplateType.VIDEO_LIVE,
          contentWidth: this.width, contentHeight: this.height, controlGroups: [] });
        this.controller = controller;
        RustDeskNapi.appendDiagnosticLog('pip', 'controller_created');
        // Opt-in only: returning home must not silently open a remote desktop.
        controller.setAutoStartEnabled(false);
        if (this.disposed || generation !== this.generation) {
          this.clearController(controller);
          return;
        }
        if (deviceInfo.sdkApiVersion >= 20 && !(await controller.getPiPSettingSwitch())) {
          RustDeskNapi.appendDiagnosticLog('pip', 'system_setting_disabled');
          this.onError('disabled', 0);
          this.clearController(controller);
          return;
        }
        if (this.disposed || generation !== this.generation) {
          this.clearController(controller);
          return;
        }
        const liveController: pictureInPicture.PiPController = controller;
        controller.on('stateChange', (state: pictureInPicture.PiPState, _reason: string) => {
          if (this.controller !== liveController) return;
          RustDeskNapi.appendDiagnosticLog('pip', `state=${state}`);
          if (state === pictureInPicture.PiPState.STARTED && generation === this.generation && !this.disposed) {
            this.publish('active');
          } else if (state === pictureInPicture.PiPState.ABOUT_TO_STOP ||
            state === pictureInPicture.PiPState.ABOUT_TO_RESTORE) {
            this.publish('stopping');
          } else if (state === pictureInPicture.PiPState.STOPPED) {
            this.clearController(liveController);
          } else if (state === pictureInPicture.PiPState.ERROR) {
            this.onError('system', 1300014);
            this.stop();
          }
        });
        // A live remote session is not a seekable/pauseable media player.
        controller.setPiPControlEnabled(pictureInPicture.PiPControlType.VIDEO_PLAY_PAUSE, false);
        startAttempted = true;
        await controller.startPiP();
        if (this.controller !== controller) return;
        if (this.disposed || generation !== this.generation) {
          await controller.stopPiP();
          this.clearController(controller);
          return;
        }
        this.publish('active');
        this.applyContentSize(); // Includes resolution changes that arrived during create/start.
        RustDeskNapi.refreshVideo();
        RustDeskNapi.appendDiagnosticLog('pip', `started size=${this.width}x${this.height}`);
      } catch (error) {
        const code: number = (error as BusinessError).code ?? -1;
        RustDeskNapi.appendDiagnosticLog('pip', `start_failed code=${code}`);
        if (!this.disposed && generation === this.generation) this.onError('start', code);
        if (controller && startAttempted && this.controller === controller) {
          await this.stopController(controller);
        } else if (controller) {
          this.clearController(controller);
        } else {
          this.publish('idle');
        }
      }
    });
  }

  stop(): Promise<void> {
    RustDeskNapi.appendDiagnosticLog('pip', `stop_requested phase=${this.phase}`);
    ++this.generation; // Also cancel a pending create/start, before it can show a stale session.
    if (this.phase !== 'idle') this.publish('stopping');
    return this.enqueue(async () => {
      if (this.controller) await this.stopController(this.controller);
      else this.publish('idle');
    });
  }

  dispose(): Promise<void> {
    this.disposed = true;
    return this.stop();
  }

  updateContentSize(width: number, height: number): void {
    if (!Number.isFinite(width) || !Number.isFinite(height) ||
      width <= 0 || height <= 0 || (this.width === width && this.height === height)) return;
    this.width = Math.round(width);
    this.height = Math.round(height);
    this.applyContentSize();
  }

  private applyContentSize(): void {
    if (!this.controller || this.phase !== 'active') return;
    try {
      this.controller.updateContentSize(this.width, this.height);
      RustDeskNapi.appendDiagnosticLog('pip', `content_size=${this.width}x${this.height}`);
    } catch (error) {
      RustDeskNapi.appendDiagnosticLog('pip', `resize_failed code=${(error as BusinessError).code ?? -1}`);
    }
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const result = RemotePictureInPicture.operations.then(operation);
    RemotePictureInPicture.operations = result.catch(() => {});
    return result;
  }

  private async stopController(controller: pictureInPicture.PiPController): Promise<void> {
    try {
      await controller.stopPiP();
      this.clearController(controller);
    } catch (error) {
      if (this.controller !== controller) return; // STOPPED already confirmed cleanup.
      const code: number = (error as BusinessError).code ?? -1;
      RustDeskNapi.appendDiagnosticLog('pip', `stop_failed code=${code}`);
      // Keep the handle and video lease so the user can retry; never claim that
      // a still-visible system window has stopped after a rejected API call.
      this.publish('active');
      if (!this.disposed) this.onError('stop', code);
    }
  }

  private clearController(controller: pictureInPicture.PiPController): void {
    if (this.controller !== controller) return;
    try { controller.off('stateChange'); } catch (_error) {}
    this.controller = undefined;
    this.publish('idle');
  }

  private publish(phase: RemotePiPPhase): void {
    const previous = this.phase;
    this.phase = phase;
    if (phase !== 'idle') {
      RemotePictureInPicture.videoOwner = this;
      RemoteSessionBackgroundTask.setPictureInPictureActive(true);
    } else if (RemotePictureInPicture.videoOwner === this) {
      RemotePictureInPicture.videoOwner = undefined;
      RemoteSessionBackgroundTask.setPictureInPictureActive(false);
    }
    if (!this.disposed) {
      this.onPhase(phase);
      if (phase === 'idle' && previous !== 'idle') this.onClosed();
    }
  }
}
