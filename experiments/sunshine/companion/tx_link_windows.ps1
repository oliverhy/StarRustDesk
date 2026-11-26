param([Parameter(Mandatory=$true)][string]$LocalAddress,
      [ValidateRange(1,3300)][int]$MaxSamples=3300,[switch]$CompareWifi,[switch]$CompareEthernet)
$ErrorActionPreference = 'Stop'
try {
    $local = [Net.IPAddress]::Parse($LocalAddress)
    $selected = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and
            @($_.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.Equals($local) }).Count -eq 1 })
    if ($selected.Count -ne 1) { 'link_setup 0 0'; exit 2 }
    $adapter = $selected[0]
    $wireless = [int]($adapter.NetworkInterfaceType -eq 'Wireless80211')
    $gates = @($adapter.GetIPProperties().GatewayAddresses |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.Equals([Net.IPAddress]::Any) })
    if ($gates.Count -ne 1) { "link_setup 0 $wireless"; exit 3 }
    $gateway = $gates[0].Address
    if ($CompareWifi -and $CompareEthernet) { 'link_setup 0 0'; exit 3 }
    $compareLan=$CompareWifi -or $CompareEthernet
    if ($compareLan) {
        $b=$local.GetAddressBytes(); $g=$gateway.GetAddressBytes()
        $private=($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
                  ($b[0] -eq 192 -and $b[1] -eq 168))
        if (($CompareWifi -and $wireless -ne 1) -or ($CompareEthernet -and $adapter.NetworkInterfaceType -ne 'Ethernet') -or
            -not $private -or $b[0] -ne $g[0] -or $b[1] -ne $g[1] -or
            $b[2] -ne $g[2] -or $g[3] -in @(0,255,$b[3])) { "link_setup 0 $wireless"; exit 3 }
    }
    "link_setup 1 $wireless"
    if ($compareLan) { "private_gateway $($gateway.IPAddressToString)" }
    $ping = [Net.NetworkInformation.Ping]::new()
    $budget = [Diagnostics.Stopwatch]::StartNew()
    $notices=$null
    try {
        $neighbor=$null
        try {
            Add-Type -Path (Join-Path $PSScriptRoot 'tx_neighbor_windows.cs')
            $neighbor=[TxGatewayCache]::new([uint32]$adapter.GetIPProperties().GetIPv4Properties().Index,$gateway)
        } catch {}
        if ($wireless -eq 1) {
            try {
                Add-Type -Path (Join-Path $PSScriptRoot 'tx_wlan_windows.cs')
                $notices = [TxWlanEvents]::new([Guid]::Parse($adapter.Id))
                "wlan_setup $([int]($notices.Status -eq 0)) $($notices.Status)"
            } catch {
                'wlan_setup 0 1'
            }
        }
        for ($i=0; $i -lt $MaxSamples -and $budget.Elapsed.TotalSeconds -lt 730; $i++) {
            $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $status = 0
            $detail = 4
            $rtt = 0
            try {
                $r = $ping.Send($gateway,450,[byte[]]::new(8))
                if ($r.Status -eq 'Success') { $status = 1; $detail=1; $rtt = $r.RoundtripTime }
                elseif ($r.Status -eq 'TimedOut') { $detail=2 } else { $detail=3 }
            } catch {}
            $s = $adapter.GetIPv4Statistics()
            $up = [int]($adapter.OperationalStatus -eq 'Up')
            $cache = @(4294967295,0,0)
            if ($neighbor) { $cache = $neighbor.Read() }
            $observed = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            "link $stamp $status $rtt $up $($s.OutgoingPacketsDiscarded) $($s.OutgoingPacketsWithErrors) $($s.BytesSent) $($s.BytesReceived)"
            "link_observed $stamp $observed $($cache[0]) $($cache[1]) $($cache[2])"
            if ($notices) { $notices.Drain() }
            if ($compareLan) { "link_ping_detail $stamp $detail" }
            if ($CompareWifi -and $notices -and ($i % 2 -eq 0)) {
                $notices.ReadPhy(); $notices.ReadQuality(); $notices.ReadRadio()
            }
            Start-Sleep -Milliseconds 245
        }
    } finally {
        if ($notices) { $notices.Dispose() }
        $ping.Dispose()
    }
} catch {
    'link_setup 0 0'
    exit 4
}
