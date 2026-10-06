@echo off
REM ============================================================
REM  Set the database password on this machine, once.
REM  Every other script here then finds it by itself.
REM ============================================================
setlocal
set HERE=%~dp0
if not exist "%HERE%set-db-password.ps1" (
  echo ERROR: set-db-password.ps1 is missing from this folder.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%set-db-password.ps1"
