# guest-debloat.ps1 - remove marketing, ads and AI features from a kids' VM (Windows 10), via PowerShell Direct.
# Machine-wide policies (HKLM) + the Default user profile (so future kid accounts inherit it) + current admin user.
# Keeps Microsoft Store + Xbox apps (Minecraft needs them), Photos, Calculator, Paint, Camera.
#   .\guest-debloat.ps1 -VMName <vm>
param([Parameter(Mandatory)][string]$VMName)
# ---- site config ---------------------------------------------------------------
# Folder holding one DPAPI-encrypted guest-admin credential per VM (<vm>.xml), created
# with Export-Clixml by the host user. Only that user, on that machine, can decrypt it.
$CredDir = '<GUEST_CRED_DIR>'
# ---------------------------------------------------------------------------------
$cred = Import-Clixml "$CredDir\$VMName.xml"

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    function Set-Reg($path, $name, $value, $type = 'DWord') {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
    }
    $P = 'HKLM:\SOFTWARE\Policies\Microsoft'

    # --- AI: Copilot, Cortana, web/Bing search
    Set-Reg "$P\Windows\WindowsCopilot" TurnOffWindowsCopilot 1
    Set-Reg "$P\Windows\Windows Search" AllowCortana 0
    Set-Reg "$P\Windows\Windows Search" DisableWebSearch 1
    Set-Reg "$P\Windows\Windows Search" ConnectedSearchUseWeb 0
    Set-Reg "$P\Windows\Explorer" DisableSearchBoxSuggestions 1

    # --- marketing / consumer content / ads
    Set-Reg "$P\Windows\CloudContent" DisableWindowsConsumerFeatures 1
    Set-Reg "$P\Windows\CloudContent" DisableSoftLanding 1
    Set-Reg "$P\Windows\CloudContent" DisableConsumerAccountStateContent 1
    Set-Reg "$P\Windows\CloudContent" DisableCloudOptimizedContent 1
    Set-Reg "$P\Windows\CloudContent" DisableTailoredExperiencesWithDiagnosticData 1
    Set-Reg "$P\Windows\AdvertisingInfo" DisabledByGroupPolicy 1
    Set-Reg "$P\Windows\Windows Feeds" EnableFeeds 0                     # News and Interests widget
    Set-Reg "$P\Windows\DataCollection" AllowTelemetry 1                 # 'Required' (lowest Home allows)
    Set-Reg "$P\Windows\DataCollection" DoNotShowFeedbackNotifications 1
    Set-Reg "$P\Windows\OneDrive" DisableFileSyncNGSC 1
    Set-Reg "$P\Windows\System" EnableActivityFeed 0

    # --- Edge: no Copilot/sidebar, shopping, rewards, news feed, first-run pitch
    $E = "$P\Edge"
    foreach ($kv in @{ HubsSidebarEnabled = 0; CopilotCDPPageContext = 0; CopilotPageContext = 0; EdgeShoppingAssistantEnabled = 0
                       ShowMicrosoftRewards = 0; NewTabPageContentEnabled = 0; NewTabPageHideDefaultTopSites = 1
                       NewTabPageQuickLinksEnabled = 0; SpotlightExperiencesAndRecommendationsEnabled = 0
                       ShowRecommendationsEnabled = 0; PersonalizationReportingEnabled = 0; HideFirstRunExperience = 1
                       EdgeCollectionsEnabled = 0; DiscoverPageContextEnabled = 0 }.GetEnumerator()) { Set-Reg $E $kv.Key $kv.Value }

    # --- per-user suggestion/ad switches: current admin + Default profile (future accounts)
    $cdm = @{ ContentDeliveryAllowed = 0; OemPreInstalledAppsEnabled = 0; PreInstalledAppsEnabled = 0; PreInstalledAppsEverEnabled = 0
              SilentInstalledAppsEnabled = 0; SoftLandingEnabled = 0; SystemPaneSuggestionsEnabled = 0; RotatingLockScreenEnabled = 0
              RotatingLockScreenOverlayEnabled = 0; 'SubscribedContent-310093Enabled' = 0; 'SubscribedContent-338387Enabled' = 0
              'SubscribedContent-338388Enabled' = 0; 'SubscribedContent-338389Enabled' = 0; 'SubscribedContent-338393Enabled' = 0
              'SubscribedContent-353694Enabled' = 0; 'SubscribedContent-353696Enabled' = 0; 'SubscribedContent-353698Enabled' = 0 }
    function Set-UserPrefs($root) {
        foreach ($kv in $cdm.GetEnumerator()) { Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" $kv.Key $kv.Value }
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Search" BingSearchEnabled 0
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Search" CortanaConsent 0
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowCortanaButton 0
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowSyncProviderNotifications 0
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Search" SearchboxTaskbarMode 1          # icon, not a big box
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Feeds" ShellFeedsTaskbarViewMode 2      # news widget off
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled 0
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Privacy" TailoredExperiencesWithDiagnosticDataEnabled 0
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" ScoobeSystemSettingEnabled 0  # "finish setting up" nag
        Set-Reg "$root\Software\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot 1
        Set-Reg "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowCopilotButton 0
        Remove-ItemProperty "$root\Software\Microsoft\Windows\CurrentVersion\Run" -Name OneDriveSetup -ErrorAction SilentlyContinue
    }
    Set-UserPrefs 'HKCU:'
    reg.exe load HKU\KidsDefault C:\Users\Default\NTUSER.DAT | Out-Null
    Set-UserPrefs 'Registry::HKEY_USERS\KidsDefault'
    Remove-ItemProperty 'Registry::HKEY_USERS\KidsDefault\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDriveSetup -ErrorAction SilentlyContinue
    [gc]::Collect(); Start-Sleep 2; reg.exe unload HKU\KidsDefault | Out-Null
    'policies + user prefs applied (current user + Default profile)'

    # --- remove preinstalled junk (installed + provisioned for new users)
    $junk = 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.SkypeApp', 'Microsoft.YourPhone',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer',
            'Microsoft.Office.OneNote', 'Microsoft.Wallet', 'Microsoft.Messaging', 'Microsoft.OneConnect', 'Microsoft.Print3D',
            'Microsoft.549981C3F5F10', 'Microsoft.Copilot', 'Microsoft.WindowsCommunicationsApps', 'Microsoft.ZuneVideo',
            'king.com.*', '*CandyCrush*', 'SpotifyAB.SpotifyMusic', 'Disney.*', 'Microsoft.MicrosoftStickyNotes'
    $removed = @()
    foreach ($j in $junk) {
        Get-AppxPackage -AllUsers -Name $j -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; $removed += $_.Name } catch {} }
        Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $j | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null; $removed += "$($_.DisplayName) (provisioned)" }
    }
    "removed: " + (($removed | Sort-Object -Unique) -join ', ')

    # --- OneDrive
    $od = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"; if (-not (Test-Path $od)) { $od = "$env:SystemRoot\System32\OneDriveSetup.exe" }
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path $od) { Start-Process $od -ArgumentList '/uninstall' -Wait; 'OneDrive uninstalled' }
    "kept: " + ((Get-AppxPackage -AllUsers | Where-Object Name -match 'WindowsStore|Xbox|Photos|Calculator|Paint|Camera' | Select-Object -ExpandProperty Name -Unique) -join ', ')
}
