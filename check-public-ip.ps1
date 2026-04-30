# check-public-ip.ps1
# Monitors public IP and triggers Alibaba + MikroTik IPsec update on change.
# Must run on a machine on the same internet connection as the MikroTik.
# Requires PowerShell 7+ (for -SkipCertificateCheck).

$updaterUrl   = "https://120.79.157.95:8444/update-vpn-ip"
$sharedSecret = "381d6073d7435ce1caa2cd341da06c4a453031c0c7993b8b7bfb8f35d137cb32"
$mikrotikHost = "192.168.88.1"   # MikroTik LAN IP - no cloud needed, same LAN
$mikrotikUser = "admin"
$stateFile    = "$PSScriptRoot\last-public-ip.txt"
$logFile      = "$PSScriptRoot\ip-monitor.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Message"
    Add-Content $logFile $line
    Write-Host $line
}

# Resolve current public IP via OpenDNS (specific server bypasses tunnel)
try {
    $dns = Resolve-DnsName -Name "myip.opendns.com" -Server "208.67.222.222" -Type A -ErrorAction Stop
    $currentIp = $dns.IPAddress
} catch {
    Write-Log "Failed to resolve public IP via OpenDNS: $_" "ERROR"
    exit 1
}

if (-not $currentIp) {
    Write-Log "Empty IP from OpenDNS" "ERROR"
    exit 1
}

# Compare against stored IP
$lastIp = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { "" }

if ($currentIp -eq $lastIp) {
    Write-Log "Public IP unchanged: $currentIp" "DEBUG"
    exit 0
}

Write-Log "Public IP changed: $lastIp -> $currentIp - triggering update" "WARN"

# Notify China ECS to update Alibaba customer gateway
$body    = '{"newIp":"' + $currentIp + '"}'
$headers = @{ Authorization = "Bearer $sharedSecret" }

try {
    $response = Invoke-RestMethod -Uri $updaterUrl -Method Post `
        -Body $body -ContentType "application/json" `
        -Headers $headers -SkipCertificateCheck -ErrorAction Stop
} catch {
    Write-Log "HTTP request to vpn-updater failed: $_" "ERROR"
    exit 1
}

if ($response.status -ne "ok") {
    Write-Log "Updater returned error: $($response | ConvertTo-Json -Compress)" "ERROR"
    exit 1
}

Write-Log "Alibaba updated OK: $($response | ConvertTo-Json -Compress)"

# Update MikroTik IPsec identity via SSH (requires SSH key auth or password in ssh config)
if ($mikrotikHost) {
    try {
        $cmd1 = "/ip ipsec identity set [find peer=alibaba-peer] my-id=(""address:$currentIp"")"
        $cmd2 = "/ip ipsec installed-sa flush"
        ssh -o StrictHostKeyChecking=no "${mikrotikUser}@${mikrotikHost}" $cmd1
        ssh -o StrictHostKeyChecking=no "${mikrotikUser}@${mikrotikHost}" $cmd2
        Write-Log "MikroTik IPsec identity updated to $currentIp"
    } catch {
        Write-Log "Failed to update MikroTik via SSH: $_" "ERROR"
        exit 1
    }
} else {
    Write-Log "mikrotikHost not set - skipping MikroTik SSH update" "WARN"
}

# Persist new IP
Set-Content $stateFile $currentIp
Write-Log "Done - tunnel recovering"
