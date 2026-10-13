# guest-base-install.ps1 - shared base software for a kids' VM, run from the HOST via PowerShell Direct.
#   winget (App Installer, provisioned for all users) + TightVNC server (service, password
#   auth, firewall limited to the server + the Hyper-V host).
#
#   .\guest-base-install.ps1 -VMName <vm>
#
# Needs: the host user in "Hyper-V Administrators"; the guest admin credential and the VNC
# password stored as DPAPI files in $CredDir (never in docs or the repo).
param([Parameter(Mandatory)][string]$VMName)

# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
# Only these addresses may open the guest's VNC port: the server (Guacamole) and the host.
$VncAllowFrom = @('<SERVER_IP>', '<GAMING_PC_IP>')

$cred  = Import-Clixml "$CredDir\$VMName.xml"
$vncpw = (Import-Clixml "$CredDir\vnc-password.xml").GetNetworkCredential().Password

Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $vncpw, $VncAllowFrom -ScriptBlock {
    param($vncpw, $VncAllowFrom)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $dl = 'C:\ProgramData\kids-setup'; New-Item -ItemType Directory -Force $dl | Out-Null
    function Say($m) { "$(Get-Date -Format HH:mm:ss) $m" }

    # ---- winget: latest App Installer + its dependencies, provisioned system-wide
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $rel = Invoke-RestMethod https://api.github.com/repos/microsoft/winget-cli/releases/latest -Headers @{ 'User-Agent' = 'kids-setup' }
        Say "winget release $($rel.tag_name)"
        $get = { param($pattern) $a = $rel.assets | Where-Object name -match $pattern | Select-Object -First 1
                 $p = Join-Path $dl $a.name; if (-not (Test-Path $p)) { Invoke-WebRequest $a.browser_download_url -OutFile $p -UseBasicParsing }; $p }
        $bundle  = & $get '\.msixbundle$'
        $license = & $get 'License1\.xml$'
        $depzip  = & $get 'Dependencies\.zip$'
        Expand-Archive $depzip -DestinationPath "$dl\deps" -Force
        $deps = Get-ChildItem "$dl\deps" -Recurse -Include *.appx, *.msix | Where-Object FullName -match 'x64' | Select-Object -ExpandProperty FullName
        Say ("dependencies: " + (($deps | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
        Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $deps -LicensePath $license | Out-Null
        Say 'App Installer provisioned for all users'
        try { Add-AppxPackage -Path $bundle -DependencyPath $deps -ForceApplicationShutdown; Say 'App Installer registered for the current user' }
        catch { Say "per-user register deferred to next interactive sign-in: $($_.Exception.Message)" }
    } else { Say 'winget already present' }
    $wg = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory | Sort-Object Name -Descending | Select-Object -First 1
    Say "winget.exe: $(if ($wg -and (Test-Path "$($wg.FullName)\winget.exe")) { "$($wg.FullName)\winget.exe" } else { 'NOT FOUND' })"

    # ---- TightVNC server
    if (-not (Get-Service tvnserver -ErrorAction SilentlyContinue)) {
        $page = (Invoke-WebRequest https://www.tightvnc.com/download.php -UseBasicParsing).Content
        $rel  = [regex]::Match($page, '/download/[\d.]+/tightvnc-[\d.]+-gpl-setup-64bit\.msi').Value
        if (-not $rel) { throw 'TightVNC MSI link not found on download page' }
        $msi = Join-Path $dl (Split-Path $rel -Leaf)
        Invoke-WebRequest "https://www.tightvnc.com$rel" -OutFile $msi -UseBasicParsing
        Say "TightVNC: $(Split-Path $rel -Leaf)"
        $args = @('/i', $msi, '/quiet', '/norestart', 'ADDLOCAL=Server',
                  'SERVER_REGISTER_AS_SERVICE=1', 'SERVER_ADD_FIREWALL_EXCEPTION=0', 'SERVER_ALLOW_SAS=1',
                  'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
                  'SET_PASSWORD=1', "VALUE_OF_PASSWORD=$vncpw",
                  'SET_USECONTROLAUTHENTICATION=1', 'VALUE_OF_USECONTROLAUTHENTICATION=1',
                  'SET_CONTROLPASSWORD=1', "VALUE_OF_CONTROLPASSWORD=$vncpw",
                  'SET_REMOVEWALLPAPER=1', 'VALUE_OF_REMOVEWALLPAPER=0')
        $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
        Say "msiexec exit $($p.ExitCode)"
    } else { Say 'TightVNC already installed' }
    Set-Service tvnserver -StartupType Automatic; Start-Service tvnserver -ErrorAction SilentlyContinue
    Say "tvnserver: $((Get-Service tvnserver).Status) / $((Get-Service tvnserver).StartType)"

    # firewall: VNC only from the server (Guacamole) and the Hyper-V host
    Get-NetFirewallRule -DisplayName 'Kids VNC (server + host)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'Kids VNC (server + host)' -Direction Inbound -Protocol TCP -LocalPort 5900 `
        -RemoteAddress $VncAllowFrom -Action Allow -Profile Any | Out-Null
    Say "firewall: TCP 5900 allowed from $($VncAllowFrom -join ' + ') only"
    Say "listening: $([bool](Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue))"
}
