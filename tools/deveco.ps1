$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$devecoCli = "C:\Users\YIN\AppData\Roaming\npm\devecocli.cmd"
$devecoPath = "C:\Program Files\Huawei\DevEco Studio"
$devecoBin = Join-Path $devecoPath 'bin'
$jbrBin = Join-Path $devecoPath 'jbr\bin'
$nodeBin = "C:\Program Files\Huawei\DevEco Studio\tools\node"
$npmBin = Split-Path -Parent $devecoCli

if (-not (Test-Path -LiteralPath $devecoCli)) {
  throw "devecocli was not found at $devecoCli. Run: npm install -g --prefix `"$npmBin`" @deveco/deveco-cli@latest"
}

if (-not (Test-Path -LiteralPath $devecoPath)) {
  throw "DevEco Studio was not found at $devecoPath. Update `$devecoPath in this script."
}

if (-not (Test-Path -LiteralPath (Join-Path $nodeBin 'node.exe'))) {
  throw "DevEco Studio Node.js was not found at $nodeBin. Update `$nodeBin in this script."
}

$env:PATH = "$devecoBin;$jbrBin;$nodeBin;$npmBin;$env:PATH"
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
