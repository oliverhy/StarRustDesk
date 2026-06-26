$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$devecoCli = "C:\Users\YIN\AppData\Roaming\npm\devecocli.cmd"
$devecoPath = "D:\work\DevEco Studio"
$npmBin = Split-Path -Parent $devecoCli

if (-not (Test-Path -LiteralPath $devecoCli)) {
  throw "devecocli was not found at $devecoCli. Run: npm install -g @deveco/deveco-cli@1.0.0"
}

if (-not (Test-Path -LiteralPath $devecoPath)) {
  throw "DevEco Studio was not found at $devecoPath. Update `$devecoPath in this script."
}

$env:PATH = "$npmBin;$env:PATH"
$env:DEVECO_PATH = $devecoPath
$env:DEVECO_CLI_SKIP_VERSION_CHECK = "1"

Push-Location $projectRoot
try {
  & $devecoCli @Args
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
