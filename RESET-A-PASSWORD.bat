@echo off
REM ============================================================
REM  HCIS - reset ONE account's password, deliberately
REM
REM  PUT-HCIS-BACK.bat does not do this. If an account is there
REM  and working it leaves it completely alone, because
REM  overwriting a password that is in use locks that person out
REM  with no warning.
REM
REM  So this is the deliberate version. It lists the accounts,
REM  you pick one, and it says in words whether it worked. The
REM  person is asked to choose their own at first sign-in.
REM ============================================================
setlocal
set HERE=%~dp0

if not exist "%HERE%reset-a-password.ps1" (
  echo.
  echo   ERROR: reset-a-password.ps1 is missing from this folder.
  echo.
  echo   This usually means the package is still inside the zip.
  echo   Right-click the zip, choose Extract All, and run it from
  echo   the folder that comes out.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%reset-a-password.ps1" %*

echo.
pause
