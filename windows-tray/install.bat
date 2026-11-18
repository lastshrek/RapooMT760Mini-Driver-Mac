@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   MT760 切屏 - Windows 托盘工具 安装
echo ============================================
echo.

where python >nul 2>&1
if errorlevel 1 (
  echo [错误] 没有找到 Python。
  echo.
  echo 请先安装 Python 3（安装时勾选 "Add Python to PATH"）：
  echo   https://www.python.org/downloads/
  echo 装好后重新双击本文件。
  echo.
  pause
  exit /b 1
)

python --version
echo.
echo 正在安装依赖（使用国内镜像，失败会自动重试默认源）...
echo.

python -m pip install hidapi pystray Pillow -i https://pypi.tuna.tsinghua.edu.cn/simple --timeout 30
if errorlevel 1 (
  echo.
  echo 国内镜像失败，改用默认源重试...
  python -m pip install hidapi pystray Pillow --timeout 30
)
if errorlevel 1 (
  echo.
  echo [错误] 依赖安装失败。请检查网络后重试，或手动执行：
  echo   python -m pip install hidapi pystray Pillow
  echo.
  pause
  exit /b 1
)

echo.
echo ============================================
echo [完成] 依赖已装好。
echo   双击 start.bat   启动托盘图标
echo   双击 selftest.bat 自检接收器
echo ============================================
echo.
pause
