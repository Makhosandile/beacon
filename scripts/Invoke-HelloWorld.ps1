$Output = "Hello World! The Fleet Agent ran this on $(Get-Date)"
Add-Content -Path "C:\ProgramData\FleetAgent\hello-world.log" -Value $Output