@echo off
REM ============================================================
REM  HCIS - put this box back after a database restore
REM
REM  DOUBLE-CLICK THIS ONE. It is the whole job.
REM
REM  Run it after the data centre has restored a database over
REM  hcis_db. It will:
REM
REM    1. tell you what is on the box now
REM    2. stop, changing nothing, if this is not HCIS
REM    3. back up whatever is there
REM    4. apply the thirteen database updates
REM    5. install the token signing key - without this NOBODY
REM       can sign in, and it is the first thing anyone notices
REM    6. make sure the accounts exist
REM    7. load the assessment records, if the data file is here
REM    8. prove sign-in works, and show what changed
REM
REM  Safe to run when nothing is wrong. Safe to run twice. It
REM  will not overwrite a password somebody is already using.
REM
REM  Afterwards run STEP-2-reload-api.bat. That part is not
REM  optional - PostgREST keeps answering from the structure it
REM  learned when it started until it is told to look again.
REM ============================================================
setlocal
set HERE=%~dp0

if not exist "%HERE%recover.ps1" (
  echo.
  echo   ERROR: recover.ps1 is missing from this folder.
  echo.
  echo   This usually means the package is still inside the zip.
  echo   Right-click the zip, choose Extract All, and run it from
  echo   the folder that comes out.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%recover.ps1" %*

echo.
pause
