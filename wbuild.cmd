@echo off
REM Windows bootstrap for the W build system.
REM
REM Requires w.exe (the pinned Windows seed) in the repository root; when
REM missing it is downloaded from GitHub Releases per .\SEEDS and its
REM sha256 is verified (curl.exe and PowerShell ship with Windows 10+).
REM Cold start: w.exe compiles the compiler (bin\wv2.exe) then the build
REM executor (bin\wexec.exe) from the manifest; a warm tree refreshes
REM through the manifest's cached wv2_win / wexec_win targets and runs
REM the up-to-date executor. 'rmdir /s /q bin' resets everything.
REM
REM Usage: wbuild.cmd [target ...]
REM   wbuild.cmd verify_win   self-host fixpoint (wv3_win==wv4_win==wv5_win)
REM   wbuild.cmd --list       show every target in the manifest
REM
REM The win64 chain (wv2_win, wexec_win, build_win, verify_win,
REM update_win), the generated sources and the win64 tests work here:
REM wexec runs targets serially (no fork), drops the manifest's "wine"
REM prefix, resolves "bin/wv2" to bin\wv2.exe, compiles untargeted
REM "bin/wv2 f.w -o bin/tool" host tools for win64 (bin\tool.exe), and
REM supplies echo/cmp when PATH lacks them. Targets that run ELF binaries
REM (build, verify, tests, ...) are Linux-only.

setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist bin mkdir bin

REM Download the pinned seed from GitHub Releases when it is missing.
if not exist w.exe (
    for /f "usebackq eol=# tokens=1-4" %%a in ("SEEDS") do (
        if "%%a"=="w.exe" (
            echo Downloading seed w.exe from release %%b...
            curl.exe -fsSL -o w.exe.download "https://github.com/reardan/w/releases/download/%%b/%%c"
            if errorlevel 1 (
                echo Error: seed w.exe download failed
                exit /b 1
            )
            for /f %%h in ('powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 'w.exe.download').Hash.ToLower()"') do set seedhash=%%h
            if /i not "!seedhash!"=="%%d" (
                del w.exe.download
                echo Error: seed w.exe does not match the sha256 pinned in SEEDS
                exit /b 1
            )
            move /y w.exe.download w.exe >nul
        )
    )
    if not exist w.exe (
        echo Error: seed w.exe missing and no SEEDS entry found
        exit /b 1
    )
)

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
    bin\wv2.exe win64 tools\wexec_main.w -o bin\wexec.exe
    if errorlevel 1 (
        echo Error: failed to compile tools\wexec_main.w
        exit /b 1
    )
)

REM Warm: let wexec rebuild its own toolchain dependencies when sources
REM changed (stdout suppressed like the Unix wrapper; errors stay visible),
REM then promote them: the manifest's "wv2" target runs the Linux seed, so
REM on Windows bin\wv2.exe and bin\wexec.exe are the previous build's
REM wv2_win / wexec_win outputs (wexec treats "wv2" as satisfied by
REM bin\wv2.exe and compiles untargeted host tools for win64).
bin\wexec.exe wv2_win wexec_win >nul
if errorlevel 1 (
    echo Error: failed to refresh wv2_win / wexec_win
    exit /b 1
)
fc /b bin\wv2_win.exe bin\wv2.exe >nul 2>nul || copy /y bin\wv2_win.exe bin\wv2.exe >nul
fc /b bin\wexec_win.exe bin\wexec.exe >nul 2>nul || copy /y bin\wexec_win.exe bin\wexec.exe >nul

REM Forward all arguments to the executor.
bin\wexec.exe %*
