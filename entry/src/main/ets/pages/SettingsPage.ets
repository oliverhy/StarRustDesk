import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { ServerConfigDialog } from '../widget/ServerConfigDialog'
import { RustDeskNapi } from '../service/RustDeskNapi'

interface SettingItem {
  label: string
  value: string
}

@Component
export struct SettingsPage {
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
  @State resolution: string = 'Auto'
  @State frameRate: number = 30
  @State showResolutionPicker: boolean = false
  @State showFrameRatePicker: boolean = false
  @State pageWidth: number = 0
  private serverConfigDialogController: CustomDialogController = new CustomDialogController({
    builder: ServerConfigDialog(),
    autoCancel: true,
    customStyle: true,
    cornerRadius: 8,
  })

  aboutToAppear(): void {
    let savedRes: string = RustDeskNapi.getOption('resolution')
    if (savedRes.length > 0) {
      this.resolution = savedRes
    }
    let savedFps: string = RustDeskNapi.getOption('frame-rate')
    if (savedFps.length > 0) {
      this.frameRate = parseInt(savedFps)
    }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text('设置')
            .fontSize(this.pageWidth >= 820 ? 30 : 26)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('连接质量、网络服务与外观')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#B7C0CF' : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(this.pageWidth >= 820 ? 116 : 104)
      .padding({ left: this.pageWidth >= 820 ? 32 : 16, right: this.pageWidth >= 820 ? 32 : 16, top: 24, bottom: 18 })

      Scroll() {
        Column({ space: 16 }) {
          this.buildSectionCard(translate('Account'), [
            { label: translate('Device Name'), value: RustDeskNapi.getDeviceName() },
          ])
          this.buildDisplayCard()
          this.buildServerConfigCard()
          this.buildThemeToggle()
          this.buildSectionCard(translate('About'), [
            { label: translate('Version'), value: '1.0.0' },
          ])
        }
        .width(this.pageWidth >= 820 ? 720 : '100%')
        .padding(RustDeskTheme.PAGE_PADDING)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.pageWidth = newValue.width as number
    })
  }

  @Builder
  buildDisplayCard() {
    Column() {
      Text(translate('Display'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(translate('Resolution'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(this.resolution)
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
        Text('>')
          .fontSize(16)
          .fontColor(RustDeskTheme.DARK_GRAY)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .onClick(() => {
        this.showResolutionPicker = !this.showResolutionPicker
        this.showFrameRatePicker = false
      })

      if (this.showResolutionPicker) {
        Column({ space: 4 }) {
          this.buildOptionItem('Auto', () => { this.selectResolution('Auto') })
          this.buildOptionItem('720p', () => { this.selectResolution('720p') })
          this.buildOptionItem('1080p', () => { this.selectResolution('1080p') })
          this.buildOptionItem('4K', () => { this.selectResolution('4K') })
        }
        .width('100%')
        .padding({ left: 8 })
      }

      Divider()
        .height(1)
        .color(RustDeskTheme.DIVIDER)
        .margin({ top: 4, bottom: 4 })

      Row() {
        Text(translate('Frame Rate'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Text(this.frameRate.toString())
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
        Text('>')
          .fontSize(16)
          .fontColor(RustDeskTheme.DARK_GRAY)
          .margin({ left: 4 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })
      .onClick(() => {
        this.showFrameRatePicker = !this.showFrameRatePicker
        this.showResolutionPicker = false
      })

      if (this.showFrameRatePicker) {
        Column({ space: 4 }) {
          this.buildOptionItem('15', () => { this.selectFrameRate(15) })
          this.buildOptionItem('30', () => { this.selectFrameRate(30) })
          this.buildOptionItem('60', () => { this.selectFrameRate(60) })
        }
        .width('100%')
        .padding({ left: 8 })
      }
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .shadow({ radius: 12, color: this.isDarkMode ? '#33000000' : '#12345A84', offsetX: 0, offsetY: 4 })
    .width('100%')
  }

  selectResolution(res: string): void {
    this.resolution = res
    this.showResolutionPicker = false
    RustDeskNapi.setOption('resolution', res)
  }

  selectFrameRate(fps: number): void {
    this.frameRate = fps
    this.showFrameRatePicker = false
    RustDeskNapi.setOption('frame-rate', fps.toString())
  }

  @Builder
  buildOptionItem(label: string, onClick: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(RustDeskTheme.ACCENT)
      .padding({ top: 6, bottom: 6, left: 8 })
      .width('100%')
      .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.ACCENT_SOFT)
      .borderRadius(6)
      .onClick(() => { onClick() })
  }

  @Builder
  buildSectionCard(title: string, items: SettingItem[]) {
    Column() {
      Text(title)
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')
        .margin({ bottom: 8 })

      ForEach(items, (item: SettingItem) => {
        Row() {
          Text(item.label)
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          Blank()
          if (item.value.length > 0) {
            Text(item.value)
              .fontSize(RustDeskTheme.FONT_SIZE_BODY)
              .fontColor(RustDeskTheme.TEXT_SECONDARY)
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }, (item: SettingItem) => item.label)
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .shadow({ radius: 12, color: this.isDarkMode ? '#33000000' : '#12345A84', offsetX: 0, offsetY: 4 })
    .width('100%')
  }

  @Builder
  buildServerConfigCard() {
    Column() {
      Row() {
        Column() {
          Text(translate('ID/Relay Server'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          Text(translate('Configure custom server'))
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(RustDeskTheme.TEXT_SECONDARY)
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Text('>')
          .fontSize(18)
          .fontColor(RustDeskTheme.DARK_GRAY)
      }
      .width('100%')
      .onClick(() => {
        this.serverConfigDialogController.open()
      })
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .shadow({ radius: 12, color: this.isDarkMode ? '#33000000' : '#12345A84', offsetX: 0, offsetY: 4 })
    .width('100%')
  }

  @Builder
  buildThemeToggle() {
    Column() {
      Row() {
        Text(translate('Dark Mode'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.isDarkMode })
          .onChange((isOn: boolean) => {
            this.isDarkMode = isOn
            AppStorage.set<boolean>('isDarkMode', isOn)
          })
      }
      .width('100%')
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .border({ width: 1, color: this.isDarkMode ? '#303B4D' : '#E4EAF3' })
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .shadow({ radius: 12, color: this.isDarkMode ? '#33000000' : '#12345A84', offsetX: 0, offsetY: 4 })
    .width('100%')
  }
}

@Component
struct SettingsPasswordDialog {
  @State password: string = ''
  @State passwordConfirm: string = ''
  onPasswordChange: (v: string) => void = () => {}
  onConfirmChange: (v: string) => void = () => {}
  onSave: () => void = () => {}
  onCancel: () => void = () => {}
  @State errorMsg: string = ''

  build() {
    Column({ space: 12 }) {
      Text(translate('Password'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .width('100%')
        .textAlign(TextAlign.Start)

      TextInput({ placeholder: translate('Password'), text: this.password })
        .height(40)
        .fontSize(14)
        .type(InputType.Password)
        .border({ width: 1, color: RustDeskTheme.DIVIDER, radius: 8 })
        .padding({ left: 8, right: 8 })
        .width('100%')
        .onChange((v: string) => {
          this.password = v
          this.onPasswordChange(v)
          this.errorMsg = ''
        })

      TextInput({ placeholder: translate('Confirm Password'), text: this.passwordConfirm })
        .height(40)
        .fontSize(14)
        .type(InputType.Password)
        .border({ width: 1, color: RustDeskTheme.DIVIDER, radius: 8 })
        .padding({ left: 8, right: 8 })
        .width('100%')
        .onChange((v: string) => {
          this.passwordConfirm = v
          this.onConfirmChange(v)
          this.errorMsg = ''
        })

      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(12)
          .fontColor(RustDeskTheme.ERROR)
          .width('100%')
      }

      Row({ space: 12 }) {
        Button(translate('Cancel'))
          .fontColor(RustDeskTheme.TEXT_PRIMARY)
          .backgroundColor(RustDeskTheme.BG_LIGHT)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => { this.onCancel() })

        Button(translate('Save'))
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            if (this.password !== this.passwordConfirm) {
              this.errorMsg = translate('Passwords do not match')
              return
            }
            this.onSave()
          })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .padding(24)
    .width('85%')
    .backgroundColor(Color.White)
    .border({ width: 1, color: '#E4EAF3' })
    .borderRadius(8)
  }
}
