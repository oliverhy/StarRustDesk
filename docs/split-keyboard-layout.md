# 远控“上画面下键盘”

## 开关位置

手机、平板远控页的“控 → 画面”菜单中新增开关 **上画面下键盘**（英文 “Picture above keyboard”），与“移动画面”“边缘跟随”同组。PC/2in1 和单独投屏到外接显示的页面不显示该项。工具栏排序编辑器中同名显示；已保存过工具栏顺序的用户，新项补到已保存顺序末尾。

开关保存在本机全局选项 `remote-split-keyboard`（`'1'` 开 / 其他为关），不按远端设备区分，重启 App 后仍有效。

## 行为

- 打开开关：立即弹出系统输入法（沿用“键盘”按钮的门控：未连接不打开、待确认多行文本先确认、Wayland 远端先授权），进入上下分屏。键盘已打开时直接切换为分屏布局。
- 分屏：分界线以上完整显示远端画面，按远端比例等比适配（contain）并贴着上沿、水平居中，不再保持键盘弹出前的画布并整体上移；分界线以下由系统输入法占据。用户缩放、平移参数不重置。
- 画面与输入法之间的空白：远控视口一直延伸到输入法顶边，空白属于视口本身，与原有画面黑边一致——黑色（`#090D14`），鼠标（触控板）模式下在空白处滑动会移动远端鼠标、轻点为点击；触摸模式下与原有黑边一样不响应（触摸输入层只覆盖画面）。不额外添加触摸组件。
- 关闭开关：收起键盘，画面恢复全屏。
- 开关打开期间通过键盘按钮、系统返回或输入法自身收起键盘：画面仍保持在分界线以上，下方黑色区域延伸到屏幕底部，鼠标模式下可继续当触控板；开关保持打开，再次打开键盘时键盘回到下半屏。只有关闭开关才恢复全屏。
- 新连接或重新进入远控页不会自动弹出键盘，用户打开键盘时才进入分屏。
- 开关关闭时，现有软键盘避让（保持原画布、按输入位置上移）、连续输入和 PC 行为不变。
- 不监听折叠角度，不自动切换。折叠/展开/旋转导致窗口尺寸变化时，沿用现有逻辑收起键盘，开关保持打开；键盘收起状态下页面尺寸变化会重新计算一次分界线（不在输入法动画的每一帧查询折痕）。
- 开关为开时进入远控页即为上画面布局，但不会自动弹出键盘。

## 分界规则

1. 打开键盘或切换开关时查询一次 `display.getCurrentFoldCreaseRegion().creaseRects`，不在每帧查询；查询失败或非折叠屏视为无折痕。
2. 第一条“宽 > 高、宽度 ≥ 窗口宽 80%、顶边位于当前窗口上下边之间”的折痕视为横向折痕，分界线对齐其顶边：`(creaseTop - windowTop) / density - pageOriginY`（vp）。该值不在 (0, 页面高度) 范围内时按第 3 条取一半。
3. 无横向折痕时，分界线取打开键盘前页面高度的一半。
4. 上半区高度 = `max(1, min(分界线, 页面高度 - 输入法高度))`，即输入法顶边高于分界线时以输入法顶边为准。页面高度使用打开键盘前的快照，避免 RESIZE 模式下页面随输入法缩小造成重复扣减。

5. 远控视口高度上限（`getKeyboardViewportMaxHeight`）在分屏时为 `max(1, 页面高度 - 输入法高度)`，即一直到输入法顶边；只有画面的适配高度（`getDisplayFitHeight`）= `min(视口高度, 上半区高度)`。`getDisplayTop()` 分屏时为 0，视口 Stack 与多屏切换过渡图片在分屏时都按 `Alignment.Top` 对齐（`getRemoteViewportAlignment`），与坐标映射一致。
6. 画面贴上沿后，缩放平移的竖向夹取范围随之平移（`getVerticalPanBias`）：放大后画面高于视口时，画面上沿和下沿都能平移到视口边缘，不会出现上沿够不到、下方多露黑边；未超出视口时上沿保持贴顶。非分屏时偏移为 0，夹取与原来相同。

纯几何逻辑在 `entry/src/main/ets/model/SplitKeyboardLayout.ets`，页面接入在 `RemotePage.ets` 的 `isSplitKeyboardActive`、`getEffectiveKeyboardViewportHeight`、`refreshSplitKeyboardLine`、`getSplitKeyboardViewportHeight`、`getDisplayFitHeight`、`getRemoteViewportAlignment`、`getVerticalPanBias` 等方法。

## 诊断字段

开启诊断时：

- `input-keyboard split-keyboard enabled=<0|1> keyboard_open=<0|1>`：用户切换开关。
- `input-keyboard split-keyboard line=<vp> crease=<0|1> page_h=<vp>`：计算分界线。
- `input-keyboard state ... split_keyboard=<0|1> split_line=<vp>`：键盘状态快照新增字段；分屏时 `avoid_reason=split_keyboard`、`ime_shift_y=0`。

不记录输入文字、候选词或远端文本。

## 验证边界

`tools/test-split-keyboard.cjs` 使用生产模型和从 `RemotePage.ets` 提取的方法覆盖菜单可见性、本机持久化、开关开/关、收起键盘后仍保持上画面、页面尺寸变化后重算分界线、折痕/居中/输入法高度分界、分屏点击坐标映射、画面贴上沿与放大后的平移夹取、画面下方黑色空白在鼠标模式下的触控板滑动；`tools/test-foldable-keyboard-avoidance.cjs` 确认开关关闭时原避让不变。脚本中的窗口、折痕尺寸是示意值，不是 Pura X Max 实测参数；`creaseRects` 与 `windowRect` 同为显示屏像素坐标的假设需要真机核对，判定失败时退回“取一半”。

真机应在 Pura X Max（或同类横向折痕折叠屏）竖屏半折与普通直板手机上检查：键盘位于折痕以下、画面完整在折痕以上；画面与键盘之间的空白为黑色，鼠标模式下在空白处滑动远端鼠标跟着移动；点击位置准确、中文输入法组字上屏正常；收起键盘后画面仍在上方、再打开键盘回到下半屏；关闭开关收起键盘；杀掉 App 重连后开关仍为开且不自动弹键盘。
