<#
.SYNOPSIS
    One-time installer for the fleet pull agent.
    Run once, as Administrator, on each machine (or bake it into provisioning).

    It does three things:
      1. Copies Fleet-Agent.ps1 to C:\ProgramData\FleetAgent
      2. Registers a daily scheduled task (with random jitter so 700
         machines do not all hit the repo at the same second)
      3. Registers a second trigger at machine startup, so machines that
         were powered off during their daily slot catch up as soon as
         they come online.
#>

#Requires -RunAsAdministrator

$AgentRoot   = 'C:\ProgramData\FleetAgent'
$AgentScript = Join-Path $AgentRoot 'Fleet-Agent.ps1'
$TaskName    = 'FleetAgent-DailyPull'

# --- 1. Copy the agent into place ------------------------------------------

if (-not (Test-Path $AgentRoot)) {
    New-Item -Path $AgentRoot -ItemType Directory -Force | Out-Null
}
Copy-Item -Path (Join-Path $PSScriptRoot 'Fleet-Agent.ps1') `
          -Destination $AgentScript -Force
Write-Host "Agent copied to $AgentScript"

# --- 2. Build the scheduled task -------------------------------------------

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AgentScript`""

# Daily at 02:00, with up to 1 hour of random delay (the jitter).
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At '02:00'
$dailyTrigger.RandomDelay = 'PT1H'

# Also at startup (delayed 5 minutes so networking and Docker settle first).
# This is what lets intermittently-online machines catch up.
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$startupTrigger.Delay = 'PT5M'

# Run as SYSTEM, whether or not anyone is logged in.
$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4)

# --- 3. Register (replacing any older version of the task) ------------------

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $dailyTrigger, $startupTrigger `
    -Principal $principal `
    -Settings  $settings | Out-Null

Write-Host "Scheduled task '$TaskName' registered (daily 02:00 + startup)."
Write-Host "Install complete. First run: Start-ScheduledTask -TaskName '$TaskName'"
