import { RustDeskTheme } from '../theme/RustDeskTheme'

export const RELEASE_NOTES_VERSION: string = '1.0.9'
export const RELEASE_NOTES_BUILD: string = '1000901'
export const RELEASE_NOTES_SHOWN_ID: string = `${RELEASE_NOTES_VERSION}-${RELEASE_NOTES_BUILD}`
export const RELEASE_NOTES_SHOWN_OPTION: string = 'release-notes-shown-version'

@CustomDialog
export struct ReleaseNotesDialog {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  controller?: CustomDialogController
  onClose: () => void = () => {}

  build() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('本次更新内容')
            .fontSize(22)
            .fontWeight(RustDeskTheme.FONT_WEIGHT_BOLD)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
            .width('100%')
          Text('StarRustDesk 已更新')
            .fontSize(13)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(`v${RELEASE_NOTES_VERSION}`)
          .fontSize(13)
          .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
          .fontColor(this.isDarkMode ? '#AFCBFF' : RustDeskTheme.ACCENT)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.isDarkMode ? RustDeskTheme.ACCENT_SOFT_DARK : RustDeskTheme.ACCENT_SOFT)
          .borderRadius(12)
      }
      .width('100%')

      Divider()
        .height(1)
        .color(this.isDarkMode ? RustDeskTheme.DIVIDER_DARK : RustDeskTheme.DIVIDER)

      Scroll() {
        Column({ space: 16 }) {
          this.buildSection('1.0.9（1000901）· 诊断、画面与后台连接', [
            '新增远控会话后台保持：锁屏或切换到其他应用后继续维持连接，解锁返回时自动恢复视频画面。',
            '设置中新增诊断日志开关，默认关闭；仅在用户主动开启后记录连接和解码信息。',
            '修复边缘跟随开启后按钮选中状态不刷新的问题，并统一所有选中按钮为主蓝色。',
            '移动画面模式的单指平移速度提高 50%，改善手机和平板上的画面拖动效率。',
          ])
          this.buildSection('1.0.9（1000900）· PC 鼠标体验', [
            '修复 HarmonyOS PC 使用物理鼠标或触控板时，远端左键偶发无响应的问题。',
            '修复关闭本地鼠标后，指针进入状态栏、工具栏、按钮或弹窗仍保持隐藏的问题。',
            '隐藏本地指针时继续显示并同步远端真实鼠标，改善缩放和平移后的操作一致性。',
          ])
          this.buildSection('1000816 · 边缘跟随与输入', [
            '新增放大画面后的边缘自动平移，鼠标在边缘短暂停留后视野会平滑跟随。',
            '加入触发延迟、渐进速度和自动停止保护，降低画面意外移动。',
            '调整远控工具栏，将“键盘”和“移动画面”按钮位置对调。',
            '修复 PC 端物理鼠标或触控板偶发丢失左键抬起，导致后续点击失效的问题。',
          ])
          this.buildSection('1000815 · 远端鼠标同步', [
            '显示远端真实鼠标样式，并修复缩放、平移和多显示器场景下的坐标漂移。',
            '分离本机鼠标指针开关与远端鼠标显示，关闭本机指针后远端鼠标仍然可见。',
            '修复手机触控移动远端鼠标时，电脑端已经移动但手机端光标停在原位的问题。',
          ])
          this.buildSection('1000814 · 画面移动', [
            '新增放大画面后的“移动画面”模式，单指可平移视野且不会误操作远端鼠标。',
            '移动模式选中后按钮显示绿色，并在平移视野时继续显示远端鼠标位置。',
            '移动画面模式保留双指滚动和捏合缩放，并在全屏提供悬浮入口。',
          ])
          this.buildSection('1000813 · 连接稳定性与诊断', [
            '优化网络延迟探测响应兼容性，降低部分远端主动断开连接的风险。',
            '增强完整诊断日志，记录协议消息、视频接收、远端关闭原因和连接结束统计。',
            '完善异常连接的日志导出信息，便于继续定位已连接黑屏和断线问题。',
          ])
          this.buildSection('1000812 · 视频解码兼容', [
            '新增 VP8、AV1 和 H.265 视频解码支持，扩大对不同远端编码配置的兼容范围。',
            '状态信息新增当前视频编码格式，并标明硬件解码或软件解码。',
            '完善 VP9 软件解码回退，提升部分旧系统、虚拟机和特殊显卡环境的出画成功率。',
          ])
          this.buildSection('1000811 · 黑屏与横屏修复', [
            '修复断开后快速重新连接时偶发无响应的问题。',
            '修复部分无显卡直通虚拟机已收到视频流但持续黑屏的问题。',
            '完整处理批量视频帧并保留关键帧和时间戳，提升首屏成功率。',
            'H264 解码无画面时自动请求关键帧，并支持切换 VP9 恢复画面。',
            '修复切换横屏时偶发闪退和部分页面未适配的问题。',
          ])
          this.buildSection('1.0.8 · 界面与输入', [
            '移除远控时遮挡画面的本地输入框，只保留系统键盘。',
            '修复物理键盘 Ctrl、Shift、Alt、Meta 和组合键传递。',
            '修复横屏页面内容被底部导航遮挡的问题。',
            '优化横屏双栏页面，连接列表和编辑区域可以独立上下滚动。',
            '调整分组箭头、输入框清除按钮和首页蓝色扇形背景。',
            '优化深色模式可读性以及手机、平板的页面布局。',
          ])
          this.buildSection('1.0.8 · 连接与管理', [
            '已保存连接支持新建分组、重命名、展开折叠和移动连接。',
            '新增 IPv6 地址连接支持，指定端口时可使用 [IPv6]:端口。',
            '完善中继安全握手与二次验证流程。',
            '尝试修复同一 Wi-Fi 下无法控制安卓被控端的问题。',
          ])
          this.buildSection('1.0.8 · 远控体验', [
            '新增手机、平板和 2in1 横屏及全屏远控，支持自动旋转。',
            '全屏三指上滑可调出系统键盘，输入直接传递到远端。',
            '完善鼠标和触摸模式，支持拖动、右键、滚动与双指缩放。',
            '同步远端真实鼠标位置，并在远端已显示光标时自动隐藏本地指针。',
          ])
        }
        .width('100%')
        .padding({ right: 4, bottom: 4 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)

      Button('知道了')
        .height(44)
        .width('100%')
        .fontSize(15)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(Color.White)
        .backgroundColor(RustDeskTheme.ACCENT)
        .borderRadius(7)
        .onClick(() => {
          this.onClose()
          if (this.controller !== undefined) {
            this.controller.close()
          }
        })
    }
    .width('90%')
    .height('78%')
    .constraintSize({ maxWidth: 620 })
    .padding({ left: 22, right: 22, top: 22, bottom: 18 })
    .backgroundColor(this.isDarkMode ? RustDeskTheme.CARD_DARK : Color.White)
    .border({ width: 1, color: this.isDarkMode ? RustDeskTheme.BORDER_DARK : '#E4EAF3' })
    .borderRadius(10)
    .shadow({ radius: 24, color: '#26345A84', offsetX: 0, offsetY: 8 })
  }

  @Builder
  buildSection(title: string, items: string[]) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(RustDeskTheme.FONT_WEIGHT_SEMI_BOLD)
        .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_PRIMARY_DARK : RustDeskTheme.TEXT_PRIMARY)
        .width('100%')

      ForEach(items, (item: string) => {
        Row({ space: 8 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(RustDeskTheme.ACCENT)
            .margin({ top: 7 })
          Text(item)
            .layoutWeight(1)
            .fontSize(13)
            .lineHeight(21)
            .fontColor(this.isDarkMode ? RustDeskTheme.TEXT_SECONDARY_DARK : RustDeskTheme.TEXT_SECONDARY)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (item: string) => item)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.isDarkMode ? RustDeskTheme.SURFACE_MUTED_DARK : RustDeskTheme.SURFACE_MUTED)
    .borderRadius(8)
  }
}
