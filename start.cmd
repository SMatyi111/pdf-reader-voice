@echo off
REM Double-click this to launch the PDF Reader. It bypasses Windows' default
REM "no scripts allowed" execution policy for this one run only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
echo.
echo Server stopped. Press any key to close.
pause >nul
