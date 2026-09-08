param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [string]$DevEcoPath = 'C:\Program Files\Huawei\DevEco Studio'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$java = Join-Path $DevEcoPath 'jbr\bin\java.exe'
$signer = Join-Path $DevEcoPath 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
if (-not $env:STARRUSTDESK_SIGN_PASSWORD) { throw 'Set STARRUSTDESK_SIGN_PASSWORD for this process before signing.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$metadata = Get-Content (Join-Path $root 'AppScope\app.json5') -Raw | ConvertFrom-Json
$prefix = "StarRustDesk-v$($metadata.app.versionName)-$($metadata.app.versionCode)"
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $output | Out-Null
$unsignedHap = Join-Path $output "$prefix-unsigned.hap"
$signedHap = Join-Path $output 'entry-default.hap'
$presigned = Join-Path $output "$prefix-presigned.app"
$final = Join-Path $output "$prefix-AppGallery-final.app"
Copy-Item -LiteralPath (Join-Path $root 'entry\build\default\outputs\default\entry-default-unsigned.hap') -Destination $unsignedHap
function Sign-Package([string]$InputPath, [string]$OutputPath) {
  & $java -jar $signer sign-app -mode localSign -keyAlias StarRustDesk2026 `
    -keyPwd $env:STARRUSTDESK_SIGN_PASSWORD -keystorePwd $env:STARRUSTDESK_SIGN_PASSWORD `
    -appCertFile (Join-Path $root 'signing\StarRustDesk.cer') `
    -profileFile (Join-Path $root 'signing\StarRustDeskRelease.p7b') `
    -keystoreFile (Join-Path $root 'signing\StarRustDesk.p12') `
    -inFile $InputPath -outFile $OutputPath -signAlg SHA256withECDSA -compatibleVersion 12 -inForm zip
  if ($LASTEXITCODE -ne 0) { throw "Signing failed: $OutputPath" }
}
function Verify-Package([string]$InputPath, [string]$Name) {
  & $java -jar $signer verify-app -inFile $InputPath `
    -outCertChain (Join-Path $output "$Name-cert.cer") -outProfile (Join-Path $output "$Name-profile.p7b") -inForm zip
  if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $InputPath" }
}
Sign-Package $unsignedHap $signedHap
Copy-Item -LiteralPath (Join-Path $root 'build\outputs\default\StarRustDesk-default-unsigned.app') -Destination $presigned
# Preserve the verified HAP bytes: the generic app packer may remove HAP signatures.
$archive = [IO.Compression.ZipFile]::Open($presigned, [IO.Compression.ZipArchiveMode]::Update)
try {
  $haps = @($archive.Entries | Where-Object { $_.FullName.EndsWith('.hap') })
  if ($haps.Count -ne 1 -or $haps[0].FullName -ne 'entry-default.hap') { throw 'Unexpected APP module layout.' }
  $haps[0].Delete()
  [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $signedHap, 'entry-default.hap') | Out-Null
} finally { $archive.Dispose() }
Sign-Package $presigned $final
Verify-Package $final 'outer'
$archive = [IO.Compression.ZipFile]::OpenRead($final)
$inner = Join-Path $output 'verified-inner.hap'
try {
  [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry('entry-default.hap'), $inner, $true)
} finally { $archive.Dispose() }
if ((Get-FileHash $inner).Hash -ne (Get-FileHash $signedHap).Hash) { throw 'Inner HAP bytes changed while packaging.' }
Verify-Package $inner 'inner'
& $java -jar $signer verify-profile -inFile (Join-Path $output 'inner-profile.p7b') -outFile (Join-Path $output 'verified-profile.json')
if ($LASTEXITCODE -ne 0) { throw 'Profile verification failed.' }
$profile = Get-Content (Join-Path $output 'verified-profile.json') -Raw | ConvertFrom-Json
if (-not $profile.verifiedPassed -or $profile.content.type -ne 'release') {
  throw 'Expected verified release provisioning profile.'
}
Write-Output "FORMAL_APP=$final"
Write-Output "UNSIGNED_HAP=$unsignedHap"
Get-FileHash $final,$unsignedHap | Format-List Path,Hash
