import { window } from '@kit.ArkUI';
import { RustDeskNapi } from './RustDeskNapi';

// Serialize ownership changes so late enter/leave callbacks cannot recolor a
// later page. Only navigation colors change; system gestures remain enabled.
export class RemoteNavigationBarPolicy {
  private static pending: Promise<void> = Promise.resolve();
  private owner: window.Window | undefined;
  private previous: window.SystemBarProperties | undefined;
  private active: boolean = false;

  enter(target: window.Window | undefined): void {
    if (!target || (this.active && this.owner === target)) return;
    this.owner = target;
    this.active = true;
    RemoteNavigationBarPolicy.pending = RemoteNavigationBarPolicy.pending.then(async () => {
      if (!this.active || this.owner !== target) return;
      // Do not mutate a window if its previous style cannot be restored.
      const before = target.getWindowSystemBarProperties();
      this.previous = {
        navigationBarColor: before.navigationBarColor,
        navigationBarContentColor: before.navigationBarContentColor,
        isNavigationBarLightIcon: before.isNavigationBarLightIcon
      };
      await target.setWindowSystemBarProperties({
        navigationBarColor: '#090D14', navigationBarContentColor: '#FFFFFF', isNavigationBarLightIcon: true
      });
      RustDeskNapi.appendDiagnosticLog('remote-window', 'navigation_style=remote_dark');
    }).catch(() => {
      RustDeskNapi.appendDiagnosticLog('remote-window', 'navigation_style=apply_failed');
    });
  }

  leave(): void {
    this.active = false;
    const target = this.owner;
    RemoteNavigationBarPolicy.pending = RemoteNavigationBarPolicy.pending.then(async () => {
      if (!target || !this.previous) return;
      const before = this.previous;
      this.previous = undefined;
      await target.setWindowSystemBarProperties(before);
      RustDeskNapi.appendDiagnosticLog('remote-window', 'navigation_style=restored');
    }).catch(() => {
      RustDeskNapi.appendDiagnosticLog('remote-window', 'navigation_style=restore_failed');
    });
  }
}
