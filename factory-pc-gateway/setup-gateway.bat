@echo off
setlocal
echo.
echo  ╔═══════════════════════════════════════════════════════╗
echo  ║  OogiCam Factory QA — PC Gateway Setup                ║
echo  ╚═══════════════════════════════════════════════════════╝
echo.

:: ── Check admin ──────────────────────────────────────────
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo  [ERROR] Run this script as Administrator.
    echo          Right-click ^> Run as administrator
    pause
    exit /b 1
)

set CHINA_ECS_IP=10.2.0.100
set HOTSPOT_IP=192.168.137.1
set NGINX_DIR=%~dp0nginx

echo  China ECS private IP : %CHINA_ECS_IP%
echo  Hotspot gateway IP   : %HOTSPOT_IP%
echo  nginx directory      : %NGINX_DIR%
echo.

:: ── Step 0: Keep Mobile Hotspot always on ────────────────
echo  [0/6] Disabling Mobile Hotspot auto-off...

powershell -Command "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings' -Name 'PeerlessTimeoutEnabled' -Value 0 -ErrorAction SilentlyContinue"

powershell -Command "$a = Get-NetAdapter | Where-Object { $_.Name -like '*Wi-Fi*' -or $_.InterfaceDescription -like '*Wireless*' } | Select-Object -First 1; if ($a) { Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction SilentlyContinue; Write-Host '       Wi-Fi power management disabled on:' $a.Name } else { Write-Host '       [WARN] Wi-Fi adapter not found' }"

echo        Hotspot keep-alive settings applied.
echo.

:: ── Step 0b: Set hotspot adapter to Private network profile ──
echo  [0b]  Setting hotspot adapter network profile to Private...
powershell -Command "$a = Get-NetIPAddress -IPAddress 192.168.137.1 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InterfaceAlias; if ($a) { Set-NetConnectionProfile -InterfaceAlias $a -NetworkCategory Private -ErrorAction SilentlyContinue; Write-Host '       Set to Private:' $a } else { Write-Host '       [WARN] Hotspot adapter not found — enable Mobile Hotspot first, then re-run' }"
echo.

:: ── Step 1: Check VPN ────────────────────────────────────
echo  [1/6] Checking Alibaba VPN connection...
ipconfig | findstr /C:"172.16.100." >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo        [WARN] No VPN IP detected ^(172.16.100.x^).
    echo        Make sure OpenVPN is connected before testing devices.
    echo.
) else (
    echo        VPN connected.
    echo.
)

:: ── Step 2: Generate nginx config ────────────────────────
echo  [2/6] Generating nginx config...
if not exist "%NGINX_DIR%" (
    echo        [ERROR] nginx not found at %NGINX_DIR%
    echo        Download nginx for Windows from nginx.org/en/download.html
    echo        Extract to: %NGINX_DIR%\
    echo        ^(so that %NGINX_DIR%\nginx.exe exists^)
    pause
    exit /b 1
)

mkdir "%NGINX_DIR%\conf" 2>nul
(
echo worker_processes 1;
echo.
echo events {
echo     worker_connections 256;
echo }
echo.
echo # TCP proxy — all Azure service traffic
echo stream {
echo     # HTTPS — API, streaming, storage, B2C auth
echo     server {
echo         listen %HOTSPOT_IP%:443;
echo         proxy_pass %CHINA_ECS_IP%:443;
echo         proxy_connect_timeout 10s;
echo     }
echo.
echo     # MQTT — Azure IoT Hub
echo     server {
echo         listen %HOTSPOT_IP%:8883;
echo         proxy_pass %CHINA_ECS_IP%:8883;
echo         proxy_connect_timeout 10s;
echo     }
echo.
echo     # SQL Server
echo     server {
echo         listen %HOTSPOT_IP%:1433;
echo         proxy_pass %CHINA_ECS_IP%:1433;
echo         proxy_connect_timeout 10s;
echo     }
echo.
echo     # Metrics ^(InfluxDB^)
echo     server {
echo         listen %HOTSPOT_IP%:8086;
echo         proxy_pass %CHINA_ECS_IP%:8086;
echo         proxy_connect_timeout 10s;
echo     }
echo }
echo.
echo # HTTP server — Android captive portal check
echo http {
echo     server {
echo         listen %HOTSPOT_IP%:80;
echo.
echo         # Android connectivity check — return 204 so device reports internet as connected
echo         location /generate_204 {
echo             return 204;
echo         }
echo.
echo         location / {
echo             return 204;
echo         }
echo     }
echo }
) > "%NGINX_DIR%\conf\nginx.conf"
echo        nginx.conf generated.

:: ── Step 3: Kill and restart nginx ───────────────────────
echo  [3/6] Starting nginx ^(killing any existing instances^)...
taskkill /F /IM nginx.exe >nul 2>&1
timeout /t 1 /nobreak >nul
cd /d "%NGINX_DIR%"
start /B nginx.exe
timeout /t 1 /nobreak >nul
echo        nginx started on %HOTSPOT_IP% ^(80, 443, 1433, 8086, 8883^).

:: ── Step 4: Open Windows Firewall ports ──────────────────
echo  [4/6] Opening firewall ports...

netsh advfirewall firewall delete rule name="OogiCam-QA 80"   >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA 443"  >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA 8883" >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA 1433" >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA 8086" >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA DHCP" >nul 2>&1
netsh advfirewall firewall delete rule name="OogiCam-QA DNS"  >nul 2>&1

netsh advfirewall firewall add rule name="OogiCam-QA 80"   dir=in action=allow protocol=tcp localport=80   >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA 443"  dir=in action=allow protocol=tcp localport=443  >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA 8883" dir=in action=allow protocol=tcp localport=8883 >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA 1433" dir=in action=allow protocol=tcp localport=1433 >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA 8086" dir=in action=allow protocol=tcp localport=8086 >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA DHCP" dir=in action=allow protocol=udp localport=67  >nul 2>&1
netsh advfirewall firewall add rule name="OogiCam-QA DNS"  dir=in action=allow protocol=udp localport=53  >nul 2>&1

echo        Firewall rules added ^(TCP 80/443/8883/1433/8086, UDP 67/53^).

:: ── Step 5: Configure Windows DNS ────────────────────────
echo  [5/6] Updating Windows hosts file...

set HOSTS=%SystemRoot%\System32\drivers\etc\hosts
copy /Y "%HOSTS%" "%HOSTS%.bak.oogi" >nul 2>&1

:: Comment out any existing OogiCam-related entries
powershell -Command "$hosts = '%HOSTS%'.Replace('\', '\\'); $domains = @('api.oogiservices.net','storage.oogiservices.net','streaming.oogiservices.net','streaming-za.oogiservices.net','metrics.oogiservices.net','synap-iot-production.azure-devices.net','staging-synapinc-iothub.azure-devices.net','connectivitycheck.gstatic.com'); $lines = Get-Content $hosts; $updated = $lines | ForEach-Object { $l = $_; $match = $domains | Where-Object { $l -match $_ -and -not $l.TrimStart().StartsWith('#') -and $l -notmatch '# OogiCam-QA' }; if ($match) { '# ' + $l } else { $l } }; $updated | Set-Content $hosts"

(
echo.
echo # OogiCam-QA — Factory PC gateway entries ^(added by setup-gateway.bat^)
echo %HOTSPOT_IP%  api.oogiservices.net               # OogiCam-QA
echo %HOTSPOT_IP%  storage.oogiservices.net            # OogiCam-QA
echo %HOTSPOT_IP%  streaming.oogiservices.net          # OogiCam-QA
echo %HOTSPOT_IP%  streaming-za.oogiservices.net       # OogiCam-QA
echo %HOTSPOT_IP%  metrics.oogiservices.net            # OogiCam-QA
echo %HOTSPOT_IP%  synap-iot-production.azure-devices.net      # OogiCam-QA
echo %HOTSPOT_IP%  staging-synapinc-iothub.azure-devices.net   # OogiCam-QA
echo %HOTSPOT_IP%  connectivitycheck.gstatic.com               # OogiCam-QA
) >> "%HOSTS%"

ipconfig /flushdns >nul 2>&1
echo        Hosts file updated and DNS flushed.

:: ── Step 6: Configure Android captive portal check ───────
echo  [6/6] Configuring Android captive portal check on connected devices...
adb devices 2>nul | findstr /I "device" | findstr /V "List" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    for /f "tokens=1" %%d in ('adb devices 2^>nul ^| findstr /I "	device"') do (
        echo        Device: %%d
        adb -s %%d shell settings put global captive_portal_http_url  "http://connectivitycheck.gstatic.com/generate_204"  >nul 2>&1
        adb -s %%d shell settings put global captive_portal_https_url "http://connectivitycheck.gstatic.com/generate_204"  >nul 2>&1
        adb -s %%d shell settings put global captive_portal_fallback_url "http://connectivitycheck.gstatic.com/generate_204" >nul 2>&1
    )
    echo        Captive portal check redirected to gateway on all connected devices.
) else (
    echo        [WARN] No ADB devices connected — run this command manually per device:
    echo        adb shell settings put global captive_portal_http_url  "http://connectivitycheck.gstatic.com/generate_204"
    echo        adb shell settings put global captive_portal_https_url "http://connectivitycheck.gstatic.com/generate_204"
)
echo.

echo  ═══════════════════════════════════════════════════════
echo  Setup complete!
echo.
echo  Next steps:
echo    1. Enable Windows Mobile Hotspot
echo       ^(Settings ^> Network ^> Mobile Hotspot^)
echo    2. Connect Android devices to the hotspot WiFi
echo    3. Connect devices via USB for ADB captive portal fix
echo       ^(or run manually — see above^)
echo.
echo  To verify, run:  verify-gateway.bat
echo  To stop, run:    teardown-gateway.bat
echo  ═══════════════════════════════════════════════════════
echo.
pause
