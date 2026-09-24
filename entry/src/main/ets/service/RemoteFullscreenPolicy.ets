import { window } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { RemoteDisplayPolicy } from './RemoteDisplayPolicy';
import { RustDeskNapi } from './RustDeskNapi';

// One queue for the main window, including page cleanup. A late enter request
// must complete before cleanup restores the bars or a new session enters.
export class RemoteFullscreenPolicy {
  private static pending: Promise<void> = Promise.resolve();
  private static owner: window.Window | undefined;
  private static enabled: boolean = false;
  private static pcRestoreStatus: window.WindowStatusType | undefined;
  private static pcImmersiveEntered: boolean = false;

  static apply(enabled: boolean, rollbackOnFailure: boolean = true): Promise<void> {
    const main = RemoteDisplayPolicy.getMainWindow();
    const operation = RemoteFullscreenPolicy.pending.then(async () => {
      if (!main || main !== RemoteDisplayPolicy.getMainWindow()) {
        RustDeskNapi.appendDiagnosticLog('fullscreen', 'window_unavailable');
        throw new Error('Main window unavailable');
      }
      if (RemoteFullscreenPolicy.owner !== main) {
        RemoteFullscreenPolicy.owner = main;
        RemoteFullscreenPolicy.enabled = false;
        RemoteFullscreenPolicy.pcRestoreStatus = undefined;
        RemoteFullscreenPolicy.pcImmersiveEntered = false;
      }
      const previous = RemoteFullscreenPolicy.enabled;
      try {
        await RemoteFullscreenPolicy.setWindowState(main, enabled);
        RemoteFullscreenPolicy.enabled = enabled;
        try {
          const properties = main.getWindowProperties();
          RustDeskNapi.appendDiagnosticLog('fullscreen',
            `window_applied requested=${enabled} status=${main.getWindowStatus()} layout=${properties.isLayoutFullScreen} full=${properties.isFullScreen} width=${properties.windowRect.width} height=${properties.windowRect.height}`);
        } catch (_e) {
          RustDeskNapi.appendDiagnosticLog('fullscreen', `window_applied requested=${enabled} properties=unavailable`);
        }
      } catch (error) {
        if (rollbackOnFailure) {
          try {
            await RemoteFullscreenPolicy.setWindowState(main, previous);
            RustDeskNapi.appendDiagnosticLog('fullscreen', `window_rollback enabled=${previous} result=ok`);
          } catch (_e) {
            RustDeskNapi.appendDiagnosticLog('fullscreen', `window_rollback enabled=${previous} result=failed`);
          }
        }
        throw error as Error;
      }
    });
    // Keep the queue usable after a rejection; callers still receive the error.
    RemoteFullscreenPolicy.pending = operation.catch(() => {});
    return operation;
  }

  private static async setWindowState(main: window.Window, enabled: boolean): Promise<void> {
    if (RemoteFullscreenPolicy.isPc()) {
      if (enabled) {
        if (RemoteFullscreenPolicy.pcRestoreStatus === undefined) {
          const status = main.getWindowStatus();
          if (status !== window.WindowStatusType.FLOATING && status !== window.WindowStatusType.MAXIMIZE &&
            status !== window.WindowStatusType.FULL_SCREEN) {
            RustDeskNapi.appendDiagnosticLog('fullscreen', `pc_window_status_unsupported status=${status}`);
            throw new Error('PC window status cannot be safely restored');
          }
          RemoteFullscreenPolicy.pcRestoreStatus = status;
        }
        await main.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
        RemoteFullscreenPolicy.pcImmersiveEntered = true;
        RustDeskNapi.appendDiagnosticLog('fullscreen',
          `pc_immersive_entered previous_status=${RemoteFullscreenPolicy.pcRestoreStatus}`);
      } else if (RemoteFullscreenPolicy.pcRestoreStatus !== undefined) {
        const previousStatus = RemoteFullscreenPolicy.pcRestoreStatus;
        const currentStatus = main.getWindowStatus();
        if ((RemoteFullscreenPolicy.pcImmersiveEntered || currentStatus !== previousStatus) &&
          !(previousStatus === window.WindowStatusType.FLOATING && currentStatus === previousStatus)) {
          if (previousStatus === window.WindowStatusType.MAXIMIZE) {
            await main.maximize(window.MaximizePresentation.EXIT_IMMERSIVE);
          } else if (previousStatus === window.WindowStatusType.FULL_SCREEN) {
            await main.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
          } else {
            await main.recover();
          }
        }
        RemoteFullscreenPolicy.pcRestoreStatus = undefined;
        RemoteFullscreenPolicy.pcImmersiveEntered = false;
        RustDeskNapi.appendDiagnosticLog('fullscreen', `pc_window_restored previous_status=${previousStatus}`);
      }
      return;
    }
    let failure: BusinessError | undefined;
    try {
      await main.setWindowLayoutFullScreen(enabled);
      RustDeskNapi.appendDiagnosticLog('fullscreen', `window_layout enabled=${enabled} result=ok`);
    } catch (error) {
      failure = error as BusinessError;
      RustDeskNapi.appendDiagnosticLog('fullscreen',
        `window_layout enabled=${enabled} result=failed code=${failure.code ?? -1}`);
    }
    // Always attempt bar restoration even if the layout API failed.
    try {
      const bars: Array<'status' | 'navigation'> = enabled ? [] : ['status', 'navigation'];
      await main.setWindowSystemBarEnable(bars);
      RustDeskNapi.appendDiagnosticLog('fullscreen', `window_bars hidden=${enabled} result=ok`);
    } catch (error) {
      const barError = error as BusinessError;
      RustDeskNapi.appendDiagnosticLog('fullscreen',
        `window_bars hidden=${enabled} result=failed code=${barError.code ?? -1}`);
      if (!failure) failure = barError;
    }
    if (failure) throw failure as Error;
  }

  private static isPc(): boolean {
    return deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'pc' ||
      deviceInfo.deviceType === 'desktop';
  }
}
