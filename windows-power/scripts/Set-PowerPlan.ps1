# Set-PowerPlan.ps1 - switch the active Windows power plan by name, then show a notification.
#
# Used by the desktop shortcuts in "Power Plans". No admin needed.
#
#   Set-PowerPlan.ps1 -Plan "Ultimate Performance"

param([Parameter(Mandatory)][string]$Plan)

function Show-Toast([string]$Title, [string]$Body) {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $t = [Security.SecurityElement]::Escape($Title); $b = [Security.SecurityElement]::Escape($Body)
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast duration='short'><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual><audio silent='true'/></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
        [Windows.UI.Notifications.ToastNotification]::new($xml))
}

# Look the plan up by name: the Ultimate Performance GUID differs per machine.
$guid = $null
foreach ($line in powercfg /list) {
    if ($line -match 'GUID:\s+(\S+)\s+\((.+?)\)' -and $Matches[2] -eq $Plan) { $guid = $Matches[1] }
}
if (-not $guid) { Show-Toast 'Power plan not found' "No plan named '$Plan' (see: powercfg /list)"; exit 1 }

powercfg /setactive $guid
if ($LASTEXITCODE -ne 0) { Show-Toast 'Power plan switch failed' "powercfg exited $LASTEXITCODE"; exit 1 }

Show-Toast "Power plan: $Plan" 'Switched.'
