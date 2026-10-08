<#
  Set the database password on this machine, once.

  Every other script then finds it by itself and never asks again - including
  packages downloaded later, because it is stored on the machine rather than
  in any folder that gets replaced.

  It does not just save what you type. It connects to the database with it
  first, because a saved password that is wrong is worse than no password at
  all: every later script fails with an authentication error that looks like
  something far more serious, and the real cause is a typo made days earlier.
#>

param(
    [string]$Password = '',          # for tests; use the prompt in real life
    [string]$Db       = 'hcis_db',
    [string]$DbUser   = 'postgres',
    [string]$PgBin    = ''
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

. (Join-Path $PSScriptRoot 'db-access.ps1')

if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) { Say 'psql.exe was not found on this machine.' 'Red'; exit 1 }
$psql = Join-Path $PgBin 'psql.exe'

Write-Host ''
Say '============================================================'
Say ' Set the database password on this machine'
Say '============================================================'
Write-Host ''
Say 'This is the postgres database password - NOT your HCIS login.'
Say 'You only have to do this once. After it, every script here'
Say 'finds it by itself, including ones you download later.'
Write-Host ''

# Ask, without the save prompt - this script does the saving itself, after
# it has checked the password actually works.
$env:PGPASSWORD = ''
if ($Password) {
    $env:PGPASSWORD = $Password
} else {
    Say 'You will see asterisks, or nothing at all. Both are normal.' 'Yellow'
    $a = Read-Host '  Database password' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)
    try   { $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
if (-not $env:PGPASSWORD) { Say 'Nothing typed. Nothing saved.' 'Yellow'; exit 1 }

Write-Host ''
Say 'Checking it against the database...'
$out = & $psql -q -U $DbUser -d $Db -tAc 'SELECT 1' 2>&1
$rc = $LASTEXITCODE
$text = ($out | Out-String)

if ($rc -ne 0) {
    Write-Host ''
    Say '------------------------------------------------------------' 'Red'
    Say 'That password did NOT work. Nothing has been saved.' 'Red'
    Write-Host ''
    if ($text -match 'authentication failed|password authentication') {
        Say 'The database refused it. Check for a typo and try again.' 'Yellow'
    } elseif ($text -match 'could not connect|Connection refused|server closed') {
        Say 'PostgreSQL is not running on this machine, so the password' 'Yellow'
        Say 'could not be checked at all. Start it and try again.' 'Yellow'
    } elseif ($text -match 'does not exist') {
        Say ("There is no database called $Db on this machine.") 'Yellow'
    } else {
        Say 'The message was:' 'Yellow'
        Say $text.Trim()
    }
    Say '------------------------------------------------------------' 'Red'
    Write-Host ''
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

# It works - now save it.
$file = Get-DbPasswordPath
try {
    $dir = Split-Path -Parent $file
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $file -Value $env:PGPASSWORD -NoNewline -Encoding ASCII
} catch {
    Say ('Could not save it: ' + $_.Exception.Message) 'Red'
    exit 1
}

# Tighten the file down to this account and administrators. Separate from the
# save above on purpose: by this point the password IS written and working, so
# if locking the permissions down fails, that is a warning worth printing - not
# a reason to tell someone the whole thing failed when it did not.
try {
    & icacls $file /inheritance:r /grant:r "$env:USERNAME:(R,W)" "Administrators:(F)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls returned $LASTEXITCODE" }
} catch {
    Say 'Saved, but could not restrict who may read the file.' 'Yellow'
    Say ("Check the permissions on $file by hand if that matters here.") 'Yellow'
}

# Read it back the way the other scripts will, rather than assuming the write
# was faithful.
$env:PGPASSWORD = ''
if (-not (Set-DbPassword -Quiet)) { Say 'Saved, but it could not be read back.' 'Red'; exit 1 }
$check = & $psql -q -U $DbUser -d $Db -tAc 'SELECT 1' 2>&1
if ($LASTEXITCODE -ne 0) {
    Say 'Saved, but reading it back and reconnecting failed. Tell me.' 'Red'
    exit 1
}

Write-Host ''
Say '------------------------------------------------------------' 'Green'
Say 'Done. The password works and is saved on this machine.' 'Green'
Write-Host ''
Say ("Stored in: " + $file)
Say 'No script here will ask you for it again.'
Write-Host ''
Say 'If you ever change the postgres password, run this again.'
Say '------------------------------------------------------------' 'Green'
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
exit 0
