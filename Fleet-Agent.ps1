<#
.SYNOPSIS
    Fleet pull agent.
#>

# ============================================================
#  CONFIGURATION
# ============================================================
$RepoBase      = 'https://raw.githubusercontent.com/Makhosandile/beacon/main'
$ReportUrl     = 'https://script.google.com/macros/s/AKfycbwsbVhGeW74KSvV5hmSUdaO9e7gw0MbAkEAmHj5dwAMIGOSh-bM0ky8QEURY3LMVXfP/exec'
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
    $temp = "$StateFile.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $temp -Encoding UTF8
    Move-Item -Path $temp -Destination $StateFile -Force
}

function Get-MachineIdentity {
    $identity = [pscustomobject]@{
        Machine = $env:COMPUTERNAME
        Site    = 'unknown'
        Project = 'unknown'
    }

    # 1. Environment Variables
    if (-not [string]::IsNullOrWhiteSpace($env:FLEET_SITE)) {
        $identity.Site = $env:FLEET_SITE
        $identity.Project = $env:FLEET_PROJECT
        Write-Log "Identity sourced from Environment Variables."
        return $identity
    }

    # 2. Local Application API
    try {
        $config = Invoke-RestMethod -Uri 'http://localhost:7000/config' -TimeoutSec 5 -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($config.api.sitename)) {
            $identity.Site = $config.api.sitename
            Write-Log "Identity sourced from local API."
            return $identity
        }
    }
    catch {
        Write-Log "localhost:7000/config unavailable or invalid, trying JSON fallback."
    }

    # 3. JSON Fallback
    $startupJson = 'C:\qure\startup.json'
    if (Test-Path $startupJson) {
        try {
            $config = Get-Content $startupJson -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($config.api.sitename)) {
                $identity.Site = $config.api.sitename
                Write-Log "Identity sourced from startup.json."
                return $identity
            }
        }
        catch {
            Write-Log "WARNING: Could not parse $startupJson. It may be corrupt or empty."
        }
    }

    Write-Log "WARNING: All identity sources failed. Defaulting to 'unknown'."
    return $identity
}

function Test-TargetMatch {
    param($Task, $Identity)
    $projectOk = ($Task.targets.projects -contains '*') -or
                 ($Task.targets.projects -contains $Identity.Project)
    $siteOk    = ($Task.targets.sites -contains '*') -or
                 ($Task.targets.sites -contains $Identity.Site)
    return ($projectOk -and $siteOk)
}

function Test-InsideWindow {
    param([string]$Window)
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
        $localScript = Join-Path $WorkDir (Split-Path $Task.source -Leaf)
        Get-VerifiedFile $Task.source $Task.sha256 $localScript
        $result = Invoke-TaskScript $localScript $Task.arguments $Task.timeout_minutes
    }
    elseif ($Task.type -eq 'package') {
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
foreach ($dir in @($AgentRoot, $WorkDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

Write-Log "===== Agent run starting ====="
$identity = Get-MachineIdentity
Write-Log "Identity: machine=$($identity.Machine) site=$($identity.Site) project=$($identity.Project)"

try {
    $manifestUrl = "$RepoBase/manifest.json?t=$(Get-Date -UFormat %s)"
    $rawText = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 60
    $manifest = $rawText.Substring($rawText.IndexOf('{')) | ConvertFrom-Json
}
catch {
    Write-Log "Could not fetch manifest: $($_.Exception.Message). Exiting; will retry tomorrow."
    Send-Report $identity 'heartbeat' 'offline-fetch-failed' $_.Exception.Message
    exit 0
}

$state = Get-State
Write-Log "Manifest version: remote=$($manifest.manifest_version) local=$($state.manifest_version)"
Send-Report $identity 'heartbeat' 'checked-in' "manifest version $($manifest.manifest_version)"

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
            $state.applied_tasks = @($state.applied_tasks) + $task.id
            Save-State $state
        }
    }
    catch {
        Write-Log "Task '$($task.id)' error: $($_.Exception.Message)"
        Send-Report $identity $task.id 'error' $_.Exception.Message
    }
}

$state.manifest_version = $manifest.manifest_version
Save-State $state
Write-Log "===== Agent run complete ====="