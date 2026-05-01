@echo off
title PulseWatch - Running
color 0A
echo ============================================
echo        PulseWatch AI - Full Startup
echo ============================================
echo.

echo [1/2] Starting Flask server in background...
start "PulseWatch Flask" /min cmd /c "python app.py"
timeout /t 3 /nobreak >/dev/null
echo Done.
echo.

echo [2/2] Starting public tunnel...
echo.
echo Watch for the line:  Forwarding  https://xxxx.ngrok-free.app
echo Copy that URL and paste it into the phone app.
echo.
echo ============================================
echo.
ngrok http 5001
pause
