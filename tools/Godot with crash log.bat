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

rem THE PROJECT MANAGER MUST BE SKIPPED, or this captures the wrong process.
rem Launched with no project, Godot shows the picker, prints "Editing project:
rem ..." and then SPAWNS A SEPARATE EDITOR PROCESS and exits. The editor is a
rem new process that never received --log-file, so the log stopped after three
rem lines and this window announced Godot had closed while it was plainly still
rem open. Handing it the project up front means the one process we start IS the
rem editor.
set "PROJ="
if exist "%HERE%project.godot" set "PROJ=%HERE%"
if not defined PROJ (
    for /d %%D in ("%HERE%*") do (
        if exist "%%~fD\project.godot" if not defined PROJ set "PROJ=%%~fD"
    )
)
if not defined PROJ (
    echo.
    echo   Could not find a Godot project next to this file.
    echo   Expected project.godot here, or in a folder such as GodotProject.
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
echo   Project: %PROJ%
echo   Log    : %LOG%
echo.
echo   Starting Godot. Use it as normal and make the problem happen.
echo   Leave this window open; it will tell you when Godot has closed.
echo.

rem --editor --path together open the project straight away, bypassing the
rem picker. %* passes anything extra through, which is also how this is tested.
"%GODOT%" --editor --path "%PROJ%" --log-file "%LOG%" %*

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
