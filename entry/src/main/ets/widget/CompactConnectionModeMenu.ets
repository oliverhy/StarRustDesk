import { RustDeskTheme } from '../theme/RustDeskTheme'

// Keep native Select selection/focus/dismiss behavior, replacing only each option's content.
export class CompactConnectionModeMenu implements ContentModifier<MenuItemConfiguration> {
  isDarkMode: boolean
  fontScale: number

  constructor(isDarkMode: boolean, fontScale: number) {
    this.isDarkMode = isDarkMode
    this.fontScale = fontScale
  }

  rowHeight(): number {
    return Math.ceil(36 + Math.max(0, this.fontScale - 1) * 18)
  }

  applyContent(): WrappedBuilder<[MenuItemConfiguration]> {
    return wrapBuilder(compactConnectionModeItem)
  }
}

@Builder
function compactConnectionModeItem(configuration: MenuItemConfiguration) {
  Row({ space: 8 }) {
    Text(configuration.value)
      .fontSize(14).fontWeight(FontWeight.Medium).maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      .fontColor(configuration.selected ?
        ((configuration.contentModifier as CompactConnectionModeMenu).isDarkMode ?
          RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT) :
        ((configuration.contentModifier as CompactConnectionModeMenu).isDarkMode ?
          RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY))
    if (configuration.selected) {
      Text('✓').fontSize(12)
        .fontColor((configuration.contentModifier as CompactConnectionModeMenu).isDarkMode ?
          RustDeskTheme.CONTROL_SELECTED_TEXT_DARK : RustDeskTheme.CONTROL_SELECTED_TEXT)
    }
  }.width('100%').height((configuration.contentModifier as CompactConnectionModeMenu).rowHeight())
    .padding({ left: 12, right: 12 }).borderRadius(8)
    .backgroundColor(configuration.selected ?
      ((configuration.contentModifier as CompactConnectionModeMenu).isDarkMode ?
        RustDeskTheme.CONTROL_SELECTED_BG_DARK : RustDeskTheme.CONTROL_SELECTED_BG) : Color.Transparent)
    .enabled(configuration.enabled)
    .onClick(() => { configuration.triggerSelect(configuration.index, configuration.value as string) })
}
