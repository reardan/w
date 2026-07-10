@echo off
REM Windows bootstrap for the W build system.
REM
REM Requires w.exe (the committed Windows seed) in the repository root.
REM Cold start: w.exe compiles the compiler (bin\wv2.exe) then the build
REM executor (bin\wexec.exe) from the manifest; a warm tree refreshes
REM through the manifest's cached wv2_win / wexec_win targets and runs
REM the up-to-date executor. 'rmdir /s /q bin' resets everything.
REM
REM Usage: wbuild.cmd [target ...]
REM   wbuild.cmd build        bootstrap: w.exe -> bin\wv2.exe -> wv3 -> wv4 -> wv5
REM   wbuild.cmd verify_win   self-host fixpoint (wv3==wv4==wv5)
REM   wbuild.cmd --list       show every target in build.json
REM   wbuild.cmd tests_win    full Windows test suite (needs Wine or native run)

setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist bin mkdir bin

REM Cold bootstrap: compile the compiler and executor from the Windows seed.
if not exist bin\wexec.exe (
    if not exist bin\wv2.exe (
        echo Bootstrapping compiler from seed...
        w.exe win64 w.w -o bin\wv2.exe
        if errorlevel 1 (
            echo Error: failed to compile w.w with the Windows seed w.exe
            exit /b 1
        )
    )
    echo Bootstrapping build executor...
    bin\wv2.exe win64 tools\wexec.w -o bin\wexec.exe
    if errorlevel 1 (
        echo Error: failed to compile tools\wexec.w
        exit /b 1
    )
)

REM Warm: let wexec rebuild its own toolchain dependencies when sources changed.
bin\wexec.exe wv2_win wexec_win >nul 2>&1

REM Forward all arguments to the executor.
bin\wexec.exe %*
