@echo off
REM Deploy the recording-folder timezone fix to one yi-hack-MStar camera.
REM See README.md for what this does.
set /p CAM_IP="Camera IP (e.g. 192.168.1.99): "
python "%~dp0deploy.py" %CAM_IP%
pause
