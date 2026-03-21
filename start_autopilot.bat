@echo off
REM start_autopilot.bat — Launch PZ and the AutoPilot sidecar together.
REM
REM Usage:
REM   start_autopilot.bat            (exercise mode - default)
REM   start_autopilot.bat --pilot    (pilot mode - goal-driven)
REM
REM Requirements:
REM   - ANTHROPIC_API_KEY set in environment
REM   - Python 3 with 'anthropic' package installed

set SIDECAR=%~dp0auto_pilot_sidecar.py
set PZ_DIR=C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid

REM Parse mode flag
set MODE=%1
if "%MODE%"=="" set MODE=--exercise

echo ========================================
echo  AutoPilot Sidecar Launcher
echo  Mode: %MODE%
echo ========================================

REM Start the sidecar in a new window
if "%MODE%"=="--pilot" (
    start "AutoPilot Sidecar [PILOT]" cmd /k python "%SIDECAR%" --pilot
) else (
    start "AutoPilot Sidecar [EXERCISE]" cmd /k python "%SIDECAR%"
)

REM Launch PZ via Steam (non-blocking)
echo Starting Project Zomboid via Steam...
start "" "steam://rungameid/108600"

echo.
echo Sidecar is running in a separate window.
echo Press F7 (exercise) or F8 (pilot) in-game to activate.
echo Close the sidecar window to stop it.
