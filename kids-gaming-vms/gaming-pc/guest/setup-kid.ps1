# setup-kid.ps1 - give a kids' VM its child account and game discs, from the HOST via PowerShell Direct.
#  * standard (non-admin) local account, NO password, signs in automatically at boot
#  * no screen lock / screen-off / sleep inside the VM (the host decides when VMs sleep)
#  * copies staged disc images (<GamesRoot>\_discs\<game>) to C:\Games\<game> + a desktop
#    shortcut "Game Discs". Installing the old CD games is left to a person (interactive installers).
#   .\setup-kid.ps1 -VMName <vm> -Kid kid1 -Folders 'kid1','both'
param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$Kid, [string[]]$Folders, [string[]]$Skip = @())
# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
$root = '<GAMES_ROOT>'      # host folder of game archives, one sub-folder per kid/shared set
$cred = Import-Clixml "$CredDir\$VMName.xml"

# 1. account, auto sign-in, no lock
Invoke-Command -VMName $VMName -Credential $cred -ArgumentList $Kid -ScriptBlock {
    param($Kid)
    if (-not (Get-LocalUser $Kid -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $Kid -NoPassword -FullName $Kid -AccountNeverExpires | Out-Null
        Set-LocalUser -Name $Kid -PasswordNeverExpires $true
        Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545') -Member $Kid      # Users (standard)
    }
    $w = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $w AutoAdminLogon '1'; Set-ItemProperty $w DefaultUserName $Kid
    Set-ItemProperty $w DefaultDomainName $env:COMPUTERNAME; Set-ItemProperty $w DefaultPassword ''
    New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' NoLockScreen 1 -Type DWord
    powercfg /change monitor-timeout-ac 0; powercfg /change standby-timeout-ac 0; powercfg /change hibernate-timeout-ac 0
    powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0; powercfg /setactive SCHEME_CURRENT
    "$env:COMPUTERNAME: account '$Kid' (standard, no password), auto sign-in on, lock/sleep off. Admin: " +
        [bool](Get-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544') | Where-Object Name -like "*\$Kid")
}

# 2. game discs
$s = New-PSSession -VMName $VMName -Credential $cred
Invoke-Command -Session $s { New-Item -ItemType Directory -Force C:\Games | Out-Null }
foreach ($f in $Folders) {
    foreach ($z in Get-ChildItem "$root\$f" -Filter *.zip) {
        $game = [IO.Path]::GetFileNameWithoutExtension($z.Name)
        if ($Skip -contains $game) { "skip: $game"; continue }
        $pretty = ($game -replace '[_-]+', ' ' -replace '\s+', ' ').Trim()
        $exists = Invoke-Command -Session $s -ArgumentList $pretty { param($p) Test-Path "C:\Games\$p" }
        if (-not $exists) { Copy-Item "$root\_discs\$game" -Destination "C:\Games\$pretty" -ToSession $s -Recurse }
        "copied: $pretty"
    }
}
Invoke-Command -Session $s {
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut('C:\Users\Public\Desktop\Game Discs.lnk'); $l.TargetPath = 'C:\Games'; $l.IconLocation = 'imageres.dll,25'; $l.Save()
    "C:\Games: $((Get-ChildItem C:\Games -Directory).Count) games, $([math]::Round((Get-ChildItem C:\Games -Recurse -File | Measure-Object Length -Sum).Sum/1GB,2)) GB"
}
Remove-PSSession $s
