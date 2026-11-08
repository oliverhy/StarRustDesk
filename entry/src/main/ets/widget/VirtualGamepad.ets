import { translate } from '../utils/I18n'
import { VirtualGamepadRect, virtualGamepadRect, virtualGamepadButtonSize, virtualGamepadStickSize,
  virtualGamepadPadTop, virtualGamepadFaceLeft } from '../model/VirtualGamepadGeometry'

// Transparent touch controls use the same logical codes as GameControllerKit.
// The empty parts of the overlay do not consume remote-screen touches.
@Component
struct VirtualGamepadButton {
  @Prop label: string = ''
  @Prop code: number = 0
  @Prop controlSize: number = 44
  @State down: boolean = false
  private finger: number = -1
  onButton: (code: number, down: boolean) => void = () => {}

  aboutToDisappear(): void { this.release() }
  release(): void {
    if (this.down) this.onButton(this.code, false)
    this.down = false
    this.finger = -1
  }
  touch(event: TouchEvent): void {
    event.stopPropagation()
    if (event.type === TouchType.Down && this.finger < 0 && event.changedTouches.length > 0) {
      this.finger = event.changedTouches[0].id
      this.down = true
      this.onButton(this.code, true)
    } else if (event.type === TouchType.Cancel || (event.type === TouchType.Up &&
      event.changedTouches.some((touch: TouchObject) => touch.id === this.finger))) this.release()
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.label).fontSize(Math.max(9, this.controlSize * (this.label.length > 3 ? 0.2 : 0.28))).fontWeight(FontWeight.Medium)
        .fontColor(Color.White).hitTestBehavior(HitTestMode.None)
    }.width(this.controlSize).height(this.controlSize).borderRadius(this.controlSize / 2)
      .backgroundColor(this.down ? '#A05F9DEE' : '#7042526D')
      .border({ width: 1, color: '#AABDD3F3' }).hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent) => { this.touch(event) })
      .accessibilityText(this.label)
  }
}

@Component
struct VirtualGamepadStick {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @Prop axis: number = 1
  @Prop controlSize: number = 96
  @State x: number = 0
  @State y: number = 0
  private finger: number = -1
  onAxis: (axis: number, x: number, y: number) => void = () => {}

  aboutToDisappear(): void { this.release() }
  release(): void {
    if (this.finger >= 0) this.onAxis(this.axis, 0, 0)
    this.finger = -1
    this.x = 0; this.y = 0
  }
  touch(event: TouchEvent): void {
    event.stopPropagation()
    if (event.type === TouchType.Down && this.finger < 0 && event.changedTouches.length > 0) {
      this.finger = event.changedTouches[0].id
    }
    if (event.type === TouchType.Cancel || (event.type === TouchType.Up &&
      event.changedTouches.some((touch: TouchObject) => touch.id === this.finger))) {
      this.release(); return
    }
    if (this.finger < 0) return
    const point: TouchObject | undefined = event.touches.find((touch: TouchObject) => touch.id === this.finger)
    if (!point) return
    let x: number = (point.x - this.controlSize / 2) / Math.max(1, this.controlSize * 0.34)
    let y: number = (point.y - this.controlSize / 2) / Math.max(1, this.controlSize * 0.34)
    const magnitude: number = Math.sqrt(x * x + y * y)
    if (magnitude > 1) { x /= magnitude; y /= magnitude }
    this.x = x; this.y = y
    this.onAxis(this.axis, x, y)
  }
  build() {
    Stack() {
      Circle().width(this.controlSize * 0.44).height(this.controlSize * 0.44).fill('#A08AAFD9')
        .position({ x: this.controlSize * 0.28 + this.x * this.controlSize * 0.28,
          y: this.controlSize * 0.28 + this.y * this.controlSize * 0.28 }).hitTestBehavior(HitTestMode.None)
    }.width(this.controlSize).height(this.controlSize).borderRadius(this.controlSize / 2)
      .backgroundColor('#6042526D').border({ width: 1, color: '#AABDD3F3' })
      .hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent) => { this.touch(event) })
      .accessibilityText(translate(this.axis === 1 ? '左摇杆' : '右摇杆', this.uiLanguage))
  }
}

@Component
export struct VirtualGamepad {
  @Prop viewportWidth: number = 360
  @Prop viewportHeight: number = 600
  onButton: (code: number, down: boolean) => void = () => {}
  onAxis: (axis: number, x: number, y: number) => void = () => {}

  // Keep the top buttons, face buttons and sticks in separate vertical bands,
  // including short landscape windows. Full usability still needs device QA.
  buttonSize(): number { return virtualGamepadButtonSize(this.viewportWidth, this.viewportHeight) }
  stickSize(): number { return virtualGamepadStickSize(this.viewportWidth, this.viewportHeight) }
  padTop(): number { return virtualGamepadPadTop(this.viewportWidth, this.viewportHeight) }
  faceLeft(): number { return virtualGamepadFaceLeft(this.viewportWidth, this.viewportHeight) }
  controlRect(id: string): VirtualGamepadRect { return virtualGamepadRect(id, this.viewportWidth, this.viewportHeight) }

  @Builder
  button(label: string, code: number, id: string) {
    VirtualGamepadButton({ label, code, controlSize: this.buttonSize(), onButton: (key: number, down: boolean) => { this.onButton(key, down) } })
      .position({ x: this.controlRect(id).x, y: this.controlRect(id).y })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.button('LT', 2309, 'LT')
      this.button('LB', 2307, 'LB')
      this.button('Select', 2311, 'Select')
      this.button('Home', 2313, 'Home')
      this.button('Start', 2312, 'Start')
      this.button('RB', 2308, 'RB')
      this.button('RT', 2310, 'RT')
      this.button('↑', 2012, 'up')
      this.button('←', 2014, 'left')
      this.button('→', 2015, 'right')
      this.button('↓', 2013, 'down')
      this.button('Y', 2305, 'Y')
      this.button('X', 2304, 'X')
      this.button('B', 2302, 'B')
      this.button('A', 2301, 'A')
      VirtualGamepadStick({ axis: 1, controlSize: this.stickSize(), onAxis: (axis: number, x: number, y: number) => { this.onAxis(axis, x, y) } })
        .position({ x: this.controlRect('leftStick').x, y: this.controlRect('leftStick').y })
      VirtualGamepadStick({ axis: 2, controlSize: this.stickSize(), onAxis: (axis: number, x: number, y: number) => { this.onAxis(axis, x, y) } })
        .position({ x: this.controlRect('rightStick').x, y: this.controlRect('rightStick').y })
      this.button('L3', 2314, 'L3')
      this.button('R3', 2315, 'R3')
      this.button('C', 2303, 'C')
    // Only the controls participate in hit testing. They block the underlying
    // remote viewport; empty areas still allow normal remote touch interaction.
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
}
