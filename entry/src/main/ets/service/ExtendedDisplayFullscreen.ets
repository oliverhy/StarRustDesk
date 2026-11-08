import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { RustDeskNapi } from './RustDeskNapi';

// Each extension owns its own window and restoration state. Never use the
// primary remote window's global fullscreen policy for this separate ability.
export class ExtendedDisplayFullscreen {
  private readonly target: window.Window;
  private readonly onChange: (fullscreen: boolean, busy: boolean) => void;
  private restoreStatus?: window.WindowStatusType;
  private busy: boolean = false;
  private disposed: boolean = false;
  private listening: boolean = false;
  private readonly onStatusChange = (_status: window.WindowStatusType): void => {
    if (this.disposed || this.busy) return;
    // If the user exits with the system controls, an older restore point no
    // longer belongs to a later fullscreen entered outside this policy.
    try { if (!this.isFullscreen()) this.restoreStatus = undefined; } catch (_error) {}
    this.publish();
  };

  constructor(target: window.Window, onChange: (fullscreen: boolean, busy: boolean) => void) {
    this.target = target;
    this.onChange = onChange;
  }

  start(): void {
    if (this.disposed) return;
    try { this.target.on('windowStatusChange', this.onStatusChange); this.listening = true; }
    catch (_error) { RustDeskNapi.appendDiagnosticLog('multi-display', 'fullscreen_status_listener_unavailable'); }
    this.publish();
  }

  private isFullscreen(): boolean {
    const status: window.WindowStatusType = this.target.getWindowStatus();
    if (status === window.WindowStatusType.FULL_SCREEN) return true;
    if (status !== window.WindowStatusType.MAXIMIZE) return false;
    try { if (this.target.getWindowProperties().isFullScreen) return true; } catch (_error) {}
    try { return this.target.getImmersiveModeEnabledState(); } catch (_error) { return false; }
  }

  private publish(): void {
    if (this.disposed) return;
    try { this.onChange(this.isFullscreen(), this.busy); }
    catch (_error) { RustDeskNapi.appendDiagnosticLog('multi-display', 'fullscreen_status_unavailable'); }
  }

  async toggle(): Promise<boolean> {
    if (this.disposed || this.busy) return false;
    this.busy = true;
    let entering: boolean = false;
    let previous: window.WindowStatusType | undefined;
    try {
      const full: boolean = this.isFullscreen();
      entering = !full;
      previous = this.target.getWindowStatus();
      this.publish();
      if (entering) {
        if (previous !== window.WindowStatusType.FLOATING && previous !== window.WindowStatusType.MAXIMIZE) {
          throw new Error('Unsupported window status');
        }
        this.restoreStatus = previous;
        await this.target.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
        if (this.disposed) return false;
        if (!this.isFullscreen()) throw new Error('Fullscreen not applied');
      } else {
        // A window made fullscreen by the system has no app-owned restore
        // point; returning it to maximized mode remains safe and reversible.
        if (this.restoreStatus === window.WindowStatusType.FLOATING) await this.target.recover();
        else await this.target.maximize(window.MaximizePresentation.EXIT_IMMERSIVE);
        if (this.disposed) return false;
        if (this.isFullscreen()) throw new Error('Fullscreen exit not applied');
        this.restoreStatus = undefined;
      }
      RustDeskNapi.appendDiagnosticLog('multi-display', `fullscreen applied=${entering ? 1 : 0} previous_status=${previous}`);
      return true;
    } catch (error) {
      const businessError = error as BusinessError;
      const code: number = typeof businessError?.code === 'number' ? businessError.code : -1;
      RustDeskNapi.appendDiagnosticLog('multi-display', `fullscreen_failed entering=${entering ? 1 : 0} code=${code}`);
      // Restore the pre-entry state even if the platform partially maximized.
      if (entering && !this.disposed && previous !== undefined && this.restoreStatus !== undefined) {
        try {
          const alreadyRestored: boolean = this.target.getWindowStatus() === previous && !this.isFullscreen();
          if (!alreadyRestored && previous === window.WindowStatusType.FLOATING) await this.target.recover();
          else if (!alreadyRestored && previous === window.WindowStatusType.MAXIMIZE) await this.target.maximize(window.MaximizePresentation.EXIT_IMMERSIVE);
          if (!this.disposed) this.restoreStatus = undefined;
          RustDeskNapi.appendDiagnosticLog('multi-display', 'fullscreen_rollback result=ok');
        } catch (_rollback) { RustDeskNapi.appendDiagnosticLog('multi-display', 'fullscreen_rollback result=failed'); }
      }
      return false;
    } finally {
      this.busy = false;
      this.publish();
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.listening) {
      try { this.target.off('windowStatusChange', this.onStatusChange); } catch (_error) {}
      this.listening = false;
    }
    // The owning ability is closing; never look up or resize another window.
  }
}
