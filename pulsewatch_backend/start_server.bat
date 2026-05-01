@echo off
title PulseWatch Research Server
color 0A
echo ============================================
echo        PulseWatch AI - Research Server
echo ============================================
echo.
echo  Finding server IP address...
for /f "delims=" %%i in ('python -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()"') do set LAN_IP=%%i
echo.
echo  Access the server at:
echo    http://%LAN_IP%:5001            ^(health check^)
echo    http://%LAN_IP%:5001/qr         ^(QR code - scan from phone app^)
echo.
echo  Press Ctrl+C to stop.
echo ============================================
echo.
python app.py
pause
