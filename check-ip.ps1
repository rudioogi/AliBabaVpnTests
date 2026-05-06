$logFile = "$PSScriptRoot\ip-history.log"
$now = Get-Date
$currentIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()

# Append current IP to log
"$($now.ToString('o')) $currentIp" | Add-Content $logFile

# Check for an entry older than 1 hour
$oneHourAgo = $now.AddHours(-1)
$previousIp = $null

Get-Content $logFile | ForEach-Object {
    $parts = $_ -split ' ', 2
    if ($parts.Count -eq 2) {
        $entryTime = [datetime]::Parse($parts[0])
        if ($entryTime -le $oneHourAgo) {
            $previousIp = $parts[1].Trim()
        }
    }
}

Write-Host "Current IP : $currentIp"

if ($null -eq $previousIp) {
    Write-Host "No record older than 1 hour to compare against."
} elseif ($previousIp -eq $currentIp) {
    Write-Host "No change in the last hour (was: $previousIp)"
} else {
    Write-Host "IP CHANGED in the last hour!" -ForegroundColor Yellow
    Write-Host "Previous IP: $previousIp"
}
