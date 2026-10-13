# install-ollama-server.ps1 - run the Ollama server reliably on the gaming-pc and expose it to the server only.
# Why a task: on this setup the Ollama desktop app failed to spawn its own server (it died instantly with no
# log) once OLLAMA_HOST was set to listen on all interfaces, but `ollama serve` itself ran fine. So a task
# starts the server at logon, and the desktop app simply attaches to it as a chat window.
# Part 1 (as the desktop user, no admin): user env vars + at-logon task.
# Part 2 (-Firewall, ELEVATED): inbound rule for the server only.
param([switch]$Firewall)
# ---- site config (placeholders) ------------------------------------------
$AllowedClient = '<SERVER_IP>'      # the only machine allowed to reach the API
$Port          = 11434              # Ollama's default
# ---------------------------------------------------------------------------
if ($Firewall) {
    Get-NetFirewallRule -DisplayName 'Ollama API (server only)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'Ollama API (server only)' -Direction Inbound -Protocol TCP -LocalPort $Port `
        -RemoteAddress $AllowedClient -Action Allow -Profile Any | Out-Null
    # Windows' first-run prompt creates per-program "ollama.exe" rules. REMOVE them - don't flip them to Block:
    # in Windows Firewall a Block rule always beats an Allow rule, so a blocked ollama.exe locks out the server too.
    # Without them, the default inbound policy blocks everyone except the rule above.
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^ollama(\s+app)?\.exe$' } | Remove-NetFirewallRule
    "firewall: TCP $Port allowed only from $AllowedClient (localhost always works)"
    return
}
$vars = @{ OLLAMA_HOST = "0.0.0.0:$Port"; OLLAMA_KEEP_ALIVE = '30m'; OLLAMA_FLASH_ATTENTION = '1'; OLLAMA_CONTEXT_LENGTH = '16384' }
foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'User') }
$exe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
$a  = New-ScheduledTaskAction -Execute $exe -Argument 'serve'
$tr = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
$pr = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'Ollama-server' -Action $a -Trigger $tr -Settings $st -Principal $pr -Force | Out-Null
"task Ollama-server registered (at logon, restart on failure); env vars set"
