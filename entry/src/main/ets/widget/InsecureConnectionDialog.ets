import { translate } from '../utils/I18n'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'

@CustomDialog
export struct InsecureConnectionDialog {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') dark: boolean = false
  @StorageLink('roundedRectButtons') rectangular: boolean = true
  @State remember: boolean = false
  controller?: CustomDialogController
  title: string = ''
  message: string = ''
  onCancel: () => void = () => {}
  onContinue: (remember: boolean) => void = () => {}

  aboutToAppear(): void { this.remember = false }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 8 }) {
          Text(translate(this.title, this.uiLanguage))
            .fontSize(19).fontWeight(FontWeight.Bold).layoutWeight(1)
            .fontColor(this.dark ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
            .wordBreak(WordBreak.BREAK_ALL)
          Button() {
            Row({ space: 5 }) {
              Text(this.remember ? '☑' : '□').fontSize(16)
                .fontColor(this.remember ? RustDeskTheme.ACCENT :
                  (this.dark ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
              Text(translate('7天内不再提醒', this.uiLanguage)).fontSize(12).wordBreak(WordBreak.BREAK_ALL)
                .fontColor(this.remember ? RustDeskTheme.ACCENT :
                  (this.dark ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
            }
          }
          .constraintSize({ minHeight: 44, maxWidth: 180 })
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(translate('7天内不再提醒', this.uiLanguage) + ' ' +
            translate(this.remember ? '已选中' : '未选中', this.uiLanguage))
          .onClick(() => { this.remember = !this.remember })
        }
        .width('100%').alignItems(VerticalAlign.Center)

        Text(translate(this.message, this.uiLanguage))
          .fontSize(15).width('100%').wordBreak(WordBreak.BREAK_ALL)
          .fontColor(this.dark ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)

        if (this.remember) {
          Text(translate('勾选并继续后，7天内仅对此远端、服务器及相同风险自动继续未加密连接。可在设置中清除。', this.uiLanguage))
            .fontSize(13).width('100%').wordBreak(WordBreak.BREAK_ALL)
            .fontColor(this.dark ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.ACCENT)
        }

        Row({ space: 12 }) {
          Button(translate('取消连接', this.uiLanguage))
            .layoutWeight(1).constraintSize({ minHeight: 44 }).padding(8)
            .fontColor(this.dark ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
            .backgroundColor(this.dark ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
            .attributeModifier(new ReadableButtonModifier(this.rectangular))
            .onClick(() => { this.controller?.close(); this.onCancel() })
          Button(translate(this.remember ? '继续并记住7天' : '仅本次继续', this.uiLanguage))
            .layoutWeight(1).constraintSize({ minHeight: 44 }).padding(8)
            .fontColor(Color.White).backgroundColor(RustDeskTheme.ERROR)
            .attributeModifier(new ReadableButtonModifier(this.rectangular))
            .onClick(() => { const selected = this.remember; this.controller?.close(); this.onContinue(selected) })
        }
        .width('100%')
      }
      .padding(20).width('100%').alignItems(HorizontalAlign.Start)
    }
    .width('92%').constraintSize({ maxWidth: 600, maxHeight: '80%' })
    .scrollBar(BarState.Auto).borderRadius(16)
    .backgroundColor(this.dark ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
  }
}
