# hl-backup.ps1 - restic backup of the gaming-pc to its own data drive.
#
# DRAFT: written and dry-run tested, intended to run as SYSTEM from a daily scheduled
# task that may wake the PC. Repository password is stored DPAPI-encrypted (LocalMachine).

$ErrorActionPreference = 'Stop'

# ---- CONFIG -------------------------------------------------------------------------
$Root        = 'C:\ProgramData\Homelab'
$Restic      = "$Root\bin\restic.exe"
$Repo        = '<BACKUP_DRIVE>:\<VAULT_DIR>\gaming-pc'
$PwFile      = "$Root\secrets\restic-password.dpapi"
$ExcludeFile = "$Root\backup\excludes.txt"
$Log         = "$Root\logs\hl-backup.log"
$Status      = "$Root\status.json"
$CacheDir    = "$Root\cache"

# What gets backed up. The backup drive is the destination, so it is NOT in here.
$Paths = @(
    'C:\Users',
    'C:\ProgramData\ssh',
    '<DATA_DRIVE>:\<FOLDER_1>',
    '<DATA_DRIVE>:\<FOLDER_2>'
)
# Loose documents in the root of the data drive
$Paths += Get-ChildItem '<DATA_DRIVE>:\' -File -Include *.docx, *.doc, *.pdf, *.xlsx, *.txt -ErrorAction SilentlyContinue |
          ForEach-Object FullName

$Retention = @('--keep-daily', '14', '--keep-weekly', '8', '--keep-monthly', '6')
# -------------------------------------------------------------------------------------

function Write-Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $Log -Value $line -Encoding UTF8
}

function Get-RepoPassword {
    Add-Type -AssemblyName System.Security
    $bytes = [IO.File]::ReadAllBytes($PwFile)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'LocalMachine')
    [Text.Encoding]::UTF8.GetString($plain)
}

# Run restic, stream its output to the log, return @{ Code; Lines }.
function Invoke-Restic([string[]]$ResticArgs) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # restic writes progress to stderr
    $lines = & $Restic @ResticArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $eap
    $lines | Where-Object { $_ -notmatch '"message_type":"status"' } | ForEach-Object { Add-Content $Log "    $_" -Encoding UTF8 }
    @{ Code = $code; Lines = $lines }
}

function Save-Status([hashtable]$s) {
    $prev = $null
    if (Test-Path $Status) { $prev = Get-Content $Status -Raw | ConvertFrom-Json }
    if ($s.result -eq 'ok' -or $s.result -eq 'warning') { $s.last_success = $s.finished }
    elseif ($prev) { $s.last_success = $prev.last_success }
    $s | ConvertTo-Json | Set-Content -Path $Status -Encoding UTF8
}

$start = Get-Date
$st = @{ started = $start.ToString('s'); finished = $null; result = 'failed'; message = ''; snapshot = $null
         files_new = 0; files_changed = 0; bytes_added = 0; duration_s = 0; checked = $false; last_success = $null }

try {
    Write-Log "=== backup start"
    if (-not (Test-Path "$Repo\config")) { throw "repository not found at $Repo (is the drive present?)" }

    $env:RESTIC_REPOSITORY = $Repo
    $env:RESTIC_PASSWORD   = Get-RepoPassword
    $env:RESTIC_CACHE_DIR  = $CacheDir

    # --use-fs-snapshot = VSS: open/locked files (browser profiles, NTUSER.DAT) are read consistently.
    $b = Invoke-Restic (@('backup', '--use-fs-snapshot', '--json', '--iexclude-file', $ExcludeFile,
                          '--exclude-caches', '--tag', 'nightly') + $Paths)
    $summary = $b.Lines | Where-Object { $_ -match '"message_type":"summary"' } | Select-Object -Last 1
    if ($summary) {
        $j = $summary | ConvertFrom-Json
        $st.snapshot = $j.snapshot_id; $st.files_new = $j.files_new; $st.files_changed = $j.files_changed
        $st.bytes_added = $j.data_added
    }
    # restic: 0 = ok, 3 = snapshot made but some files unreadable, anything else = failed
    switch ($b.Code) {
        0       { $st.result = 'ok' }
        3       { $st.result = 'warning'; $st.message = 'some files could not be read (see log)' }
        default { throw "restic backup exited $($b.Code)" }
    }

    $f = Invoke-Restic (@('forget', '--prune', '--tag', 'nightly') + $Retention)
    if ($f.Code -ne 0) { $st.result = 'warning'; $st.message = "forget/prune exited $($f.Code)" }

    # Sundays: verify repository structure
    if ((Get-Date).DayOfWeek -eq 'Sunday') {
        $c = Invoke-Restic @('check')
        $st.checked = $true
        if ($c.Code -ne 0) { $st.result = 'warning'; $st.message = "restic check exited $($c.Code)" }
    }
}
catch {
    $st.result = 'failed'
    $st.message = $_.Exception.Message
    Write-Log "ERROR: $($_.Exception.Message)"
}
finally {
    Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
    $end = Get-Date
    $st.finished = $end.ToString('s')
    $st.duration_s = [int]($end - $start).TotalSeconds
    Save-Status $st
    Write-Log ("=== backup {0}: {1} new, {2} changed, {3:N1} MB added, {4}s {5}" -f `
        $st.result, $st.files_new, $st.files_changed, ($st.bytes_added / 1MB), $st.duration_s, $st.message)
}

if ($st.result -eq 'failed') { exit 1 } else { exit 0 }
