# 远控功能栏图标

使用 RustDesk 官方移动端采用的 Material Icons 图形体系，保留 StarRustDesk 的按钮布局、文字标签及蓝灰/淡蓝配色。不更改任何输入、菜单动作或连接行为。

| 入口 | Material Icons 图形 | 本地资源 |
| --- | --- | --- |
| 屏幕 | `tv` | `remote_menu_screens.svg` |
| 输入 | `mouse` | `remote_menu_input.svg` |
| 输入菜单中的触摸模式 | `touch_app` | `remote_input_touch.svg` |
| 键盘与独立键盘按钮 | `keyboard` | `keyboard_launcher.svg` |
| 键盘旁的组合键展开入口 | `expand_more` | `remote_keyboard_expand.svg` |
| 画面 | `settings_overscan` | `remote_menu_view.svg` |
| 更多 | `more_vert` | `remote_menu_more.svg` |
| 断开 | `close` | `remote_menu_disconnect.svg` |

“画面”是我们自己的分类，使用同一图标体系的 `settings_overscan`，不是声称它是 RustDesk 官方同名入口。官方桌面版还有自己的 SVG 图标，本次没有混用两套视觉粗细。

普通图标为蓝灰，选中沿用现有淡蓝底与深蓝图标；深色模式使用浅蓝灰与浅蓝选中颜色。断开使用红色，深色模式适当提亮。功能栏图标显示为 20 vp，独立键盘按钮保持既有 26 vp；底部、侧边和全屏悬浮栏共用资源。

键盘旁的展开箭头使用同系列 14 vp 矢量图形，不使用字体字符。键盘按钮与箭头共用一个选中背景和外框，中间只保留 16 vp 高的细分隔线；箭头点击区域为 28 vp 宽，并在组合键栏展开/收起时以 200 ms 旋转 180°。点击键盘仍唤起本地输入，点击箭头仅切换组合键栏，不自动唤起输入法或释放修饰键。

## 来源与许可

- Material Icons 上游：[google/material-design-icons](https://github.com/google/material-design-icons/tree/737e3324305806514d7909874fa1818ae1808232/src)，固定提交 `737e3324305806514d7909874fa1818ae1808232`。
- 素材路径：`src/hardware/{tv,mouse,keyboard}/materialicons/24px.svg`、`src/action/{settings_overscan,touch_app}/materialicons/24px.svg`、`src/navigation/{more_vert,close,expand_more}/materialicons/24px.svg`。
- 官方移动端用法：[remote_page.dart](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/mobile/pages/remote_page.dart)。
- 模式双选参考：[gesture_help.dart](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/mobile/widgets/gesture_help.dart)。本项目按实际菜单宽度改为横排或纵排，不照搬官方的固定最小宽度；根据手机截图反馈，图标缩为 16 vp、标签缩为 13 fp，与其他菜单文字协调，点击区域不缩小。
- 许可：Apache-2.0，完整许可随包保存在 `entry/src/main/resources/rawfile/licenses/material-icons-Apache-2.0.txt`。
- 修改：加入本项目颜色与修改说明，移除不参与绘制的透明背景路径；保留实际图形路径。

自动测试覆盖资源、状态配色和原动作保留；视觉预览不等同于设备上的 ArkUI 绘制验收。
