import { window } from '@kit.ArkUI';
import { RustDeskNapi } from './RustDeskNapi';
import { BusinessError } from '@kit.BasicServicesKit';

interface RemoteBarOwner { token: number; target: window.Window }

// One writer: leaving remote restores the current theme, not a stale snapshot.
export class SystemBarTheme {
  private static target: window.Window | undefined;
  private static dark: boolean = false;
  private static remote: RemoteBarOwner[] = [];
  private static nextToken: number = 0;
  private static revision: number = 0;
  private static pending: Promise<void> = Promise.resolve();

  static attach(target: window.Window): void {
    SystemBarTheme.target = target;
    SystemBarTheme.remote = [];
    SystemBarTheme.apply('attach');
  }

  static detach(): void {
    SystemBarTheme.target = undefined;
    SystemBarTheme.remote = [];
    SystemBarTheme.revision++;
  }

  static setDark(dark: boolean): void {
    SystemBarTheme.dark = dark;
    SystemBarTheme.apply('theme');
  }

  static enterRemote(target: window.Window): number {
    const token: number = ++SystemBarTheme.nextToken;
    SystemBarTheme.remote.push({ token, target });
    SystemBarTheme.apply('remote_enter');
    return token;
  }

  static leaveRemote(token: number): void {
    SystemBarTheme.remote = SystemBarTheme.remote.filter((owner: RemoteBarOwner) => owner.token !== token);
    SystemBarTheme.apply('remote_leave');
  }

  static refresh(): void { SystemBarTheme.apply('foreground'); }

  private static apply(reason: string): void {
    const target = SystemBarTheme.target;
    const revision: number = ++SystemBarTheme.revision;
    if (!target) return;
    const remote: boolean = SystemBarTheme.remote.some((owner: RemoteBarOwner) => owner.target === target);
    const dark: boolean = remote || SystemBarTheme.dark;
    const background: string = remote ? '#090D14' : dark ? '#111827' : '#F7F9FC';
    const content: string = dark ? '#FFFFFF' : '#17253D';
    SystemBarTheme.pending = SystemBarTheme.pending.then(async () => {
      if (revision !== SystemBarTheme.revision || target !== SystemBarTheme.target) return;
      await target.setWindowSystemBarProperties({ statusBarColor: background, navigationBarColor: background,
        statusBarContentColor: content, navigationBarContentColor: content,
        isStatusBarLightIcon: dark, isNavigationBarLightIcon: dark });
      SystemBarTheme.log(`system_bars_applied reason=${reason} dark=${dark} remote=${remote}`);
    }).catch((error: BusinessError) => {
      SystemBarTheme.log(`system_bars_failed reason=${reason} code=${error.code ?? -1}`);
    });
  }

  private static log(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('theme', message); } catch (_e) {}
  }
}
