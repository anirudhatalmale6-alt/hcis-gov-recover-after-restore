@echo off
REM ============================================================
REM  HCIS - what is on this box right now
REM
REM  READS ONLY. CHANGES NOTHING. Safe at any time, including
REM  while somebody else is working, and safe before or after a
REM  restore.
REM
REM  Run this first if you are not sure whether anything is
REM  wrong, or to check afterwards that it is fixed.
REM ============================================================
setlocal
set HERE=%~dp0

if not exist "%HERE%check-state.ps1" (
  echo.
  echo   ERROR: check-state.ps1 is missing from this folder.
  echo.
  echo   This usually means the package is still inside the zip.
  echo   Right-click the zip, choose Extract All, and run it from
  echo   the folder that comes out.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%check-state.ps1" %*

echo.
pause
