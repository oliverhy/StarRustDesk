import { translate } from '../utils/I18n'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ConnectionPage } from './ConnectionPage'
import { SettingsPage } from './SettingsPage'
import { RustDeskNapi } from '../service/RustDeskNapi'
import {
  RELEASE_NOTES_SHOWN_OPTION,
  RELEASE_NOTES_SHOWN_ID,
  RELEASE_NOTES_VERSION,
  ReleaseNotesDialog,
} from '../widget/ReleaseNotesDialog'

@Entry
@Component
struct HomePage {
  @State currentTabIndex: number = 0
  @State pageWidth: number = 0
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  private swiperController: SwiperController = new SwiperController()
  private releaseNotesScheduled: boolean = false
  private releaseNotesDialogController: CustomDialogController = new CustomDialogController({
    builder: ReleaseNotesDialog({
      onClose: () => {
        RustDeskNapi.setOption(RELEASE_NOTES_SHOWN_OPTION, RELEASE_NOTES_SHOWN_ID)
      },
    }),
    autoCancel: false,
    customStyle: true,
    cornerRadius: 10,
  })

  aboutToAppear(): void {
    if (this.releaseNotesScheduled ||
      RustDeskNapi.getOption(RELEASE_NOTES_SHOWN_OPTION) === RELEASE_NOTES_SHOWN_ID) {
      return
    }
    this.releaseNotesScheduled = true
    setTimeout(() => {
      this.releaseNotesDialogController.open()
    }, 280)
  }

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
      .padding({ bottom: 78 })
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
    .width(this.pageWidth >= 820 ? 440 : '92%')
    .height(58)
    .padding(6)
    .margin({ bottom: 12 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_FLOATING_DARK : RustDeskTheme.HOME_FLOATING)
    .border({
      width: 1,
      color: this.isDarkMode ? '#805C93E6' : '#80518BDD'
    })
    .borderRadius(18)
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
        .fontColor(index === this.currentTabIndex ?
          (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
          (this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY))
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(index === this.currentTabIndex ?
      (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG) : Color.Transparent)
    .border({ width: 1, color: index === this.currentTabIndex ?
      (this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BORDER_DARK : RustDeskTheme.CONTROL_SELECTED_BORDER) : Color.Transparent })
    .borderRadius(12)
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
