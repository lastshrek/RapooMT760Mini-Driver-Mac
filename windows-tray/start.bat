@echo off
chcp 65001 >nul
cd /d "%~dp0"

REM 启动前检查依赖，避免 pythonw 无窗口静默失败
python -c "import hid, pystray, PIL" >nul 2>&1
if errorlevel 1 (
  echo [错误] 依赖未安装或 Python 不在 PATH 中。
  echo 请先双击 install.bat 完成安装，再运行本文件。
  echo.
  pause
  exit /b 1
)

echo 正在启动 MT760 托盘图标...
echo 启动后本窗口可关闭；托盘右下角出现红色鼠标图标即成功。
echo 若没出现图标，双击 selftest.bat 查看原因。
start "" pythonw mt760_tray.py
timeout /t 2 >nul
