@echo off
title PulseWatch - Cloudflare Tunnel Setup
echo ============================================
echo   PulseWatch AI - Cloudflare Tunnel Setup
echo ============================================
echo.
echo This gives your server a permanent public HTTPS URL
echo so patients anywhere can send data to you.
echo.
echo [1/3] Downloading cloudflared for Windows...
powershell -Command "Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile 'cloudflared.exe'"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Download failed. Check your internet connection.
    pause
    exit /b 1
)
echo Done.
echo.
echo [2/3] Starting tunnel...
echo.
echo !! IMPORTANT: Copy the https://xxxx.cfargotunnel.com URL shown below !!
echo !! Paste it into server_service.dart as _defaultServerUrl             !!
echo.
echo The tunnel will keep running in this window.
echo Press Ctrl+C to stop it.
echo ============================================
echo.
cloudflared.exe tunnel --url http://localhost:5001
pause
