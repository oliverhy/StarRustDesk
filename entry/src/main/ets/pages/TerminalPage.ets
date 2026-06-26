import { router } from '@kit.ArkUI';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { translate } from '../utils/I18n';
import { RustDeskNapi } from '../service/RustDeskNapi';

@Entry
@Component
struct TerminalPage {
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false
  @State commandHistory: string[] = []
  @State currentCommand: string = ''
  @State output: string = ''

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

        Text(translate('Terminal'))
          .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .margin({ left: 12 })

        Blank()

        Button(translate('Send'))
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
          .height(28)
          .enabled(this.currentCommand.length > 0)
          .onClick(() => {
            this.executeCommand()
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })

      Scroll() {
        Text(this.output.length > 0 ? this.output : translate('Terminal'))
          .fontSize(13)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
          .width('100%')
      }
      .layoutWeight(1)
      .padding(8)
      .backgroundColor(Color.Black)
      .borderRadius(8)
      .margin({ left: 8, right: 8 })

      Row({ space: 8 }) {
        TextInput({ placeholder: translate('Send'), text: this.currentCommand })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .onChange((v: string) => { this.currentCommand = v })
          .onSubmit(() => { this.executeCommand() })

        Button(translate('Send'))
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(6)
          .height(36)
          .enabled(this.currentCommand.length > 0)
          .onClick(() => { this.executeCommand() })
      }
      .padding(8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? RustDeskTheme.BG_DARK : RustDeskTheme.BG_LIGHT)
  }

  executeCommand(): void {
    if (this.currentCommand.length === 0) {
      return
    }
    let cmd: string = this.currentCommand
    this.commandHistory.push(cmd)
    this.currentCommand = ''
    // Send command via keyboard events
    for (let i: number = 0; i < cmd.length; i++) {
      let charCode: number = cmd.charCodeAt(i)
      RustDeskNapi.sendKeyEvent(charCode, 0)
      RustDeskNapi.sendKeyEvent(charCode, 1)
    }
    // Send Enter
    RustDeskNapi.sendKeyEvent(13, 0)
    RustDeskNapi.sendKeyEvent(13, 1)
    this.output += '$ ' + cmd + '\n'
  }
}
