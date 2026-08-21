<#
.SYNOPSIS
    Operator-side helper. Run this from your checkout of the fleet repo
    before committing, to keep hashes and the version number honest.

    It does three things:
      1. Parses every .ps1 in scripts/ with the real PowerShell parser,
         so a syntax error can never reach the fleet.
      2. Recomputes the SHA-256 of every artifact referenced in the
         manifest and writes the correct value in, so hashes can never
         drift from the files.
      3. Bumps manifest_version by one.

    Typical flow:
        # edit scripts/, packages/, add a task entry to manifest.json
        .\Publish-FleetTask.ps1
        git add -A ; git commit -m "Deploy disk reclaim v3" ; git push
#>

$RepoRoot     = $PSScriptRoot
$ManifestPath = Join-Path $RepoRoot 'manifest.json'

# --- 1. Syntax-check every script before it can ship ------------------------

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

# --- 2. Refresh every hash in the manifest ----------------------------------

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

foreach ($task in $manifest.tasks) {
    $artifact = Join-Path $RepoRoot $task.source
    if (-not (Test-Path $artifact)) {
        throw "Task '$($task.id)' references missing file: $($task.source)"
    }
    $task.sha256 = (Get-FileHash -Path $artifact -Algorithm SHA256).Hash
    Write-Host ("Hashed {0}  ->  {1}" -f $task.source, $task.sha256)
}

# --- 3. Bump the version and write the manifest back -------------------------

$manifest.manifest_version = $manifest.manifest_version + 1
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ManifestPath -Encoding UTF8

Write-Host ("Manifest is now version {0}. Ready to commit and push." -f $manifest.manifest_version) -ForegroundColor Green
