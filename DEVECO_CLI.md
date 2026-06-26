# DevEco CLI

This project is configured for `@deveco/deveco-cli@1.0.0`.

Local paths:

- DevEco Studio: `D:\work\DevEco Studio`
- DevEco CLI: `C:\Users\YIN\AppData\Roaming\npm\devecocli.cmd`
- Project: `C:\Users\YIN\DevecostudioProjects\StarRustDesk`

Use the project wrapper from PowerShell:

```powershell
.\tools\deveco.ps1 --version
.\tools\deveco.ps1 build --build-mode debug
.\tools\deveco.ps1 build --build-mode release
.\tools\deveco.ps1 run --module entry
.\tools\deveco.ps1 device list
.\tools\deveco.ps1 log --level E --bundle-name com.example.starrustdesk
.\tools\deveco.ps1 emulator list
```

The wrapper pins the local DevEco Studio path, adds the npm global bin directory
to `PATH` for this command, and skips the CLI update check so normal builds do
not need network access.

Codex MCP is configured in `.codex/config.toml` with `deveco-mcp`, using the
same DevEco Studio and project paths.
