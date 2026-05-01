@echo off
title PulseWatch - ngrok Setup
echo ============================================
echo        PulseWatch AI - ngrok Setup
echo ============================================
echo.
echo [1/2] Downloading ngrok...
powershell -Command "Invoke-WebRequest -Uri 'https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip' -OutFile 'ngrok.zip'"
powershell -Command "Expand-Archive -Path 'ngrok.zip' -DestinationPath '.' -Force"
del ngrok.zip
echo Done.
echo.
echo [2/2] Setup complete!
echo.
echo Now run:  run_all.bat
echo ============================================
pause
