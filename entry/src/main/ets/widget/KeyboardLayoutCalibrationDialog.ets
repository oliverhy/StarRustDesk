import { translate } from '../utils/I18n';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { ButtonShapeModifier } from '../theme/ButtonShapeModifier';
import { KeyboardLayoutCapture } from '../model/PhysicalKeyboardLayout';

@CustomDialog
export struct KeyboardLayoutCalibrationDialog {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans';
  @StorageLink('isDarkMode') dark: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  @StorageLink('uiFontScale') uiFontScale: number = 1;
  controller?: CustomDialogController;
  deviceId: number = -1;
  deviceName: string = '';
  onSave: (swap: boolean) => boolean = () => false;
  onClose: () => void = () => {};
  @State phase: string = 'idle';
  @State error: string = '';
  @State ready: boolean = false;
  @State swap: boolean = false;
  private capture: KeyboardLayoutCapture = new KeyboardLayoutCapture(-1);

  aboutToAppear(): void { this.capture = new KeyboardLayoutCapture(this.deviceId); }
  begin(): void {
    this.capture.begin(); this.phase = this.capture.phase; this.error = ''; this.ready = false;
  }
  handleKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) return true;
    this.capture.input(event.keyCode, event.type === KeyType.Down ? 0 : 1, event.deviceId);
    this.phase = this.capture.phase;
    const result: boolean | undefined = this.capture.result();
    this.ready = result !== undefined; this.swap = result ?? false;
    this.error = this.capture.error === 'device' ? '请使用正在校准的同一把键盘' :
      this.capture.error === 'modifier' ? '请按左侧 Command 或 Option，不要按字母键' :
      this.capture.error === 'same' ? '两个按键被识别为同一个键，请检查键盘模式后重试' : '';
    return true;
  }
  prompt(): string {
    if (this.phase === 'command') return '请按键帽上的左 Command 键';
    if (this.phase === 'command-release' || this.phase === 'option-release') return '请松开按键';
    if (this.phase === 'option') return '请按键帽上的左 Option 键';
    if (this.phase === 'done') return this.swap ? '需要互换 Command / Option' : '键位已正确，无需互换';
    return '点击开始，依次按下并松开左 Command、左 Option。';
  }
  close(): void { this.onClose(); this.controller?.close(); }
  save(): void {
    const result: boolean | undefined = this.capture.result();
    if (result === undefined) return;
    if (this.onSave(result)) this.close();
    else this.error = '保存校准失败或键盘已改变，请重新校准';
  }
  build() {
    Column({ space: 12 }) {
      Text(translate('校准 Command / Option', this.uiLanguage)).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.dark ? '#EFF4FB' : RustDeskTheme.TEXT_PRIMARY).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text(this.deviceName).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(this.dark ? '#B8C5D9' : RustDeskTheme.TEXT_SECONDARY).width('100%')
          Text(translate('只识别两个修饰键，不记录文字，也不会将校准按键发送到远端。取消不改变设置。', this.uiLanguage))
            .fontSize(12).fontColor(this.dark ? '#B8C5D9' : RustDeskTheme.TEXT_SECONDARY).width('100%')
          Text(translate(this.prompt(), this.uiLanguage)).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(this.dark ? '#AFCBFF' : RustDeskTheme.ACCENT).width('100%')
          Button(translate(this.phase === 'idle' ? '开始校准' : '重新校准', this.uiLanguage))
            .id('keyboardLayoutCapture').width('100%').constraintSize({ minHeight: 44 + Math.max(0, this.uiFontScale - 1) * 18 })
            .fontSize(14).focusable(true).focusOnTouch(true).onClick(() => { this.begin(); })
            .onKeyEvent((event: KeyEvent): boolean => { return this.handleKey(event); })
            .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
          if (this.error) {
            Text(translate(this.error, this.uiLanguage)).fontSize(12).fontColor(RustDeskTheme.ERROR).width('100%')
          }
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: '55%' }).scrollBar(BarState.Off)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End, alignItems: ItemAlign.Center }) {
        Button(translate('取消', this.uiLanguage)).fontSize(14).margin({ right: 8, bottom: 4 })
          .constraintSize({ minHeight: 44 + Math.max(0, this.uiFontScale - 1) * 18 })
          .onClick(() => { this.close(); }).attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
        Button(translate('保存校准', this.uiLanguage)).fontSize(14).enabled(this.ready).margin({ bottom: 4 })
          .constraintSize({ minHeight: 44 + Math.max(0, this.uiFontScale - 1) * 18 })
          .onClick(() => { this.save(); }).attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
      }.width('100%')
    }.padding(20).width('92%').constraintSize({ maxWidth: 520, maxHeight: '90%' }).borderRadius(20)
      .backgroundColor(this.dark ? '#1E2A3A' : '#FFFFFF')
  }
}
