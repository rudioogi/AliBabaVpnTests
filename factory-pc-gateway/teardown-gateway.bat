@echo off
setlocal
echo.
echo  ╔═══════════════════════════════════════════════════════╗
echo  ║  OogiCam Factory QA — Gateway Teardown                ║
echo  ╚═══════════════════════════════════════════════════════╝
echo.

:: ── Check admin ──────────────────────────────────────────
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo  [ERROR] Run this script as Administrator.
    pause
    exit /b 1
)

:: ── Stop nginx ───────────────────────────────────────────
echo  [1/3] Stopping nginx...
set NGINX_DIR=%~dp0nginx
if exist "%NGINX_DIR%\nginx.exe" (
    cd /d "%NGINX_DIR%"
    nginx.exe -s quit 2>nul
    timeout /t 2 /nobreak >nul
    taskkill /F /IM nginx.exe >nul 2>&1
    echo        nginx stopped.
) else (
    echo        nginx not found, skipping.
)

:: ── Remove hosts entries ─────────────────────────────────
echo  [2/3] Removing hosts file entries...
set HOSTS=%SystemRoot%\System32\drivers\etc\hosts
findstr /V /C:"# OogiCam-QA" "%HOSTS%" > "%HOSTS%.tmp" 2>nul
move /Y "%HOSTS%.tmp" "%HOSTS%" >nul 2>&1
ipconfig /flushdns >nul 2>&1
echo        Hosts file cleaned and DNS flushed.

:: ── Restore backup ───────────────────────────────────────
echo  [3/3] Hosts file backup available at:
echo        %HOSTS%.bak.oogi
echo.

echo  ═══════════════════════════════════════════════════════
echo  Teardown complete.
echo.
echo  Remember to:
echo    - Turn off Windows Mobile Hotspot
echo    - Disconnect OpenVPN if done testing
echo  ═══════════════════════════════════════════════════════
echo.
pause
