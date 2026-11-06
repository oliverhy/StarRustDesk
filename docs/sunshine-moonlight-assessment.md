# Sunshine / Moonlight 接入评估

评估日期：2026-11-05。此文为方案评估，尚未接入或验证鸿蒙真机兼容性。

## 定位与边界

- 保留现有 RustDesk 连接和自建服务器；新增独立的 Sunshine 连接类型，不假设能用 RustDesk ID、中继或账号直接连接 Sunshine。
- 被控电脑需要用户自行部署并运行 Sunshine，客户端需要与 Sunshine 完成配对。优先测试局域网；跨网需要额外验证路由、NAT、防火墙或用户自有 VPN，不应默认暴露互联网端口。
- 两类连接在设置、认证凭据、断线、日志和安全提示上隔离；不修改现有服务器，不覆盖用户连接数据。

## 客户端工作

1. 基于 `moonlight-common-c` 固定版本的 C 核心和其指定 ENet 子模块验证鸿蒙 arm64/x86_64 编译，检查 TLS、socket、线程和依赖兼容性；编译通过不代表实机可用。
2. 单独实现设备发现或手动地址、HTTPS 服务发现、证书与 PIN 配对、应用列表、启动和断开。客户端密钥及配对凭据存系统安全存储，不写入诊断日志和普通备份。
3. 使用鸿蒙视频硬解接入 H.264/H.265，检查关键帧、队列、颜色空间和表面生命周期；复用现有音频输出时验证格式、同步和断连资源释放。
4. 独立接入键盘、鼠标、触摸和手柄；Moonlight 原生手柄事件与现有 RustDesk 键鼠映射是两套语义，不可混称，也不可互相覆盖设置。
5. 默认要求安全配对；明确协商音频、视频和控制加密状态。对端无法满足安全策略时拒绝或经明确的风险提示决定，不能静默降级。
6. 仅记录阶段、连接类型、错误类别及非敏感统计；不得记录地址、PIN、密钥、令牌或原始配对消息。

## 许可证与发布

`moonlight-common-c` 为 GPL-3.0，依赖及现有应用的完整许可证与分发方式需要逐项核对；是否组合分发、源码和书面授权义务需在引入前确认，不能仅凭进程隔离或开源名称推断。核查 Sunshine 与各子模块及商标要求。

## 分阶段验证

- P0：隔离工程验证固定版本交叉编译，产出依赖及许可证清单，不接入正式应用。
- P1：用户提供的测试 Sunshine 主机上完成局域网发现、配对和只读连接，验证断线清理及异常处理。
- P2：完成音视频、输入、实体及虚拟手柄，测试手机、折叠屏、平板和 PC 的横竖屏/窗口；独立验证用户设置互不覆盖。
- P3：对丢包、抖动、弱网、后台、跨网及安全协商进行故障注入，比较端到端按键到画面延迟，报告输入、网络、解码和显示测试条件与样本分布；不根据网络 RTT 冒充端到端延迟。

## 官方参考

- Moonlight 核心库及专用 ENet 依赖：https://github.com/moonlight-stream/moonlight-common-c
- Android 客户端配对与 HTTP 层：https://github.com/moonlight-stream/moonlight-android/tree/master/app/src/main/java/com/limelight/nvstream/http
- Sunshine 加密配置：https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html
- Moonlight 控制、音视频协商与加密标记：https://github.com/moonlight-stream/moonlight-common-c/blob/master/src/Limelight.h
