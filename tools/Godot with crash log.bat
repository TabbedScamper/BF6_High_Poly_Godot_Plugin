@echo off
setlocal enabledelayedexpansion
rem ===================================================================
rem  Start the Portal SDK's Godot editor so that it WRITES A LOG FILE.
rem
rem  Put this file in the same folder as Godot_v4.6.3-stable_win64.exe
rem  and double-click it instead of the exe. Use Godot normally. If it
rem  crashes, the log on your Desktop has the engine's last words in it,
rem  including the crash itself.
rem
rem  Why this is needed: the Godot EDITOR writes no log of its own, and
rem  the "Project Settings > Debug > File Logging" switch does not change
rem  that -- it only affects a running game. The --log-file argument below
rem  is what actually captures an editor session.
rem
rem  Nothing is installed and nothing is changed. This only starts the
rem  editor that is already there with one extra argument.
rem ===================================================================

rem The folder THIS file is sitting in, so the path does not have to be
rem edited and this works wherever the SDK lives.
set "HERE=%~dp0"

rem Find the editor next to us. Matches any version, and skips the
rem console build if one happens to be present.
set "GODOT="
for %%F in ("%HERE%Godot_v*.exe") do (
    echo %%~nxF | find /i "_console" >nul || set "GODOT=%%~fF"
)

if not defined GODOT (
    echo.
    echo   Could not find Godot in this folder:
    echo     %HERE%
    echo.
    echo   Put this .bat next to Godot_v4.6.3-stable_win64.exe and run it again.
    echo.
    pause
    exit /b 1
)

rem A timestamp, so relaunching after a crash cannot overwrite the log of
rem the crash you were trying to capture. PowerShell is used because the
rem built-in %DATE%/%TIME% change shape with regional settings.
for /f %%S in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "STAMP=%%S"
set "LOG=%USERPROFILE%\Desktop\godot-crash-%STAMP%.log"

echo.
echo   Editor : %GODOT%
echo   Log    : %LOG%
echo.
echo   Starting Godot. Use it as normal and make the problem happen.
echo   Leave this window open; it will tell you when Godot has closed.
echo.

rem %* passes anything extra straight through to Godot.
"%GODOT%" --log-file "%LOG%" %*

echo.
if exist "%LOG%" (
    echo   Godot has closed. Send this file:
    echo     %LOG%
) else (
    echo   Godot has closed, but no log was written. Send a screenshot of
    echo   this window instead.
)
echo.
pause
