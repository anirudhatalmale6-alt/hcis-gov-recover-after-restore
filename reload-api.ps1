<#
  HCIS - restart the API and PROVE the new columns are visible.

  Why this step exists at all:

  The database now has columns that did not exist before - the payroll
  placements, the pension amounts, the institution allowance. PostgREST keeps
  its own copy of the database's shape in memory and will happily keep serving
  the OLD shape after the database has changed. When that happens the site
  looks broken in a way that has nothing to do with the browser: payroll comes
  back empty or errors, and clearing the cache does not help.

  The catch-up asks the database to tell PostgREST to reload. That only works
  if PostgREST is listening for it, so this restarts it outright and then
  checks the result rather than assuming.

  And it checks by the PID. On 21 August "schtasks /End" reported SUCCESS on
  this very box while killing nothing at all - the running postgrest.exe had
  been started by hand, and a service manager can only stop what it started.
  It reported success and the old schema kept being served for an afternoon.
  So: the process id must CHANGE, or this script says so.
#>
$ErrorActionPreference = 'Continue'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '============================================================'
Say ' HCIS - reload the API so it can see the new columns'
Say '============================================================'
Say ''

function Get-PortPid {
    $line = (netstat -ano | Select-String ':3000\s' | Select-String 'LISTENING' |
             Select-Object -First 1)
    if (-not $line) { return $null }
    return ($line.ToString().Trim() -split '\s+')[-1]
}

$before = Get-PortPid
if ($before) { Say "PostgREST is running now as process $before." }
else { Say 'Nothing is listening on port 3000 at the moment.' 'Yellow' }

Say ''
Say 'Stopping it...'
taskkill /F /IM postgrest.exe 2>&1 | Out-String | Write-Host
Start-Sleep -Seconds 2

Say 'Starting it again through the scheduled task...'
schtasks /Run /TN "PostgREST-HCIS" 2>&1 | Out-String | Write-Host
Start-Sleep -Seconds 6

$after = Get-PortPid
if (-not $after) {
    Say ''
    Say 'The scheduled task did not bring it back up. Trying directly...' 'Yellow'
    $bat = 'C:\HCIS\postgrest\start-postgrest.bat'
    if (Test-Path -LiteralPath $bat) {
        Start-Process -FilePath $bat -WindowStyle Minimized
        Start-Sleep -Seconds 6
        $after = Get-PortPid
    }
}

if (-not $after) {
    Say ''
    Say 'THE API IS NOT RUNNING. The site will not load data until it is.' 'Red'
    Say 'Send me a photo of this window - do not run anything else.'
    Say ''
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}

Say ''
if ($before -and ($after -eq $before)) {
    Say "The process id is STILL $after - it did not actually restart." 'Red'
    Say 'This is exactly what happened on 21 August. Send me a photo.'
    Say ''
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
Say "Restarted. It is now process $after (it was $before) - so it really did restart." 'Green'

# ---- the actual proof: ask the API for something that did not exist before
#
# This used to read a column off the payroll_records table without signing in.
# That check is now WRONG, and worse, wrong in the safe-looking direction: the
# 15 September change deliberately took the anonymous role's access to every
# table away, so a correctly updated box answers "permission denied for table
# payroll_records" and the script used to shout "Do NOT deploy". It cried wolf
# on exactly the boxes that were fine.
#
# So ask something that needs no table privileges at all. The sign-in function
# is the one thing the anonymous role may still call - it has to be, or nobody
# could ever log in - and the catch-up REPLACED it so that it hands back an
# access_token. Ask PostgREST for that column by name, with a username that
# cannot exist:
#
#   * new function in the cache -> 200 and an empty list (no such user)
#   * old function still cached -> 400, "column ... access_token does not exist"
#   * no function at all        -> 404 PGRST202, the migrations never ran
#
# Nothing is written either way: for an unknown username the function returns
# before it touches the failed-attempt counter. Verified against the live API.
Say ''
Say 'Asking the API for one of the new fields...'

function Ask-Column($col) {
    $uri = 'http://localhost:3000/rpc/hcis_login?select=' + $col
    $body = '{"p_identifier":"zz.schema.probe.nobody","p_password":"x"}'
    try {
        $r = Invoke-WebRequest -Uri $uri -Method Post -Body $body `
                 -ContentType 'application/json' -UseBasicParsing -TimeoutSec 20
        return @{ Code = [int]$r.StatusCode; Body = $r.Content }
    } catch {
        # Getting the status and the body out of a failed request is not the
        # same in both PowerShells, and this box may have either. Windows
        # PowerShell 5.1 gives an HttpWebResponse, which has a stream to read.
        # PowerShell 7 gives an HttpResponseMessage, which has NO
        # GetResponseStream at all - calling it throws, and then the code and
        # the body are both lost and this script cannot tell a 400 from a 404.
        # So take whichever route the object actually offers.
        $resp = $_.Exception.Response
        $code = 0
        if ($resp) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }

        $body = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = $_.ErrorDetails.Message
        } elseif ($resp -and ($resp | Get-Member -Name GetResponseStream -MemberType Method)) {
            try {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
            } catch { $body = '' }
        }
        if (-not $code -and -not $body) { $body = $_.Exception.Message }
        return @{ Code = $code; Body = $body }
    }
}

$real  = Ask-Column 'access_token'
# The control. If asking for a column that CANNOT exist also comes back 200,
# then this test proves nothing and must not be reported as a pass.
$bogus = Ask-Column 'no_such_column_zz'

$ok = $false
$why = ''
if ($real.Code -eq 200 -and $bogus.Code -eq 200) {
    $why = 'This check cannot tell right from wrong on this box - it accepted a field name that does not exist. Send me a photo; do not treat this as a pass.'
} elseif ($real.Code -eq 200) {
    $ok = $true
} elseif ($real.Code -eq 404) {
    $why = 'The API has no hcis_login function at all - the database step has not run, or not finished. Run STEP-1-database.bat first.'
} elseif ($real.Code -eq 400) {
    $why = 'The API is still serving the OLD shape of the sign-in function - the restart did not refresh it. This is the 21 August problem again.'
} elseif ($real.Code -eq 0) {
    $why = 'Could not reach the API at all: ' + $real.Body
} else {
    $why = ('The API answered ' + $real.Code + ': ' + $real.Body)
}

Say ''
if ($ok) {
    Say '============================================================'
    Say ' GOOD - the API is serving the new shape.' 'Green'
    Say ' Now run deploy-frontend.ps1, then Ctrl+F5 in the browser.'
    Say '============================================================'
} else {
    Say '============================================================'
    if ($real.Code -eq 0) {
        Say ' The API could not be reached.' 'Red'
    } else {
        Say ' The API is running but is NOT serving the new shape.' 'Red'
    }
    Say ''
    Say (' ' + $why) 'Red'
    Say ''
    Say ' Do NOT deploy the new build yet.' 'Red'
    Say ' Send me a photo of this window and I will sort it.'
    Say '============================================================'
}
Say ''
if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
if ($ok) { exit 0 } else { exit 1 }
