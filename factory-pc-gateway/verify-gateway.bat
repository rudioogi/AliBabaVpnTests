@echo off
setlocal EnableDelayedExpansion
echo.
echo  ╔═══════════════════════════════════════════════════════╗
echo  ║  OogiCam Factory QA — Gateway Verification            ║
echo  ╚═══════════════════════════════════════════════════════╝
echo.

set HOTSPOT_IP=192.168.137.1
set PASS=0
set FAIL=0

:: ── VPN ──────────────────────────────────────────────────
echo  [VPN Connection]
ipconfig | findstr /C:"172.16.100." >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo    PASS  VPN connected ^(172.16.100.x^)
    set /a PASS+=1
) else (
    echo    FAIL  VPN not connected — start OpenVPN first
    set /a FAIL+=1
)
echo.

:: ── nginx ────────────────────────────────────────────────
echo  [nginx Process]
tasklist /FI "IMAGENAME eq nginx.exe" 2>nul | findstr /I "nginx.exe" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo    PASS  nginx is running
    set /a PASS+=1
) else (
    echo    FAIL  nginx is not running — run setup-gateway.bat
    set /a FAIL+=1
)
echo.

:: ── Port listeners ───────────────────────────────────────
echo  [nginx Listening on Hotspot IP]
for %%P in (443 8883 1433) do (
    netstat -an | findstr /C:"%HOTSPOT_IP%:%%P" | findstr "LISTENING" >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        echo    PASS  %HOTSPOT_IP%:%%P listening
        set /a PASS+=1
    ) else (
        echo    FAIL  %HOTSPOT_IP%:%%P not listening
        set /a FAIL+=1
    )
)
echo.

:: ── Hosts file ───────────────────────────────────────────
echo  [Hosts File Entries]
for %%H in (api.oogiservices.net synap-iot-production.azure-devices.net streaming.oogiservices.net) do (
    findstr /C:"%%H" %SystemRoot%\System32\drivers\etc\hosts >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        echo    PASS  %%H in hosts file
        set /a PASS+=1
    ) else (
        echo    FAIL  %%H missing from hosts file
        set /a FAIL+=1
    )
)
echo.

:: ── DNS resolution ───────────────────────────────────────
echo  [DNS Resolution ^(ping check^)]
for %%H in (api.oogiservices.net synap-iot-production.azure-devices.net) do (
    ping -n 1 -w 2000 %%H | findstr /C:"%HOTSPOT_IP%" >nul 2>&1
    if !ERRORLEVEL! EQU 0 (
        echo    PASS  %%H resolves to %HOTSPOT_IP%
        set /a PASS+=1
    ) else (
        echo    FAIL  %%H does NOT resolve to %HOTSPOT_IP% — flush DNS: ipconfig /flushdns
        set /a FAIL+=1
    )
)
echo.

:: ── TCP connectivity through proxy chain ─────────────────
echo  [TCP Connectivity to China ECS via VPN]
powershell -Command "try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('%HOTSPOT_IP%', 443); $c.Close(); Write-Host '   PASS  %HOTSPOT_IP%:443 reachable' } catch { Write-Host '   FAIL  %HOTSPOT_IP%:443 unreachable' }"
powershell -Command "try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('%HOTSPOT_IP%', 8883); $c.Close(); Write-Host '   PASS  %HOTSPOT_IP%:8883 reachable' } catch { Write-Host '   FAIL  %HOTSPOT_IP%:8883 unreachable' }"
echo.

:: ── Summary ──────────────────────────────────────────────
echo  ═══════════════════════════════════════════════════════
echo   Passed: %PASS%   Failed: %FAIL%
echo  ═══════════════════════════════════════════════════════
echo.
if %FAIL% GTR 0 (
    echo  Fix the failures above, then re-run this script.
) else (
    echo  All checks passed. Connect your Android device
    echo  to the Windows Mobile Hotspot and start testing.
)
echo.
pause
