@echo off
echo.
echo  Building OogiCam China QA Test Tool...
echo  ───────────────────────────────────────
echo.

dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  BUILD FAILED
    pause
    exit /b 1
)

echo.
echo  ═══════════════════════════════════════════════
echo  Build complete!
echo.
echo  Output: publish\AliVpnTests.exe
echo  Config: publish\appsettings.json
echo.
echo  Copy the entire 'publish' folder to the factory PC.
echo  Edit appsettings.json with your connection strings,
echo  then run AliVpnTests.exe.
echo  ═══════════════════════════════════════════════
echo.
pause
