# send-ntfy.ps1 - publish a notification from the gaming-pc to the server's ntfy (JSON publish, UTF-8 safe).
# Uses the DPAPI-wrapped token, so it must run as the desktop user in a normal session.
# Every message gets the tag 'gaming-pc' so you can tell where it came from.
param([Parameter(Mandatory)][string]$Topic, [ValidateRange(1, 5)][int]$Priority = 3,
      [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Message, [string[]]$Tags = @())
# ---- site config (placeholders) ------------------------------------------
$Server    = 'http://<SERVER_IP>:<NTFY_PORT>'
$TokenFile = Join-Path $env:USERPROFILE '.homelab\ntfy\token.xml'
# ---------------------------------------------------------------------------
$token = (Import-Clixml $TokenFile).GetNetworkCredential().Password
$body = @{ topic = $Topic; title = $Title; message = $Message; priority = $Priority; tags = @($Tags + 'gaming-pc') } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Post -Uri "$Server/" -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
