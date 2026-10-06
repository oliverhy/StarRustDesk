import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { RustDeskNapi } from './RustDeskNapi';

const THEME_STORE: string = 'starrustdesk_theme';
const THEME_KEY: string = 'mode';

export class ThemePreference {
  private static store: preferences.Preferences | undefined;
  private static appContext: common.UIAbilityContext | undefined;
  private static mode: string = 'system';
  private static systemDark: boolean = false;
  private static generation: number = 0;
  private static saveQueue: Promise<void> = Promise.resolve();

  static initialize(context: common.UIAbilityContext, systemDark: boolean): void {
    ThemePreference.generation++;
    ThemePreference.appContext = context;
    ThemePreference.systemDark = systemDark;
    ThemePreference.mode = 'system';
    ThemePreference.store = undefined;
    let source: string = 'default';
    let migrateMemory: boolean = false;
    try {
      const store = preferences.getPreferencesSync(context, { name: THEME_STORE });
      ThemePreference.store = store;
      const stored = store.getSync(THEME_KEY, '');
      if (typeof stored === 'string' && ThemePreference.validMode(stored)) {
        ThemePreference.mode = stored;
        source = 'preferences';
      } else if (stored === '' && AppStorage.get<boolean>('isDarkModeManual') === true &&
        typeof AppStorage.get<boolean>('isDarkMode') === 'boolean') {
        // Preserve an already-restored choice in a warm Ability recreation.
        // Do not register old PersistentStorage keys before the UI is ready.
        ThemePreference.mode = AppStorage.get<boolean>('isDarkMode') === true ? 'dark' : 'light';
        source = 'legacy_memory';
        migrateMemory = true;
      } else if (stored !== '') {
        ThemePreference.log('restore_invalid_mode; fallback=system');
      }
    } catch (error) {
      ThemePreference.log(`restore_failed code=${(error as BusinessError)?.code ?? 0}; fallback=system`);
    }
    ThemePreference.apply();
    ThemePreference.log(`restored source=${source} mode=${ThemePreference.mode} dark=${ThemePreference.isDark()}`);
    if (migrateMemory) {
      ThemePreference.setMode(ThemePreference.mode).then((saved: boolean) => {
        ThemePreference.log(`legacy_memory_migration saved=${saved}`);
      });
    }
  }

  static updateSystem(systemDark: boolean): void {
    ThemePreference.systemDark = systemDark;
    if (ThemePreference.mode === 'system') {
      ThemePreference.apply();
      ThemePreference.log(`system_applied dark=${systemDark}`);
    }
  }

  static isDark(): boolean {
    return ThemePreference.mode === 'dark' || (ThemePreference.mode === 'system' && ThemePreference.systemDark);
  }

  static setMode(mode: string): Promise<boolean> {
    if (!ThemePreference.validMode(mode)) return Promise.resolve(false);
    const generation = ThemePreference.generation;
    // Serialize writes so rapid choices cannot finish out of order.
    const task: Promise<boolean> = ThemePreference.saveQueue.then(async (): Promise<boolean> => {
      if (generation !== ThemePreference.generation) return false;
      const previous = ThemePreference.mode;
      let store = ThemePreference.store;
      try {
        if (!store) {
          const context = ThemePreference.appContext;
          if (!context) return false;
          store = preferences.getPreferencesSync(context, { name: THEME_STORE });
          ThemePreference.store = store;
        }
        ThemePreference.log(`save_started mode=${mode}`);
        store.putSync(THEME_KEY, mode);
        // putSync alone changes only the Preferences cache. Acknowledge and
        // apply the choice only after the disk flush succeeds.
        await store.flush();
        if (generation === ThemePreference.generation) {
          ThemePreference.mode = mode;
          ThemePreference.apply();
        }
        ThemePreference.log(`save_complete mode=${mode}`);
        return true;
      } catch (error) {
        try { store?.putSync(THEME_KEY, previous); } catch (_error) {}
        ThemePreference.log(`save_failed code=${(error as BusinessError)?.code ?? 0}`);
        return false;
      }
    });
    ThemePreference.saveQueue = task.then(() => {}, () => {});
    return task;
  }

  private static validMode(mode: string): boolean {
    return mode === 'system' || mode === 'dark' || mode === 'light';
  }

  private static apply(): void {
    AppStorage.setOrCreate('isDarkModeManual', ThemePreference.mode !== 'system');
    AppStorage.setOrCreate('isDarkMode', ThemePreference.isDark());
  }

  private static log(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('theme', message); } catch (_error) {}
  }
}
