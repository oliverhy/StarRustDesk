param([ValidateRange(1,18000)][int]$MaxSamples=7200,
      [ValidateRange(0,2147483647)][int]$SunshinePid=0,
      [switch]$Lan1080, [switch]$PrimaryOutput)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'capture_activity_windows.cs')
    [CaptureActivityWindows]::Run($MaxSamples, $SunshinePid, $Lan1080.IsPresent, $PrimaryOutput.IsPresent)
} catch {
    'capture_setup 0 0 0'
    exit 2
}
