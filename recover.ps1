<#
  HCIS - put this box back after a database restore.

  WHAT THIS IS FOR

  The government data centre is restoring a database over hcis_db. That
  restore replaces everything done on the database side since August:

    * the thirteen updates, including the NARS tables
    * the token signing key - and without it NOT ONE PERSON can sign in,
      which is the first thing anybody notices
    * every account
    * the change that stopped the whole database being readable without
      signing in

  None of that is a fault in their restore. A restore does what it says. It
  just means somebody has to put the rest back afterwards, and the symptom if
  nobody does is a total sign-in failure with no explanation on screen.

  This exists so that does not depend on me being told it happened. It is one
  file, it can be run by anybody, and it says in words what it found and what
  it did.

  SAFE TO RUN WHEN NOTHING IS WRONG

  Every one of the thirteen updates is written to be applied more than once -
  verified, not assumed. So this does not try to work out which ones are
  missing and apply only those. It applies all of them, every time.

  That is deliberate. A clever version that skipped the ones it believed were
  already there would skip the wrong one the day a marker was wrong, and the
  update it skipped would be the one holding the door shut. Applying all
  thirteen costs about a minute and cannot make that mistake.

  The report before and after is for the person reading the screen. Nothing
  here BRANCHES on it.

  ORDER, which is not negotiable

    1. report what is on the box now
    2. refuse to go on unless this is HCIS
    3. back up what is there, whatever it is
    4. apply the thirteen updates
    5. install the signing key, read off this machine's own PostgREST
    6. make sure somebody can sign in
    7. load the assessment records, if the data file is here
    8. report what is on the box now, and prove sign-in works

  Driven by PUT-HCIS-BACK.bat. The logic is here rather than in the .bat
  because this can be tested and batch string handling cannot.
#>

param(
    [string]$Db         = 'hcis_db',
    [string]$DbUser     = 'postgres',
    [string]$PgBin      = '',
    [string]$Root        = 'C:\HCIS',
    [string]$DbPassword = '',
    [string]$Password   = '',    # temporary password for the accounts
    [switch]$NoAccounts,
    [switch]$NoRecords
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }
function Rule { Write-Host '  ------------------------------------------------------------' }
function Head($t) {
    Write-Host ''
    Say '============================================================'
    Say " $t"
    Say '============================================================'
}

# The accounts that have to exist for somebody to get back in. Names and
# addresses as the Health Department gave them. NO PASSWORDS HERE - this file
# is published. One temporary password is typed at the prompt and every one of
# them must change it at first sign-in.
$ACCOUNTS = @(
    @{ User = 'Evans';          Role = 'super_admin';     Group = 'Admin';
       First = 'Evans';         Last = 'Delcy';           Email = '' },
    @{ User = 'evans.nars';     Role = 'health_assessor'; Group = 'Health';
       First = 'Evans';         Last = '(NARS assessor)'; Email = '' },
    @{ User = 'marylene.lucas'; Role = 'health_assessor'; Group = 'Health';
       First = 'Marylene';      Last = 'Lucas';           Email = 'Marylene.Lucas@health.gov.sc' },
    @{ User = 'vlmarie';        Role = 'health_assessor'; Group = 'Health';
       First = 'Veriene';       Last = 'Louis-Marie';     Email = 'vlmarie@health.gov.sc' },
    @{ User = 'fiona.paulin';   Role = 'health_assessor'; Group = 'Health';
       First = 'Fiona';         Last = 'Paulin';          Email = 'fiona.paulin@health.gov.sc' },
    @{ User = 'r.burka';        Role = 'health_assessor'; Group = 'Health';
       First = 'Rhonda';        Last = 'Burka';           Email = 'r.burka@health.gov.sc' }
)

$MIGRATIONS = @(
    '30_nars_and_access_control.sql',  '31_login_returns_a_token.sql',
    '32_nars_references.sql',          '33_admin_functions_need_a_session.sql',
    '34_nars_feeds_hcis.sql',          '35_nars_catches_up.sql',
    '36_nars_release_to_hcis.sql',     '37_nars_bands_are_settings.sql',
    '38_remove_the_default_grants.sql','39_dashboard_counts_honestly.sql',
    '40_nin_house_format.sql',         '42_say_why_a_login_was_refused.sql'
)
# 41 is not in that list. It needs the key passed in, so set-jwt-secret.ps1
# runs it separately at step 5.

# ---- tools ---------------------------------------------------------------
if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) {
    Say 'psql.exe was not found on this machine.' 'Red'
    Say 'If PostgreSQL is somewhere unusual, pass -PgBin "the\path\to\bin".' 'Red'
    exit 1
}
$psql    = Join-Path $PgBin 'psql.exe'
$pgdump  = Join-Path $PgBin 'pg_dump.exe'
$restore = Join-Path $PgBin 'pg_restore.exe'
$dbDir   = Join-Path $PSScriptRoot 'db'
$acctSql = Join-Path $PSScriptRoot 'accounts\account.sql'
$stateSql= Join-Path $dbDir 'state.sql'

# ---- everything present before anything is touched -----------------------
$needed = @($MIGRATIONS + '41_set_jwt_secret.sql' + 'state.sql') |
          Where-Object { -not (Test-Path (Join-Path $dbDir $_)) }
if ($needed) {
    Say 'These files are missing from the db folder:' 'Red'
    $needed | ForEach-Object { Say "  $_" 'Red' }
    Say 'The download is incomplete. Right-click the zip, Extract All, and run it' 'Red'
    Say 'from the extracted folder - not from inside the zip.' 'Red'
    exit 1
}
if (-not (Test-Path $acctSql)) {
    Say 'accounts\account.sql is missing. Unzip the package again.' 'Red'; exit 1
}

if ($DbPassword) { $env:PGPASSWORD = $DbPassword }
. (Join-Path $PSScriptRoot 'db-access.ps1')
if (-not (Set-DbPassword)) { exit 1 }

& $psql -U $DbUser -d $Db -c 'select 1' *> $null
if ($LASTEXITCODE -ne 0) {
    Say "Cannot reach the database $Db on this machine." 'Red'
    Say 'If the restore is still running, wait for it to finish and run this again.' 'Yellow'
    exit 1
}

# ---- reading the state ---------------------------------------------------
#
# state.sql is the only thing that decides whether something is present. This
# reads its answers; it does not form its own. Lines are kept only if they have
# the three fields state.sql promises, so anything else psql prints cannot be
# mistaken for a result.
function Get-State {
    $raw = & $psql -tA -U $DbUser -d $Db -f $stateSql 2>&1
    $rows = @()
    foreach ($line in $raw) {
        $parts = ([string]$line).Split('|')
        if ($parts.Count -eq 3 -and $parts[2].Trim() -in @('yes', 'no')) {
            $rows += [pscustomobject]@{
                Kind    = $parts[0].Trim()
                Item    = $parts[1].Trim()
                Present = $parts[2].Trim()
            }
        }
    }
    return $rows
}

function Show-State($rows, $title) {
    Head $title
    foreach ($k in @('core', 'change', 'account', 'data')) {
        $these = @($rows | Where-Object { $_.Kind -eq $k })
        if (-not $these) { continue }
        $label = switch ($k) {
            'core'    { 'The tables HCIS cannot work without' }
            'change'  { 'The thirteen database updates' }
            'account' { 'Can anybody sign in' }
            'data'    { 'The assessment records' }
        }
        Write-Host ''
        Say $label 'Cyan'
        foreach ($r in $these) {
            if ($r.Present -eq 'yes') {
                Say ("  [ yes ] {0}" -f $r.Item) 'Green'
            } else {
                Say ("  [ NO  ] {0}" -f $r.Item) 'Red'
            }
        }
    }
    Write-Host ''
}

$before = Get-State
if (-not $before) {
    Say 'The state check returned nothing at all. That is not a result, so I am' 'Red'
    Say 'stopping rather than guessing. Send me what is printed above.' 'Red'
    exit 1
}

Show-State $before 'What is on this box NOW'

# ---- 2. is this HCIS at all? --------------------------------------------
$missingCore = @($before | Where-Object { $_.Kind -eq 'core' -and $_.Present -eq 'no' })
if ($missingCore) {
    Rule
    Say 'STOPPING. Nothing has been changed.' 'Red'
    Write-Host ''
    Say 'This database is not HCIS. These tables are not in it:' 'Red'
    $missingCore | ForEach-Object { Say ("  " + $_.Item) 'Red' }
    Write-Host ''
    Say 'That probably means the restore put a different system here rather than' 'Yellow'
    Say 'an older copy of this one. If so this package is the wrong tool and' 'Yellow'
    Say 'applying it would make a mess of both. Send me a photo of this window' 'Yellow'
    Say 'and run nothing else.' 'Yellow'
    Rule
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

$changesMissing = @($before | Where-Object { $_.Kind -eq 'change' -and $_.Present -eq 'no' }).Count
$keyMissing     = @($before | Where-Object { $_.Item -like '41*' -and $_.Present -eq 'no' }).Count -gt 0

Rule
if ($changesMissing -eq 0) {
    Say "All thirteen updates are already on this box." 'Green'
    Say 'Carrying on anyway - they are all safe to apply again, and that is' 'Gray'
    Say 'cheaper than me deciding which to skip.' 'Gray'
} else {
    Say "$changesMissing of the thirteen updates are missing from this box." 'Yellow'
}
if ($keyMissing) {
    Say 'The token signing key is NOT there. Nobody can sign in to this box' 'Red'
    Say 'right now. That is what this fixes.' 'Red'
}
Rule

# ---- the temporary password, asked for once, before any work starts ------
#
# Asked now rather than at step 7, so the run does not stop half way through
# waiting for somebody who has walked away.
if (-not $NoAccounts -and -not $Password) {
    Write-Host ''
    Say 'The accounts need a temporary password.' 'Cyan'
    Say 'All six get the same one and every one of them has to change it at'
    Say 'first sign-in, so it only has to survive until each person logs in once.'
    Write-Host ''
    Say 'An account that is already here and working will be LEFT ALONE - this'
    Say 'does not overwrite a password somebody is using.'
    Write-Host ''
    $a = Read-Host '  Temporary password (at least 10 characters)' -AsSecureString
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
    if ($s1.Length -lt 10) { Say 'That is shorter than 10 characters. Nothing has been changed.' 'Red'; exit 1 }
    $Password = $s1
}

# ---- 3. backup ----------------------------------------------------------
Head 'Taking a backup first'
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $PSScriptRoot ("hcis_before_recovery_{0}.dump" -f $stamp)

& $pgdump -U $DbUser -d $Db -Fc -f $backup
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $backup) -or (Get-Item $backup).Length -eq 0) {
    Say 'The backup failed or came out empty. Nothing has been changed.' 'Red'
    Say 'I am not willing to touch this box without one. If the disk is full,' 'Red'
    Say 'that is the thing to fix first.' 'Red'
    exit 1
}
Say ("Backup: {0}" -f $backup) 'Green'
Say ("Size:   {0:N0} bytes" -f (Get-Item $backup).Length) 'Green'

function Bail($what) {
    Write-Host ''
    Rule
    Say $what 'Red'
    Write-Host ''
    Say 'To put this box back exactly as it was a moment ago:' 'Yellow'
    Say ("  `"{0}`" -U {1} -d {2} --clean --if-exists `"{3}`"" -f $restore, $DbUser, $Db, $backup) 'Yellow'
    Write-Host ''
    Say 'Send me a photo of this window and run nothing else.' 'Yellow'
    Rule
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

# ---- 4. the thirteen updates -------------------------------------------
Head 'Applying the database updates'
Write-Host ''
foreach ($m in $MIGRATIONS) {
    Say "   $m"
    & $psql -q -U $DbUser -d $Db -v ON_ERROR_STOP=1 -f (Join-Path $dbDir $m)
    if ($LASTEXITCODE -ne 0) {
        Bail "STOPPED at $m. That step wrote nothing. The steps before it stand, and the backup above undoes all of them."
    }
}
Say 'All applied.' 'Green'

# ---- 5. the signing key ------------------------------------------------
Head 'Installing the token signing key'
Say 'Read off this machine''s own PostgREST configuration, so the two cannot'
Say 'disagree about what the key is.'
Write-Host ''
& (Join-Path $PSScriptRoot 'set-jwt-secret.ps1') -Root $Root -PgBin $PgBin -Db $Db -DbUser $DbUser
if ($LASTEXITCODE -ne 0) {
    Bail 'The signing key could not be installed. THIS IS THE ONE THAT MATTERS - until it is in place nobody can sign in to this box at all, because the updates above changed sign-in to need it.'
}

# ---- 6. accounts --------------------------------------------------------
if ($NoAccounts) {
    Head 'Accounts - skipped as asked'
} else {
    Head 'Making sure somebody can sign in'
    $failed = @()
    foreach ($p in $ACCOUNTS) {
        Write-Host ''
        Say ("---- {0}" -f $p.User) 'Cyan'
        $psqlArgs = @(
            '-q', '-U', $DbUser, '-d', $Db, '-v', 'ON_ERROR_STOP=1',
            '-v', ("usr="   + $p.User),
            '-v', ("pwd="   + $Password),
            '-v', ("role="  + $p.Role),
            '-v', ("grp="   + $p.Group),
            '-v', ("firstname=" + $p.First),
            '-v', ("lastname="  + $p.Last),
            '-v', 'mustchange=yes',
            '-v', 'mode=create-if-missing'
        )
        if ($p.Email) { $psqlArgs += @('-v', ("email=" + $p.Email)) }
        $psqlArgs += @("-f", $acctSql)
        & $psql @psqlArgs
        if ($LASTEXITCODE -ne 0) { $failed += $p.User }
    }
    if ($failed.Count -gt 0) {
        # By name. "Some failed" is not something anybody can act on.
        Write-Host ''
        Say ('THESE ACCOUNTS DID NOT WORK: ' + ($failed -join ', ')) 'Red'
        Say 'The others above were done. The database updates and the signing key' 'Yellow'
        Say 'are in place, so this is not holding the box down - but tell me.' 'Yellow'
    }

    # ---- which of them can actually be signed into, with the password typed?
    #
    # The per-account tables above each say this, but they scroll past, and the
    # one that matters is the one that says NO. An account that already existed
    # and was working was deliberately left alone - which is right, and also
    # means the temporary password does not open it. Nobody should have to
    # work that out by reading six tables.
    #
    # crypt(), not hcis_login: the sign-in function raises when the signing key
    # is missing and that error is indistinguishable from a wrong password.
    $names  = ($ACCOUNTS | ForEach-Object { "'" + ($_.User -replace "'", "''") + "'" }) -join ','
    $usable = & $psql -tA -U $DbUser -d $Db -c @"
SELECT username || '|' ||
       CASE WHEN status <> 'active' THEN 'not-active'
            WHEN coalesce(password_hash,'') = '' THEN 'no-password'
            WHEN password_hash = crypt('$($Password -replace "'","''")', password_hash)
                 THEN 'typed'
            ELSE 'own' END
  FROM system_users WHERE username IN ($names) ORDER BY username
"@ 2>&1

    $typed = @(); $own = @(); $broken = @()
    foreach ($l in $usable) {
        $f = ([string]$l).Split('|')
        if ($f.Count -ne 2) { continue }
        switch ($f[1].Trim()) {
            'typed' { $typed  += $f[0].Trim() }
            'own'   { $own    += $f[0].Trim() }
            default { $broken += ($f[0].Trim() + ' (' + $f[1].Trim() + ')') }
        }
    }

    Write-Host ''
    Rule
    if ($typed) {
        Say 'These use the temporary password you just typed:' 'Green'
        $typed | ForEach-Object { Say "  $_" 'Green' }
    }
    if ($own) {
        Write-Host ''
        Say 'These were ALREADY on this box and working, so I did not touch' 'Yellow'
        Say 'them. They keep their own passwords:' 'Yellow'
        $own | ForEach-Object { Say "  $_" 'Yellow' }
        Write-Host ''
        Say 'If nobody knows the password for one of those, that is what' 'Yellow'
        Say 'RESET-A-PASSWORD.bat is for. I did not guess, because overwriting' 'Yellow'
        Say 'a password somebody is using locks them out with no warning.' 'Yellow'
    }
    if ($broken) {
        Write-Host ''
        Say 'These cannot be signed into at all - tell me:' 'Red'
        $broken | ForEach-Object { Say "  $_" 'Red' }
    }
    Rule
}

# ---- 7. the assessment records -----------------------------------------
#
# The data file is NOT in this package and never will be: it holds real names,
# identity numbers and answers about people's health, and this package is
# published. It is carried between the machines by hand.
$loader = Join-Path $PSScriptRoot 'nars-data\load-nars-records.sql'
$dataFile = $null
if (Test-Path (Join-Path $PSScriptRoot 'nars-data')) {
    $dataFile = Get-ChildItem (Join-Path $PSScriptRoot 'nars-data') -Filter 'nars_records_*.sql' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
}

if ($NoRecords) {
    Head 'Assessment records - skipped as asked'
} elseif (-not $dataFile) {
    Head 'Assessment records - no data file here'
    Say 'nars-data\nars_records_YYYYMMDD.sql is not in this folder, so there is' 'Yellow'
    Say 'nothing to load and this step has been skipped.' 'Yellow'
    Write-Host ''
    Say 'That file is deliberately not part of the package: it holds real names,' 'Gray'
    Say 'identity numbers and answers about people''s health, and the package is' 'Gray'
    Say 'published. Ask me for it, put it in the nars-data folder, and run this' 'Gray'
    Say 'again - it will pick up where this left off.' 'Gray'
    Write-Host ''
    Say 'EVERYTHING ELSE ABOVE IS DONE. People can sign in without this step.' 'Green'
} else {
    Head 'Loading the assessment records'
    Say ("From: {0}" -f $dataFile.Name)
    Write-Host ''
    # Forward slashes: psql reads \i as its own escape, and a Windows path
    # inside it loses the backslashes.
    $p = ($dataFile.FullName -replace '\\', '/')
    & $psql -q -U $DbUser -d $Db -v ON_ERROR_STOP=1 -v ("file=" + $p) -f $loader
    if ($LASTEXITCODE -ne 0) {
        # Not a Bail. Records are the last step and the box is already usable
        # without them; undoing the signing key to retry a data load would be
        # the wrong trade.
        Write-Host ''
        Say 'The records did not load, and the reason is printed above.' 'Red'
        Say 'Everything before this step IS done - people can sign in. Tell me' 'Yellow'
        Say 'what it says and I will sort the records out separately.' 'Yellow'
    }
}

# ---- 8. prove it -------------------------------------------------------
Head 'Checking that sign-in actually works'

# Not a count of rows and not a guess. This signs a real token for a real
# account using the key just installed, with a password that is deliberately
# wrong. A wrong password is expected; a complaint about the signing key is
# not, and that is the thing being tested.
$probe = (& $psql -tA -U $DbUser -d $Db -c @"
SELECT coalesce((SELECT 'got-a-token' FROM hcis_login(
         (SELECT username FROM system_users
           WHERE status='active' AND password_hash <> '' ORDER BY username LIMIT 1),
         'deliberately-wrong-password') LIMIT 1), 'refused-as-expected')
"@ 2>&1) -join ' '

if ($probe -match 'signing secret|signing key') {
    Bail 'Sign-in STILL reports that the signing key is missing. Do not hand this box over in this state - nobody can get in.'
}
if ($probe -match 'ERROR') {
    Say 'The sign-in check returned an error:' 'Red'
    Say "  $probe" 'Red'
    Say 'Everything above was applied. Send me this and do not hand the box over yet.' 'Yellow'
} else {
    Say 'Sign-in answers correctly and does not complain about the key.' 'Green'
}

$after = Get-State
Show-State $after 'What is on this box now'

$stillMissing = @($after | Where-Object {
    $_.Present -eq 'no' -and $_.Kind -in @('core', 'change')
})

Rule
if ($stillMissing) {
    Say 'SOME THINGS ARE STILL MISSING:' 'Red'
    $stillMissing | ForEach-Object { Say ("  " + $_.Item) 'Red' }
    Say 'Send me a photo of this window.' 'Red'
} else {
    Say 'The database side is back.' 'Green'
    Write-Host ''
    Say 'Still to do, and this is NOT optional:' 'Yellow'
    Say '  1. run STEP-2-reload-api.bat - PostgREST learned the old structure' 'Yellow'
    Say '     when it started and will keep answering from it until told.' 'Yellow'
    Say '  2. sign in and check the dashboard shows numbers, not zeros.' 'Yellow'
    if (-not $NoAccounts) {
        Write-Host ''
        Say 'Each person uses the temporary password you typed, and will be asked' 'Cyan'
        Say 'to set their own the first time. Any account that was already here' 'Cyan'
        Say 'and working kept its own password - the table above says which.' 'Cyan'
    }
}
Write-Host ''
Say ("Backup, if anything needs undoing: {0}" -f $backup)
Rule
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
if ($stillMissing) { exit 1 }
exit 0
