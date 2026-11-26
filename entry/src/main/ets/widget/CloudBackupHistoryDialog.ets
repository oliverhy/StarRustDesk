import { CloudBackupSummary } from '../service/CloudSyncService'
import { settingsPalette } from '../theme/SettingsSkin'
import { translate } from '../utils/I18n'
import { SettingsAction } from './SettingsControls'

@CustomDialog
export struct CloudBackupHistoryDialog {
  controller?: CustomDialogController
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @Prop backups: CloudBackupSummary[] = []
  @Prop hasMore: boolean = false
  @Prop busy: boolean = false
  onSelect: (id: string) => void = () => {}
  onMore: () => void = () => {}
  onClose: () => void = () => {}

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(translate('云端历史备份', this.uiLanguage)).fontSize(20).fontWeight(700).fontColor(this.primaryColor())
          .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
        SettingsAction({ icon: 'close', tone: 'quiet', accessibleLabel: translate('关闭', this.uiLanguage),
          onAction: () => { this.onClose() } })
      }
      .width('100%')
      Text(translate('云端最多保留最近 5 份备份，成功同步后自动清理更早备份。选择后先预览，不会立即覆盖本机。', this.uiLanguage))
        .fontSize(13).fontColor(this.secondaryColor()).width('100%')
      List({ space: 8 }) {
        ForEach(this.backups, (backup: CloudBackupSummary) => {
          ListItem() {
            Row({ space: 7 }) {
              Column({ space: 4 }) {
                Text(backup.time > 0 ? new Date(backup.time).toLocaleString() : translate('时间未知', this.uiLanguage))
                  .fontSize(14).fontWeight(650).fontColor(this.primaryColor()).width('100%').wordBreak(WordBreak.BREAK_WORD)
                Text(translate(this.summary(backup), this.uiLanguage))
                  .fontSize(13).fontColor(this.secondaryColor()).width('100%').wordBreak(WordBreak.BREAK_WORD)
                if (backup.serverConfigured) {
                  Text(translate('包含服务器配置', this.uiLanguage)).fontSize(12).fontColor(this.secondaryColor()).width('100%')
                }
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
              SettingsAction({ label: translate('预览并恢复', this.uiLanguage), isEnabled: backup.readable && !this.busy,
                maxWidth: 130, onAction: () => { this.onSelect(backup.id) } })
            }
            .padding(9).width('100%')
            .backgroundColor(settingsPalette(this.isDarkMode).app)
            .border({ width: 1, color: settingsPalette(this.isDarkMode).hair, radius: 11 })
          }
        }, (backup: CloudBackupSummary) => backup.id)
        if (this.hasMore) {
          ListItem() {
            SettingsAction({ label: translate(this.busy ? '加载中…' : '显示更早备份', this.uiLanguage),
              isEnabled: !this.busy, onAction: () => { this.onMore() } })
          }
        }
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      SettingsAction({ label: translate('关闭', this.uiLanguage), onAction: () => { this.onClose() } })
        .alignSelf(ItemAlign.End)
    }
    .width('92%').height('78%').constraintSize({ maxWidth: 460 }).padding(16)
    .backgroundColor(settingsPalette(this.isDarkMode).surface)
    .border({ width: 1, color: settingsPalette(this.isDarkMode).line, radius: 16 })
  }

  private summary(backup: CloudBackupSummary): string {
    if (!backup.readable) return '备份不完整或无法读取，不能恢复'
    if (backup.encrypted) return '已加密，输入备份密码后查看数量'
    if (backup.connectionCount === 0) return `空连接备份 · ${backup.groupCount} 个分组`
    return `${backup.connectionCount} 个连接 · ${backup.groupCount} 个分组`
  }

  private primaryColor(): ResourceColor { return settingsPalette(this.isDarkMode).ink }
  private secondaryColor(): ResourceColor { return settingsPalette(this.isDarkMode).muted }
}
