import { translate } from '../utils/I18n'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'

// Only display names, IDs and file details belong here; never pass credentials or API tokens.
@CustomDialog
export struct FullTextDialog {
  title: string = ''
  content: string = ''
  language: string = 'zh-Hans'
  dark: boolean = false
  rectangular: boolean = true
  controller?: CustomDialogController

  build() {
    Column({ space: 16 }) {
      Text(translate(this.title, this.language))
        .fontSize(19).fontWeight(FontWeight.Medium).width('100%')
        .fontColor(this.dark ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
      Scroll() {
        Text(this.content).fontSize(15).width('100%').wordBreak(WordBreak.BREAK_ALL)
          .copyOption(CopyOptions.LocalDevice)
          .fontColor(this.dark ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
      }.width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
      Button(translate('关闭', this.language))
        .width('100%').constraintSize({ minHeight: 44 }).padding(10).fontSize(15)
        .fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT)
        .attributeModifier(new ReadableButtonModifier(this.rectangular))
        .onClick(() => { this.controller?.close() })
    }.width('92%').height('65%').constraintSize({ maxWidth: 680 })
      .padding(20).alignItems(HorizontalAlign.Start).borderRadius(16)
      .backgroundColor(this.dark ? RustDeskTheme.CARD_DARK : Color.White)
  }
}
