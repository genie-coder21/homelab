# keepawake.ps1 - the server's hook to keep the gaming-pc awake while a kids' VM is in use.
#   & 'C:\ProgramData\kids-vms\keepawake.ps1' -Mode on       # hold awake (idempotent)
#   & 'C:\ProgramData\kids-vms\keepawake.ps1' -Mode off      # release (idempotent) - restores normal sleep
#   & 'C:\ProgramData\kids-vms\keepawake.ps1'                # status
# Works by starting/stopping the SYSTEM task "KidsVMs-KeepAwake" (keepawake-holder.ps1). No power settings are
# changed, so "off" can't leave sleep disabled, and the user's power-plan switching still works. Exit 0 = ok.
param([ValidateSet('on', 'off', 'status')][string]$Mode = 'status')
$task = 'KidsVMs-KeepAwake'
try {
    $t = Get-ScheduledTask -TaskName $task -ErrorAction Stop
    if ($Mode -eq 'on'  -and $t.State -ne 'Running') { Start-ScheduledTask -TaskName $task; Start-Sleep 2 }
    if ($Mode -eq 'off' -and $t.State -eq 'Running') { Stop-ScheduledTask  -TaskName $task; Start-Sleep 2 }
    $state = (Get-ScheduledTask -TaskName $task).State
    "keepawake: $(if ($state -eq 'Running') { 'ON (holding the PC awake)' } else { 'OFF (normal sleep)' })"
    Add-Content 'C:\ProgramData\kids-vms\keepawake.log' "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') mode=$Mode -> $state (by $env:USERNAME)" -ErrorAction SilentlyContinue
    exit 0
} catch { "keepawake ERROR: $($_.Exception.Message)"; exit 1 }
