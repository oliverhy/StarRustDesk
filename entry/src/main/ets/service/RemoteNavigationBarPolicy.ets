import { window } from '@kit.ArkUI';
import { SystemBarTheme } from './SystemBarTheme';

// Serialize ownership changes so late enter/leave callbacks cannot recolor a
// later page. Only navigation colors change; system gestures remain enabled.
export class RemoteNavigationBarPolicy {
  private owner: window.Window | undefined;
  private token: number = 0;

  enter(target: window.Window | undefined): void {
    if (!target || this.owner === target) return;
    this.leave();
    this.owner = target;
    this.token = SystemBarTheme.enterRemote(target);
  }

  leave(): void {
    if (this.token > 0) SystemBarTheme.leaveRemote(this.token);
    this.token = 0;
    this.owner = undefined;
  }
}
