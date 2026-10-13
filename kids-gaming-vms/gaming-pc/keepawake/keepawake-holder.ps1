# keepawake-holder.ps1 - holds the gaming-pc awake while kids' VMs run. Started/stopped by keepawake.ps1
# through the SYSTEM task "KidsVMs-KeepAwake". It changes NO power settings: it holds a system power request
# (SetThreadExecutionState ES_CONTINUOUS|ES_SYSTEM_REQUIRED) which Windows drops the moment this process ends.
# Safety net: exits by itself after 10 minutes with no VM running, so a missed "off" can't pin the PC awake.
$log = 'C:\ProgramData\kids-vms\keepawake.log'
function L($m) { Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" }
Add-Type -Namespace KA -Name P -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[void][KA.P]::SetThreadExecutionState([uint32]'0x80000001')          # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
L 'holding awake'
$idle = 0
while ($true) {
    Start-Sleep 60
    $running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object State -eq 'Running').Count
    if ($running) { $idle = 0 } else { $idle++ }
    if ($idle -ge 10) { L 'no VM running for 10 min - releasing on my own'; break }
}
[void][KA.P]::SetThreadExecutionState([uint32]'0x80000000')          # ES_CONTINUOUS only = release
