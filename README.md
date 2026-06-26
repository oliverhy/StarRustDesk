# StarRustDesk

StarRustDesk is a HarmonyOS remote desktop client inspired by RustDesk. It is built with ArkTS/ArkUI, C++ NAPI, and a Rust networking core, targeting HarmonyOS phones, tablets, and 2-in-1 devices.

## Features

- Connect to RustDesk-compatible remote IDs.
- Custom ID server, relay server, API server, and server key configuration.
- TCP rendezvous and relay connection support.
- Encrypted peer transport handshake.
- H264/VP9 video decode path through native rendering.
- Mouse, keyboard, text input, multi-display switching, and pinch zoom/pan.
- Optional clipboard text synchronization.
- Connection presets for stability, high FPS, smoothness, and lower latency.
- Phone and tablet UI adaptation.

## Project Layout

```text
AppScope/                  App-level HarmonyOS resources
entry/src/main/ets/        ArkTS UI, pages, services, models
entry/src/main/cpp/        Native NAPI bridge and video rendering
entry/src/main/rust/       Rust remote desktop transport core
entry/libs/                Prebuilt Rust static libraries linked by CMake
tools/deveco.ps1           Local DevEco CLI wrapper
```

## Requirements

- DevEco Studio installed locally.
- `@deveco/deveco-cli@1.0.0`.
- HarmonyOS device or emulator with developer mode enabled.
- PowerShell on Windows.

This repo includes `tools/deveco.ps1`, which points to the local DevEco Studio installation used during development. If your DevEco Studio path is different, update the `$devecoPath` value in that script.

## Build

```powershell
.\tools\deveco.ps1 build --build-mode debug
```

Release build:

```powershell
.\tools\deveco.ps1 build --build-mode release
```

## Run On Device

List connected devices:

```powershell
.\tools\deveco.ps1 device list
```

Install and launch:

```powershell
.\tools\deveco.ps1 run --module entry
```

Install to a specific device:

```powershell
.\tools\deveco.ps1 run --device <device-serial> --module entry
```

## Server Configuration

Open the app settings and configure:

- ID server: rendezvous server, default port `21116`.
- Relay server: relay server, default port `21117`.
- API server: optional.
- Key: custom server public key.

The app first asks the rendezvous server for a connection path. If direct punch-through is available it tries direct connection first. If direct connection fails, or the server returns a relay response immediately, the client connects through the relay server.

## Notes

- Relay currently uses TCP.
- The Rust core is linked into `libentry.so` through prebuilt static libraries in `entry/libs/`.
- Local files such as signing materials, build outputs, dependency folders, and local DevEco settings are ignored by Git.
- Clipboard synchronization should be enabled deliberately because clipboard contents may contain private data.

## License

No license has been selected yet. Add a license before publishing this project publicly.
