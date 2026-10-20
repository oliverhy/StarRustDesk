import { ReadableButtonModifier } from '../theme/ReadableButtonModifier'
import { translate } from '../utils/I18n'

// Reactive props keep async request completion and selection changes reflected
// in the actual button, rather than retaining a builder's initial value args.
@Component
export struct ApiAccountAction {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop isEnabled: boolean = true;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  onAction: () => void = () => {};

  build() {
    Button(translate(this.label, this.uiLanguage)).constraintSize({ minHeight: 38 }).fontSize(13)
      .fontColor(this.isDarkMode ? '#C5DFFF' : '#2763AC')
      .backgroundColor(this.isDarkMode ? (this.selected ? '#314E71' : '#27384D') :
        (this.selected ? '#CFE3FF' : '#EEF4FC'))
      .enabled(this.isEnabled)
      .onClick(() => { if (this.isEnabled) this.onAction(); })
      .attributeModifier(new ReadableButtonModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
  }
}
