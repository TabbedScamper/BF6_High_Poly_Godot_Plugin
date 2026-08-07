@echo off
REM Build the BF6 Oodle shim.
REM
REM No godot-cpp: this compiles against gdextension_interface.h alone, which
REM Godot itself emits (--dump-gdextension-interface). One translation unit,
REM no submodules, no SCons — the whole native surface is three methods.
REM
REM   build.bat            release
REM   build.bat debug      with symbols

setlocal
set VS=C:\Program Files\Microsoft Visual Studio\18\Community
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 (
  echo could not initialise the MSVC environment
  exit /b 1
)

set HERE=%~dp0
set OUT=%HERE%bin
if not exist "%OUT%" mkdir "%OUT%"

set FLAGS=/nologo /std:c++17 /EHsc /W3 /O2 /DNDEBUG
if "%1"=="debug" set FLAGS=/nologo /std:c++17 /EHsc /W3 /Od /Zi

cl %FLAGS% /LD ^
  /I"%HERE%" ^
  "%HERE%src\bf6_oodle.cpp" ^
  /Fe:"%OUT%\bf6_oodle.windows.x86_64.dll" ^
  /Fo:"%OUT%\\" ^
  /link /DLL

if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo.
echo built %OUT%\bf6_oodle.windows.x86_64.dll
endlocal
