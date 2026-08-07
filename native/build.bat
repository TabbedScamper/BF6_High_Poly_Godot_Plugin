@echo off
REM Build the BF6 native shim.
REM
REM No godot-cpp: this compiles against gdextension_interface.h alone, which
REM Godot itself emits (--dump-gdextension-interface). One translation unit,
REM no submodules, no SCons.
REM
REM   build.bat            release
REM   build.bat debug      with symbols
REM
REM TRAILING WHITESPACE IS FATAL HERE, so do not add any. `set HERE=%~dp0 `
REM with one trailing space puts that space INSIDE the variable, every path
REM built from it becomes "...\native\ src\...", and cl fails with
REM "D8003: missing source filename" — which reads like a broken command line
REM rather than a stray space three lines earlier. That cost a while to find.
REM
REM The cl invocation is deliberately ONE LINE. A caret continuation only joins
REM lines that end CRLF, and this file has arrived with mixed endings more than
REM once; not depending on them is cheaper than normalising it again.

setlocal
set "VS=C:\Program Files\Microsoft Visual Studio\18\Community"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 (
  echo could not initialise the MSVC environment
  echo looked in "%VS%"
  exit /b 1
)

set "HERE=%~dp0"
set "OUT=%HERE%bin"

REM WHY INC EXISTS, and it is the whole reason this script failed for a while.
REM
REM %~dp0 ends with a backslash, so /I"%HERE%" expands to /I"...\native\" — and
REM \" is an ESCAPED QUOTE to MSVC's argument parser, not a closing one. The
REM argument never terminates, swallows the rest of the command line including
REM the .cpp path, and cl reports "D8003: missing source filename" about a line
REM that visibly contains one.
REM
REM INC is the same path without the trailing separator, which is what /I wants
REM anyway. /Fo:"%OUT%\\" is fine as it stands: there the doubled backslash IS
REM the escape, so the quote closes and the argument ends in a single one.
set "INC=%HERE:~0,-1%"

if not exist "%OUT%" mkdir "%OUT%"

set "FLAGS=/nologo /std:c++17 /EHsc /W3 /O2 /DNDEBUG"
if "%1"=="debug" set "FLAGS=/nologo /std:c++17 /EHsc /W3 /Od /Zi"

cl %FLAGS% /LD /I"%INC%" "%HERE%src\bf6_oodle.cpp" /Fe:"%OUT%\bf6_oodle.windows.x86_64.dll" /Fo:"%OUT%\\" /link /DLL

if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo.
echo built %OUT%\bf6_oodle.windows.x86_64.dll
endlocal
