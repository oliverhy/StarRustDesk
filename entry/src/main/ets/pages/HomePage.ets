import { translate } from '../utils/I18n'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ConnectionPage } from './ConnectionPage'
import { SettingsPage } from './SettingsPage'

@Entry
@Component
struct HomePage {
  @State currentTabIndex: number = 0
  @State pageWidth: number = 0
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  private swiperController: SwiperController = new SwiperController()

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Circle()
            .width(this.pageWidth >= 820 ? 900 : 520)
            .height(this.pageWidth >= 820 ? 900 : 520)
            .fill(this.isDarkMode ? '#202D44' : '#D7E5FF')
            .offset({
              x: this.pageWidth >= 820 ? -450 : -260,
              y: this.pageWidth >= 820 ? -450 : -260
            })
        }
        .width('100%')
        .height(196)
        .backgroundColor(this.isDarkMode ? '#19202B' : '#F7F9FD')
        .clip(true)
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
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.pageWidth = newValue.width as number
    })
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
