import { readableInputHeight } from '../theme/ReadableLayout'
import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'
import { ConnectionEditorGroup, ConnectionEditResult, SavedConnectionDraft, SavedConnectionEditing } from '../model/SavedConnectionEditing'
import { RustDeskTheme } from '../theme/RustDeskTheme'
import { translate } from '../utils/I18n'

@CustomDialog
export struct SavedConnectionEditorDialog {
  @StorageLink('uiFontScale') uiFontScale: number = 1
  controller?: CustomDialogController
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true
  @Prop initial: SavedConnectionDraft = SavedConnectionEditing.empty()
  @Prop groups: ConnectionEditorGroup[] = []
  @Prop createNew: boolean = false
  @State remoteId: string = ''
  @State name: string = ''
  @State groupId: string = ''
  @State performancePreset: string = 'smooth'
  @State password: string = ''
  @State passwordMode: string = 'keep'
  @State lockAfterDisconnect: boolean = false
  @State privacyMode: boolean = false
  @State autoUnlock: boolean = false
  @State osPassword: string = ''
  @State clearOsPassword: boolean = false
  @State showAdvanced: boolean = false
  @State busy: boolean = false
  @State error: string = ''
  private active: boolean = false
  private generation: number = 0
  onSave: (draft: SavedConnectionDraft, action: string) => Promise<ConnectionEditResult> =
    async () => { return { success: false, message: '保存失败，请重试' } }
  onClose: () => void = () => {}

  aboutToAppear(): void {
    this.active = true
    this.generation++
    this.remoteId = this.initial.remoteId
    this.name = this.initial.name
    this.groupId = this.initial.groupId
    this.performancePreset = this.initial.performancePreset
    this.lockAfterDisconnect = this.initial.lockAfterDisconnect
    this.privacyMode = this.initial.privacyMode
    this.autoUnlock = this.initial.autoUnlock
    this.password = ''
    this.osPassword = ''
    this.passwordMode = 'keep'
    this.clearOsPassword = false
    this.showAdvanced = false
    this.busy = false
    this.error = ''
  }

  aboutToDisappear(): void {
    this.active = false
    this.generation++
    this.password = ''
    this.osPassword = ''
  }

  identityChanged(): boolean {
    return !SavedConnectionEditing.sameEndpoint(this.remoteId, this.initial.remoteId)
  }

  changeRemoteId(value: string): void {
    if (!this.createNew || this.busy) return
    const normalized = SavedConnectionEditing.endpoint(value)
    const changed = !SavedConnectionEditing.sameEndpoint(normalized, this.remoteId)
    this.remoteId = normalized
    this.error = ''
    if (changed) {
      this.password = ''
      this.osPassword = ''
      this.passwordMode = 'keep'
      this.clearOsPassword = false
      this.lockAfterDisconnect = false
      this.privacyMode = false
      this.autoUnlock = false
    }
  }

  requestSave(): void {
    if (this.busy) return
    this.save()
  }

  cancelPasswordReplacement(): void {
    this.password = ''
    this.passwordMode = 'keep'
    this.error = ''
  }

  async save(): Promise<void> {
    if (this.busy || this.remoteId.length === 0) return
    if (this.passwordMode === 'replace' && this.password.trim().length === 0) {
      this.error = '请输入新密码，或取消更换后选择清除'
      return
    }
    this.busy = true
    const generation = this.generation
    const draft: SavedConnectionDraft = {
      remoteId: this.remoteId, name: this.name, groupId: this.groupId, performancePreset: this.performancePreset,
      password: this.password, passwordMode: this.passwordMode, lockAfterDisconnect: this.lockAfterDisconnect,
      privacyMode: this.privacyMode, autoUnlock: this.autoUnlock && this.lockAfterDisconnect,
      osPassword: this.osPassword, clearOsPassword: this.clearOsPassword,
      hasPassword: !this.identityChanged() && this.initial.hasPassword,
      hasOsPassword: !this.identityChanged() && this.initial.hasOsPassword
    }
    try {
      const result = await this.onSave(draft, this.createNew ? 'new' : 'update')
      if (!this.active || generation !== this.generation) return
      if (result.success) this.onClose()
      else this.error = result.message
    } catch (_error) {
      if (this.active && generation === this.generation) this.error = '保存失败，请重试'
    } finally { if (generation === this.generation) this.busy = false }
  }

  build() {
    Column({ space: 12 }) {
      Text(translate(this.createNew ? '新增连接' : '修改连接', this.uiLanguage)).fontSize(21).fontWeight(FontWeight.Bold)
        .fontColor(this.primary()).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          if (this.createNew) {
            TextInput({ placeholder: translate('远端 ID / IP', this.uiLanguage), text: this.remoteId })
              .height(readableInputHeight(48, this.uiFontScale, 18)).fontSize(16).enabled(!this.busy).onChange((value: string) => { this.changeRemoteId(value) })
          } else {
            Column({ space: 4 }) {
              Text(translate('远端 ID / IP', this.uiLanguage)).fontSize(12).fontColor(this.secondary()).width('100%')
              Text(this.remoteId).fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.primary()).width('100%')
                .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
            }.width('100%').padding(12).borderRadius(12)
              .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_SURFACE_DARK : RustDeskTheme.HOME_SURFACE)
          }
          TextInput({ placeholder: translate('连接名称（可选）', this.uiLanguage), text: this.name })
            .height(readableInputHeight(48, this.uiFontScale, 18)).fontSize(16).enabled(!this.busy).onChange((value: string) => { this.name = value })
          Select(this.groupOptions())
            .value(this.groups.find((group: ConnectionEditorGroup) => group.id === this.groupId)?.name ?? translate('未分组', this.uiLanguage))
            .selected(Math.max(0, this.groups.findIndex((group: ConnectionEditorGroup) => group.id === this.groupId) + 1))
            .width('100%').enabled(!this.busy).onSelect((index: number) => { this.groupId = index === 0 ? '' : this.groups[index - 1].id })
          Button(translate(this.showAdvanced ? '收起连接选项' : '连接选项', this.uiLanguage))
            .width('100%').constraintSize({ minHeight: 40 }).fontSize(14).enabled(!this.busy)
            .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons))
            .backgroundColor(Color.Transparent).fontColor(this.secondary())
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
                this.showAdvanced = !this.showAdvanced
              })
            })
          if (this.showAdvanced) {
          Column({ space: 12 }) {
          if (!this.identityChanged() && this.initial.hasPassword && this.passwordMode === 'keep') {
            Row({ space: 8 }) {
              Text(translate('密码已保存', this.uiLanguage)).fontColor(this.primary()).layoutWeight(1)
              this.smallAction('更换', () => { this.passwordMode = 'replace' })
              this.smallAction('清除', () => { this.passwordMode = 'clear' })
            }.width('100%')
          } else if (this.passwordMode === 'clear') {
            Row({ space: 8 }) {
              Text(translate('密码待清除，保存后生效', this.uiLanguage)).fontColor(this.primary()).layoutWeight(1)
              this.smallAction('撤销', () => { this.passwordMode = 'keep' })
            }.width('100%')
          } else {
            TextInput({ placeholder: translate('输入新密码', this.uiLanguage), text: this.password })
              .type(InputType.Password).showPasswordIcon(true).height(readableInputHeight(48, this.uiFontScale, 18)).enabled(!this.busy)
              .onChange((value: string) => {
                this.password = value
                this.passwordMode = value.length > 0 || (!this.identityChanged() && this.initial.hasPassword) ? 'replace' : 'keep'
              })
            if (!this.identityChanged() && this.initial.hasPassword && this.passwordMode === 'replace') {
              this.smallAction('取消更换', () => { this.cancelPasswordReplacement() })
            }
          }
          Text(translate('连接模式', this.uiLanguage)).fontColor(this.primary()).width('100%')
          Select([{ value: translate('稳定', this.uiLanguage) }, { value: translate('高帧率', this.uiLanguage) },
            { value: translate('高流畅', this.uiLanguage) }, { value: translate('高丝滑', this.uiLanguage) },
            { value: translate('保留当前设置', this.uiLanguage) }])
            .selected(this.presetIndex()).width('100%').enabled(!this.busy)
            .onSelect((index: number) => { this.performancePreset = index === 4 ? this.initial.performancePreset :
              ['stable', 'high_fps', 'smooth', 'silky'][index] })
          this.option('断开后锁屏', this.lockAfterDisconnect, (value: boolean) => {
            this.lockAfterDisconnect = value; if (!value) this.autoUnlock = false
          })
          this.option('隐私模式', this.privacyMode, (value: boolean) => { this.privacyMode = value })
          this.option('自动解锁', this.autoUnlock, (value: boolean) => {
            this.autoUnlock = value; if (value) this.lockAfterDisconnect = true
          })
          if (this.autoUnlock) {
            Text(translate(!this.identityChanged() && this.initial.hasOsPassword && !this.clearOsPassword ?
              '系统密码已保存，不会回填显示' : '请输入远端系统登录密码', this.uiLanguage))
              .fontSize(12).fontColor(this.secondary()).width('100%')
            TextInput({ placeholder: translate('输入新的系统密码（可选）', this.uiLanguage), text: this.osPassword })
              .type(InputType.Password).showPasswordIcon(false).height(readableInputHeight(48, this.uiFontScale, 18)).enabled(!this.busy)
              .onChange((value: string) => { this.osPassword = value })
            if (!this.identityChanged() && this.initial.hasOsPassword) {
              this.option('清除已保存系统密码', this.clearOsPassword, (value: boolean) => { this.clearOsPassword = value })
            }
          }
          }.width('100%').transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: -8 }))
            .animation({ duration: 220, curve: Curve.EaseInOut }))
          }
          if (this.error.length > 0) {
            Text(translate(this.error, this.uiLanguage)).fontSize(13).fontColor(RustDeskTheme.ERROR).width('100%')
          }
        }.width('100%').padding({ bottom: 8 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      Row({ space: 10 }) {
        this.smallAction('取消', () => { if (!this.busy) this.onClose() })
        Button(translate(this.busy ? '保存中…' : (this.createNew ? '保存新连接' : '保存修改'), this.uiLanguage))
          .layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(14)
          .enabled(!this.busy && this.remoteId.length > 0)
          .fontColor(Color.White).backgroundColor(RustDeskTheme.ACCENT).onClick(() => { this.requestSave() })
          .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
      }.width('100%')
    }.width('92%').height(this.showAdvanced ? '78%' : '52%').constraintSize({ maxWidth: 560 }).padding(18).borderRadius(18)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.HOME_CARD_DARK : RustDeskTheme.HOME_CARD)
  }

  @Builder
  smallAction(label: string, action: () => void) {
    Button(translate(label, this.uiLanguage)).constraintSize({ minHeight: 40 }).fontSize(14).enabled(!this.busy)
      .fontColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
      .backgroundColor(this.isDarkMode ? RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG)
      .onClick(action).attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule))
  }

  @Builder
  option(label: string, value: boolean, change: (value: boolean) => void) {
    Row({ space: 12 }) {
      Text(translate(label, this.uiLanguage)).fontSize(14).fontColor(this.primary()).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value }).enabled(!this.busy).onChange(change)
    }.width('100%').constraintSize({ minHeight: 42 })
  }

  private presetIndex(): number {
    const index = ['stable', 'high_fps', 'smooth', 'silky'].indexOf(this.performancePreset)
    return index < 0 ? 4 : index
  }
  private groupOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: translate('未分组', this.uiLanguage) }]
    this.groups.forEach((group: ConnectionEditorGroup) => { options.push({ value: group.name }) })
    return options
  }
  private primary(): ResourceColor { return this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY }
  private secondary(): ResourceColor { return this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY }
}
