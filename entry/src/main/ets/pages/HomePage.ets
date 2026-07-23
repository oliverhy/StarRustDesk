import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'
import { translate } from '../utils/I18n'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ConnectionPage } from './ConnectionPage'
import { SettingsPage } from './SettingsPage'
import { PRIVACY_POLICY_VERSION } from '../utils/PrivacyPolicy'

@Entry
@Component
struct HomePage {
  @State currentTabIndex: number = 0
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
  @StorageLink('privacyConsentVersion') privacyConsentVersion: string = ''
  private swiperController: SwiperController = new SwiperController()

  aboutToAppear(): void {
    this.isDarkMode = AppStorage.get<boolean>('isDarkMode') ?? false
  }

  build() {
    if (this.privacyConsentVersion === PRIVACY_POLICY_VERSION) {
      this.buildMainContent()
    } else {
      this.buildPrivacyConsent()
    }
  }

  @Builder
  buildMainContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row() {
          Column()
            .width('42%')
            .height('100%')
            .backgroundColor(this.isDarkMode ? '#202D44' : '#D7E5FF')
          Blank()
        }
        .width('100%')
        .height(196)
        .backgroundColor(this.isDarkMode ? '#19202B' : '#F7F9FD')
        Blank()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)

      Swiper(this.swiperController) {
        ConnectionPage()
        SettingsPage()
      }
      .indicator(false)
      .loop(false)
      .duration(280)
      .curve(Curve.EaseInOut)
      .onChange((index: number) => {
        this.currentTabIndex = index
      })
      .width('100%')
      .height('100%')
      .padding({ bottom: 66 })
      .backgroundColor(Color.Transparent)

      this.buildFloatingTabBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)
  }

  @Builder
  buildPrivacyConsent() {
    Column() {
      Blank()

      Column({ space: 18 }) {
        Text('欢迎使用 StarRustDesk')
          .fontSize(26)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')
          .textAlign(TextAlign.Center)

        Text('隐私保护说明')
          .fontSize(18)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')

        Text('为了向你提供远程连接服务，StarRustDesk 会在你主动使用相关功能时处理服务器地址、连接密钥、网络状态及剪贴板文本。服务器配置和连接凭据保存在本机；剪贴板内容仅在你启用同步并建立远程连接后传输。')
          .fontSize(15)
          .lineHeight(23)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .width('100%')

        Row() {
          Text('请阅读并同意')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          Text('《隐私政策》')
            .fontSize(14)
            .fontColor(RustDeskTheme.ACCENT)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .onClick(() => {
              router.pushUrl({ url: 'pages/PrivacyPolicyPage' })
            })
        }
        .width('100%')

        Button('同意并继续')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(8)
          .onClick(() => {
            this.privacyConsentVersion = PRIVACY_POLICY_VERSION
          })

        Button('不同意并退出')
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            let context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
            context.terminateSelf()
          })
      }
      .width('90%')
      .constraintSize({ maxWidth: 520 })
      .padding({ left: 24, right: 24, top: 28, bottom: 20 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
      .border({ width: 1, color: this.isDarkMode ? '#344052' : '#E4EAF3' })
      .borderRadius(12)
      .shadow({
        radius: 24,
        color: this.isDarkMode ? '#66000000' : '#24345A84',
        offsetX: 0,
        offsetY: 8
      })

      Blank()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : '#F3F7FD')
  }

  @Builder
  buildFloatingTabBar() {
    Row({ space: 6 }) {
      this.buildTabItem(0, translate('Connection'))
      this.buildTabItem(1, translate('Settings'))
    }
    .height(52)
    .padding(5)
    .margin({ left: 24, right: 24, bottom: 9 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
    .border({
      width: 1,
      color: this.isDarkMode ? '#344052' : '#E5EAF2'
    })
    .borderRadius(8)
    .clip(true)
    .shadow({
      radius: 18,
      color: this.isDarkMode ? '#66000000' : '#1A335A8A',
      offsetX: 0,
      offsetY: 6
    })
  }

  @Builder
  buildTabItem(index: number, label: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(index === this.currentTabIndex ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
        .fontColor(index === this.currentTabIndex ? Color.White : (this.isDarkMode ? '#D6DCE7' : RustDeskTheme.TEXT_SECONDARY))
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .height(42)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(index === this.currentTabIndex ? RustDeskTheme.ACCENT : Color.Transparent)
    .borderRadius(6)
    .clip(true)
    .onClick(() => {
      if (index === this.currentTabIndex) {
        return
      }
      animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
        this.currentTabIndex = index
      })
      this.swiperController.changeIndex(index, true)
    })
  }
}
