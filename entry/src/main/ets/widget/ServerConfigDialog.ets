import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'
import { RustDeskNapi } from '../service/RustDeskNapi'

@CustomDialog
export struct ServerConfigDialog {
  @State idServer: string = ''
  @State relayServer: string = ''
  @State apiServer: string = ''
  @State serverKey: string = ''
  @State errorMsg: string = ''
  @State isTesting: boolean = false
  @State testResult: string = ''
  controller?: CustomDialogController

  aboutToAppear(): void {
    this.idServer = RustDeskNapi.getOption('custom-rendezvous-server')
    this.relayServer = RustDeskNapi.getOption('relay-server')
    this.apiServer = RustDeskNapi.getOption('api-server')
    this.serverKey = RustDeskNapi.getOption('key')
  }

  build() {
    Column({ space: 12 }) {
      Text(translate('ID/Relay Server'))
        .fontSize(RustDeskTheme.FONT_SIZE_TITLE)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
        .width('100%')
        .textAlign(TextAlign.Start)

      this.buildField(translate('ID Server'), this.idServer, (v: string) => { this.idServer = v })
      this.buildField(translate('Relay Server'), this.relayServer, (v: string) => { this.relayServer = v })
      this.buildField(translate('API Server'), this.apiServer, (v: string) => { this.apiServer = v })
      this.buildField(translate('Key'), this.serverKey, (v: string) => { this.serverKey = v })

      if (this.testResult.length > 0) {
        Row() {
          Circle()
            .width(8)
            .height(8)
            .fill(this.testResult.startsWith('✓') || this.testResult === translate('Server connected successfully') ? RustDeskTheme.SUCCESS : RustDeskTheme.ERROR)
          Text(this.testResult)
            .fontSize(12)
            .fontColor(this.testResult.startsWith('✓') || this.testResult === translate('Server connected successfully') ? RustDeskTheme.SUCCESS : RustDeskTheme.ERROR)
            .margin({ left: 4 })
        }
        .width('100%')
      }

      if (this.isTesting) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
          Text(translate('Testing connection...'))
            .fontSize(12)
            .fontColor(RustDeskTheme.TEXT_SECONDARY)
            .margin({ left: 6 })
        }
        .width('100%')
      }

      Row({ space: 12 }) {
        Button(translate('Cancel'))
          .fontColor(RustDeskTheme.TEXT_PRIMARY)
          .backgroundColor(RustDeskTheme.BG_LIGHT)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            if (this.controller != undefined) {
              this.controller.close()
            }
          })

        Button(translate('Test Connection'))
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.SUCCESS)
          .borderRadius(8)
          .layoutWeight(1)
          .enabled(!this.isTesting)
          .onClick(() => {
            this.testConnection()
          })

        Button(translate('OK'))
          .fontColor(Color.White)
          .backgroundColor(RustDeskTheme.ACCENT)
          .borderRadius(8)
          .layoutWeight(1)
          .enabled(!this.isTesting)
          .onClick(() => {
            this.saveConfig()
          })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .padding(24)
    .width('90%')
    .backgroundColor(Color.White)
    .borderRadius(16)
  }

  testConnection(): void {
    if (this.idServer.length === 0) {
      this.testResult = translate('Please enter ID server address')
      return
    }
    this.isTesting = true
    this.testResult = ''
    let result: string = RustDeskNapi.testIfValidServer(this.idServer)
    this.isTesting = false
    if (result.length === 0) {
      this.testResult = translate('Server connected successfully')
    } else {
      this.testResult = '✗ ' + result
    }
  }

  saveConfig(): void {
    RustDeskNapi.setOption('custom-rendezvous-server', this.idServer.trim())
    RustDeskNapi.setOption('relay-server', this.relayServer.trim())
    RustDeskNapi.setOption('api-server', this.apiServer.trim())
    RustDeskNapi.setOption('key', this.serverKey.trim())
    if (this.controller != undefined) {
      this.controller.close()
    }
  }

  @Builder
  buildField(label: string, value: string, onChange: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(RustDeskTheme.TEXT_SECONDARY)
        .width('100%')
      TextInput({ placeholder: label, text: value })
        .height(40)
        .fontSize(14)
        .border({ width: 1, color: RustDeskTheme.DIVIDER, radius: 8 })
        .padding({ left: 8, right: 8 })
        .onChange((v: string) => { onChange(v) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
