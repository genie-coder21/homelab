# guest-mount-games.ps1 - keep a kids' VM's game discs mounted at FIXED drive letters across reboots.
# The old JumpStart games remember the CD drive letter they were installed from (C:\Windows\ka.ini,
# C:\KA\*\*.ini, <game>\*.ini), so every image must come back on exactly that letter.
# Installs, inside the guest via PowerShell Direct:
#   C:\ProgramData\kids-setup\mount-map.csv   (Letter,Image - image path relative to C:\Games)
#   C:\ProgramData\kids-setup\mount-games.ps1 (ISO -> Mount-DiskImage + letter; CUE/BIN -> WinCDEmu batchmnt64)
#   task "KidsSetup-MountGames" (SYSTEM, at startup) + runs it once now.  Log: mount-games.log
#   .\guest-mount-games.ps1 -VMName <vm> -Map @{ E='<game folder>\<image>.iso'; F='<game folder>\<image>.cue'; ... }
param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][hashtable]$Map)
# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
$cred = Import-Clixml "$CredDir\$VMName.xml"
Set-VMDvdDrive -VMName $VMName -Path $null -ErrorAction SilentlyContinue      # eject the Windows installer ISO (frees D:)
$csv = ($Map.GetEnumerator() | Sort-Object Key | ForEach-Object { '{0},"{1}"' -f $_.Key.ToUpper(), $_.Value }) -join "`n"

Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $csv -ScriptBlock {
    param($csv)
    $d = 'C:\ProgramData\kids-setup'
    "Letter,Image`n$csv" | Set-Content "$d\mount-map.csv" -Encoding UTF8
    @'
# mount-games.ps1 - mount every game disc at its fixed letter (idempotent). Runs as SYSTEM at startup.
$d = 'C:\ProgramData\kids-setup'; $log = "$d\mount-games.log"
function L($m) { Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" }
$wcd = 'C:\Program Files (x86)\WinCDEmu\batchmnt64.exe'
Start-Sleep 20                                   # let WinCDEmu's driver and the volume manager settle
foreach ($row in Import-Csv "$d\mount-map.csv") {
    $letter = $row.Letter.TrimEnd(':'); $img = Join-Path 'C:\Games' $row.Image
    if (-not (Test-Path $img)) { L "MISSING $img"; continue }
    if (Test-Path "${letter}:\") { L "ok (already mounted) ${letter}: $($row.Image)"; continue }
    try {
        if ($img -match '\.iso$') {
            $di = Get-DiskImage -ImagePath $img
            if (-not $di.Attached) { $di = Mount-DiskImage -ImagePath $img -NoDriveLetter -PassThru; Start-Sleep 2 }
            $vol = Get-CimInstance Win32_Volume | Where-Object { $_.DeviceID -eq ((Get-DiskImage -ImagePath $img | Get-Volume).Path) }
            $vol | Set-CimInstance -Property @{ DriveLetter = "${letter}:" }
        } else {
            & $wcd $img $letter /wait | Out-Null
        }
        Start-Sleep 1
        L ("{0} ${letter}: {1}" -f $(if (Test-Path "${letter}:\") { 'MOUNTED' } else { 'FAILED ' }), $row.Image)
    } catch { L "ERROR ${letter}: $($row.Image) - $($_.Exception.Message)" }
}
'@ | Set-Content "$d\mount-games.ps1" -Encoding UTF8
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile("$d\mount-games.ps1", [ref]$null, [ref]$e)
    if ($e) { "PARSE ERROR in mount-games.ps1: $($e[0].Message)"; return }
    $a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $d\mount-games.ps1"
    Register-ScheduledTask -TaskName 'KidsSetup-MountGames' -Action $a -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Force | Out-Null
    "task registered; map has $((Import-Csv "$d\mount-map.csv").Count) discs"
}
