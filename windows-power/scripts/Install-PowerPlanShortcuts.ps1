# Install-PowerPlanShortcuts.ps1 - (re)create the "Power Plans" desktop folder.
#
# Copies Set-PowerPlan.ps1 to %USERPROFILE%\Scripts\power\, draws one icon per plan,
# and makes a shortcut per plan on the desktop. Safe to re-run (overwrites its own files).
# No admin needed.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Dest    = Join-Path $env:USERPROFILE 'Scripts\power'
$Folder  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Power Plans'
$Plans   = @(   # name as shown by powercfg /list, letter + colour for the icon
    @{ Name = 'Power saver';          Label = 'Power Saver';          Letter = 'S'; Color = '#2E9E5B' },
    @{ Name = 'Balanced';             Label = 'Balanced';             Letter = 'B'; Color = '#2F6FD6' },
    @{ Name = 'Ultimate Performance'; Label = 'Ultimate Performance'; Letter = 'U'; Color = '#D64533' }
)

# Write a single-image .ico (256px PNG inside, which Windows scales down)
function New-LetterIcon([string]$Path, [string]$Hex, [string]$Letter) {
    $bmp = New-Object Drawing.Bitmap 256, 256
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($Hex))), 8, 8, 240, 240)
    $font = New-Object Drawing.Font 'Segoe UI', 140, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($Letter, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 6, 256, 256), $sf)
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $png = $ms.ToArray()
    $g.Dispose(); $bmp.Dispose()
    $w = New-Object IO.BinaryWriter ([IO.File]::Create($Path))
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)                     # ICONDIR
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)       # 256x256, no palette
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$png.Length); $w.Write([uint32]22)
    $w.Write($png); $w.Close()
}

New-Item -ItemType Directory -Force $Dest, $Folder | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Set-PowerPlan.ps1') $Dest -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($p in $Plans) {
    $ico = Join-Path $Dest ("{0}.ico" -f ($p.Label -replace ' ', ''))
    New-LetterIcon $ico $p.Color $p.Letter
    $lnk = $shell.CreateShortcut((Join-Path $Folder "$($p.Label).lnk"))
    $lnk.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\Set-PowerPlan.ps1`" -Plan `"$($p.Name)`""
    $lnk.WorkingDirectory = $Dest
    $lnk.IconLocation     = "$ico,0"
    $lnk.WindowStyle      = 7          # start minimised: no console flash
    $lnk.Description      = "Switch power plan to $($p.Label)"
    $lnk.Save()
    "created: $($p.Label)"
}
