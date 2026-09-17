@echo off
rem  Check High-Poly Install - double-click this.
rem
rem  A plain launcher for verify_install.ps1, which must sit NEXT TO this file.
rem  An earlier version embedded the PowerShell in this .bat so there would be
rem  only one file to send; it broke on quoting when cmd handed the text to
rem  PowerShell, and a diagnostic that fails to run is worse than one extra
rem  file. Two files that work beat one clever file that does not.
setlocal
if not exist "%~dp0verify_install.ps1" (
  echo.
  echo   verify_install.ps1 is missing.
  echo   It has to be in the same folder as this file. Please unzip both
  echo   files together and run this again.
  echo.
  pause
  exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_install.ps1"
echo.
pause
