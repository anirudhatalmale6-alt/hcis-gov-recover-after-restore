<#
  HCIS - what is on this box right now.

  READS ONLY. CHANGES NOTHING. Safe to run at any time, including while
  somebody is using the system, and safe to run before deciding whether
  anything needs fixing at all.

  It asks db\state.sql - the same file the recovery asks - so the two can
  never give different answers about the state of the box.

  Driven by WHAT-IS-MISSING.bat.
#>

param(
    [string]$Db         = 'hcis_db',
    [string]$DbUser     = 'postgres',
    [string]$PgBin      = '',
    [string]$DbPassword = ''
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }
function Rule { Write-Host '  ------------------------------------------------------------' }

if (-not $PgBin) {
    $PgBin = @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
               'C:\Program Files\PostgreSQL\16\bin', 'C:\Program Files\PostgreSQL\17\bin') |
             Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
}
if (-not $PgBin) { Say 'psql.exe was not found on this machine.' 'Red'; exit 1 }
$psql     = Join-Path $PgBin 'psql.exe'
$stateSql = Join-Path $PSScriptRoot 'db\state.sql'
if (-not (Test-Path $stateSql)) {
    Say 'db\state.sql is missing. Unzip the package again.' 'Red'; exit 1
}

if ($DbPassword) { $env:PGPASSWORD = $DbPassword }
. (Join-Path $PSScriptRoot 'db-access.ps1')
if (-not (Set-DbPassword)) { exit 1 }

& $psql -U $DbUser -d $Db -c 'select 1' *> $null
if ($LASTEXITCODE -ne 0) {
    Say "Cannot reach the database $Db on this machine." 'Red'
    Say 'If a restore is running, wait for it to finish and try again.' 'Yellow'
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

# Keep only lines with the three fields state.sql promises, so nothing else
# psql prints can be mistaken for a result.
$rows = @()
foreach ($line in (& $psql -tA -U $DbUser -d $Db -f $stateSql 2>&1)) {
    $p = ([string]$line).Split('|')
    if ($p.Count -eq 3 -and $p[2].Trim() -in @('yes','no')) {
        $rows += [pscustomobject]@{ Kind = $p[0].Trim(); Item = $p[1].Trim(); Present = $p[2].Trim() }
    }
}
if (-not $rows) {
    Say 'The check returned nothing at all. That is not a result, so I am not' 'Red'
    Say 'going to pretend it is one. Send me what is printed above.' 'Red'
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

Write-Host ''
Say '============================================================'
Say ' HCIS - what is on this box'
Say '============================================================'
Say (" {0}   database {1}" -f (Get-Date -Format 'dd MMM yyyy HH:mm'), $Db)

foreach ($k in @('core','change','account','data')) {
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
        if ($r.Present -eq 'yes') { Say ("  [ yes ] " + $r.Item) 'Green' }
        else                      { Say ("  [ NO  ] " + $r.Item) 'Red' }
    }
}

# ---- the verdict, in a sentence -----------------------------------------
#
# The list above is the evidence. This is the part somebody can act on, and
# the order matters: the signing key first, because when it is missing nothing
# else about the box is visible to anybody.
$coreMissing = @($rows | Where-Object { $_.Kind -eq 'core'   -and $_.Present -eq 'no' })
$chgMissing  = @($rows | Where-Object { $_.Kind -eq 'change' -and $_.Present -eq 'no' })
$keyMissing  = @($rows | Where-Object { $_.Item -like '41*'  -and $_.Present -eq 'no' }).Count -gt 0
$noAdmin     = @($rows | Where-Object { $_.Item -like '*administer*' -and $_.Present -eq 'no' }).Count -gt 0
$noHealth    = @($rows | Where-Object { $_.Item -like '*Needs Assessment module*' -and $_.Present -eq 'no' }).Count -gt 0
$noRecords   = @($rows | Where-Object { $_.Kind -eq 'data'   -and $_.Present -eq 'no' }).Count -gt 0

Write-Host ''
Rule
if ($coreMissing) {
    Say 'THIS DATABASE IS NOT HCIS.' 'Red'
    Write-Host ''
    Say 'These tables are not in it:' 'Red'
    $coreMissing | ForEach-Object { Say ("  " + $_.Item) 'Red' }
    Write-Host ''
    Say 'That means something else has been put here, not an older copy of' 'Yellow'
    Say 'HCIS. Do NOT run PUT-HCIS-BACK.bat - it would apply our updates to' 'Yellow'
    Say 'somebody else''s database. Send me a photo of this window.' 'Yellow'
} elseif ($keyMissing) {
    Say 'NOBODY CAN SIGN IN TO THIS BOX AT THE MOMENT.' 'Red'
    Write-Host ''
    Say 'The token signing key is missing. Sign-in needs it and refuses' 'Red'
    Say 'without it, so every password looks wrong, including correct ones.' 'Red'
    Write-Host ''
    Say 'Run PUT-HCIS-BACK.bat. It puts this and everything else back.' 'Green'
} elseif ($chgMissing) {
    Say ("{0} of the thirteen database updates are missing." -f $chgMissing.Count) 'Yellow'
    Write-Host ''
    Say 'People can still sign in, so this is not an emergency - but the box is' 'Yellow'
    Say 'behind and the Needs Assessment side will not work properly.' 'Yellow'
    Write-Host ''
    Say 'Run PUT-HCIS-BACK.bat.' 'Green'
} elseif ($noAdmin) {
    Say 'The updates are all in place, but there is no working administrator' 'Red'
    Say 'account on this box - so nobody can manage it.' 'Red'
    Write-Host ''
    Say 'Run PUT-HCIS-BACK.bat.' 'Green'
} else {
    Say 'This box is up to date. Nothing needs doing.' 'Green'
    if ($noHealth) {
        Write-Host ''
        Say 'One thing worth knowing: there is no Health Department account, so' 'Yellow'
        Say 'the Needs Assessment module will refuse everybody. NARS checks the' 'Yellow'
        Say 'group, not the job title, so even an administrator is turned away.' 'Yellow'
        Say 'PUT-HCIS-BACK.bat creates them.' 'Yellow'
    }
    if ($noRecords) {
        Write-Host ''
        Say 'And there are no assessment records on this box yet. That is' 'Gray'
        Say 'expected if they have not been moved across from the office' 'Gray'
        Say 'server - the records live there.' 'Gray'
    }
}
Rule
Write-Host ''
Say 'Nothing was changed by this check.' 'Gray'
Write-Host ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }

# Exit code so this can be used from another script: 0 nothing to do,
# 1 something needs attention, 2 this is not HCIS at all.
if ($coreMissing) { exit 2 }
if ($keyMissing -or $chgMissing -or $noAdmin) { exit 1 }
exit 0
