import { GameScreenRenderKey } from '../model/GameScreenRenderKey'
import { GAMEPAD_TARGETS, GamepadTarget } from '../model/GamepadMapping'

@Component
struct ScreenControlButton {
  @ObjectLink item: GameScreenRenderKey
  @Prop editing: boolean = false
  @Prop selected: boolean = false
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 600
  @State pressed: boolean = false
  private finger: number = -1
  private startX: number = 0
  private startY: number = 0
  private initialX: number = 0
  private initialY: number = 0
  onButton: (id: number, target: string, down: boolean) => void = () => {}
  onSelect: (id: number) => void = () => {}
  onMove: (id: number, x: number, y: number) => void = () => {}

  aboutToDisappear(): void { this.release() }
  release(): void {
    if (this.pressed) this.onButton(this.item.id, this.item.target, false)
    this.pressed = false
    this.finger = -1
  }
  touch(event: TouchEvent): void {
    event.stopPropagation()
    if (event.type === TouchType.Down && this.finger < 0 && event.changedTouches.length > 0) {
      const point: TouchObject = event.changedTouches[0]
      this.finger = point.id
      if (this.editing) {
        this.startX = point.windowX; this.startY = point.windowY
        this.initialX = this.item.x; this.initialY = this.item.y
        this.onSelect(this.item.id)
      } else { this.pressed = true; this.onButton(this.item.id, this.item.target, true) }
    } else if (event.type === TouchType.Cancel || (event.type === TouchType.Up &&
      event.changedTouches.some((point: TouchObject) => point.id === this.finger))) {
      this.release(); return
    }
    if (this.editing && this.finger >= 0 && event.type === TouchType.Move) {
      const point: TouchObject | undefined = event.touches.find((touch: TouchObject) => touch.id === this.finger)
      if (point) this.onMove(this.item.id,
        Math.max(0, Math.min(1, this.initialX + (point.windowX - this.startX) / Math.max(1, this.viewportWidth - this.item.size))),
        Math.max(0, Math.min(1, this.initialY + (point.windowY - this.startY) / Math.max(1, this.viewportHeight - this.item.size))))
    }
  }
  label(): string { return GAMEPAD_TARGETS.find((target: GamepadTarget) => target.value === this.item.target)?.label ?? '?' }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.label()).fontSize(this.label().length > 2 ? 11 : 16).fontColor(Color.White)
        .maxLines(2).textAlign(TextAlign.Center).hitTestBehavior(HitTestMode.None)
    }.width(this.item.size).height(this.item.size).borderRadius(this.item.size / 2)
      .position({ x: this.item.x * Math.max(0, this.viewportWidth - this.item.size),
        y: this.item.y * Math.max(0, this.viewportHeight - this.item.size) })
      .backgroundColor(this.pressed ? '#CC397FE1' : '#AA253C5B')
      .opacity(this.editing ? 1 : this.item.opacity / 100)
      .border({ width: this.selected && this.editing ? 3 : 1, color: this.selected && this.editing ? '#FF64AEFF' : '#AAC6DAFF' })
      .hitTestBehavior(HitTestMode.Default).onTouch((event: TouchEvent) => { this.touch(event) })
      .accessibilityText(this.label())
  }
}

@Component
export struct GameScreenOverlay {
  @Link keys: GameScreenRenderKey[]
  @Prop editing: boolean = false
  @Prop selected: number = -1
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 600
  onButton: (id: number, target: string, down: boolean) => void = () => {}
  onSelect: (id: number) => void = () => {}
  onMove: (id: number, x: number, y: number) => void = () => {}
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.keys, (item: GameScreenRenderKey) => {
        ScreenControlButton({ item, editing: this.editing, selected: this.selected === item.id,
          viewportWidth: this.viewportWidth, viewportHeight: this.viewportHeight,
          onButton: this.onButton, onSelect: this.onSelect, onMove: this.onMove })
      }, (item: GameScreenRenderKey) => item.id.toString())
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
}
