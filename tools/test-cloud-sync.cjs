const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '..')
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8')
const assert = (condition, message) => {
  if (!condition) throw new Error(message)
}

const appConfig = JSON.parse(read('AppScope/app.json5'))
const backupConfig = JSON.parse(read('entry/src/main/resources/base/profile/backup_config.json'))
const cloudService = read('entry/src/main/ets/service/CloudSyncService.ets')
const backupService = read('entry/src/main/ets/service/ConnectionBackupService.ets')
const settings = read('entry/src/main/ets/pages/SettingsPage.ets')
const connectionPage = read('entry/src/main/ets/pages/ConnectionPage.ets')
const serverDialog = read('entry/src/main/ets/widget/ServerConfigDialog.ets')
const entryAbility = read('entry/src/main/ets/entryability/EntryAbility.ets')
const snapshotStore = read('entry/src/main/ets/service/CloudSyncSnapshotStore.ets')
const historyDialog = read('entry/src/main/ets/widget/CloudBackupHistoryDialog.ets')

assert(appConfig.app.cloudFileSyncEnabled === true, 'cloud file sync must be enabled in app config')
assert(backupConfig.allowToBackupRestore === true, 'system backup fallback must be enabled')
assert(backupConfig.includes.includes('/data/storage/el2/base/files/cloud_backup/'),
  'system backup must only include the safe cloud mirror')
assert(cloudService.includes('context.cloudFileDir'), 'cloud data must be stored in the app cloud directory')
assert(cloudService.includes('ConnectionBackupService.encrypt'), 'sensitive cloud data must be encrypted')
assert(cloudService.includes("serverKey: includesSecrets ? RustDeskNapi.getOption('key') : ''"),
  'server key must be excluded from the default cloud snapshot')
assert(cloudService.includes("password: password"), 'encrypted snapshots must support connection passwords')
assert(backupService.includes('serverConfig?: ConnectionBackupServerConfig'),
  'backup payload must support server configuration')
assert(backupService.includes('普通备份不得包含服务器密钥'),
  'plain backup validation must reject server keys')
assert(settings.includes('个人云空间同步'), 'settings must expose the cloud sync toggle')
assert(settings.includes('从云端恢复'), 'settings must expose cloud restore')
assert(connectionPage.includes('CloudSyncService.markLocalChanged()'),
  'saved connection changes must mark cloud data dirty')
assert(serverDialog.includes('CloudSyncService.markLocalChanged()'),
  'server configuration changes must mark cloud data dirty')
assert(entryAbility.includes('CloudSyncService.syncNow(this.context)'),
  'foreground must trigger cloud reconciliation')
assert(entryAbility.includes('CloudSyncService.upload(this.context)'),
  'background must flush local changes to cloud')
assert(snapshotStore.includes('static readonly MAX_BACKUPS: number = 5'),
  'cloud retention must use a single five-backup limit')
assert(cloudService.includes("result.success && (action === 'sync' || action === 'upload')"),
  'failed sync, history browsing and explicit restore must not prune snapshots')
assert(historyDialog.includes('最多保留最近 5 份备份'), 'history UI must disclose the retention limit')
assert(!historyDialog.includes('历史文件不会删除'), 'history UI must not promise unlimited retention')

console.log('cloud-sync checks passed')
