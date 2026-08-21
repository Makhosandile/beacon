<#
.SYNOPSIS
    Fleet pull agent.
    Runs once per day (scheduled task). Checks the central GitHub repo for
    a new manifest, downloads and applies any tasks that target this machine,
    and reports the outcome to a central endpoint.

.NOTES
    Design rules kept deliberately simple:
      - The repo is the source of truth. The agent only pulls, never listens.
      - Every artifact is SHA-256 verified before it is executed.
      - Every task has an id. A task id is applied at most once (run_once),
        tracked in local state, so daily polling is always safe.
      - Machines that were offline simply catch up on their next run.
#>

# ============================================================
#  CONFIGURATION - edit these for your fleet
# ============================================================

$RepoBase      = 'https://raw.githubusercontent.com/YOUR-ORG/fleet-repo/main'
$ReportUrl     = 'https://script.google.com/macros/s/YOUR-DEPLOYMENT-ID/exec'
$AgentRoot     = 'C:\ProgramData\FleetAgent'
$StateFile     = Join-Path $AgentRoot 'state.json'
$LogFile       = Join-Path $AgentRoot 'agent.log'
$WorkDir       = Join-Path $AgentRoot 'work'

# ============================================================
#  SMALL HELPERS
# ============================================================

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Get-State {
    # Local state remembers: last manifest version seen, and which task ids
    # have already been applied on this machine.
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{
        manifest_version = 0
        applied_tasks    = @()
    }
}

function Save-State {
    param($State)
    # Write to a temp file then rename, so a crash mid-write
    # never leaves a corrupt state file behind.
    $temp = "$StateFile.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $temp -Encoding UTF8
    Move-Item -Path $temp -Destination $StateFile -Force
}

function Get-MachineIdentity {
    # Ask the local application who we are (site / project).
    # Fall back to startup.json if the app is not running.
    try {
        $config = Invoke-RestMethod -Uri 'http://localhost:7000/config' -TimeoutSec 10
        return [pscustomobject]@{
            Machine = $env:COMPUTERNAME
            Site    = $config.site
            Project = $config.project
        }
    }
    catch {
        Write-Log "localhost:7000/config unavailable, trying startup.json"
    }

    $startupJson = 'C:\qure\startup.json'
    if (Test-Path $startupJson) {
        $config = Get-Content $startupJson -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            Machine = $env:COMPUTERNAME
            Site    = $config.site
            Project = $config.project
        }
    }

    # Last resort: identify by machine name only.
    return [pscustomobject]@{
        Machine = $env:COMPUTERNAME
        Site    = 'unknown'
        Project = 'unknown'
    }
}

function Test-TargetMatch {
    param($Task, $Identity)
    # A task matches if BOTH its project list and site list
    # contain '*' or contain this machine's value.
    $projectOk = ($Task.targets.projects -contains '*') -or
                 ($Task.targets.projects -contains $Identity.Project)
    $siteOk    = ($Task.targets.sites -contains '*') -or
                 ($Task.targets.sites -contains $Identity.Site)
    return ($projectOk -and $siteOk)
}

function Test-InsideWindow {
    param([string]$Window)
    # Window format: "01:00-05:00". Empty window = run any time.
    if ([string]::IsNullOrWhiteSpace($Window)) { return $true }

    $parts = $Window.Split('-')
    $start = [datetime]::ParseExact($parts[0], 'HH:mm', $null)
    $end   = [datetime]::ParseExact($parts[1], 'HH:mm', $null)
    $now   = Get-Date

    $today = $now.Date
    $start = $today.Add($start.TimeOfDay)
    $end   = $today.Add($end.TimeOfDay)

    return ($now -ge $start -and $now -le $end)
}

function Get-VerifiedFile {
    param([string]$RelativePath, [string]$ExpectedSha256, [string]$Destination)
    # Download to a temp path, verify the hash, then rename into place.
    # We never execute a file that has not passed verification.
    $url  = "$RepoBase/$RelativePath"
    $temp = "$Destination.download"

    Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing

    $actual = (Get-FileHash -Path $temp -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpper()) {
        Remove-Item $temp -Force
        throw "Hash mismatch for $RelativePath. Expected $ExpectedSha256, got $actual."
    }

    Move-Item -Path $temp -Destination $Destination -Force
}

function Invoke-TaskScript {
    param([string]$ScriptPath, [string]$Arguments, [int]$TimeoutMinutes)
    # Run the task in a child PowerShell process with a timeout,
    # so a hung script cannot hang the agent itself.
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $Arguments"

    $process = Start-Process -FilePath 'powershell.exe' `
                             -ArgumentList $psArgs `
                             -PassThru -WindowStyle Hidden

    $finished = $process.WaitForExit($TimeoutMinutes * 60 * 1000)
    if (-not $finished) {
        $process.Kill()
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false }
}

function Send-Report {
    param($Identity, [string]$TaskId, [string]$Status, [string]$Detail)
    # Best-effort telemetry. A failed report never blocks the agent.
    $body = @{
        machine  = $Identity.Machine
        site     = $Identity.Site
        project  = $Identity.Project
        task_id  = $TaskId
        status   = $Status
        detail   = $Detail
        time_utc = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri $ReportUrl -Method Post -Body $body `
                          -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    }
    catch {
        Write-Log "Report failed for '$TaskId': $($_.Exception.Message)"
    }
}

# ============================================================
#  TASK EXECUTION
# ============================================================

function Invoke-FleetTask {
    param($Task, $Identity)

    Write-Log "Applying task '$($Task.id)' (type: $($Task.type))"
    Send-Report $Identity $Task.id 'started' ''

    if ($Task.type -eq 'script') {
        # --- Script task: download one .ps1 and run it ---
        $localScript = Join-Path $WorkDir (Split-Path $Task.source -Leaf)
        Get-VerifiedFile $Task.source $Task.sha256 $localScript

        $result = Invoke-TaskScript $localScript $Task.arguments $Task.timeout_minutes
    }
    elseif ($Task.type -eq 'package') {
        # --- Package task: download a zip, extract, run its installer ---
        $localZip    = Join-Path $WorkDir "$($Task.id).zip"
        $extractDir  = Join-Path $WorkDir $Task.id
        Get-VerifiedFile $Task.source $Task.sha256 $localZip

        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -Path $localZip -DestinationPath $extractDir

        $installer = Join-Path $extractDir $Task.install_command
        $result = Invoke-TaskScript $installer $Task.arguments $Task.timeout_minutes
    }
    else {
        throw "Unknown task type: $($Task.type)"
    }

    if ($result.TimedOut) {
        Write-Log "Task '$($Task.id)' TIMED OUT after $($Task.timeout_minutes) minutes"
        Send-Report $Identity $Task.id 'timeout' "killed after $($Task.timeout_minutes)m"
        return $false
    }

    if ($result.ExitCode -ne 0) {
        Write-Log "Task '$($Task.id)' FAILED with exit code $($result.ExitCode)"
        Send-Report $Identity $Task.id 'failed' "exit code $($result.ExitCode)"
        return $false
    }

    Write-Log "Task '$($Task.id)' completed successfully"
    Send-Report $Identity $Task.id 'success' ''
    return $true
}

# ============================================================
#  MAIN
# ============================================================

# Make sure our folders exist.
foreach ($dir in @($AgentRoot, $WorkDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

Write-Log "===== Agent run starting ====="

$identity = Get-MachineIdentity
Write-Log "Identity: machine=$($identity.Machine) site=$($identity.Site) project=$($identity.Project)"

# 1. Fetch the manifest (cache-busting query param avoids stale CDN copies).
try {
    $manifestUrl = "$RepoBase/manifest.json?t=$(Get-Date -UFormat %s)"
    $manifest = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 60
}
catch {
    Write-Log "Could not fetch manifest: $($_.Exception.Message). Exiting; will retry tomorrow."
    Send-Report $identity 'heartbeat' 'offline-fetch-failed' $_.Exception.Message
    exit 0
}

# 2. Compare against what we last saw (informational - we still evaluate
#    every task below, because a task may have been deferred yesterday by
#    its time window and needs another chance today).
$state = Get-State
Write-Log "Manifest version: remote=$($manifest.manifest_version) local=$($state.manifest_version)"
Send-Report $identity 'heartbeat' 'checked-in' "manifest version $($manifest.manifest_version)"

# 3. Work through each task in the manifest. The applied_tasks list in local
#    state is what makes this loop safe to run every single day.
foreach ($task in $manifest.tasks) {

    if ($state.applied_tasks -contains $task.id -and $task.run_once) {
        Write-Log "Skipping '$($task.id)': already applied on this machine."
        continue
    }

    if (-not (Test-TargetMatch $task $identity)) {
        Write-Log "Skipping '$($task.id)': does not target this machine."
        continue
    }

    if (-not (Test-InsideWindow $task.window)) {
        Write-Log "Skipping '$($task.id)': outside allowed window '$($task.window)'. Will retry next run."
        continue
    }

    try {
        $succeeded = Invoke-FleetTask $task $identity
        if ($succeeded -and $task.run_once) {
            # Record success so daily polling never re-runs this task.
            $state.applied_tasks = @($state.applied_tasks) + $task.id
            Save-State $state
        }
    }
    catch {
        Write-Log "Task '$($task.id)' error: $($_.Exception.Message)"
        Send-Report $identity $task.id 'error' $_.Exception.Message
        # Continue with the next task; one bad task must not block the rest.
    }
}

# 4. Remember the manifest version we processed (used for fleet-wide
#    "how far behind is each machine" reporting in the registry).
$state.manifest_version = $manifest.manifest_version
Save-State $state

Write-Log "===== Agent run complete ====="
