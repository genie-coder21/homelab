# install-keepawake.ps1 - one-time, ELEVATED: copy keepawake to C:\ProgramData\kids-vms\, register the SYSTEM
# task "KidsVMs-KeepAwake", allow the server's SSH login user to start/stop it, then test on/off with powercfg.
$SshUser = '<HOST_SSH_USER>'     # the local account the server's SSH key logs in as
$src = $PSScriptRoot; $dst = 'C:\ProgramData\kids-vms'; $out = "$dst\install.log"
New-Item -ItemType Directory -Force $dst | Out-Null
# The SSH user must be able to append to keepawake.log, or its on/off calls log nothing (silently).
icacls $dst /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
Copy-Item "$src\keepawake.ps1", "$src\keepawake-holder.ps1" $dst -Force
& {
    $a  = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $dst\keepawake-holder.ps1"
    $st = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'KidsVMs-KeepAwake' -Action $a -Settings $st -User SYSTEM -RunLevel Highest -Force | Out-Null
    # let the non-elevated SSH user start/stop it: add a read+execute ACE to the task's security descriptor
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $t = $svc.GetFolder('\').GetTask('KidsVMs-KeepAwake')
    $sid = (New-Object Security.Principal.NTAccount $SshUser).Translate([Security.Principal.SecurityIdentifier]).Value
    $sd = $t.GetSecurityDescriptor(4)
    if ($sd -notmatch $sid) { $t.SetSecurityDescriptor($sd + "(A;;GRGX;;;$sid)", 0) }
    "task registered; $SshUser may run it"
    "--- test ON";  & "$dst\keepawake.ps1" -Mode on;  Start-Sleep 5; powercfg /requests | Select-String -Context 0,2 'SYSTEM:' | Out-String
    "--- test OFF"; & "$dst\keepawake.ps1" -Mode off; Start-Sleep 3; powercfg /requests | Select-String -Context 0,2 'SYSTEM:' | Out-String
} *>&1 | Out-File $out -Encoding utf8
