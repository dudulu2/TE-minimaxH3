@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ==============================================
echo   TE-Speed MiniMax H3 一键卸载 / 回退
echo ==============================================
echo.
echo 建议先完全关闭 ComfyUI。
echo 回退器只会在当前 core 仍含 TE hook 时恢复 model.py，
echo 防止 ComfyUI 更新后用旧备份覆盖新版本。
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Uninstall-TE.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo 回退未完成，错误码：%RC%
) else (
  echo 回退完成。
)
echo.
pause
exit /b %RC%
