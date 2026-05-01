@echo off
title PulseWatch Backend Setup
echo ============================================
echo       PulseWatch Backend - First Setup
echo ============================================
echo.
echo [1/3] Installing Python dependencies...
pip install -r requirements.txt
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: pip install failed.
    echo Make sure Python 3.10+ is installed and added to PATH.
    echo Download from: https://www.python.org/downloads/
    pause
    exit /b 1
)
echo.
echo [2/3] Opening Windows Firewall port 5001...
netsh advfirewall firewall add rule name="PulseWatch Backend Port 5001" dir=in action=allow protocol=TCP localport=5001
echo Done.
echo.
echo [3/3] Setup complete!
echo.
echo  Run start_server.bat to start the server.
echo ============================================
pause
