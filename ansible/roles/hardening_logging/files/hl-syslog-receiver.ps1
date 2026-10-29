# hl-syslog-receiver.ps1 - minimal syslog-over-TCP receiver for the gaming PC.
# Deployed by playbooks/logging-gaming-pc.yml.
#
# The server's rsyslog streams one line per message (LF-framed). This script accepts connections
# ONLY from the server's LAN address (the Windows firewall rule allows only that address too) and
# appends each line to  <LogRoot>\<host>\<host>-yyyy-MM-dd.log  (host = 2nd field of the line).
# Files older than KeepDays are deleted once a day. Runs as SYSTEM from a scheduled task
# (at startup, restarted on failure). Plain Windows PowerShell 5.1 - nothing to install.
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$AllowedSender,
    [Parameter(Mandatory = $true)][string]$LogRoot,
    [int]$KeepDays = 180
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$selfLog = Join-Path $LogRoot '_receiver.log'
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot | Out-Null }

function Write-Self([string]$m) {
    try { [System.IO.File]::AppendAllText($selfLog, ((Get-Date).ToString('s') + ' ' + $m + "`r`n"), $utf8) } catch {}
}

$writers = @{}      # "host|date" -> StreamWriter
function Get-Writer([string]$hostName, [string]$day) {
    $key = "$hostName|$day"
    if ($writers.ContainsKey($key)) { return $writers[$key] }
    foreach ($k in @($writers.Keys)) { if (-not $k.EndsWith("|$day")) { try { $writers[$k].Dispose() } catch {}; $writers.Remove($k) } }
    $dir = Join-Path $LogRoot $hostName
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $path = Join-Path $dir ("$hostName-$day.log")
    # FileShare.ReadWrite: the file can be opened in Notepad / Get-Content -Wait while we write.
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $w = New-Object System.IO.StreamWriter($fs, $utf8)
    $writers[$key] = $w
    return $w
}

function Write-Line([string]$line) {
    $line = $line.TrimEnd("`r")
    if ($line.Length -eq 0) { return }
    $parts = $line.Split(' ', 3)
    $h = if ($parts.Count -ge 2 -and $parts[1] -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $parts[1].ToLowerInvariant() } else { '_unknown' }
    $w = Get-Writer $h (Get-Date).ToString('yyyy-MM-dd')
    $w.WriteLine($line)
}

function Remove-Old {
    $cut = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -Path $LogRoot -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '_receiver.log' -and $_.LastWriteTime -lt $cut } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

while ($true) {
    $listener = $null
    $clients = New-Object System.Collections.ArrayList
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        Write-Self "listening on tcp/$Port, allowed sender $AllowedSender, root $LogRoot"
        $lastPrune = [datetime]::MinValue
        $buf = New-Object byte[] 65536
        $chars = New-Object char[] 131072
        while ($true) {
            $busy = $false
            while ($listener.Pending()) {
                $c = $listener.AcceptTcpClient()
                $ip = $c.Client.RemoteEndPoint.Address.ToString()
                if ($ip -ne $AllowedSender) { Write-Self "rejected connection from $ip"; $c.Close(); continue }
                [void]$clients.Add([pscustomobject]@{ C = $c; S = $c.GetStream(); D = $utf8.GetDecoder(); P = New-Object System.Text.StringBuilder; Last = Get-Date; Ip = $ip })
                Write-Self "connection from $ip"
            }
            foreach ($cl in @($clients)) {
                $drop = $false
                try {
                    if ($cl.C.Available -gt 0) {
                        $busy = $true
                        $n = $cl.S.Read($buf, 0, $buf.Length)
                        if ($n -le 0) { $drop = $true }
                        else {
                            $cl.Last = Get-Date
                            $nc = $cl.D.GetChars($buf, 0, $n, $chars, 0)
                            [void]$cl.P.Append($chars, 0, $nc)
                            $text = $cl.P.ToString()
                            $nl = $text.LastIndexOf("`n")
                            if ($nl -ge 0) {
                                foreach ($l in $text.Substring(0, $nl).Split("`n")) { Write-Line $l }
                                [void]$cl.P.Clear(); [void]$cl.P.Append($text.Substring($nl + 1))
                            } elseif ($cl.P.Length -gt 1048576) { Write-Line $text; [void]$cl.P.Clear() }
                        }
                    } elseif ($cl.C.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
                        $drop = $true   # readable with nothing to read = peer closed
                    } elseif (((Get-Date) - $cl.Last).TotalHours -gt 2) {
                        $drop = $true   # half-open after sleep/network loss; rsyslog reconnects
                    }
                } catch { $drop = $true }
                if ($drop) {
                    if ($cl.P.Length -gt 0) { Write-Line $cl.P.ToString() }
                    try { $cl.C.Close() } catch {}
                    $clients.Remove($cl)
                    Write-Self "connection from $($cl.Ip) closed"
                }
            }
            foreach ($w in $writers.Values) { $w.Flush() }
            if (((Get-Date) - $lastPrune).TotalHours -ge 24) { Remove-Old; $lastPrune = Get-Date }
            if (-not $busy) { Start-Sleep -Milliseconds 250 }
        }
    } catch {
        Write-Self ("error: " + $_.Exception.Message + " - restarting listener in 10 s")
    } finally {
        foreach ($cl in @($clients)) { try { $cl.C.Close() } catch {} }
        foreach ($w in @($writers.Values)) { try { $w.Dispose() } catch {} }
        $writers.Clear()
        if ($listener) { try { $listener.Stop() } catch {} }
    }
    Start-Sleep -Seconds 10
}
