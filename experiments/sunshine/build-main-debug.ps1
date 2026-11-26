param(
    [Parameter(Mandatory=$true)][string]$Dependencies,
    [Parameter(Mandatory=$true)][string]$PreviousDebugHap,
    [string]$TestBroker='',
    [switch]$UseLocalTestBroker,
    [switch]$Request8ForCellularTest,
    [switch]$UsbLanCandidate,
    [switch]$PhoneRxTrial,
    [switch]$CoreRxWitness,
    [switch]$ReaderQosTrial,
    [switch]$KeyRecoveryTrial,
    [switch]$KeyDecoderSlotTrial,
    [switch]$BurstMarginTrial,
    [string]$PairedMarginBaseline='',
    [switch]$NormalFecForLanTrial,
    [string]$DevEco=(Join-Path $env:ProgramFiles 'Huawei/DevEco Studio'),
    [string]$NativeSdk='C:/PROGRA~1/Huawei/DEVECO~1/sdk/default/OPENHA~1/native'
)
$ErrorActionPreference='Stop'
if ($UsbLanCandidate -and ($UseLocalTestBroker -or $TestBroker -or $Request8ForCellularTest)) { throw 'Temporary endpoint is LAN-only' }
if ($PhoneRxTrial -and !$UsbLanCandidate) { throw 'Phone receive trial requires the isolated LAN debug build' }
if ($CoreRxWitness -and !$PhoneRxTrial) { throw 'Core receive witness requires the standard LAN phone trial' }
if ($KeyRecoveryTrial -and (!$CoreRxWitness -or $ReaderQosTrial -or $NormalFecForLanTrial -or $BurstMarginTrial)) { throw 'Recovery policy comparison requires unmodified LAN reader, FEC and socket' }
$env:SESAME_KEY_RECOVERY_TRIAL=if($KeyRecoveryTrial){'1'}else{'0'}
if($KeyDecoderSlotTrial -and !$KeyRecoveryTrial){throw 'Decoder slot trial requires the LAN key recovery trial'}
$env:SESAME_KEY_SLOT_TRIAL=if($KeyDecoderSlotTrial){'1'}else{'0'}
if ($NormalFecForLanTrial -and !$CoreRxWitness) { throw 'Runtime-equivalent FEC trial requires instrumented LAN debug package' }
if ($ReaderQosTrial -and (!$CoreRxWitness -or $NormalFecForLanTrial)) { throw 'Reader QoS comparison requires the original FEC mode and view-only LAN trial' }
if ($BurstMarginTrial -and (!$CoreRxWitness -or $ReaderQosTrial -or $NormalFecForLanTrial)) { throw 'Burst margin comparison requires stock reader, original FEC and isolated LAN debug' }
$env:SESAME_READER_QOS_TRIAL=if($ReaderQosTrial){'1'}else{'0'}
$env:SESAME_CORE_NORMAL_FEC=if($NormalFecForLanTrial){'1'}else{'0'}
$env:SESAME_CORE_RX_WITNESS=if($CoreRxWitness){'1'}else{'0'}
$peerFeatures=if($PhoneRxTrial){'phone-rx-trial'}else{'companion-soak'}
if($ReaderQosTrial){$peerFeatures='phone-reader-qos'}
if($BurstMarginTrial){$peerFeatures='phone-burst-margin'}
if($PairedMarginBaseline){
    if(!$BurstMarginTrial -or $PairedMarginBaseline -notmatch '^\d{8}-\d{6}-1080p60-20000k-encoder-stock-rxauto-ethernet-[0-9a-f]{4}$'){throw 'Named bounded LAN comparison and sealed stock run required'}
    $directory=Join-Path (Join-Path $PSScriptRoot '.generated/lan-compare') $PairedMarginBaseline
    $baseline=Get-Content -Raw -LiteralPath (Join-Path $directory 'result.json')|ConvertFrom-Json
    $proof=@((Get-Content -Raw -LiteralPath (Join-Path $directory 'phone-reader-dispatch.json')|ConvertFrom-Json)|Where-Object {$_.ph -ge 8 -and $_.bc -eq $_.ph -and $_.hb -eq $_.ph -and $_.ha -eq $_.ph})
    if($baseline.route -ne 'lan' -or !$baseline.encrypted_video_audio -or !$baseline.host_refuses_input -or $baseline.usb_forward -or $baseline.reader_trial_status -ne 'reader_phase_observed' -or $baseline.playback.secs -lt 550 -or !$proof.Count){throw 'Missing comparable sealed real-LAN pressure evidence'}
    $peerFeatures='phone-margin-comparison'
}
$env:SESAME_PHONE_RX_TRIAL=if($PhoneRxTrial){'1'}else{'0'}
$env:SESAME_SUNSHINE_USB_LAN_CANDIDATE=if($UsbLanCandidate){'1'}else{'0'}
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$old=(Resolve-Path -LiteralPath $PreviousDebugHap).Path
$hap=Join-Path $root 'entry/build/default/outputs/default/entry-default-signed.hap'
if ($old -eq $hap) { throw 'Keep the previously accepted debug HAP separate from the build output.' }
$env:STAR_SUNSHINE_DEPS=(Resolve-Path -LiteralPath $Dependencies).Path.Replace('\','/')
$pins=@{
    'moonlight-common-c'='8599b6042a4ba27749b0f94134dd614b4328a9bc'
    'moonlight-common-c/enet'='bbf71856bb144729af4ed08af6bc2f5826a96db5'
    'ohos-openssl'='c0935238f7e155f00391b95adcac63fa55856f1f'
}
foreach($dep in $pins.Keys) {
    $folder=Join-Path $Dependencies $dep
    if ((git -C $folder rev-parse HEAD) -ne $pins[$dep] -or $LASTEXITCODE -ne 0 -or
        @(git -C $folder status --porcelain --untracked-files=no).Count) { throw "Unverified dependency: $dep" }
}
$packOptions=@()
if ($UseLocalTestBroker) {
    if ($TestBroker) { throw 'Choose a single test broker source' }
    $TestBroker=(& python.exe -B (Join-Path $PSScriptRoot 'companion/public_target.py'))
    if ($LASTEXITCODE -ne 0 -or !$TestBroker) { throw 'Local test target is missing or invalid' }
    $budget=(& python.exe -B (Join-Path $PSScriptRoot 'companion/public_target.py') --max-relay)
    if ($LASTEXITCODE -ne 0 -or $budget -notin '1800','8000') { throw 'Unconfirmed relay policy' }
    if ($Request8ForCellularTest -and $budget -eq '8000') { $packOptions=@('--relay-8m') }
}
if ($Request8ForCellularTest -and !$packOptions.Count) { throw '8 Mbps test preference requires the authorized high-relay target' }
if ($TestBroker -and $TestBroker -notmatch '^\d{1,3}(?:\.\d{1,3}){3}:23388$') { throw 'Invalid test broker' }
$env:SESAME_STREAM_TEST_BUILD='1'
$env:SESAME_SUNSHINE_LAN_BENCH='1'
$env:SESAME_SUNSHINE_LONG_BENCH='1'
$env:SESAME_SUNSHINE_COMPANION='1'
$env:SESAME_SUNSHINE_COMPANION_BROKER=$TestBroker
$env:JAVA_HOME=Join-Path $DevEco 'jbr'
$env:DEVECO_SDK_HOME=Join-Path $DevEco 'sdk'
$env:PATH="$DevEco/tools/ohpm/bin;$DevEco/tools/node;$env:JAVA_HOME/bin;$env:PATH"
$cargo=Join-Path $HOME '.cargo/bin/cargo.exe'
$area=Join-Path $PSScriptRoot ('.generated/verify-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($area)
function VerifySigner([string]$path,[string]$label) {
    $cert=Join-Path $area "$label.cer"
    $p7=Join-Path $area "$label.p7b"
    & "$DevEco/jbr/bin/java.exe" -jar "$DevEco/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar" verify-app -inFile $path -outCertChain $cert -outProfile $p7 *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Unverified HAP signature' }
    $x=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert)
    try { return @($x.Thumbprint,(Get-FileHash -LiteralPath $p7).Hash) } finally { $x.Dispose() }
}
Push-Location -LiteralPath $root
try {
    $before=VerifySigner $old 'previous'
    $local = (Get-Content -LiteralPath 'build-profile.json5' -Raw | ConvertFrom-Json).app
    if (@($local.signingConfigs).Count -ne 1 -or @($local.products).Count -ne 1 -or
        $local.products[0].signingConfig -ne $local.signingConfigs[0].name) { throw 'Ambiguous project signer' }
    $material=$local.signingConfigs[0].material
    $x=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new($material.certpath)
    try { if ($x.Thumbprint -ne $before[0] -or (Get-FileHash -LiteralPath $material.profile).Hash -ne $before[1]) {
        throw 'Not the previously accepted debug signing identity'
    } } finally { $x.Dispose() }
    'accepted_debug_signer_verified=1'
    # CMake doesn't track environment variable changes by itself. Trigger
    # native reconfiguration on a real endpoint change, including a LAN build.
    $stamp=Join-Path $PSScriptRoot '.generated/native-route.tag'
    $routeTag=([string]$TestBroker)+$(if($UsbLanCandidate){'|usb-lan-only'}else{''})
    if($PhoneRxTrial){$routeTag+='|rx-ahead-1'}
    if($CoreRxWitness){$routeTag+='|core-rx-witness-1'}
    if($KeyRecoveryTrial){$routeTag+='|confirmed-key-recovery-1'}
    if($KeyDecoderSlotTrial){$routeTag+='|decoder-slot-2ms-1'}
    if($NormalFecForLanTrial){$routeTag+='|fec-runtime'}
    if($ReaderQosTrial){$routeTag+='|reader-qos-initiated'}
    if($BurstMarginTrial){$routeTag+='|reader-burst-margin'}
    if($PairedMarginBaseline){$routeTag+='|margin-controlled-comparison'}
    if (!(Test-Path -LiteralPath $stamp) -or [IO.File]::ReadAllText($stamp) -cne $routeTag) {
        [IO.File]::WriteAllText($stamp,$routeTag)
    }
    python.exe -B experiments/sunshine/pack_ui.py @packOptions
    if ($LASTEXITCODE) { throw 'Renderer packaging failed' }
    $assets=Join-Path $root 'entry/src/sunshineTest/resources/rawfile/sunshine'
    Copy-Item -LiteralPath "$Dependencies/moonlight-common-c/LICENSE.txt" -Destination "$assets/MOONLIGHT-LICENSE.txt"
    Copy-Item -LiteralPath "$Dependencies/moonlight-common-c/enet/LICENSE" -Destination "$assets/ENET-LICENSE.txt"
    $native=$NativeSdk.Replace('\','/').TrimEnd('/')
    foreach ($arch in 'aarch64','x86_64') {
        $triple="$arch-unknown-linux-ohos"
        $suffix=$triple.Replace('-','_')
        $upper=$suffix.ToUpperInvariant()
        [Environment]::SetEnvironmentVariable("CC_$suffix","$native/llvm/bin/clang.exe")
        [Environment]::SetEnvironmentVariable("AR_$suffix","$native/llvm/bin/llvm-ar.exe")
        [Environment]::SetEnvironmentVariable("CFLAGS_$suffix","--target=$arch-linux-ohos --sysroot=$native/sysroot")
        [Environment]::SetEnvironmentVariable("CARGO_TARGET_${upper}_LINKER","$native/llvm/bin/clang.exe")
        [Environment]::SetEnvironmentVariable("CARGO_TARGET_${upper}_RUSTFLAGS","-C link-arg=--target=$arch-linux-ohos -C link-arg=--sysroot=$native/sysroot -C link-arg=-fuse-ld=lld")
        & $cargo build --manifest-path experiments/sunshine/peer/Cargo.toml --locked --release --lib --features $peerFeatures --target $triple --quiet
        if ($LASTEXITCODE) { throw "Peer build failed: $arch" }
        "merged_peer_built=$arch"
    }
    & ohpm.bat install --all
    if ($LASTEXITCODE) { throw 'Module dependency resolution failed' }
    $output=& node.exe "$DevEco/tools/hvigor/bin/hvigorw.js" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon 2>&1
    if ($LASTEXITCODE) {
        $output | Select-String -Pattern 'ERROR|failed|Error:|At File:|fatal error:' | Select-Object -First 26 | ForEach-Object { $_.Line -replace '\b\d{1,3}(?:\.\d{1,3}){3}:23388\b','[test broker]' }
        throw 'Merged debug build failed'
    }
    # CMake caches per ABI. Never install an incremental build still bound
    # to an older test broker (especially when a LAN-only build was requested).
    foreach ($abi in 'arm64-v8a','x86_64') {
        $ninja=Join-Path $root "entry/.cxx/default/default/debug/$abi/build.ninja"
        $candidatePresent=Select-String -Quiet -LiteralPath $ninja -SimpleMatch 'SESAME_SUNSHINE_USB_LAN_CANDIDATE=1'
        if ([bool]$candidatePresent -ne [bool]$UsbLanCandidate) { throw 'Unverified LAN candidate build scope' }
        $rxPresent=Select-String -Quiet -LiteralPath $ninja -SimpleMatch 'SESAME_PHONE_RX_TRIAL=1'
        if ([bool]$rxPresent -ne [bool]$PhoneRxTrial) { throw 'Unverified phone receive build scope' }
        $corePresent=Select-String -Quiet -LiteralPath $ninja -SimpleMatch 'SESAME_CORE_RX_WITNESS=1'
        if ([bool]$corePresent -ne [bool]$CoreRxWitness) { throw 'Unverified core receive witness scope' }
        $keyPresent=Select-String -Quiet -LiteralPath $ninja -SimpleMatch 'SESAME_KEY_RECOVERY_TRIAL=1'
        if ([bool]$keyPresent -ne [bool]$KeyRecoveryTrial) { throw 'Unverified LAN confirmed recovery trial' }
        $slotPresent=Select-String -Quiet -LiteralPath $ninja -SimpleMatch 'SESAME_KEY_SLOT_TRIAL=1'
        if ([bool]$slotPresent -ne [bool]$KeyDecoderSlotTrial) { throw 'Unverified LAN decoder slot trial' }
        $qosPresent=Select-String -Quiet -LiteralPath $ninja -SimpleMatch 'SESAME_READER_QOS_TRIAL=1'
        if ([bool]$qosPresent -ne [bool]$ReaderQosTrial) { throw 'Unverified reader QoS scope' }
        $definition=(Select-String -LiteralPath $ninja -Pattern 'SESAME_SUNSHINE_COMPANION_BROKER=' |
            Select-Object -First 1).Line
        $endpoint=if ($definition -match 'SESAME_SUNSHINE_COMPANION_BROKER=\\"(\d{1,3}(?:\.\d{1,3}){3}:23388)\\"') { $Matches[1] } else { '' }
        if ($endpoint -ne $TestBroker -or ($definition -and !$endpoint)) {
            throw 'Native build has stale test routing options; reconfigure the debug build before installing.'
        }
    }
    $rxMode=if($PhoneRxTrial){'ahead'}else{'inline'}
    $coreMode=if($CoreRxWitness){'on'}else{'off'}
    $fecMode=if($NormalFecForLanTrial){'runtime'}else{'debug'}
    $readerMode=if($ReaderQosTrial){'initiated'}else{'unchanged'}
    $phaseMode=if($PhoneRxTrial){'v1'}else{'none'}
    $marginMode=if($PairedMarginBaseline){'paired'}elseif($BurstMarginTrial){'bounded'}else{'off'}
    python.exe -B experiments/sunshine/check-merged-hap.py --preview "--expected-broker=$TestBroker" "--expected-rx=$rxMode" "--expected-core-rx=$coreMode" "--expected-fec=$fecMode" "--expected-reader=$readerMode" "--expected-phase=$phaseMode" "--expected-margin=$marginMode" $hap
    if ($LASTEXITCODE) { throw 'Not the merged test artifact' }
    $after=VerifySigner $hap 'new'
    if ((Compare-Object $before $after) -or (Get-FileHash $hap).Hash -eq (Get-FileHash $old).Hash) { throw 'Signer or package mismatch' }
    "merged_debug_signature_verified=1 sha256=$((Get-FileHash $hap).Hash)"
} finally {
    Pop-Location
    foreach ($file in 'previous.cer','previous.p7b','new.cer','new.p7b') {
        $f=Join-Path $area $file
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f }
    }
    [IO.Directory]::Delete($area)
}
