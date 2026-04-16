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

set CHINA_ECS_IP=CHANGE_ME
if "%CHINA_ECS_IP%"=="CHANGE_ME" (
    echo  [ERROR] Edit this script first!
    echo          Open setup-gateway.bat and set CHINA_ECS_IP to your
    echo          China ECS private VPC IP ^(e.g. 10.2.0.100^)
    echo.
    pause
    exit /b 1
)

set HOTSPOT_IP=192.168.137.1
set NGINX_DIR=%~dp0nginx
set ACRYLIC_HOSTS=%~dp0acrylic-hosts.txt

echo  China ECS private IP : %CHINA_ECS_IP%
echo  Hotspot gateway IP   : %HOTSPOT_IP%
echo  nginx directory      : %NGINX_DIR%
echo.

:: ── Step 1: Check VPN ────────────────────────────────────
echo  [1/4] Checking Alibaba VPN connection...
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
echo  [2/4] Generating nginx config...
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
echo }
) > "%NGINX_DIR%\conf\nginx.conf"
echo        nginx.conf generated.

:: ── Step 3: Start nginx ──────────────────────────────────
echo  [3/4] Starting nginx...
tasklist /FI "IMAGENAME eq nginx.exe" 2>nul | findstr /I "nginx.exe" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo        Stopping existing nginx...
    cd /d "%NGINX_DIR%"
    nginx.exe -s quit 2>nul
    timeout /t 2 /nobreak >nul
)
cd /d "%NGINX_DIR%"
start /B nginx.exe
echo        nginx started on %HOTSPOT_IP% ^(443, 8883, 1433^).

:: ── Step 4: Configure Windows DNS ────────────────────────
echo  [4/4] Updating Windows hosts file for hotspot DNS...

:: Back up hosts file
set HOSTS=%SystemRoot%\System32\drivers\etc\hosts
copy /Y "%HOSTS%" "%HOSTS%.bak.oogi" >nul 2>&1

:: Remove any previous OogiCam QA entries
findstr /V /C:"# OogiCam-QA" "%HOSTS%" > "%HOSTS%.tmp" 2>nul
move /Y "%HOSTS%.tmp" "%HOSTS%" >nul 2>&1

:: Add new entries
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
) >> "%HOSTS%"

ipconfig /flushdns >nul 2>&1
echo        Hosts file updated and DNS flushed.

echo.
echo  ═══════════════════════════════════════════════════════
echo  Setup complete!
echo.
echo  Next steps:
echo    1. Enable Windows Mobile Hotspot
echo       ^(Settings ^> Network ^> Mobile Hotspot^)
echo    2. Connect your Android device to the hotspot WiFi
echo    3. The device will use this PC as DNS + proxy
echo.
echo  To verify, run:  verify-gateway.bat
echo  To stop, run:    teardown-gateway.bat
echo  ═══════════════════════════════════════════════════════
echo.
pause
