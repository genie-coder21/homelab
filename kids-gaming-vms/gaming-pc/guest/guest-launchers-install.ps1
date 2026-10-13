# guest-launchers-install.ps1 - Steam, Epic Games Launcher and WinCDEmu (mounts BIN/CUE/MDF disc
# images; Windows 10 only mounts ISO natively), installed silently from the HOST via PowerShell Direct.
#   .\guest-launchers-install.ps1 -VMName <vm>
# Note: WinCDEmu's installer stops on a driver-trust prompt when run unattended; if it hangs,
# kill it and run the downloaded installer by hand inside the guest once.
param([Parameter(Mandatory)][string]$VMName)
# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
$cred = Import-Clixml "$CredDir\$VMName.xml"
$t = 0; while ((Get-VMIntegrationService -VMName $VMName -Name Heartbeat).PrimaryStatusDescription -ne 'OK' -and $t -lt 600) { Start-Sleep 10; $t += 10 }

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $dl = 'C:\ProgramData\kids-setup'; New-Item -ItemType Directory -Force $dl | Out-Null
    function Say($m) { "$(Get-Date -Format HH:mm:ss) $m" }
    function Get-File($url, $name) { $p = Join-Path $dl $name; Invoke-WebRequest $url -OutFile $p -UseBasicParsing; $p }

    # Steam (NSIS installer, /S = silent)
    if (-not (Test-Path 'C:\Program Files (x86)\Steam\steam.exe')) {
        $p = Get-File 'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe' 'SteamSetup.exe'
        $r = Start-Process $p -ArgumentList '/S' -Wait -PassThru; Say "Steam installer exit $($r.ExitCode)"
    }
    Say "Steam present: $(Test-Path 'C:\Program Files (x86)\Steam\steam.exe')"

    # Epic Games Launcher (MSI)
    $epic = 'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'
    if (-not (Test-Path $epic)) {
        $p = Get-File 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi' 'EpicInstaller.msi'
        $r = Start-Process msiexec.exe -ArgumentList "/i `"$p`" /qn /norestart" -Wait -PassThru; Say "Epic msiexec exit $($r.ExitCode)"
    }
    Say "Epic present: $(Test-Path $epic)"

    # WinCDEmu
    if (-not (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -match 'WinCDEmu')) {
        $rel = Invoke-RestMethod https://api.github.com/repos/sysprogs/WinCDEmu/releases/latest -Headers @{ 'User-Agent' = 'kids-setup' }
        $a = $rel.assets | Where-Object name -match '^WinCDEmu-[\d.]+\.exe$' | Select-Object -First 1
        if ($a) {
            $p = Get-File $a.browser_download_url $a.name
            $r = Start-Process $p -ArgumentList '/UNATTENDED' -Wait -PassThru; Say "WinCDEmu $($a.name) exit $($r.ExitCode)"
        } else { Say "WinCDEmu: no installer asset in release $($rel.tag_name)" }
    }
    Say ("WinCDEmu present: " + [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -match 'WinCDEmu'))
    Say "Windows Update loop: " + ((Get-Content "$dl\wu.log" -ErrorAction SilentlyContinue | Select-Object -Last 1))
}
