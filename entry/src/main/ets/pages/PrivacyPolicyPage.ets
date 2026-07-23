import { router } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { PRIVACY_POLICY_URL } from '../utils/PrivacyPolicy'

@Entry
@Component
struct PrivacyPolicyPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  private controller: webview.WebviewController = new webview.WebviewController()

  build() {
    Column() {
      Row() {
        Button('返回')
          .height(40)
          .fontSize(15)
          .fontColor(RustDeskTheme.ACCENT)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            router.back()
          })

        Text('隐私政策')
          .fontSize(20)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Blank()
          .width(64)
      }
      .width('100%')
      .height(56)
      .padding({ left: 4, right: 4 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
      .border({ width: { bottom: 1 }, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })

      Web({ src: PRIVACY_POLICY_URL, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)
  }
}
