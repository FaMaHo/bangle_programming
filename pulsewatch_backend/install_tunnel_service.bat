@echo off
title PulseWatch - Install Tunnel as Windows Service
echo Installing cloudflared as a Windows startup service...
echo (Run this once after setup_tunnel.bat has given you a URL)
echo.
cloudflared.exe service install
echo.
echo Done. The tunnel will now start automatically with Windows.
pause
