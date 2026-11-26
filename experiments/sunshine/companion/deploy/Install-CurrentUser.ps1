param([Parameter(Mandatory=$true)][string]$SunshineArchive,[switch]$NoShortcut)
$ErrorActionPreference='Stop'
function Get-ArchiveFileDigest([string]$Path){
    $stream=[IO.File]::OpenRead($Path)
    try {
        $sha=[Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
        finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
}
$files=@('SesameStreamCompanion.exe','sesame_wan_peer.exe','Test-LocalNetwork.ps1')
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SHA256.json') -Raw | ConvertFrom-Json
foreach($name in $files){
    $actual=Get-ArchiveFileDigest (Join-Path $PSScriptRoot $name)
    if($actual -ne $manifest.$name){throw "Test package integrity check failed: $name"}
}
$base=Join-Path $env:LOCALAPPDATA 'SesameStreamCompanion'
$version=$manifest.'SesameStreamCompanion.exe'.Substring(0,16)+'-'+$manifest.'sesame_wan_peer.exe'.Substring(0,8)
$dir=Join-Path (Join-Path $base 'versions') $version
[void][IO.Directory]::CreateDirectory($dir)
foreach($name in $files){
    $dest=Join-Path $dir $name
    if(!(Test-Path -LiteralPath $dest)){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $dest
    }
    if((Get-ArchiveFileDigest $dest) -ne $manifest.$name){throw "Existing version conflict: $name"}
}
$exe=Join-Path $dir $files[0]
& $exe --prepare-sunshine (Resolve-Path -LiteralPath $SunshineArchive).Path
if($LASTEXITCODE){throw 'Sunshine import failed; current launcher and pairing are unchanged.'}
& $exe --self-check
if($LASTEXITCODE){throw 'Cannot verify the installed companion.'}
if(!$NoShortcut){
    $programs=[Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut((Join-Path $programs 'Sesame Stream (test).lnk'))
    $link.TargetPath=$exe; $link.WorkingDirectory=$dir; $link.Save()
}
Write-Output "Installed for this user only: $exe"
