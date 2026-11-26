import { translate } from '../utils/I18n'
import { SettingsAction } from './SettingsControls'

// Reactive props keep async request completion and selection changes reflected
// in the actual button, rather than retaining a builder's initial value args.
@Component
export struct ApiAccountAction {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop isEnabled: boolean = true;
  @Prop tone: string = 'neutral';
  onAction: () => void = () => {};

  build() {
    SettingsAction({ label: translate(this.label, this.uiLanguage),
      tone: this.selected ? 'primary' : this.tone, isEnabled: this.isEnabled,
      onAction: () => { if (this.isEnabled) this.onAction(); } })
  }
}
