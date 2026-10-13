# guest-internet.ps1 - turn a kids' VM's internet access on or off, from the HOST via PowerShell Direct.
# OFF = the guest firewall blocks all outbound traffic except the home LAN, so VNC/Guacamole,
#       Sunshine/Moonlight and the server keep working (and replies to inbound connections are always allowed).
# ON  = back to Windows' default (outbound allowed).
# Kids use standard accounts, so they can't change it.
#   .\guest-internet.ps1 -VMName <vm> -Off
#   .\guest-internet.ps1 -VMName <vm> -On
#   .\guest-internet.ps1 -VMName <vm>          # just report the state
param([Parameter(Mandatory)][string]$VMName, [switch]$On, [switch]$Off)
# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
$LanCidr   = '<LAN_CIDR>'          # the home LAN, e.g. 192.0.2.0/24
$GatewayIp = '<LAN_GATEWAY_IP>'    # used only for the reachability report
$cred = Import-Clixml "$CredDir\$VMName.xml"
$mode = if ($Off) { 'off' } elseif ($On) { 'on' } else { 'status' }

Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $mode, $LanCidr, $GatewayIp -ScriptBlock {
    param($mode, $LanCidr, $GatewayIp)
    $rule = 'Kids - allow home LAN (internet off)'
    if ($mode -eq 'off') {
        if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule -Direction Outbound -RemoteAddress $LanCidr, LocalSubnet -Action Allow -Profile Any | Out-Null
        }
        Set-NetFirewallProfile -All -Enabled True -DefaultOutboundAction Block
    } elseif ($mode -eq 'on') {
        Set-NetFirewallProfile -All -DefaultOutboundAction Allow
    }
    $blocked = (Get-NetFirewallProfile | Where-Object DefaultOutboundAction -eq 'Block').Count -eq 3
    $net = Test-Connection 1.1.1.1 -Count 1 -Quiet
    $lan = Test-Connection $GatewayIp -Count 1 -Quiet
    "$env:COMPUTERNAME internet: $(if ($blocked) { 'OFF' } else { 'ON' })   (test: internet reachable=$net, home LAN reachable=$lan)"
}
