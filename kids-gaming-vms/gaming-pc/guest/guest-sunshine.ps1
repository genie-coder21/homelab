# guest-sunshine.ps1 - install Sunshine (Moonlight host) in a kids' VM, from the HOST via PowerShell Direct.
# Per VM (never cloned: Sunshine keeps a unique identity). No GPU in these VMs -> software (x264) encoding.
# Web UI login is generated once (random), shared by the kids' VMs, and DPAPI-stored in $CredDir.
# Sunshine adds no firewall rules of its own: allow its documented TCP/UDP ports (plus mDNS,
# UDP 5353, for Moonlight discovery) from the LAN in the guest firewall separately.
#   .\guest-sunshine.ps1 -VMName <vm>
param([Parameter(Mandatory)][string]$VMName)
# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
$cred = Import-Clixml "$CredDir\$VMName.xml"
$wf = "$CredDir\sunshine-webui.xml"
if (-not (Test-Path $wf)) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $b = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    New-Object PSCredential 'sunshine', (ConvertTo-SecureString (-join ($b | ForEach-Object { $chars[$_ % $chars.Length] })) -AsPlainText -Force) | Export-Clixml $wf
}
$web = (Import-Clixml $wf).GetNetworkCredential()

Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $web.UserName, $web.Password -ScriptBlock {
    param($u, $p)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $dl = 'C:\ProgramData\kids-setup'; $dir = 'C:\Program Files\Sunshine'
    function Say($m) { "$(Get-Date -Format HH:mm:ss) $m" }
    if (-not (Test-Path "$dir\sunshine.exe")) {
        $rel = Invoke-RestMethod https://api.github.com/repos/LizardByte/Sunshine/releases/latest -Headers @{ 'User-Agent' = 'kids-setup' }
        $a = $rel.assets | Where-Object name -match 'Windows-AMD64-installer\.msi$' | Select-Object -First 1
        $msi = Join-Path $dl $a.name; Invoke-WebRequest $a.browser_download_url -OutFile $msi -UseBasicParsing
        $r = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
        Say "Sunshine $($rel.tag_name) installer exit $($r.ExitCode)"
    }
    # config: software encoding, friendly name, web UI reachable from the LAN
    $conf = "$dir\config\sunshine.conf"; New-Item -ItemType Directory -Force (Split-Path $conf) | Out-Null
    $lines = @(Get-Content $conf -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*(encoder|sunshine_name|origin_web_ui_allowed)\s*=' })
    $lines += 'encoder = software', "sunshine_name = $env:COMPUTERNAME", 'origin_web_ui_allowed = lan'
    Set-Content $conf $lines -Encoding ASCII
    Push-Location $dir; & .\sunshine.exe --creds $u $p 2>&1 | Out-Null; Pop-Location
    $svc = Get-Service SunshineService -ErrorAction SilentlyContinue
    if ($svc) { Set-Service SunshineService -StartupType Automatic; Restart-Service SunshineService -Force }
    Start-Sleep 8
    Say "service: $($svc.Name) $((Get-Service SunshineService -ErrorAction SilentlyContinue).Status)"
    Say "listening: " + ((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in 47984, 47989, 47990 | Select-Object -ExpandProperty LocalPort -Unique) -join ',')
    Say "firewall rules: " + ((Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -match 'Sunshine' | Select-Object -ExpandProperty DisplayName -Unique) -join ', ')
}
