@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo === MT760 selftest (lists receiver interfaces, sends one frame each) ===
python mt760_tray.py selftest
echo.
echo === Now switching to channel 1 (A machine) ===
python mt760_tray.py chan 1
pause
