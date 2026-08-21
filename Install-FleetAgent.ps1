<#
.SYNOPSIS
    One-time installer for the fleet pull agent.
#>
#Requires -RunAsAdministrator

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
Write-Host "Install complete. First run: Start-ScheduledTask -TaskName '$TaskName'"