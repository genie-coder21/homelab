# Analyze every tracked PowerShell file. All findings are printed; Error and ParseError fail
# the run. Warning and Information are style advice for Windows scripts that can't run on the
# Linux runner, so they are reported for review rather than treated as failures.
$ErrorActionPreference = 'Stop'
$files = @(git ls-files '*.ps1' '*.psm1' '*.psd1')
if ($files.Count -eq 0) { throw 'no PowerShell files found' }
$results = @(foreach ($file in $files) { Invoke-ScriptAnalyzer -Path $file })
$results | Sort-Object Severity, ScriptPath, Line |
    Format-Table Severity, RuleName, @{ n = 'Location'; e = { '{0}:{1}' -f $_.ScriptName, $_.Line } }, Message -Wrap |
    Out-String -Width 200 | Write-Output
$failing = @($results | Where-Object { $_.Severity -in 'Error', 'ParseError' })
Write-Output ('{0} files, {1} findings, {2} failing' -f $files.Count, $results.Count, $failing.Count)
if ($failing.Count -gt 0) { exit 1 }
