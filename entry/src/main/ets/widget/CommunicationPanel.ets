import { readableInputHeight } from '../theme/ReadableLayout'
import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'
import { translate } from '../utils/I18n'
import { common } from '@kit.AbilityKit';
import { CommunicationService, SessionChatMessage } from '../service/CommunicationService';

// Controls visibility of the call actions without changing the call lifecycle.
const VOICE_CALL_UI_ENABLED: boolean = true;

@Component
export struct CommunicationPanel {
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  @State messages: SessionChatMessage[] = [];
  @State draft: string = '';
  @State state: number = 0;
  @State muted: boolean = false;
  @State notice: string = '';
  onClose: () => void = () => {};
  private timer: number = -1;
  private scrollTimer: number = -1;
  private revision: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    CommunicationService.setPanelOpen(true);
    this.refresh();
    this.timer = setInterval(() => { this.refresh(); }, 200);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) clearInterval(this.timer);
    if (this.scrollTimer !== -1) clearTimeout(this.scrollTimer);
    CommunicationService.setPanelOpen(false);
  }

  refresh(): void {
    if (this.revision === CommunicationService.revision) return;
    this.revision = CommunicationService.revision;
    const scroll: boolean = this.messages.length === 0 || this.scroller.isAtEnd();
    this.messages = CommunicationService.messages.slice();
    this.state = CommunicationService.callState;
    this.muted = CommunicationService.muted;
    this.notice = CommunicationService.notice;
    if (scroll) {
      if (this.scrollTimer !== -1) clearTimeout(this.scrollTimer);
      this.scrollTimer = setTimeout(() => { this.scroller.scrollEdge(Edge.Bottom); this.scrollTimer = -1; }, 30);
    }
  }

  statusText(): string {
    switch (this.state) {
      case 1: return '正在呼叫，等待远端接听…';
      case 2: return this.muted ? '通话中 · 麦克风已关闭' : '通话中 · 麦克风正在使用';
      case 3: return '远端已拒绝语音通话';
      case 4: return '语音通话已结束';
      case 5: return '远端未接听，或该客户端暂不支持语音通话';
      default: return '文字聊天与远端语音通话';
    }
  }

  send(): void {
    if (CommunicationService.send(this.draft)) { this.draft = ''; this.refresh(); }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#66000000')
        .onClick(() => { this.onClose(); });
      Column({ space: 10 }) {
        Row() {
          Text(translate(VOICE_CALL_UI_ENABLED ? '聊天与通话' : '聊天', this.uiLanguage)).fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor(this.isDarkMode ? '#F1F5F9' : '#17253D').layoutWeight(1);
          Button(translate('关闭', this.uiLanguage)).constraintSize({ minHeight: 36 }).fontSize(14).fontColor('#286BC2').backgroundColor('#DFEDFF')
            .onClick(() => { this.onClose(); })
            .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
        }.width('100%');
        if (VOICE_CALL_UI_ENABLED) {
          Text(translate(this.statusText(), this.uiLanguage)).fontSize(13).fontColor(this.isDarkMode ? '#BFDBFE' : '#385D87').width('100%');
          Row({ space: 10 }) {
            if (this.state === 1 || this.state === 2) {
              if (this.state === 2) {
                Button(translate(this.muted ? '开启麦克风' : '静音', this.uiLanguage)).constraintSize({ minHeight: 38 }).fontSize(14)
                  .fontColor('#245FA5').backgroundColor(this.muted ? '#C7DFFF' : '#E5EFFF')
                  .onClick(() => { CommunicationService.toggleMute(); this.refresh(); })
                  .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
              }
              Button(translate(this.state === 1 ? '取消呼叫' : '挂断', this.uiLanguage)).constraintSize({ minHeight: 38 }).fontSize(14)
                .fontColor('#B03040').backgroundColor('#FFE2E5')
                .onClick(() => { CommunicationService.hangup(); this.refresh(); })
                .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
            } else {
              Button(translate('发起语音', this.uiLanguage)).constraintSize({ minHeight: 38 }).fontSize(14).fontColor('#245FA5').backgroundColor('#DFEDFF')
                .onClick(() => {
                  CommunicationService.call(this.getUIContext().getHostContext() as common.UIAbilityContext);
                })
                .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
            }
          }.width('100%');
        }
        if (this.notice.length > 0) {
          Text(translate(this.notice, this.uiLanguage)).fontSize(12).fontColor(this.isDarkMode ? '#FFCCA0' : '#925018').width('100%');
        }
        Scroll(this.scroller) {
          Column({ space: 10 }) {
            if (this.messages.length === 0) {
              Text(translate('暂无消息\n发送的文字将显示在远端 RustDesk 聊天窗口', this.uiLanguage)).fontSize(14)
                .fontColor(this.isDarkMode ? '#ABBBD0' : '#617089').textAlign(TextAlign.Center)
                .width('100%').padding(24);
            }
            ForEach(this.messages, (message: SessionChatMessage) => {
              Column({ space: 3 }) {
                Text(`${translate(message.outgoing ? '我' : '远端', this.uiLanguage)} · ${message.time}`).fontSize(11)
                  .fontColor(this.isDarkMode ? '#ABBBD0' : '#617089');
                Text(message.text).fontSize(15).fontColor(this.isDarkMode ? '#F1F5F9' : '#17253D')
                  .copyOption(CopyOptions.LocalDevice).padding(10).borderRadius(12)
                  .backgroundColor(message.outgoing ? (this.isDarkMode ? '#254565' : '#DFEDFF') :
                    (this.isDarkMode ? '#303E50' : '#EEF2F7'))
                  .constraintSize({ maxWidth: '90%' });
              }.width('100%').alignItems(message.outgoing ? HorizontalAlign.End : HorizontalAlign.Start);
            }, (message: SessionChatMessage) => message.id.toString());
          }.width('100%');
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto);
        Row({ space: 8 }) {
          TextInput({ text: this.draft, placeholder: translate('输入聊天消息', this.uiLanguage) }).layoutWeight(1).height(readableInputHeight(42, this.uiFontScale, 18))
            .maxLength(1000).fontSize(15).fontColor(this.isDarkMode ? '#F1F5F9' : '#17253D')
            .backgroundColor(this.isDarkMode ? '#303E50' : '#EEF2F7')
            .enterKeyType(EnterKeyType.Send).onChange((text: string) => { this.draft = text; })
            .onSubmit(() => { this.send(); });
          Button(translate('发送', this.uiLanguage)).constraintSize({ minHeight: 42 }).width(64).fontSize(14).fontColor('#245FA5').backgroundColor('#D8E9FF')
            .enabled(this.draft.trim().length > 0).onClick(() => { this.send(); })
            .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
        }.width('100%');
        Text(translate(VOICE_CALL_UI_ENABLED ? '记录仅保留本次连接；已接通的语音在系统允许时可后台继续，挂断即停止采集，建议使用耳机。' : '聊天记录仅保留本次连接。', this.uiLanguage))
          .fontSize(11).fontColor(this.isDarkMode ? '#ABBBD0' : '#617089').width('100%');
      }.width('92%').constraintSize({ maxWidth: 520 }).height('86%').padding(16)
        .borderRadius(20).backgroundColor(this.isDarkMode ? '#1E2A3A' : '#FFFFFF');
    }.width('100%').height('100%').zIndex(100);
  }
}
