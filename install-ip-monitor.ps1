# install-ip-monitor.ps1
# Installs check-public-ip.ps1 as a Windows scheduled task (every 5 minutes).
# Run once as Administrator.

$taskName  = "OogiVpnIpMonitor"
$scriptPath = "$PSScriptRoot\check-public-ip.ps1"

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Error "PowerShell 7 (pwsh) not found. Install from https://github.com/PowerShell/PowerShell/releases"
    exit 1
}

$action = New-ScheduledTaskAction `
    -Execute "pwsh.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -Once -At (Get-Date)

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -Force

Write-Host "Scheduled task '$taskName' registered - runs every 5 minutes."
Write-Host "Log file: $PSScriptRoot\ip-monitor.log"
Write-Host ""
Write-Host "To run now:   Start-ScheduledTask -TaskName '$taskName'"
Write-Host "To stop:      Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
Write-Host "To view log:  Get-Content '$PSScriptRoot\ip-monitor.log' -Tail 50"
