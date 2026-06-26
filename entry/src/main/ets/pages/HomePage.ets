import { translate } from '../utils/I18n'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ConnectionPage } from './ConnectionPage'
import { ServerPage } from './ServerPage'
import { SettingsPage } from './SettingsPage'

@Entry
@Component
struct HomePage {
  @State currentTabIndex: number = 0
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
  private swiperController: SwiperController = new SwiperController()

  aboutToAppear(): void {
    this.isDarkMode = AppStorage.get<boolean>('isDarkMode') ?? false
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Swiper(this.swiperController) {
        ConnectionPage()
        ServerPage()
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
      .padding({ bottom: 58 })
      .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)

      this.buildFloatingTabBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)
  }

  @Builder
  buildFloatingTabBar() {
    Stack({ alignContent: Alignment.Start }) {
      Column() {
        Blank()
      }
      .width(112)
      .height(38)
      .backgroundColor(this.isDarkMode ? '#4A6FA8FF' : '#5A9CC8FF')
      .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
      .border({
        width: 1,
        color: '#88FFFFFF'
      })
      .borderRadius(19)
      .clip(true)
      .position({ x: 5, y: 4 })
      .translate({ x: this.currentTabIndex * 115, y: 0 })
      .animation({ duration: 320, curve: Curve.EaseInOut })

      Row({ space: 3 }) {
        this.buildTabItem(0, translate('Connection'))
        this.buildTabItem(1, translate('Server'))
        this.buildTabItem(2, translate('Settings'))
      }
      .height(46)
      .padding({ left: 5, right: 5, top: 4, bottom: 4 })
    }
    .height(46)
    .margin({ left: 26, right: 26, bottom: 10 })
    .backgroundColor(this.isDarkMode ? '#24242B38' : '#24FFFFFF')
    .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
    .border({
      width: 1,
      color: this.isDarkMode ? '#70FFFFFF' : '#E6FFFFFF'
    })
    .borderRadius(23)
    .clip(true)
    .shadow({
      radius: 15,
      color: this.isDarkMode ? '#66000000' : '#22000000',
      offsetX: 0,
      offsetY: 4
    })
  }

  @Builder
  buildTabItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(14)
        .fontWeight(index === this.currentTabIndex ? RustDeskTheme.FONT_WEIGHT_SEMI_BOLD : 500)
        .fontColor(index === this.currentTabIndex ? '#FF2D6A' : (this.isDarkMode ? '#E8FFFFFF' : '#CC111111'))
        .textAlign(TextAlign.Center)
    }
    .width(112)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(19)
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
