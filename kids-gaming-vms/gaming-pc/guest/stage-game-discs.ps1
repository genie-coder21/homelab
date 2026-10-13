# stage-game-discs.ps1 - unpack the archived game zips in <GAMES_ROOT>\<folder>\ into
# <GAMES_ROOT>\_discs\<game>\, keeping only what's needed to play: disc images + manuals.
# Inner .zip/.7z archives (some uploads nest them) are unpacked too (.7z via Windows 11's tar).
#   .\stage-game-discs.ps1
$root = '<GAMES_ROOT>'; $out = "$root\_discs"
$keep = '\.(iso|bin|cue|mdf|mds|img|ccd|sub|pdf|zip|7z)$'
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($z in Get-ChildItem $root -Recurse -Filter *.zip | Where-Object { $_.DirectoryName -notlike "$out*" }) {
    $game = [IO.Path]::GetFileNameWithoutExtension($z.Name)
    $dest = Join-Path $out $game
    if (Test-Path $dest) { "skip (already staged): $game"; continue }
    New-Item -ItemType Directory -Force $dest | Out-Null
    $a = [IO.Compression.ZipFile]::OpenRead($z.FullName)
    foreach ($e in $a.Entries | Where-Object { $_.Name -match $keep -and $_.Name -notmatch '_jp2\.zip$|Scans\.zip$|MDF\+MDS\.zip$' }) {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dest $e.Name), $true)
    }
    $a.Dispose()
    foreach ($inner in Get-ChildItem $dest -Include *.zip, *.7z -File -Recurse) {
        if ($inner.Extension -eq '.7z') { tar -xf $inner.FullName -C $dest } else { Expand-Archive $inner.FullName $dest -Force }
        Remove-Item $inner.FullName
    }
    $files = Get-ChildItem $dest -Recurse -File
    "{0,-72} {1,3} files {2,6:N0} MB  [{3}]" -f $game, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), (($files.Extension | Sort-Object -Unique) -join ' ')
}
