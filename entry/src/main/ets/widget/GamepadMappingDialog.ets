import { GamepadBinding, GamepadMapping, GamepadTarget, GAMEPAD_CODES, GAMEPAD_LABELS, GAMEPAD_TARGETS,
  decodeGamepadMapping, defaultGamepadMapping, gamepadMappingHasConflicts } from '../model/GamepadMapping'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'
import { translate } from '../utils/I18n'

@CustomDialog
export struct GamepadMappingDialog {
  @StorageLink('uiFontScale') uiFontScale: number = 1
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  controller?: CustomDialogController
  @Prop initial: GamepadMapping = defaultGamepadMapping()
  @State mapping: GamepadMapping = defaultGamepadMapping()
  @State error: string = ''
  onSave: (mapping: GamepadMapping) => boolean = () => false
  onClose: () => void = () => {}

  aboutToAppear(): void {
    this.mapping = decodeGamepadMapping(JSON.stringify(this.initial))
    this.error = ''
  }

  setBinding(code: number, target: string): void {
    this.mapping = { version: 1, bindings: this.mapping.bindings.map((item: GamepadBinding): GamepadBinding =>
      ({ code: item.code, target: item.code === code ? target : item.target })),
      leftStick: this.mapping.leftStick, rightStick: this.mapping.rightStick,
      deadzone: this.mapping.deadzone, sensitivity: this.mapping.sensitivity }
  }

  targetIndex(code: number): number {
    const target: string = this.mapping.bindings.find((item: GamepadBinding) => item.code === code)?.target ?? 'none'
    return Math.max(0, GAMEPAD_TARGETS.findIndex((item: GamepadTarget) => item.value === target))
  }

  targetOptions(): SelectOption[] {
    return GAMEPAD_TARGETS.map((item: GamepadTarget): SelectOption => ({ value: translate(item.label, this.uiLanguage) }))
  }

  save(): void {
    if (this.onSave(this.mapping)) { this.onClose(); this.controller?.close() }
    else this.error = '手柄设置保存失败，请重试'
  }

  build() {
    Column({ space: 10 }) {
      Text(translate('手柄映射设置', this.uiLanguage)).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(this.primary()).width('100%')
      Scroll() {
        Column({ space: 10 }) {
          Text(translate('手柄按键映射为远端键鼠；不支持只识别原生手柄的游戏。', this.uiLanguage))
            .fontSize(13).fontColor(this.secondary()).width('100%')
          Row({ space: 10 }) {
            Text(translate('左摇杆', this.uiLanguage)).fontSize(14).fontColor(this.primary()).layoutWeight(1)
            Select([{ value: 'WASD' }, { value: translate('方向键', this.uiLanguage) }, { value: translate('关闭', this.uiLanguage) }])
              .selected(['wasd', 'arrows', 'off'].indexOf(this.mapping.leftStick))
              .value(this.mapping.leftStick === 'wasd' ? 'WASD' : translate(this.mapping.leftStick === 'arrows' ? '方向键' : '关闭', this.uiLanguage))
              .width('58%').onSelect((index: number) => {
                if (index >= 0 && index < 3) this.mapping.leftStick = ['wasd', 'arrows', 'off'][index]
              })
          }.width('100%').constraintSize({ minHeight: 44 })
          Row({ space: 10 }) {
            Text(translate('右摇杆', this.uiLanguage)).fontSize(14).fontColor(this.primary()).layoutWeight(1)
            Select([{ value: translate('鼠标移动', this.uiLanguage) }, { value: translate('方向键', this.uiLanguage) },
              { value: translate('关闭', this.uiLanguage) }])
              .selected(['mouse', 'arrows', 'off'].indexOf(this.mapping.rightStick))
              .value(translate(this.mapping.rightStick === 'mouse' ? '鼠标移动' : this.mapping.rightStick === 'arrows' ? '方向键' : '关闭', this.uiLanguage))
              .width('58%').onSelect((index: number) => {
                if (index >= 0 && index < 3) this.mapping.rightStick = ['mouse', 'arrows', 'off'][index]
              })
          }.width('100%').constraintSize({ minHeight: 44 })
          Text(translate(`摇杆死区：${this.mapping.deadzone}%`, this.uiLanguage)).fontSize(13).fontColor(this.primary()).width('100%')
          Slider({ value: this.mapping.deadzone, min: 5, max: 45, step: 1 }).width('100%')
            .onChange((value: number) => { this.mapping.deadzone = Math.round(value) })
          Text(translate(`鼠标灵敏度：${this.mapping.sensitivity}%`, this.uiLanguage)).fontSize(13).fontColor(this.primary()).width('100%')
          Slider({ value: this.mapping.sensitivity, min: 25, max: 200, step: 5 }).width('100%')
            .onChange((value: number) => { this.mapping.sensitivity = Math.round(value) })
          if (gamepadMappingHasConflicts(this.mapping)) {
            Text(translate('存在重复按键映射，请确认是否符合游戏操作习惯。', this.uiLanguage))
              .fontSize(12).fontColor(RustDeskTheme.ERROR).width('100%')
          }
          ForEach(GAMEPAD_CODES, (code: number, index: number) => {
            Row({ space: 10 }) {
              Text(GAMEPAD_LABELS[index]).fontSize(14).fontColor(this.primary()).layoutWeight(1)
              Select(this.targetOptions()).selected(this.targetIndex(code))
                .value(translate(GAMEPAD_TARGETS[this.targetIndex(code)].label, this.uiLanguage)).width('58%')
                .onSelect((selected: number) => {
                  if (selected >= 0 && selected < GAMEPAD_TARGETS.length) this.setBinding(code, GAMEPAD_TARGETS[selected].value)
                })
            }.width('100%').constraintSize({ minHeight: 44 })
          }, (code: number) => `${code}`)
          if (this.error.length > 0) Text(translate(this.error, this.uiLanguage)).fontSize(13).fontColor(RustDeskTheme.ERROR).width('100%')
        }.width('100%').padding({ bottom: 8 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      Row({ space: 8 }) {
        Button(translate('恢复默认', this.uiLanguage)).layoutWeight(1).onClick(() => { this.mapping = defaultGamepadMapping() })
          .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons))
        Button(translate('取消', this.uiLanguage)).layoutWeight(1).onClick(() => { this.onClose(); this.controller?.close() })
          .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons))
        Button(translate('保存', this.uiLanguage)).layoutWeight(1).fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT)
          .onClick(() => { this.save() }).attributeModifier(new ReadableButtonModifier(this.roundedRectButtons))
      }.width('100%')
    }.width('92%').height('80%').constraintSize({ maxWidth: 560 }).padding(18).borderRadius(18)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
  }

  private primary(): ResourceColor { return this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY }
  private secondary(): ResourceColor { return this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY }
}
