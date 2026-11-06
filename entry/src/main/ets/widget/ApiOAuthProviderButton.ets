import { translate } from '../utils/I18n';

// Provider names come from the server. They are displayed as text only; server
// supplied SVG/HTML is never executed or loaded into the login interface.
@Component
export struct ApiOAuthProviderButton {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans';
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  @Prop providerName: string = '';
  @Prop isEnabled: boolean = true;
  onAction: () => void = () => {};

  private label(): string {
    switch (this.providerName.toLowerCase()) {
      case 'google': return 'Google';
      case 'github': return 'GitHub';
      case 'microsoft':
      case 'azure': return 'Microsoft';
      case 'apple': return 'Apple';
      case 'gitlab': return 'GitLab';
      default: return this.providerName;
    }
  }

  private badge(): string {
    const name = this.providerName.toLowerCase();
    if (name === 'google') return 'G';
    if (name === 'github') return 'GH';
    if (name === 'microsoft' || name === 'azure') return '▦';
    if (name === 'apple') return 'A';
    return this.providerName.slice(0, 2).toUpperCase();
  }

  private badgeColor(): ResourceColor {
    const name = this.providerName.toLowerCase();
    if (name === 'google' || name === 'microsoft' || name === 'azure') return '#2868C7';
    if (name === 'github' || name === 'apple') return '#243249';
    return '#3968AA';
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Stack() {
          if (this.providerName.toLowerCase() === 'google') {
            Image($r('app.media.auth_google')).width(23).height(23).objectFit(ImageFit.Contain);
          } else if (this.providerName.toLowerCase() === 'github') {
            Image($r('app.media.auth_github')).width(23).height(23).objectFit(ImageFit.Contain);
          } else if (this.providerName.toLowerCase() === 'microsoft' || this.providerName.toLowerCase() === 'azure') {
            Image($r('app.media.auth_microsoft')).width(23).height(23).objectFit(ImageFit.Contain);
          } else if (this.providerName.toLowerCase() === 'gitlab') {
            Image($r('app.media.auth_gitlab')).width(23).height(23).objectFit(ImageFit.Contain);
          } else {
            Text(this.badge()).fontSize(this.badge().length > 1 ? 12 : 20).fontWeight(FontWeight.Bold)
              .fontColor(this.badgeColor());
          }
        }.width(34).height(34).backgroundColor('#FFFFFF').borderRadius(10);
        Text(`${translate('继续使用', this.uiLanguage)} ${this.label()}`)
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#EDF3FB' : '#19283E').layoutWeight(1);
        Text('›').fontSize(22).fontColor(this.isDarkMode ? '#A8BAD2' : '#71839A');
      }.width('100%');
    }
    .width('100%').constraintSize({ minHeight: 50 }).padding({ left: 12, right: 14, top: 8, bottom: 8 })
    .backgroundColor(this.isDarkMode ? '#26384D' : '#FFFFFF')
    .border({ width: 1, color: this.isDarkMode ? '#455B73' : '#DFE8F3' })
    .borderRadius(this.roundedRectButtons ? 12 : 25)
    .accessibilityText(`${translate('继续使用', this.uiLanguage)} ${this.label()}`)
    .opacity(this.isEnabled ? 1 : 0.55).enabled(this.isEnabled)
    .onClick(() => { if (this.isEnabled) this.onAction(); });
  }
}
