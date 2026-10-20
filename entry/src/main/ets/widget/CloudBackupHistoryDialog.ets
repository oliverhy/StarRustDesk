import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'
import { CloudBackupSummary } from '../service/CloudSyncService'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'

@CustomDialog
export struct CloudBackupHistoryDialog {
  controller?: CustomDialogController
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @Prop backups: CloudBackupSummary[] = []
  @Prop hasMore: boolean = false
  @Prop busy: boolean = false
  onSelect: (id: string) => void = () => {}
  onMore: () => void = () => {}
  onClose: () => void = () => {}

  build() {
    Column({ space: 12 }) {
      Text(translate('云端历史备份', this.uiLanguage))
        .fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.primaryColor()).width('100%')
      Text(translate('按时间降序排列。选择后先预览，不会立即覆盖本机；历史文件不会删除。', this.uiLanguage))
        .fontSize(13).fontColor(this.secondaryColor()).width('100%')
      List({ space: 8 }) {
        ForEach(this.backups, (backup: CloudBackupSummary) => {
          ListItem() {
            Column({ space: 6 }) {
              Text(backup.time > 0 ? new Date(backup.time).toLocaleString() : translate('时间未知', this.uiLanguage))
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.primaryColor()).width('100%')
              Text(translate(this.summary(backup), this.uiLanguage))
                .fontSize(13).fontColor(this.secondaryColor()).width('100%')
              if (backup.serverConfigured) {
                Text(translate('包含服务器配置', this.uiLanguage)).fontSize(12).fontColor(this.secondaryColor()).width('100%')
              }
              Button(translate('预览并恢复', this.uiLanguage))
                .width('100%').fontSize(14).constraintSize({ minHeight: 40 })
                .fontColor(this.isDarkMode ? '#76A9FF' : RustDeskTheme.ACCENT)
                .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
                .enabled(backup.readable && !this.busy)
                .onClick(() => { this.onSelect(backup.id) })
                .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
            }
            .padding(12).width('100%').borderRadius(12)
            .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
          }
        }, (backup: CloudBackupSummary) => backup.id)
        if (this.hasMore) {
          ListItem() {
            Button(translate(this.busy ? '加载中…' : '显示更早备份', this.uiLanguage))
              .width('100%').enabled(!this.busy).fontSize(14)
              .onClick(() => { this.onMore() })
              .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
          }
        }
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Button(translate('关闭', this.uiLanguage))
        .width('100%').constraintSize({ minHeight: 42 }).fontSize(15).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT)
        .onClick(() => { this.onClose() })
        .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 8, ButtonType.Capsule))
    }
    .width('92%').height('78%').constraintSize({ maxWidth: 620 }).padding(18)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White).borderRadius(16)
  }

  private summary(backup: CloudBackupSummary): string {
    if (!backup.readable) return '备份不完整或无法读取，不能恢复'
    if (backup.encrypted) return '已加密，输入备份密码后查看数量'
    if (backup.connectionCount === 0) return `空连接备份 · ${backup.groupCount} 个分组`
    return `${backup.connectionCount} 个连接 · ${backup.groupCount} 个分组`
  }

  private primaryColor(): ResourceColor { return this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY }
  private secondaryColor(): ResourceColor { return this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY }
}
