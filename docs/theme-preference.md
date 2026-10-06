# 主题选择持久化修复

## 原因与范围

旧实现于 EntryAbility.onCreate 中注册 isDarkMode/isDarkModeManual 的 PersistentStorage，早于 UI loadContent 完成；设置页只修改对应 AppStorage 状态。[华为持久化 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1086)指出，UI 实例初始化前调用会导致持久化失败。简单后移注册还可能遇到默认 AppStorage 值覆盖已存值的问题。

仅修改主题相关链路：新增 ThemePreference 服务，调整 EntryAbility 的主题初始化/系统配置更新和 SettingsPage 的深色开关。没有修改网络、远控、云同步、按钮样式或其他设置的保存逻辑。

## 新行为

- 独立系统首选项文件 starrustdesk_theme，只有 mode 键，取值 system/dark/light；不依赖 UI 实例是否已加载。默认跟随系统，现有开关分别保存 dark/light。
- 在第一屏加载前同步读取用户选择，再填充 UI 的 isDarkMode/isDarkModeManual。系统颜色更新仅影响 system；缺失颜色字段或 COLOR_MODE_NOT_SET 不被误当浅色。
- 切换先 putSync 再 await flush，完成后才确认并应用状态。写入串行执行，避免请求乱序；开关保存期间暂时禁用，失败回退且提示已有“保存设置失败，请重试”。恢复/保存异常不会引起启动失败，也不会改写服务器配置。
- 日志分类 theme，包含 restored/source/mode/dark、save_started/save_complete/save_failed 和安全错误码。不记录原始首选项内容、令牌、密码或服务器信息。
- 已经在内存恢复的旧手动选择可迁移；不会注册或改写旧主题 PersistentStorage 磁盘数据。旧版本若从未成功保存，无法凭空恢复该选择，需在修正版重新选择一次。

## 验证

- 63 组 Node 回归全部通过；主题专项含 14 个保存/冷启动/系统切换/异常/迁移场景，并测试启动顺序、局部配置更新和受控开关。冷启动是新 VM 加持久化磁盘模拟，不代表真机已经验收。
- Debug 构建成功，包内版本 1.2.22（1002022），debug=true，支持 phone/tablet/2in1。
- 调试包：build-artifacts/StarRustDesk-v1.2.22-1002022-theme-persistence-debug.hap。
- SHA-256：2FE4F19EE6CBFCA8D41503F6052CB52E7A7ABF69D88950259AD4BD03A83CA116。
- 尚未安装；需要真机开启深色、等待开关保存完成、强制结束进程、重新启动，并验证手动浅色与系统深色不冲突。正式 APP、版本号和 GitHub Release 未变。
