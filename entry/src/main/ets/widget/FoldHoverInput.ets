import { translate } from '../utils/I18n';

@Component
export struct FoldHoverInput {
  @Prop widthVp: number = 0;
  @Prop padOpen: boolean = false;
  @Prop manual: boolean = false;
  @Prop imeOpen: boolean = false;
  @Prop modifierMask: number = 0;
  @Prop language: string = 'zh-Hans';
  onKey: (key: string) => void = () => {};
  onIme: () => void = () => {};
  onPadOpen: (open: boolean) => void = () => {};
  onPadTouch: (event: TouchEvent) => void = () => {};
  onMouseButton: (button: number, event: TouchEvent) => void = () => {};
  @State functionKeys: boolean = false;
  @State symbols: boolean = false;

  @Builder
  caption(label: string, action: () => void, selected: boolean = false) {
    Button(translate(label, this.language))
      .type(ButtonType.Normal).padding({ left: 8, right: 8 })
      .height(42).borderRadius(10).fontSize(13).fontColor(Color.White)
      .backgroundColor(selected ? '#285DA2' : '#263347')
      .onClick(action)
  }

  isModifierSelected(key: string): boolean {
    const bit = key === 'Shift' ? 2 : key === 'Ctrl' ? 1 : key === 'Alt' ? 4 : key === 'Win/Cmd' ? 8 : 0;
    return (this.modifierMask & bit) !== 0;
  }

  @Builder
  keyRow(keys: string[]) {
    Row({ space: 3 }) {
      ForEach(keys, (key: string) => {
        Button(translate(key === ' ' ? '空格' : key, this.language))
          .type(ButtonType.Normal)
          .height(39).layoutWeight(key === ' ' ? 3 : 1)
          .padding(0).borderRadius(7).fontSize(key.length > 2 ? 11 : 15).fontColor(Color.White)
          .backgroundColor(this.isModifierSelected(key) ? '#285DA2' : '#263347')
          .onClick(() => { this.onKey(key); })
      }, (key: string) => key)
    }.width('100%')
  }

  @Builder
  keyboard() {
    Scroll() {
      Column({ space: 4 }) {
        if (this.functionKeys) {
          this.keyRow(['F1', 'F2', 'F3', 'F4', 'F5', 'F6'])
          this.keyRow(['F7', 'F8', 'F9', 'F10', 'F11', 'F12'])
          this.keyRow(['Esc', 'Tab', 'Home', 'End', 'Delete', '↵'])
        } else if (this.symbols) {
          this.keyRow(['!', '@', '#', '$', '%', '^', '&', '*', '(', ')'])
          this.keyRow(['-', '_', '+', '=', '[', ']', '{', '}', '/', '?'])
          this.keyRow([';', ':', '"', "'", ',', '.', '<', '>', '⌫'])
        } else {
          this.keyRow(['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'])
          this.keyRow(['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'])
          this.keyRow(['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', '⌫'])
          this.keyRow(['Shift', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '↵'])
        }
        this.keyRow(['Ctrl', 'Alt', 'Win/Cmd', ' ', '←', '↑', '↓', '→'])
      }.width('100%')
    }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto)
  }

  @Builder
  mouseButton(label: string, button: number) {
    Button(translate(label, this.language))
      .type(ButtonType.Normal).layoutWeight(1).height(38).borderRadius(8)
      .fontSize(13).fontColor(Color.White).backgroundColor('#263347')
      .onTouch((event: TouchEvent) => { this.onMouseButton(button, event); })
  }

  @Builder
  trackpad() {
    Column({ space: 5 }) {
      Column() {
        Text(translate('触控板', this.language)).fontSize(14).fontColor('#A9BED8')
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      .borderRadius(10).backgroundColor('#172234')
      .border({ color: '#54647D', width: 1 })
      .onTouch((event: TouchEvent) => { this.onPadTouch(event); })
      Row({ space: 4 }) {
        this.mouseButton('左键', 1)
        this.mouseButton('右键', 2)
      }.width('100%')
    }.layoutWeight(1).height('100%')
  }

  build() {
    Column({ space: 5 }) {
      if (!this.imeOpen && this.manual) {
        Row() {
          Blank()
          this.caption('系统输入法', this.onIme)
        }.width('100%')
        Row() { this.trackpad() }.width('100%').layoutWeight(1)
      } else if (!this.imeOpen) {
        Row({ space: 4 }) {
          this.caption('系统输入法', this.onIme)
          this.caption('符号', () => { this.symbols = !this.symbols; this.functionKeys = false; }, this.symbols)
          this.caption('功能键', () => { this.functionKeys = !this.functionKeys; this.symbols = false; }, this.functionKeys)
          Blank()
          Button(translate(this.padOpen ? '收起触控板' : '‹ 触控板', this.language))
            .type(ButtonType.Normal).height(42).padding({ left: 8, right: 8 })
            .fontSize(13).fontColor(Color.White).borderRadius(10).backgroundColor('#285DA2')
            .onClick(() => { this.onPadOpen(!this.padOpen); })
            .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 12 })
              .onActionEnd((event: GestureEvent) => {
                if (Math.abs(event.offsetX) >= 12) this.onPadOpen(event.offsetX < 0);
              }))
        }.width('100%')
        Row({ space: 6 }) {
          if (!this.padOpen || this.widthVp >= 680) this.keyboard()
          if (this.padOpen) this.trackpad()
        }.width('100%').layoutWeight(1)
      }
    }.padding(6).backgroundColor('#101927').width('100%').height('100%').clip(true)
  }
}
