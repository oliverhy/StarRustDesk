param([Parameter(Mandatory=$true)][string]$HelperPath,[int]$InterfaceIndex,[ipaddress]$ListenAddress)
# Read-only. Never enumerate SSIDs, pairing information or remote addresses.
$ErrorActionPreference='Stop'
$exe=(Resolve-Path -LiteralPath $HelperPath).Path
if([IO.Path]::GetFileName($exe) -ine 'SesameStreamCompanion.exe'){throw 'Select the installed companion executable.'}
if($ListenAddress){
    $binding=@(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ListenAddress.IPAddressToString |
        Where-Object AddressState -eq Preferred | Select-Object -ExpandProperty InterfaceIndex -Unique)
    if($binding.Count -ne 1 -or ($InterfaceIndex -and $binding[0] -ne $InterfaceIndex)){throw 'Cannot identify a single bound interface.'}
    $InterfaceIndex=$binding[0]
}
$net=@(Get-NetConnectionProfile)
if($InterfaceIndex){$net=@($net | Where-Object InterfaceIndex -eq $InterfaceIndex)}
if(!$net.Count){throw 'No matching active network profile.'}
$dir=[IO.Path]::GetDirectoryName($exe)
foreach($profile in $net){
    $category=[string]$profile.NetworkCategory
    $policy=if($category -eq 'DomainAuthenticated'){'Domain'}else{$category}
    Write-Output ('interface={0} profile={1}' -f $profile.InterfaceIndex,$category)
    foreach($name in @('SesameStreamCompanion.exe','sesame_wan_peer.exe')){
        $path=[IO.Path]::Combine($dir,$name)
        $filters=@(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -Program $path -ErrorAction SilentlyContinue)
        $rules=@(foreach($f in $filters){
            Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $f | Where-Object {
                $profiles=([string]$_.Profile) -split ',\s*'
                $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and
                    ($profiles -contains 'Any' -or $profiles -contains $policy)
            }
        })
        $deny=@($rules | Where-Object Action -eq 'Block').Count
        $allow=@($rules | Where-Object Action -eq 'Allow').Count
        Write-Output ('program={0} matching_inbound_block={1} matching_inbound_allow={2}' -f $name,$deny,$allow)
    }
}
Write-Output 'Explicit program rules only; ports, scope, policy and actual connectivity still need verification. No settings changed.'
