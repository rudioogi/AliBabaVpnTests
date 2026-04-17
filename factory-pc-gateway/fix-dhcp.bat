@echo off
setlocal
echo.
echo  ╔═══════════════════════════════════════════════════════╗
echo  ║  OogiCam Factory QA — Fix Android DHCP                ║
echo  ╚═══════════════════════════════════════════════════════╝
echo.
echo  Use this when Android devices get stuck at "Obtaining IP address".
echo.

:: ── Check admin ──────────────────────────────────────────
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo  [ERROR] Run this script as Administrator.
    pause
    exit /b 1
)

:: ── Step 1: Set hotspot adapter to Private ───────────────
echo  [1/3] Setting hotspot adapter to Private network profile...
powershell -Command "$a = Get-NetIPAddress -IPAddress 192.168.137.1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceAlias; if ($a) { Set-NetConnectionProfile -InterfaceAlias $a -NetworkCategory Private -ErrorAction SilentlyContinue; Write-Host '       Set to Private:' $a } else { Write-Host '       [WARN] Hotspot adapter not found — is Mobile Hotspot enabled?' }"
echo.

:: ── Step 2: Re-open DHCP + DNS firewall rules ─────────────
echo  [2/3] Refreshing DHCP/DNS firewall rules...
netsh advfirewall firewall delete rule name="OogiCam-QA DHCP" >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA DHCP" dir=in action=allow protocol=udp localport=67 >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA DNS" >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA DNS" dir=in action=allow protocol=udp localport=53 >nul 2>&1
echo        DHCP ^(UDP 67^) and DNS ^(UDP 53^) rules applied.
echo.

:: ── Step 3: Flush DNS cache ───────────────────────────────
echo  [3/3] Flushing DNS cache...
ipconfig /flushdns >nul 2>&1
echo        DNS flushed.
echo.

echo  ═══════════════════════════════════════════════════════
echo  Done. Now on your Android device:
echo    1. Forget the hotspot WiFi network
echo    2. Reconnect — it should get an IP within 5 seconds
echo.
echo  If still failing, disable and re-enable Mobile Hotspot
echo  in Windows Settings ^> Network ^> Mobile Hotspot, then
echo  reconnect the Android device.
echo  ═══════════════════════════════════════════════════════
echo.
pause
