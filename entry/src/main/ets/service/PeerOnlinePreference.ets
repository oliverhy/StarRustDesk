import { RustDeskNapi } from './RustDeskNapi'

const ONLINE_OPTION: string = 'peer-online-query-enabled'
// A one-time default migration, deliberately unrelated to the app version.
// Later upgrades must not overwrite the user's manual off/on choice.
const DEFAULT_MIGRATION_OPTION: string = 'peer-online-default-on-migrated'

export class PeerOnlinePreference {
  static initialize(): void {
    let enabled: boolean = false
    try {
      const stored: string = RustDeskNapi.getOption(ONLINE_OPTION)
      const migrated: boolean = RustDeskNapi.getOption(DEFAULT_MIGRATION_OPTION) === '1'
      enabled = stored !== '0'
      if (!migrated) {
        // Fresh installs and the first upgrade from the old default-off policy.
        if (RustDeskNapi.setOption(ONLINE_OPTION, '1') === 0) {
          enabled = true
          RustDeskNapi.setOption(DEFAULT_MIGRATION_OPTION, '1')
          PeerOnlinePreference.log('default_on_migrated')
        } else {
          enabled = stored === '1'
          PeerOnlinePreference.log('default_migration_save_failed')
        }
      }
    } catch (_error) {
      // Preference failures must not break startup or begin a network query.
      enabled = false
      PeerOnlinePreference.log('preference_initialize_failed')
    }
    AppStorage.setOrCreate('peerOnlineQueryEnabled', enabled)
  }

  static setEnabled(enabled: boolean): boolean {
    try {
      if (RustDeskNapi.setOption(ONLINE_OPTION, enabled ? '1' : '0') !== 0) {
        PeerOnlinePreference.log('preference_save_failed')
        return false
      }
      // Also mark explicit choices, so a delayed migration cannot reset them.
      RustDeskNapi.setOption(DEFAULT_MIGRATION_OPTION, '1')
      AppStorage.setOrCreate('peerOnlineQueryEnabled', enabled)
      PeerOnlinePreference.log(`preference_changed enabled=${enabled}`)
      return true
    } catch (_error) {
      PeerOnlinePreference.log('preference_save_failed')
      return false
    }
  }

  private static log(message: string): void {
    try {
      RustDeskNapi.appendDiagnosticLog('online-state', message)
    } catch (_error) {}
  }
}
