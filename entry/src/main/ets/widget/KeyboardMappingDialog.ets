import { translate } from '../utils/I18n';
import { RustDeskTheme } from '../theme/RustDeskTheme';
import { ButtonShapeModifier } from '../theme/ButtonShapeModifier';
import { KEYBOARD_REMAP_KEYS, KeyboardRemapConfig, KeyboardRemapRule, decodeKeyboardRemap,
  keyboardModifierBit, keyboardRemapHarmonyCode, keyboardRemapKeyLabel, keyboardRemapTargetLabel,
  keyboardRemapPreset, validKeyboardRemap } from '../model/KeyboardRemapping';

@CustomDialog
export struct KeyboardMappingDialog {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans';
  @StorageLink('isDarkMode') dark: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  @StorageLink('uiFontScale') uiFontScale: number = 1;
  controller?: CustomDialogController;
  initial: string = '';
  onSave: (value: string) => boolean = () => false;
  onClose: () => void = () => {};
  @State mappingEnabled: boolean = false;
  @State rules: KeyboardRemapRule[] = [];
  @State sourceKey: number = 114;
  @State targetKey: number = 38;
  @State modifiers: number = 0;
  @State recording: boolean = false;
  @State error: string = '';

  aboutToAppear(): void {
    const config: KeyboardRemapConfig = decodeKeyboardRemap(this.initial);
    this.mappingEnabled = config.enabled;
    this.rules = config.rules;
  }

  selectSource(code: number): void {
    this.sourceKey = code;
    if ((keyboardModifierBit(code) !== 0) !== (keyboardModifierBit(this.targetKey) !== 0)) {
      this.targetKey = keyboardModifierBit(code) !== 0 ? 91 : 38;
    }
    if (keyboardModifierBit(code) !== 0) this.modifiers = 0;
    this.recording = false;
  }

  targetKeys(): number[] {
    return KEYBOARD_REMAP_KEYS.filter((code: number) =>
      (keyboardModifierBit(code) !== 0) === (keyboardModifierBit(this.sourceKey) !== 0));
  }

  applyPreset(name: string): void {
    // Choosing a preset edits the draft; it never opts a user into remapping.
    this.rules = keyboardRemapPreset(name, this.mappingEnabled).rules;
    this.error = '';
  }

  addRule(): void {
    const rule: KeyboardRemapRule = { source: this.sourceKey, target: this.targetKey, modifiers: this.modifiers, enabled: true };
    const next: KeyboardRemapRule[] = this.rules.filter((item: KeyboardRemapRule) => item.source !== rule.source);
    next.push(rule);
    const config: KeyboardRemapConfig = { version: 1, enabled: this.mappingEnabled, rules: next };
    if (!validKeyboardRemap(config) || JSON.stringify(config).length > 2048) {
      this.error = '映射规则无效或数量过多'; return;
    }
    this.rules = next;
    this.error = '';
  }

  save(): void {
    const config: KeyboardRemapConfig = { version: 1, enabled: this.mappingEnabled, rules: this.rules };
    const value: string = JSON.stringify(config);
    if (!validKeyboardRemap(config) || value.length > 2048) { this.error = '映射规则无效或数量过多'; return; }
    if (this.onSave(value)) this.close();
    else this.error = '保存键盘映射失败，请重试';
  }

  close(): void {
    this.recording = false;
    this.onClose();
    this.controller?.close();
  }

  @Builder
  modifierOption(bit: number, label: string) {
    Button(label)
      .fontSize(12).constraintSize({ minHeight: 40 + Math.max(0, this.uiFontScale - 1) * 18 })
      .backgroundColor((this.modifiers & bit) !== 0 ? (this.dark ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG) : Color.Transparent)
      .fontColor(this.dark ? '#AFCBFF' : RustDeskTheme.CONTROL_SELECTED_TEXT)
      .onClick(() => { this.modifiers ^= bit; })
      .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
  }

  build() {
    Column({ space: 12 }) {
      Text(translate('自定义键盘映射', this.uiLanguage)).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.dark ? '#EFF4FB' : RustDeskTheme.TEXT_PRIMARY).width('100%')
      Row() {
        Text(translate('启用实体键盘映射', this.uiLanguage)).fontSize(15).layoutWeight(1)
          .fontColor(this.dark ? '#EFF4FB' : RustDeskTheme.TEXT_PRIMARY)
        Toggle({ type: ToggleType.Switch, isOn: this.mappingEnabled }).selectedColor(RustDeskTheme.ACCENT)
          .onChange((value: boolean) => { this.mappingEnabled = value; })
      }.width('100%')
      Text(translate('仅当前远端生效；中文输入、粘贴及快捷栏按标注发送，不做文本替换。', this.uiLanguage))
        .fontSize(12).fontColor(this.dark ? '#B8C5D9' : RustDeskTheme.TEXT_SECONDARY).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Button(translate('Mac 常用预设', this.uiLanguage))
            .width('100%').constraintSize({ minHeight: 44 }).fontSize(14)
            .fontColor(this.dark ? '#AFCBFF' : RustDeskTheme.CONTROL_SELECTED_TEXT)
            .backgroundColor(this.dark ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
            .bindMenu([
              { value: translate('Ctrl → Command（保留左右键）', this.uiLanguage), action: () => { this.applyPreset('macCtrl'); } },
              { value: translate('Ctrl 与 Win/Cmd 互换', this.uiLanguage), action: () => { this.applyPreset('macSwap'); } },
              { value: translate('F3 → Ctrl+↑', this.uiLanguage), action: () => { this.applyPreset('macMission'); } }
            ])
            .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
          Text(translate('预设会替换当前规则，但不会自动启用；组合键效果取决于远端系统设置。', this.uiLanguage))
            .fontSize(11).fontColor(this.dark ? '#B8C5D9' : RustDeskTheme.TEXT_SECONDARY).width('100%')
          ForEach(this.rules, (rule: KeyboardRemapRule) => {
            Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
              Text(`${keyboardRemapKeyLabel(rule.source)} → ${keyboardRemapTargetLabel(rule)}`)
                .fontSize(14).fontColor(this.dark ? '#EFF4FB' : RustDeskTheme.TEXT_PRIMARY).layoutWeight(1)
              Toggle({ type: ToggleType.Checkbox, isOn: rule.enabled }).selectedColor(RustDeskTheme.ACCENT).onChange((value: boolean) => {
                this.rules = this.rules.map((item: KeyboardRemapRule): KeyboardRemapRule => ({ source: item.source, target: item.target,
                  modifiers: item.modifiers, enabled: item.source === rule.source ? value : item.enabled }));
              })
              Button(translate('修改', this.uiLanguage)).fontSize(12).onClick(() => {
                this.sourceKey = rule.source; this.targetKey = rule.target; this.modifiers = rule.modifiers;
              }).attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
              Button(translate('删除', this.uiLanguage)).fontSize(12).fontColor(RustDeskTheme.ERROR)
                .onClick(() => { this.rules = this.rules.filter((item: KeyboardRemapRule) => item.source !== rule.source); })
                .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
            }.width('100%').padding({ top: 4, bottom: 4 })
          }, (rule: KeyboardRemapRule) => `${rule.source}-${rule.target}-${rule.modifiers}-${rule.enabled}`)
          Divider()
          Text(translate('源按键', this.uiLanguage)).fontSize(14).fontColor(this.dark ? '#EFF4FB' : RustDeskTheme.TEXT_PRIMARY).width('100%')
          Select(KEYBOARD_REMAP_KEYS.map((code: number): SelectOption => ({ value: keyboardRemapKeyLabel(code) })))
            .selected(KEYBOARD_REMAP_KEYS.indexOf(this.sourceKey)).value(keyboardRemapKeyLabel(this.sourceKey))
            .width('100%').onSelect((index: number) => { this.selectSource(KEYBOARD_REMAP_KEYS[index]); })
          Button(translate(this.recording ? '请按一个源按键…' : '录入实体按键', this.uiLanguage))
            .id('keyboardRemapCapture').width('100%').constraintSize({ minHeight: 44 })
            .focusable(true).focusOnTouch(true)
            .onClick(() => { this.recording = true; this.error = ''; })
            .onKeyEvent((event: KeyEvent): boolean => {
              if (!this.recording) return false;
              if (event.type === KeyType.Down) {
                const code: number = keyboardRemapHarmonyCode(event.keyCode);
                if (code > 0) this.selectSource(code);
                else this.error = '首版仅支持修饰键、F1–F12、方向及编辑键';
              }
              return true;
            })
            .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
          Text(translate('目标按键', this.uiLanguage)).fontSize(14).fontColor(this.dark ? '#EFF4FB' : RustDeskTheme.TEXT_PRIMARY).width('100%')
          Select(this.targetKeys().map((code: number): SelectOption => ({ value: keyboardRemapKeyLabel(code) })))
            .selected(this.targetKeys().indexOf(this.targetKey)).value(keyboardRemapKeyLabel(this.targetKey))
            .width('100%').onSelect((index: number) => { this.targetKey = this.targetKeys()[index]; })
          if (keyboardModifierBit(this.sourceKey) === 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              this.modifierOption(1, 'Ctrl')
              this.modifierOption(2, 'Shift')
              this.modifierOption(4, 'Alt/Option')
              this.modifierOption(8, 'Win/Cmd')
            }.width('100%')
            Text(translate('选中修饰键后，一次按下源键发送一次完整组合键，不随长按反复触发。', this.uiLanguage))
              .fontSize(11).fontColor(this.dark ? '#B8C5D9' : RustDeskTheme.TEXT_SECONDARY).width('100%')
          }
          Button(translate('添加或替换规则', this.uiLanguage)).width('100%').constraintSize({ minHeight: 44 })
            .onClick(() => { this.addRule(); }).attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
          Button(translate('恢复默认（关闭并清空）', this.uiLanguage)).width('100%').constraintSize({ minHeight: 44 })
            .onClick(() => { this.mappingEnabled = false; this.rules = []; this.error = ''; })
            .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: '55%' }).scrollBar(BarState.Off)
      if (this.error) {
        Text(translate(this.error, this.uiLanguage)).fontSize(12).fontColor(RustDeskTheme.ERROR).width('100%')
      }
      Row({ space: 12 }) {
        Button(translate('取消', this.uiLanguage)).layoutWeight(1).constraintSize({ minHeight: 44 })
          .onClick(() => { this.close(); }).attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
        Button(translate('保存', this.uiLanguage)).layoutWeight(1).constraintSize({ minHeight: 44 })
          .onClick(() => { this.save(); }).attributeModifier(new ButtonShapeModifier(this.roundedRectButtons))
      }.width('100%')
    }.padding(20).width('92%').constraintSize({ maxWidth: 560, maxHeight: '90%' }).borderRadius(20)
      .backgroundColor(this.dark ? '#1E2A3A' : '#FFFFFF')
  }
}
