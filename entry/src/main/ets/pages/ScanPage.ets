import { router } from '@kit.ArkUI';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { translate } from '../utils/I18n';

@Entry
@Component
struct ScanPage {
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
  @State scanResult: string = ''

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          Text('←')
            .fontSize(18)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        }
        .width(36).height(36)
        .backgroundColor(Color.Transparent)
        .onClick(() => { router.back() })

        Text(translate('Scan QR Code'))
          .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      Column({ space: 16 }) {
        Column({ space: 8 }) {
          Text('📷')
            .fontSize(64)
          Text(translate('Scan from camera'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(RustDeskTheme.TEXT_SECONDARY)
        }
        .width('100%')
        .padding(32)
        .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
        .borderRadius(RustDeskTheme.CARD_RADIUS)
        .alignItems(HorizontalAlign.Center)

        Divider()
          .height(1)
          .color(RustDeskTheme.DIVIDER)

        Column({ space: 8 }) {
          Text(translate('Enter ID manually'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(RustDeskTheme.TEXT_SECONDARY)

          TextInput({ placeholder: translate('Remote ID'), text: this.scanResult })
            .type(InputType.Normal)
            .maxLength(12)
            .fontSize(RustDeskTheme.FONT_SIZE_ID)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(RustDeskTheme.ID_COLOR)
            .textAlign(TextAlign.Center)
            .onChange((value: string) => { this.scanResult = value })

          Button(translate('Connect'))
            .fontColor(Color.White)
            .backgroundColor(RustDeskTheme.ACCENT)
            .borderRadius(8)
            .width('100%')
            .enabled(this.scanResult.length > 0)
            .onClick(() => {
              AppStorage.set<string>('scannedId', this.scanResult)
              router.back()
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding(RustDeskTheme.PAGE_PADDING)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)
  }
}
