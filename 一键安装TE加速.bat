@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ==============================================
echo   TE-Speed MiniMax H3 一键安装
echo ==============================================
echo.
echo 建议先完全关闭 ComfyUI。
echo 安装器会自动备份核心 model.py 和被修改的工作流。
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Install-TE.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo 安装未完成，错误码：%RC%
) else (
  echo 安装完成。
)
echo.
pause
exit /b %RC%
