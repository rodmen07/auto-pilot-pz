@echo off
setlocal enableextensions

REM sync_after_merge.bat
REM Pull latest changes from origin/main and optionally deploy to the live PZ mods dir.
REM
REM Usage:
REM   sync_after_merge.bat
REM   sync_after_merge.bat <branch>
REM
REM Optional env var:
REM   AUTO_PILOT_GAME_MOD_DIR=C:\path\to\Zomboid\mods\auto_pilot

set REPO_DIR=%~dp0
for %%I in ("%REPO_DIR%") do set REPO_DIR=%%~fI
if "%REPO_DIR:~-1%"=="\" set REPO_DIR=%REPO_DIR:~0,-1%

set BRANCH=%~1
if "%BRANCH%"=="" set BRANCH=main

set DEST=%AUTO_PILOT_GAME_MOD_DIR%
if "%AUTO_PILOT_GAME_MOD_DIR%"=="" set DEST=%USERPROFILE%\Zomboid\mods\auto_pilot
for %%I in ("%DEST%") do set DEST=%%~fI
if "%DEST:~-1%"=="\" set DEST=%DEST:~0,-1%

echo ========================================
echo  AutoPilot: Sync After Merge
echo  Repo   : %REPO_DIR%
echo  Branch : %BRANCH%
echo  Deploy : %DEST%
echo ========================================

where git >nul 2>&1
if errorlevel 1 (
    echo ERROR: git is not available in PATH.
    exit /b 1
)

set DIRTY=
for /f "delims=" %%G in ('git -C "%REPO_DIR%" status --porcelain') do set DIRTY=1
if defined DIRTY (
    echo ERROR: working tree has uncommitted changes. Commit or stash first.
    exit /b 1
)

echo.
echo Fetching origin/%BRANCH% ...
git -C "%REPO_DIR%" fetch origin %BRANCH% || exit /b 1

echo Switching to %BRANCH% ...
git -C "%REPO_DIR%" checkout %BRANCH% || exit /b 1

echo Pulling latest changes (fast-forward only) ...
git -C "%REPO_DIR%" pull --ff-only origin %BRANCH% || exit /b 1

if /I "%REPO_DIR%"=="%DEST%" (
    echo.
    echo Repo path is the live mod path. No deploy copy needed.
    echo Sync complete.
    exit /b 0
)

echo.
echo Deploying files to live mod path ...
if not exist "%DEST%" mkdir "%DEST%"

robocopy "%REPO_DIR%42" "%DEST%\42" /MIR /R:1 /W:1 >nul
set RC=%ERRORLEVEL%
if %RC% GEQ 8 (
    echo ERROR: robocopy failed with code %RC%.
    exit /b %RC%
)

echo Deploy complete.
exit /b 0
