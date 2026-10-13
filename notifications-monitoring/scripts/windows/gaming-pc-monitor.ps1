# gaming-pc-monitor.ps1 - the gaming-pc's own health checks, published to the server's ntfy.
# Runs hidden in the user's session (scheduled task "Homelab-gaming-pc-monitor", at logon), every 5 minutes.
# Alerts only on CHANGE: once when a problem appears, once when it clears ("Resolved").
param([switch]$Once)
# ---- site config (placeholders) ------------------------------------------
$Topic      = 'lab-alerts'
$Drives     = @('C', 'D')                    # volumes to watch for free space
$MinFreePct = 10
$WatchVMs   = @('<VM_NAME_1>', '<VM_NAME_2>') # Hyper-V guests whose health to watch (empty = none)
$WatchLog   = '<PATH_TO_LOG_TO_WATCH>'       # any log whose new ERROR lines should alert (optional)
# ---------------------------------------------------------------------------
$send  = Join-Path $PSScriptRoot 'send-ntfy.ps1'
$dir   = Join-Path $env:LOCALAPPDATA 'homelab-ntfy'; New-Item -ItemType Directory -Force $dir | Out-Null
$stateFile = Join-Path $dir 'monitor-state.json'; $log = Join-Path $dir 'monitor.log'
function L($m) { Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; if ((Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force } }

$state = @{}
if (Test-Path $stateFile) { (Get-Content $stateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value } }

function Check($key, [bool]$bad, $priority, $title, $message) {
    $was = [bool]$state[$key]
    if ($bad -and -not $was) {
        try { & $send -Topic $Topic -Priority $priority -Title $title -Message $message -Tags warning; L "ALERT $key : $message" } catch { L "send failed ($key): $($_.Exception.Message)"; return }
        $state[$key] = $true
    } elseif (-not $bad -and $was) {
        try { & $send -Topic $Topic -Priority 2 -Title "Resolved: $title" -Message 'OK again.' -Tags white_check_mark; L "RESOLVED $key" } catch { L "send failed ($key): $($_.Exception.Message)"; return }
        $state[$key] = $false
    }
}

function Run-Checks {
    $vmms = Get-Service vmms -ErrorAction SilentlyContinue
    if ($vmms) { Check 'vmms' ($vmms.Status -ne 'Running') 5 'Hyper-V service stopped' "vmms is $($vmms.Status); VMs can't start." }

    foreach ($d in $Drives) {
        $v = Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue
        if ($v -and $v.Size) { $pct = [math]::Round(100 * $v.SizeRemaining / $v.Size, 1)
            Check "free-$d" ($pct -lt $MinFreePct) 4 "Gaming-pc ${d}: low on space" "${d}: has $pct % free ($([math]::Round($v.SizeRemaining/1GB)) GB)." }
    }
    foreach ($p in Get-PhysicalDisk) {
        Check "disk-$($p.DeviceId)" ($p.HealthStatus -ne 'Healthy') 5 'Gaming-pc disk unhealthy' "$($p.FriendlyName) ($([math]::Round($p.Size/1TB,1)) TB) reports $($p.HealthStatus) / $($p.OperationalStatus)."
    }

    # New ERROR lines since the last pass (tracks the byte offset; handles rotation)
    if ($WatchLog -and (Test-Path $WatchLog)) {
        $since = if ($state['log-pos']) { [long]$state['log-pos'] } else { (Get-Item $WatchLog).Length }
        $len = (Get-Item $WatchLog).Length; if ($len -lt $since) { $since = 0 }
        $new = if ($len -gt $since) { $fs = [IO.File]::Open($WatchLog, 'Open', 'Read', 'ReadWrite'); $fs.Seek($since, 'Begin') | Out-Null; (New-Object IO.StreamReader $fs).ReadToEnd(); $fs.Dispose() } else { '' }
        $state['log-pos'] = $len
        $err = ($new -split "`r?`n" | Where-Object { $_ -match 'ERROR' }) -join "`n"
        if ($err) { try { & $send -Topic $Topic -Priority 4 -Title 'Watched log: ERROR' -Message $err -Tags warning; L "ALERT log: $err" } catch {} }
    }

    foreach ($n in $WatchVMs) {
        $vm = Get-VM -Name $n -ErrorAction SilentlyContinue; if (-not $vm) { continue }
        $badState = "$($vm.State)" -match 'Critical' -or ($vm.Status -and $vm.Status -ne 'Operating normally')
        Check "vm-$n" $badState 4 "VM problem: $n" "State $($vm.State), status '$($vm.Status)'."
    }
    $state | ConvertTo-Json | Set-Content $stateFile
}

L 'monitor starting'
do { try { Run-Checks } catch { L "check round failed: $($_.Exception.Message)" }; if (-not $Once) { Start-Sleep 300 } } while (-not $Once)
