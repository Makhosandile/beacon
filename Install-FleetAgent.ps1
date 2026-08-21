<#
.SYNOPSIS
    One-time installer for the fleet pull agent.
#>
#Requires -RunAsAdministrator

# ============================================================
#  1. SHARED FUNCTIONS
# ============================================================
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
        return $identity
    }

    # 2. Local Application API
    try {
        $config = Invoke-RestMethod -Uri 'http://localhost:7000/config' -TimeoutSec 5 -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($config.site)) {
            $identity.Site = $config.site
            $identity.Project = $config.project
            return $identity
        }
    }
    catch {}

    # 3. JSON Fallback
    $startupJson = 'C:\qure\startup.json'
    if (Test-Path $startupJson) {
        try {
            $config = Get-Content $startupJson -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($config.site)) {
                $identity.Site = $config.site
                $identity.Project = $config.project
                return $identity
            }
        }
        catch {}
    }

    return $identity
}

# ============================================================
#  2. INSTALLATION LOGIC
# ============================================================
$AgentRoot   = 'C:\ProgramData\FleetAgent'
$AgentScript = Join-Path $AgentRoot 'Fleet-Agent.ps1'
$TaskName    = 'FleetAgent-DailyPull'

if (-not (Test-Path $AgentRoot)) {
    New-Item -Path $AgentRoot -ItemType Directory -Force | Out-Null
}

Copy-Item -Path (Join-Path $PSScriptRoot 'Fleet-Agent.ps1') `
          -Destination $AgentScript -Force
Write-Host "Agent copied to $AgentScript"

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AgentScript`""

$dailyTrigger = New-ScheduledTaskTrigger -Daily -At '02:00'
$dailyTrigger.RandomDelay = 'PT1H'

$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$startupTrigger.Delay = 'PT5M'

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $dailyTrigger, $startupTrigger `
    -Principal $principal `
    -Settings  $settings | Out-Null

Write-Host "Scheduled task '$TaskName' registered (daily 02:00 + startup)."


# ============================================================
#  3. VERIFY AND DISPLAY IDENTITY
# ============================================================
$identity = Get-MachineIdentity

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "      Fleet Agent Successfully Deployed!         " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Machine Name : $($identity.Machine)" -ForegroundColor White
Write-Host "  Assigned Site: $($identity.Site)" -ForegroundColor White
Write-Host "  Project      : $($identity.Project)" -ForegroundColor White
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To monitor the first run, execute:"
Write-Host "Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Yellow
Write-Host "Get-Content -Path 'C:\ProgramData\FleetAgent\agent.log' -Wait" -ForegroundColor Yellow