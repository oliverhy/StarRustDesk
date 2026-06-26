import { RustDeskTheme } from '../theme/RustDeskTheme';
import { translate } from '../utils/I18n';
import { ServerService } from '../service/ServerService';
import { RustDeskNapi, SessionInfo } from '../service/RustDeskNapi';

@Component
export struct ServerPage {
  @State isServiceRunning: boolean = false;
  @State deviceId: string = ServerService.getDeviceId();
  @State isOnline: boolean = false;
  @State isDarkMode: boolean = AppStorage.get<boolean>('isDarkMode') ?? false;
  @State password: string = '';
  @State showPasswordDialog: boolean = false;
  @State passwordInput: string = '';
  @State passwordConfirm: string = '';
  @State sessions: SessionInfo[] = [];
  private sessionTimer: number = -1;

  aboutToAppear(): void {
    this.password = RustDeskNapi.getOption('password');
    this.startSessionPolling();
  }

  aboutToDisappear(): void {
    if (this.sessionTimer !== -1) {
      clearTimeout(this.sessionTimer);
    }
  }

  startSessionPolling(): void {
    let poll = () => {
      if (this.isServiceRunning) {
        this.sessions = RustDeskNapi.getActiveSessions();
        this.isOnline = this.sessions.length > 0;
      }
      this.sessionTimer = setTimeout(poll, 3000);
    };
    this.sessionTimer = setTimeout(poll, 3000);
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          this.buildServiceToggleCard();
          this.buildDeviceInfoCard();
          this.buildPasswordCard();
          this.buildSessionCard();
        }
        .width('100%')
        .padding(RustDeskTheme.PAGE_PADDING);
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  buildServiceToggleCard() {
    Column() {
      Row() {
        Column() {
          Text(this.isServiceRunning ? translate('Stop Service') : translate('Start Service'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
            .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY);
          Text(this.isServiceRunning ? translate('Online') : translate('Offline'))
            .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
            .fontColor(this.isServiceRunning ? RustDeskTheme.SUCCESS : RustDeskTheme.DARK_GRAY);
        }
        .alignItems(HorizontalAlign.Start);

        Blank();

        Toggle({ type: ToggleType.Switch, isOn: this.isServiceRunning })
          .onChange((isOn: boolean) => {
            this.isServiceRunning = isOn;
            AppStorage.set<boolean>('isServiceRunning', isOn);
            if (isOn) {
              ServerService.startService();
            } else {
              ServerService.stopService();
            }
          });
      }
      .width('100%');
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .width('100%');
  }

  @Builder
  buildDeviceInfoCard() {
    Column() {
      Row() {
        Text(translate('Device ID'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(RustDeskTheme.TEXT_SECONDARY);
        Blank();
        Text(this.deviceId)
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
          .fontColor(RustDeskTheme.ID_COLOR);
      }
      .width('100%');

      Divider()
        .height(1)
        .color(RustDeskTheme.DIVIDER)
        .margin({ top: 8, bottom: 8 });

      Row() {
        Text(translate('Status'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(RustDeskTheme.TEXT_SECONDARY);
        Blank();
        Row() {
          Circle()
            .width(8)
            .height(8)
            .fill(this.isOnline ? RustDeskTheme.CONNECTED_GREEN : RustDeskTheme.DARK_GRAY);
          Text(this.isOnline ? translate('Online') : translate('Offline'))
            .fontSize(RustDeskTheme.FONT_SIZE_BODY)
            .fontColor(this.isOnline ? RustDeskTheme.SUCCESS : RustDeskTheme.DARK_GRAY);
        }
        .alignItems(VerticalAlign.Center);
      }
      .width('100%');
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .width('100%');
  }

  @Builder
  buildPasswordCard() {
    Column() {
      Row() {
        Text(translate('Password'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY);
        Blank();
        Text(this.password.length > 0 ? '********' : translate('Set'))
          .fontSize(RustDeskTheme.FONT_SIZE_BODY)
          .fontColor(this.password.length > 0 ? RustDeskTheme.TEXT_SECONDARY : RustDeskTheme.ACCENT);
      }
      .width('100%');
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .width('100%')
    .onClick(() => {
      this.passwordInput = this.password
      this.passwordConfirm = this.password
      this.showPasswordDialog = true
    })

    if (this.showPasswordDialog) {
      PasswordDialog({
        password: this.passwordInput,
        passwordConfirm: this.passwordConfirm,
        onPasswordChange: (v: string) => { this.passwordInput = v },
        onConfirmChange: (v: string) => { this.passwordConfirm = v },
        onSave: () => {
          if (this.passwordInput === this.passwordConfirm) {
            RustDeskNapi.setOption('password', this.passwordInput)
            this.password = this.passwordInput
          }
          this.showPasswordDialog = false
        },
        onCancel: () => {
          this.showPasswordDialog = false
        }
      })
    }
  }

  @Builder
  buildSessionCard() {
    Column() {
      Text(translate('Active Sessions'))
        .fontSize(RustDeskTheme.FONT_SIZE_BODY)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
        .width('100%');

      Divider()
        .height(1)
        .color(RustDeskTheme.DIVIDER)
        .margin({ top: 8, bottom: 8 });

      if (this.sessions.length > 0) {
        ForEach(this.sessions, (session: SessionInfo) => {
          Row() {
            Circle()
              .width(8).height(8)
              .fill(RustDeskTheme.SUCCESS)
            Text(session.peerId)
              .fontSize(14)
              .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
              .fontColor(this.isDarkMode ? Color.White : RustDeskTheme.TEXT_PRIMARY)
              .margin({ left: 8 })
            Blank()
            Text(session.clientAddr)
              .fontSize(12)
              .fontColor(RustDeskTheme.TEXT_SECONDARY)
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }, (session: SessionInfo) => session.peerId + session.clientAddr)
      } else {
        Text(translate('No active sessions'))
          .fontSize(RustDeskTheme.FONT_SIZE_SMALL)
          .fontColor(RustDeskTheme.TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 16 });
      }
    }
    .padding(16)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : RustDeskTheme.CARD_LIGHT)
    .borderRadius(RustDeskTheme.CARD_RADIUS)
    .width('100%');
  }
}

@Component
struct PasswordDialog {
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
    .borderRadius(16)
  }
}
