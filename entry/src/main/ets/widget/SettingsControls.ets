import { curves, LengthMetricsUnit } from '@kit.ArkUI'
import { settingsPalette } from '../theme/SettingsSkin'
import { translate } from '../utils/I18n'

export interface SettingsChoice {
  key: string
  label: string
  icon?: string
  tone?: string
  literal?: boolean
}

// SVG paths from the approved 24 × 24 prototype, including its original circles and rounded rectangles.
const GLYPHS: Map<string, string> = new Map<string, string>([
  ['sliders', 'M4 7h5m5 0h6M4 17h8m5 0h3M14 7A2.5 2.5 0 1 1 9 7A2.5 2.5 0 1 1 14 7ZM17 17A2.5 2.5 0 1 1 12 17A2.5 2.5 0 1 1 17 17Z'],
  ['screen', 'M5 4H19A2 2 0 0 1 21 6V15A2 2 0 0 1 19 17H5A2 2 0 0 1 3 15V6A2 2 0 0 1 5 4ZM8 21h8m-4-4v4'],
  ['server', 'M5 4H19A2 2 0 0 1 21 6V9A2 2 0 0 1 19 11H5A2 2 0 0 1 3 9V6A2 2 0 0 1 5 4ZM5 13H19A2 2 0 0 1 21 15V18A2 2 0 0 1 19 20H5A2 2 0 0 1 3 18V15A2 2 0 0 1 5 13ZM7 7.5h.01M7 16.5h.01m5-9h5m-5 9h5'],
  ['cloud', 'M7 18a4.5 4.5 0 1 1 .7-8.94A6 6 0 0 1 19.2 11 3.5 3.5 0 1 1 19.5 18z'],
  ['activity', 'M3 12h4l3-7 4 14 3-7h4'],
  ['info', 'M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12ZM12 16v-5m0-3h.01'],
  ['clock', 'M20.5 12A8.5 8.5 0 1 1 3.5 12A8.5 8.5 0 1 1 20.5 12ZM12 8v4l3 2'],
  ['next', 'm9 6 6 6-6 6'],
  ['down', 'm6 9 6 6 6-6'],
  ['back', 'm14 6-6 6 6 6'],
  ['sync', 'M20 10a8 8 0 0 0-13.6-4.6L4 8m0-4v4h4m-4 6a8 8 0 0 0 13.6 4.6L20 16m0 4v-4h-4'],
  ['restore', 'M4 12a8 8 0 1 1 2.3 5.7M4 6v6h6m2-4v4l3 2'],
  ['download', 'M12 3v12m-4-4 4 4 4-4M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3'],
  ['trash', 'M4 7h16m-14 0 1 13h10l1-13M9 7V4h6v3m-5 3v6m4-6v6'],
  ['check', 'm5 12 4 4L19 6'],
  ['close', 'm6 6 12 12M18 6 6 18'],
  ['scan', 'M4 9V4h5m6 0h5v5m0 6v5h-5m-6 0H4v-5m0-3h16'],
  ['qr', 'M5 4H9A1 1 0 0 1 10 5V9A1 1 0 0 1 9 10H5A1 1 0 0 1 4 9V5A1 1 0 0 1 5 4ZM15 4H19A1 1 0 0 1 20 5V9A1 1 0 0 1 19 10H15A1 1 0 0 1 14 9V5A1 1 0 0 1 15 4ZM5 14H9A1 1 0 0 1 10 15V19A1 1 0 0 1 9 20H5A1 1 0 0 1 4 19V15A1 1 0 0 1 5 14ZM14 14h2v2h4v4h-2m-4 0h2'],
  ['dots', 'M6 12A1 1 0 1 1 4 12A1 1 0 1 1 6 12ZM13 12A1 1 0 1 1 11 12A1 1 0 1 1 13 12ZM20 12A1 1 0 1 1 18 12A1 1 0 1 1 20 12Z'],
  ['edit', 'M4 17v3h3L19.5 7.5l-3-3zM14.5 6.5l3 3'],
])

// The preview's elastic release, used for UI only; it never delays an action.
export const SETTINGS_RELEASE = curves.cubicBezierCurve(0.19, 1.34, 0.38, 1)
const SETTINGS_SETTLE = curves.cubicBezierCurve(0.18, 0.77, 0.26, 1)
export const SETTINGS_DIALOG_OPEN: AnimateParam = { duration: 248, curve: SETTINGS_RELEASE }
export const SETTINGS_DIALOG_CLOSE: AnimateParam = { duration: 156, curve: Curve.EaseOut }

export function settingsPromptTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.translate({ y: 8 }).combine(TransitionEffect.scale({ x: 0.983, y: 0.983 }))
      .combine(TransitionEffect.opacity(0)).animation(SETTINGS_DIALOG_OPEN),
    TransitionEffect.translate({ y: 5 }).combine(TransitionEffect.scale({ x: 0.988, y: 0.988 }))
      .combine(TransitionEffect.opacity(0)).animation(SETTINGS_DIALOG_CLOSE))
}

@Component
export struct SettingsIcon {
  @Prop @Watch('redrawIcon') icon: string = ''
  @Prop @Watch('redrawIcon') ink: string = '#215BB1'
  @Prop iconSize: number = 16
  @Prop angle: number = 0
  private painter: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true), LengthMetricsUnit.PX)
  private canvasReady: boolean = false

  private redrawIcon(): void {
    if (!this.canvasReady) return
    const width = this.painter.width
    const height = this.painter.height
    const path = GLYPHS.get(this.icon)
    this.painter.clearRect(0, 0, width, height)
    if (width <= 0 || height <= 0 || !path) return
    // Both the canvas and the SVG path use pixels: apply the 24-unit viewBox
    // exactly once, including on high-density phone screens.
    const side = Math.min(width, height)
    const scale = side / 24
    this.painter.save()
    this.painter.translate((width - side) / 2, (height - side) / 2)
    this.painter.scale(scale, scale)
    this.painter.strokeStyle = this.ink
    this.painter.lineWidth = 1.75
    this.painter.lineCap = 'round'
    this.painter.lineJoin = 'round'
    this.painter.stroke(new Path2D(path, LengthMetricsUnit.PX))
    this.painter.restore()
  }

  build() {
    Canvas(this.painter)
      .width(this.iconSize).height(this.iconSize)
      .rotate({ angle: this.angle, z: 1 })
      .animation({ duration: 205, curve: SETTINGS_RELEASE })
      .accessibilityLevel('no')
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => {
        this.canvasReady = true
        this.redrawIcon()
      })
  }
}

@Component
export struct SettingsCategoryItem {
  @StorageLink('isDarkMode') private dark: boolean = false
  @Prop title: string = ''
  @Prop description: string = ''
  @Prop icon: string = ''
  @Prop compact: boolean = true
  @Prop featured: boolean = false
  @Prop itemId: string = ''
  onAction: () => void = () => {}
  @State private pressed: boolean = false
  @State private hovered: boolean = false

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row({ space: this.compact ? 8 : 11 }) {
        Row() {
          SettingsIcon({ icon: this.icon, ink: settingsPalette(this.dark).blue, iconSize: this.compact ? 16 : 18 })
        }
        .width(this.compact ? 33 : 38).height(this.compact ? 33 : 38)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.featured ? settingsPalette(this.dark).blueSoft : settingsPalette(this.dark).pill)
        .border({ width: 1, color: settingsPalette(this.dark).pillEdge })
        .borderRadius(this.compact ? 9 : 11)

        Column({ space: 2 }) {
          Text(this.title).fontSize(16).lineHeight('21.3fp').fontWeight(700).fontColor(settingsPalette(this.dark).ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(this.description).fontSize(13).lineHeight('18.5fp').fontColor(settingsPalette(this.dark).muted)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        SettingsIcon({ icon: 'next', ink: settingsPalette(this.dark).muted, iconSize: 16 })
      }
      .width('100%')
    }
    .id(this.itemId).width('100%').constraintSize({ minHeight: this.compact ? 66 : 68 })
    .padding({ left: 7, right: 7, top: 8, bottom: 8 }).borderRadius(11)
    .scale({ x: this.pressed ? 0.982 : 1, y: this.pressed ? 0.982 : 1 })
    .animation({ duration: this.pressed ? 66 : 235, curve: this.pressed ? Curve.Linear : SETTINGS_RELEASE })
    .backgroundColor(this.hovered ? settingsPalette(this.dark).pillHover : Color.Transparent)
    .accessibilityText(this.title + '，' + this.description)
    .onHover((hovered: boolean) => { this.hovered = hovered })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) this.pressed = true
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = false
    })
    .onClick(() => { this.onAction() })
  }
}

@Component
struct SettingsPopupItem {
  @StorageLink('isDarkMode') private dark: boolean = false
  @StorageLink('uiLanguage') private uiLanguage: string = 'zh-Hans'
  @Prop label: string = ''
  @Prop icon: string = ''
  @Prop tone: string = ''
  @Prop isChoice: boolean = false
  @Prop selected: boolean = false
  onSelect: () => void = () => {}
  @State private pressed: boolean = false
  @State private hovered: boolean = false

  private fill(): ResourceColor {
    const palette = settingsPalette(this.dark)
    if (this.selected) return this.hovered ? palette.blueHover : palette.blueSoft
    if (this.hovered) return this.tone === 'warn' ? palette.redSoft : palette.pillHover
    return Color.Transparent
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row({ space: 9 }) {
        if (!this.isChoice && this.icon.length > 0) {
          SettingsIcon({ icon: this.icon, ink: this.tone === 'warn' ? settingsPalette(this.dark).red :
            settingsPalette(this.dark).subtle, iconSize: 15 })
        }
        Text(this.label).layoutWeight(1).fontSize(13).lineHeight('17fp').fontWeight(600).wordBreak(WordBreak.BREAK_WORD)
          .fontColor(this.selected ? settingsPalette(this.dark).blue :
            (this.tone === 'warn' ? settingsPalette(this.dark).red : settingsPalette(this.dark).ink))
          .textAlign(TextAlign.Start)
        if (this.isChoice) {
          SettingsIcon({ icon: 'check', ink: settingsPalette(this.dark).blue, iconSize: 15 })
            .opacity(this.selected ? 1 : 0)
        }
      }
      .width('100%')
    }
    .width('100%').constraintSize({ minHeight: 44 }).padding({ left: 9, right: 9, top: 6, bottom: 6 })
    .border({ width: 1, color: this.selected ? settingsPalette(this.dark).pillEdge : Color.Transparent })
    .borderRadius(9).backgroundColor(this.fill())
    .scale({ x: this.pressed ? 0.955 : 1, y: this.pressed ? 0.955 : 1 })
    .animation({ duration: this.pressed ? 66 : 235, curve: this.pressed ? Curve.Linear : SETTINGS_RELEASE })
    .accessibilityText(this.label)
    .accessibilityDescription(this.selected ? translate('已选中', this.uiLanguage) : '')
    .onHover((hovered: boolean) => { this.hovered = hovered })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) this.pressed = true
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = false
    })
    .onClick(() => { this.onSelect() })
  }
}

// Used by both top-level setting rows and their feature dialogs. Menus are
// anchored to the real focusable button and have no empty title or footer.
@Component
export struct SettingsAction {
  @StorageLink('isDarkMode') private dark: boolean = false
  @StorageLink('uiLanguage') private uiLanguage: string = 'zh-Hans'
  @StorageLink('roundedRectButtons') private roundedRectButtons: boolean = true
  @StorageLink('uiFontScale') private uiFontScale: number = 1
  @Prop label: string = ''
  @Prop accessibleLabel: string = ''
  @Prop controlId: string = ''
  @Prop icon: string = ''
  @Prop trailing: string = ''
  @Prop tone: string = 'neutral'
  @Prop isEnabled: boolean = true
  @Prop grouped: boolean = false
  @Prop stretch: boolean = false
  @Prop maxWidth: number = 192
  @Prop items: SettingsChoice[] = []
  @Prop selected: string = ''
  @Prop menuMaxHeight: number = 276
  onAction: () => void = () => {}
  onSelect: (key: string) => void = (_key: string) => {}
  @State private expanded: boolean = false
  @State private pressed: boolean = false
  @State private hovered: boolean = false
  @State private anchorWidth: number = 0

  private itemLabel(item: SettingsChoice): string {
    return item.literal === true ? item.label : translate(item.label, this.uiLanguage)
  }

  private popupWidth(): number {
    let width: number = Math.max(this.anchorWidth, 112)
    for (const item of this.items) {
      let textWidth: number = 0
      const label = this.itemLabel(item)
      for (let i = 0; i < label.length; i++) textWidth += label.charCodeAt(i) > 255 ? 13 : 7.5
      width = Math.max(width, textWidth * this.uiFontScale + 48)
    }
    return Math.ceil(Math.min(246, width))
  }

  private ink(): string {
    const palette = settingsPalette(this.dark)
    if (this.tone === 'primary') return palette.blue
    if (this.tone === 'danger' || this.tone === 'warn') return palette.red
    if (this.tone === 'quiet') return palette.subtle
    return palette.ink
  }

  private fill(): ResourceColor {
    const palette = settingsPalette(this.dark)
    if (this.tone === 'primary') return this.hovered ? palette.blueHover : palette.blueSoft
    if (this.tone === 'danger') return this.hovered ? palette.redHover : palette.redSoft
    if (this.hovered) return this.tone === 'warn' ? palette.redSoft : palette.pillHover
    if (this.tone === 'quiet' || this.tone === 'warn' || this.grouped) return Color.Transparent
    return palette.pill
  }

  private edge(): ResourceColor {
    const palette = settingsPalette(this.dark)
    if (this.grouped || this.tone === 'quiet' || this.tone === 'warn') return Color.Transparent
    if (this.tone === 'primary') return palette.blueLine
    if (this.tone === 'danger') return palette.redEdge
    return palette.pillEdge
  }

  private actionGradient(): Array<[ResourceColor, number]> {
    const fill = this.fill()
    const highlight = this.tone === 'neutral' && !this.grouped && this.icon !== 'back' && !this.hovered ?
      settingsPalette(this.dark).pillHighlight : fill
    // Preblend the reference's white overlay against the pill. Interpolating
    // to transparent black in the native gradient otherwise darkens the middle.
    return [[highlight, 0], [fill, 0.67], [fill, 1]]
  }

  private radius(): number {
    if (this.label.length === 0) return 22
    return this.roundedRectButtons ? (this.grouped ? 11 : 12) : (this.grouped ? 23 : 999)
  }

  private labelWidth(): number {
    return Math.max(26, this.maxWidth - 24 - (this.icon ? 21 : 0) -
      (this.items.length > 0 || this.trailing ? 19 : 0))
  }

  private activate(): void {
    if (!this.isEnabled) return
    if (this.items.length > 0) {
      this.expanded = !this.expanded
    } else {
      this.onAction()
    }
  }

  private popupTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.scale({ x: 0.96, y: 0.96, centerX: '92%', centerY: '0%' })
        .combine(TransitionEffect.opacity(0)).animation({ duration: 207, curve: SETTINGS_SETTLE }),
      TransitionEffect.scale({ x: 0.98, y: 0.98, centerX: '92%', centerY: '0%' })
        .combine(TransitionEffect.opacity(0)).animation({ duration: 112, curve: Curve.EaseIn }))
  }

  @Builder
  private buildPopup() {
    Scroll() {
      Column({ space: 2 }) {
        ForEach(this.items, (item: SettingsChoice) => {
          SettingsPopupItem({
            label: this.itemLabel(item),
            icon: item.icon ?? '',
            tone: item.tone ?? '',
            isChoice: this.selected.length > 0,
            selected: this.selected === item.key,
            onSelect: () => {
              this.expanded = false
              this.onSelect(item.key)
            }
          })
        }, (item: SettingsChoice) => item.key)
      }
      .width('100%').padding(4)
    }
    .width(this.popupWidth()).constraintSize({ maxHeight: this.menuMaxHeight })
    .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
    .backgroundColor(settingsPalette(this.dark).surface)
    .border({ width: 1, color: settingsPalette(this.dark).pillEdge }).borderRadius(14)
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row({ space: 6 }) {
        if (this.icon.length > 0) {
          SettingsIcon({ icon: this.icon, ink: this.icon === 'back' ? settingsPalette(this.dark).blue : this.ink(),
            iconSize: this.label ? 16 : 20 })
        }
        if (this.label.length > 0) {
          Text(this.label).fontSize(13).lineHeight('17.5fp').fontWeight(600).fontColor(this.ink())
            .wordBreak(WordBreak.BREAK_WORD)
            .constraintSize({ maxWidth: this.labelWidth() }).textAlign(TextAlign.Center)
        }
        if ((this.items.length > 0 && this.label.length > 0) || this.trailing.length > 0) {
          SettingsIcon({
            icon: this.items.length > 0 ? 'down' : this.trailing,
            ink: settingsPalette(this.dark).muted,
            iconSize: 13,
            angle: this.expanded ? 180 : 0
          })
        }
      }
      .justifyContent(FlexAlign.Center)
    }
    .id(this.controlId)
    .width(this.stretch ? '100%' : undefined)
    .constraintSize({ minWidth: 44, minHeight: 44, maxWidth: this.stretch ? '100%' : this.maxWidth })
    .padding({ left: this.label ? 10 : 0, right: this.label ? 10 : 0, top: 7, bottom: 7 })
    .border({ width: 1, color: this.edge(), radius: this.radius() })
    .backgroundColor(this.fill())
    .linearGradient({ angle: 165, colors: this.actionGradient() })
    .enabled(this.isEnabled).opacity(this.isEnabled ? 1 : 0.51)
    .scale({ x: this.pressed && this.isEnabled ? 0.955 : 1, y: this.pressed && this.isEnabled ? 0.955 : 1 })
    .animation({ duration: this.pressed ? 66 : 235, curve: this.pressed ? Curve.Linear : SETTINGS_RELEASE })
    .accessibilityText(this.accessibleLabel || this.label)
    .onAreaChange((_old: Area, area: Area) => {
      if (this.items.length > 0) this.anchorWidth = area.width as number
    })
    .onHover((hovered: boolean) => { this.hovered = hovered && this.isEnabled })
    .onTouch((event: TouchEvent) => {
      if (this.isEnabled && event.type === TouchType.Down) this.pressed = true
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = false
    })
    .onClick(() => { this.activate() })
    .bindPopup(this.expanded && this.items.length > 0, {
      builder: this.buildPopup,
      placement: Placement.BottomRight, enableArrow: false, targetSpace: 5,
      mask: true, autoCancel: true, focusable: true,
      popupColor: settingsPalette(this.dark).surface, backgroundBlurStyle: BlurStyle.NONE, radius: 14,
      shadow: { radius: 18, color: this.dark ? '#66000000' : '#2F16243A', offsetX: 0, offsetY: 7 },
      transition: this.popupTransition(),
      onStateChange: (event) => { if (!event.isVisible) this.expanded = false }
    })
  }
}
