# install-ntfy-subscriber.ps1 - one-time, as the desktop user (no admin needed): registers the toast
# sender identity, copies the scripts locally, and creates the at-logon tasks that keep them running.
# Re-run to update. Prerequisite: the ntfy token stored DPAPI-wrapped at $TokenFile (see README).
$dst = Join-Path $env:USERPROFILE 'Scripts\ntfy'; New-Item -ItemType Directory -Force $dst | Out-Null
foreach ($f in 'ntfy-subscriber.ps1', 'send-ntfy.ps1', 'gaming-pc-monitor.ps1') {   # re-save as UTF-8 with BOM for PS 5.1
    $t = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $f), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $dst $f), $t, (New-Object Text.UTF8Encoding $true)) }

# Toast sender identity: shows as "Homelab" instead of "Windows PowerShell"
$k = 'HKCU:\Software\Classes\AppUserModelId\Homelab.Notifications'
New-Item $k -Force | Out-Null
Set-ItemProperty $k DisplayName 'Homelab'
Set-ItemProperty $k IconUri "$env:SystemRoot\System32\imageres.dll"
Set-ItemProperty $k ShowInSettings 1 -Type DWord

# Interactive logon type is what puts the task in the user's desktop session (toasts need it).
$tr = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$pr = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
foreach ($job in @(@{ Name = 'Homelab-ntfy-subscriber'; File = 'ntfy-subscriber.ps1' },
                   @{ Name = 'Homelab-gaming-pc-monitor'; File = 'gaming-pc-monitor.ps1' })) {
    $a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dst\$($job.File)`""
    Register-ScheduledTask -TaskName $job.Name -Action $a -Trigger $tr -Settings $st -Principal $pr -Force | Out-Null
    Stop-ScheduledTask $job.Name -ErrorAction SilentlyContinue
    Start-ScheduledTask $job.Name
    "$($job.Name): $((Get-ScheduledTask $job.Name).State)"
}
