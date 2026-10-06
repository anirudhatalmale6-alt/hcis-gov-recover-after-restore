@echo off
REM ============================================================
REM  HCIS - tell PostgREST to read the database structure again
REM
REM  Run this AFTER PUT-HCIS-BACK.bat. Not optional.
REM
REM  PostgREST reads the shape of the database once, when it
REM  starts. Until it is told to look again it keeps answering
REM  from what it learned - so the updates are in place and the
REM  screens still behave as though they are not.
REM ============================================================
setlocal
set HERE=%~dp0

if not exist "%HERE%reload-api.ps1" (
  echo.
  echo   ERROR: reload-api.ps1 is missing from this folder.
  echo.
  echo   This usually means the package is still inside the zip.
  echo   Right-click the zip, choose Extract All, and run it from
  echo   the folder that comes out.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%reload-api.ps1" %*

echo.
pause
