<#
  HCIS - reset ONE account's password on this box, deliberately.

  The recovery does not do this. If an account is already there and somebody
  can sign in with it, it is left exactly as it was - because overwriting a
  password that is in use locks that person out, and the only clue is a line on
  a screen that has already scrolled past.

  So this is the separate, deliberate version: you name the account, you type
  the new password, and it says in words whether it worked.

  The person is made to change it at first sign-in, so the password typed here
  only has to survive until they log in once. HCIS has that screen and so does
  NARS, so nobody gets stranded on it.
#>

param(
    [string]$Username   = '',
    [string]$Password   = '',
    [string]$Db         = 'hcis_db',
    [string]$DbUser     = 'postgres',
    [string]$DbPassword = '',
    [string]$PgBin      = '',
    # Leave the group and role exactly as they are. Only the password changes
    # unless these are given - a reset should not quietly re-grade somebody.
    [string]$Role       = '',
    [string]$Group      = ''
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) { Say 'psql.exe was not found on this machine.' 'Red'; exit 1 }
$psql = Join-Path $PgBin 'psql.exe'
$sql  = Join-Path $PSScriptRoot 'accounts\account.sql'
if (-not (Test-Path $sql)) { Say "Missing: $sql - unzip the package again." 'Red'; exit 1 }

if ($DbPassword) { $env:PGPASSWORD = $DbPassword }
. (Join-Path $PSScriptRoot 'db-access.ps1')
if (-not (Set-DbPassword)) { exit 1 }

Write-Host ''
Say '============================================================'
Say ' Reset one password'
Say '============================================================'
Write-Host ''

# ---- which account -------------------------------------------------------
if (-not $Username) {
    Say 'The accounts on this box:' 'Cyan'
    Write-Host ''
    & $psql -q -U $DbUser -d $Db -c @"
SELECT username, role, user_group AS "group", status,
       CASE WHEN coalesce(password_hash,'') = '' THEN 'no password set'
            WHEN locked_until IS NOT NULL AND locked_until > now() THEN 'LOCKED'
            WHEN status <> 'active' THEN 'not active'
            ELSE 'can sign in' END AS "state"
  FROM system_users ORDER BY username
"@
    Write-Host ''
    $Username = (Read-Host '  Which username').Trim()
}
if (-not $Username) { Say 'Nothing typed. Nothing changed.' 'Yellow'; exit 1 }

# Does it exist? Saying "no such account" up front beats a confusing error from
# the SQL, and beats silently creating one nobody asked for.
$exists = (& $psql -tA -U $DbUser -d $Db -c @"
SELECT count(*) FROM system_users WHERE lower(username) = lower('$($Username -replace "'","''")')
"@ 2>&1).Trim()

if ($exists -ne '1') {
    Say "There is no account called `"$Username`" on this box." 'Red'
    Say 'Check the spelling against the list above. Nothing has been changed.' 'Red'
    Say 'Usernames are matched without regard to capitals, so that is not it.' 'Gray'
    exit 1
}

# What it is now, so the reset does not change anything it was not asked to.
if (-not $Role)  { $Role  = (& $psql -tA -U $DbUser -d $Db -c "SELECT role       FROM system_users WHERE lower(username)=lower('$($Username -replace "'","''")')").Trim() }
if (-not $Group) { $Group = (& $psql -tA -U $DbUser -d $Db -c "SELECT user_group FROM system_users WHERE lower(username)=lower('$($Username -replace "'","''")')").Trim() }
Say ("Account: {0}   role {1}, group {2} - both kept as they are." -f $Username, $Role, $Group)

# ---- the new password ----------------------------------------------------
if (-not $Password) {
    Write-Host ''
    Say 'They will be asked to set their own at first sign-in, so this only has'
    Say 'to last until they log in once.'
    Write-Host ''
    $a = Read-Host '  New password (at least 10 characters)' -AsSecureString
    $b = Read-Host '  Type it again' -AsSecureString
    $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)
    $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)
    try {
        $s1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($pa)
        $s2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($pb)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb)
    }
    if ($s1 -cne $s2) { Say 'Those two do not match. Nothing has been changed.' 'Red'; exit 1 }
    $Password = $s1
}
if ($Password.Length -lt 10) {
    Say 'That is shorter than 10 characters. Nothing has been changed.' 'Red'; exit 1
}

& $psql -q -U $DbUser -d $Db -v ON_ERROR_STOP=1 `
        -v ("usr=" + $Username) -v ("pwd=" + $Password) `
        -v ("role=" + $Role) -v ("grp=" + $Group) `
        -v 'mustchange=yes' -v 'mode=repair' -f $sql

if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Say 'That did not work, and the reason is above. Nothing was changed.' 'Red'
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

Write-Host ''
Say 'Done. The table above says in words whether the password works.' 'Green'
Say 'Give it to them. They will be asked to set their own straight away.' 'Yellow'
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
exit 0
