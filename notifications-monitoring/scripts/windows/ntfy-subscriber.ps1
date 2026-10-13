# ntfy-subscriber.ps1 - shows the server's ntfy notifications as native Windows toasts.
# Runs hidden in the user's desktop session (scheduled task "Homelab-ntfy-subscriber", at logon).
# Toasts only work in the interactive session - never from an SSH session (session 0).
# Streams GET /<topics>/json, resumes with ?since=<last id> after sleep or a server reboot,
# and retries forever with backoff. Windows PowerShell 5.1, no modules needed.
# Save this file as UTF-8 WITH BOM, or PS 5.1 turns the topic icons into mojibake.

# ---- site config (placeholders) ------------------------------------------
$Server    = 'http://<SERVER_IP>:<NTFY_PORT>'
$Topics    = 'lab-alerts,lab-info,lab-security'
$TokenFile = Join-Path $env:USERPROFILE '.homelab\ntfy\token.xml'   # DPAPI-wrapped, only this user can read it
$AppId     = 'Homelab.Notifications'                               # registered by install-ntfy-subscriber.ps1
# ---------------------------------------------------------------------------
$State  = Join-Path $env:LOCALAPPDATA 'homelab-ntfy'; New-Item -ItemType Directory -Force $State | Out-Null
$LastId = Join-Path $State 'last-id.txt'
$Log    = Join-Path $State 'subscriber.log'
function L($m) { Add-Content $Log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; if ((Get-Item $Log).Length -gt 1MB) { Move-Item $Log "$Log.old" -Force } }

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)

# Priority mapping: 5 = stays on screen with an alarm sound and a Dismiss button,
# 4 = sound, 3 = normal, 1-2 = silent (Action Center only).
function Show-Toast($msg) {
    $e = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $prio  = if ($msg.priority) { [int]$msg.priority } else { 3 }
    $topic = ($msg.topic -replace '^lab-', '')
    $icon  = @{ alerts = '⚠'; info = 'ℹ'; security = '🛡' }[$topic]
    $title = if ($msg.title) { $msg.title } else { $msg.topic }
    $tags  = if ($msg.tags) { ' · ' + ($msg.tags -join ' ') } else { '' }
    $launch = if ($msg.click) { " activationType=`"protocol`" launch=`"$(& $e $msg.click)`"" } else { '' }
    $scenario = if ($prio -ge 5) { ' scenario="reminder"' } else { '' }
    $audio = if ($prio -le 2) { '<audio silent="true"/>' } elseif ($prio -ge 5) { '<audio src="ms-winsoundevent:Notification.Looping.Alarm" loop="false"/>' } else { '<audio src="ms-winsoundevent:Notification.Default"/>' }
    $actions = if ($prio -ge 5) { '<actions><action content="Dismiss" arguments="dismiss" activationType="system"/></actions>' } else { '' }
    $xml = "<toast$launch$scenario><visual><binding template='ToastGeneric'><text>$(& $e "$icon $title")</text><text>$(& $e $msg.message)</text><text placement='attribution'>$(& $e "$($msg.topic) · p$prio$tags")</text></binding></visual>$audio$actions</toast>"
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument; $doc.LoadXml($xml)
    $t = New-Object Windows.UI.Notifications.ToastNotification $doc
    if ($prio -le 2) { $t.SuppressPopup = $true }
    $Notifier.Show($t)
}

$backoff = 5
L 'subscriber starting'
while ($true) {
    try {
        $token = (Import-Clixml $TokenFile).GetNetworkCredential().Password
        $since = if (Test-Path $LastId) { (Get-Content $LastId -Raw).Trim() } else { '' }
        $url = "$Server/$Topics/json" + $(if ($since) { "?since=$since" } else { '' })
        $req = [Net.HttpWebRequest]::Create($url)
        $req.Headers.Add('Authorization', "Bearer $token"); $token = $null
        $req.Timeout = 15000; $req.ReadWriteTimeout = 120000             # server keepalive is ~45 s
        $resp = $req.GetResponse(); $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        L 'connected'; $backoff = 5
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            $m = $line | ConvertFrom-Json
            if ($m.event -eq 'message') {
                Set-Content $LastId $m.id
                try { Show-Toast $m; L "toast: [$($m.topic) p$($m.priority)] $($m.title)" } catch { L "toast failed: $($_.Exception.Message)" }
            }
        }
        L 'stream ended'
    } catch { L "disconnected: $($_.Exception.Message) - retry in ${backoff}s" }
    finally { if ($reader) { $reader.Dispose() }; if ($resp) { $resp.Dispose() }; $reader = $null; $resp = $null }
    Start-Sleep $backoff; $backoff = [Math]::Min($backoff * 2, 60)
}
