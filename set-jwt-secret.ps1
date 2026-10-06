<#
  HCIS - install the token signing key into the database.

  From migration 31 onwards the database signs a token at sign-in and PostgREST
  verifies it. Both sides must use the same key or nobody can sign in, so the
  key is not written into this package. It is read out of the PostgREST
  configuration on THIS machine and handed to the database, which makes it
  impossible for the two to disagree.

  Called by STEP-1-database.bat. Nothing here prints the key itself.
#>

param(
    [string]$Root  = 'C:\HCIS',
    [string]$PgBin = '',
    [string]$Db    = 'hcis_db',
    [string]$DbUser= 'postgres',
    # Without this psql stops and asks for the database password, and the
    # window looks frozen. The catch-up passes it in; this default is here so
    # the script still works when run on its own.
    [string]$DbPassword = ''
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

# The database password is no longer written into this file - it used to be,
# and these scripts are published publicly. db-access.ps1 finds it: already in
# the environment, or saved on this machine by SET-DB-PASSWORD.bat, or it asks
# once. Without it psql stops and waits for input and the window looks frozen.
if ($DbPassword) { $env:PGPASSWORD = $DbPassword }
. (Join-Path $PSScriptRoot 'db-access.ps1')
if (-not (Set-DbPassword)) { exit 1 }

# ---- 1. find the PostgREST configuration --------------------------------
$candidates = @(
    (Join-Path $Root 'postgrest\postgrest.conf'),
    (Join-Path $Root 'postgrest\hcis.conf'),
    (Join-Path $Root 'postgrest.conf')
)
$conf = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $conf) {
    # Fall back to any .conf under the postgrest folder rather than giving up.
    $dir = Join-Path $Root 'postgrest'
    if (Test-Path $dir) {
        $conf = Get-ChildItem -Path $dir -Filter *.conf -File -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
    }
}

if (-not $conf) {
    Say 'Could not find the PostgREST configuration file.' 'Red'
    Say "Looked in: $($candidates -join ', ')" 'Red'
    Say 'Find the .conf PostgREST starts with and pass its folder as -Root.' 'Red'
    exit 1
}
Say "PostgREST configuration: $conf"

# ---- 2. read jwt-secret out of it ---------------------------------------
# PostgREST accepts the value quoted or bare, with any spacing around the "=",
# and "#" starts a comment. Take the first uncommented assignment.
$line = Get-Content -LiteralPath $conf |
        Where-Object { $_ -match '^\s*jwt-secret\s*=' -and $_ -notmatch '^\s*#' } |
        Select-Object -First 1

if (-not $line) {
    Say 'That file has no jwt-secret line.' 'Red'
    Say 'PostgREST cannot be verifying tokens without one. Check you have the right file.' 'Red'
    exit 1
}

$secret = $line -replace '^\s*jwt-secret\s*=\s*', ''
$secret = $secret -replace '\s*#.*$', ''          # trailing comment
$secret = $secret.Trim()
if ($secret.Length -ge 2 -and
    (($secret[0] -eq '"' -and $secret[-1] -eq '"') -or
     ($secret[0] -eq "'" -and $secret[-1] -eq "'"))) {
    $secret = $secret.Substring(1, $secret.Length - 2)
}

if ([string]::IsNullOrWhiteSpace($secret)) {
    Say 'The jwt-secret line is present but empty.' 'Red'
    exit 1
}

# The key is never printed. Its length and a short fingerprint are enough to
# compare against what the database ends up holding.
$md5  = [System.Security.Cryptography.MD5]::Create()
$hash = ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret)) |
         ForEach-Object { $_.ToString('x2') }) -join ''
$fp = $hash.Substring(0, 8)
Say ("Key read from PostgREST: {0} characters, fingerprint {1}" -f $secret.Length, $fp)

# ---- 3. hand it to the database -----------------------------------------
if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) { Say 'psql.exe was not found.' 'Red'; exit 1 }

$psql = Join-Path $PgBin 'psql.exe'
$sql  = Join-Path $PSScriptRoot 'db\41_set_jwt_secret.sql'
if (-not (Test-Path $sql)) { Say "Missing: $sql" 'Red'; exit 1 }

& $psql -q -U $DbUser -d $Db -v ON_ERROR_STOP=1 -v ("secret=" + $secret) -f $sql
if ($LASTEXITCODE -ne 0) {
    Say 'The database refused the key. Nothing was written.' 'Red'
    exit 1
}

# ---- 4. prove the two sides agree ---------------------------------------
# The database prints its own fingerprint above. If it does not match the one
# read from PostgREST, the value was mangled between here and there - which
# would leave sign-in issuing tokens PostgREST rejects.
$dbFp = (& $psql -tA -U $DbUser -d $Db -c "SELECT substr(md5(value),1,8) FROM auth_private.config WHERE key='jwt_secret'").Trim()
if ($dbFp -ne $fp) {
    Say "MISMATCH: PostgREST has $fp, the database stored $dbFp." 'Red'
    Say 'Sign-in would issue tokens PostgREST cannot verify. Stop and tell me.' 'Red'
    exit 1
}
Say ("Database and PostgREST agree on the key (fingerprint {0})." -f $fp) 'Green'
exit 0
