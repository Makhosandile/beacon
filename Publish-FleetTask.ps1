<#
.SYNOPSIS
    Operator-side helper. Run this from your checkout of the fleet repo
    before committing, to keep hashes and the version number honest.
#>

$RepoRoot     = $PSScriptRoot
$ManifestPath = Join-Path $RepoRoot 'manifest.json'

$errors = @()
Get-ChildItem -Path (Join-Path $RepoRoot 'scripts') -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    
    if ($parseErrors.Count -gt 0) {
        $errors += "PARSE FAILURE in $($_.Name):"
        $parseErrors | ForEach-Object { $errors += "    line $($_.Extent.StartLineNumber): $($_.Message)" }
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "Fix the parse errors above before publishing. Nothing was changed."
}
Write-Host "All scripts parse cleanly." -ForegroundColor Green

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

foreach ($task in $manifest.tasks) {
    $artifact = Join-Path $RepoRoot $task.source
    if (-not (Test-Path $artifact)) {
        throw "Task '$($task.id)' references missing file: $($task.source)"
    }
    
    $task.sha256 = (Get-FileHash -Path $artifact -Algorithm SHA256).Hash
    Write-Host ("Hashed {0}  ->  {1}" -f $task.source, $task.sha256)
}

$manifest.manifest_version = $manifest.manifest_version + 1
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ManifestPath -Encoding UTF8

Write-Host ("Manifest is now version {0}. Ready to commit and push." -f $manifest.manifest_version) -ForegroundColor Green