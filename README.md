# StarRustDesk

Thanks to Codex and Huawei's DevEco CLI. They made it possible for a beginner like me to build the HarmonyOS app I wanted.

感谢 Codex 和华为研发的 DevEco CLI，让我这样的小白也能做一个自己想要的鸿蒙 APP。

StarRustDesk is a HarmonyOS remote desktop client inspired by RustDesk. It is built with ArkTS/ArkUI, C++ NAPI, and a Rust networking core, targeting HarmonyOS phones, tablets, and 2-in-1 devices.

StarRustDesk 是一个受 RustDesk 启发的鸿蒙远程桌面客户端，基于 ArkTS/ArkUI、C++ NAPI 和 Rust 网络核心实现，适配 HarmonyOS 手机、平板和二合一设备。

## Features / 功能特性

- Connect to RustDesk-compatible remote IDs.  
  连接兼容 RustDesk 协议的远程 ID。
- Custom ID server, relay server, API server, and server key configuration.  
  支持自定义 ID 服务器、中继服务器、API 服务器和服务器 Key。
- TCP rendezvous and relay connection support.  
  支持 TCP rendezvous 和 TCP relay 中继连接。
- Encrypted peer transport handshake.  
  支持远端传输加密握手。
- H264/VP9 video decode path through native rendering.  
  基于 Native 渲染链路支持 H264/VP9 视频解码。
- Mouse, keyboard, text input, multi-display switching, and pinch zoom/pan.  
  支持鼠标、键盘、文本输入、多屏切换、双指缩放和平移。
- Optional clipboard text synchronization.  
  支持可选的剪切板文本同步。
- Connection presets for stability, high FPS, smoothness, and lower latency.  
  提供稳定、高帧率、高流畅、低延迟等连接预设。
- Phone and tablet UI adaptation.  
  支持手机和平板界面适配。

## Project Layout / 项目结构

```text
AppScope/                  App-level HarmonyOS resources / 应用级鸿蒙资源
entry/src/main/ets/        ArkTS UI, pages, services, models / ArkTS 页面、服务和模型
entry/src/main/cpp/        Native NAPI bridge and video rendering / Native NAPI 桥接和视频渲染
entry/src/main/rust/       Rust remote desktop transport core / Rust 远程桌面传输核心
entry/libs/                Prebuilt Rust static libraries linked by CMake / CMake 链接的 Rust 静态库
tools/deveco.ps1           Local DevEco CLI wrapper / 本地 DevEco CLI 包装脚本
```

## Requirements / 环境要求

- DevEco Studio installed locally.  
  本机已安装 DevEco Studio。
- `@deveco/deveco-cli@1.0.0`.  
  已安装 `@deveco/deveco-cli@1.0.0`。
- HarmonyOS device or emulator with developer mode enabled.  
  已开启开发者模式的 HarmonyOS 真机或模拟器。
- PowerShell on Windows.  
  Windows PowerShell 环境。

This repo includes `tools/deveco.ps1`, which points to the local DevEco Studio installation used during development. If your DevEco Studio path is different, update the `$devecoPath` value in that script.

仓库内置 `tools/deveco.ps1`，用于固定本地 DevEco Studio 路径并调用 DevEco CLI。如果你的 DevEco Studio 安装路径不同，请修改脚本中的 `$devecoPath`。

## Build / 构建

Debug build / Debug 构建：

```powershell
.\tools\deveco.ps1 build --build-mode debug
```

Release build / Release 构建：

```powershell
.\tools\deveco.ps1 build --build-mode release
```

## Run On Device / 真机运行

List connected devices / 查看已连接设备：

```powershell
.\tools\deveco.ps1 device list
```

Install and launch / 安装并启动：

```powershell
.\tools\deveco.ps1 run --module entry
```

Install to a specific device / 安装到指定设备：

```powershell
.\tools\deveco.ps1 run --device <device-serial> --module entry
```

## Server Configuration / 服务器配置

Open the app settings and configure:

打开应用设置页，配置以下内容：

- ID server: rendezvous server, default port `21116`.  
  ID 服务器：rendezvous 服务器，默认端口 `21116`。
- Relay server: relay server, default port `21117`.  
  中继服务器：relay 服务器，默认端口 `21117`。
- API server: optional.  
  API 服务器：可选。
- Key: custom server public key.  
  Key：自定义服务器公钥。

The app first asks the rendezvous server for a connection path. If direct punch-through is available it tries direct connection first. If direct connection fails, or the server returns a relay response immediately, the client connects through the relay server.

连接时客户端会先向 rendezvous 服务器请求连接路径。如果可打洞，会优先尝试直连；如果直连失败，或者服务器直接返回 relay 响应，则会通过中继服务器连接。

## Connection Notes / 连接说明

- Rendezvous uses TCP port `21116`.  
  Rendezvous 使用 TCP `21116` 端口。
- Relay currently uses TCP port `21117`.  
  中继当前使用 TCP `21117` 端口。
- The current HarmonyOS client does not yet implement the full UDP/KCP relay path.  
  当前鸿蒙客户端尚未实现完整 UDP/KCP 中继链路。
- Relay smoothness depends on server bandwidth, latency, and remote encoding performance.  
  中继流畅度取决于服务器带宽、网络延迟和远端编码性能。

## Notes / 注意事项

- The Rust core is linked into `libentry.so` through prebuilt static libraries in `entry/libs/`.  
  Rust 核心通过 `entry/libs/` 中的预编译静态库链接进 `libentry.so`。
- Local files such as signing materials, build outputs, dependency folders, and local DevEco settings are ignored by Git.  
  签名文件、构建产物、依赖目录和本地 DevEco 配置已通过 Git 忽略。
- Clipboard synchronization should be enabled deliberately because clipboard contents may contain private data.  
  剪切板同步可能涉及隐私内容，建议按需开启。
- This project is still under active development. APIs and behavior may change.  
  本项目仍在开发中，接口和行为后续可能调整。

## License / 许可证

No license has been selected yet. Add a license before publishing this project publicly.

当前尚未选择许可证。如需公开发布，请先补充合适的开源许可证。
