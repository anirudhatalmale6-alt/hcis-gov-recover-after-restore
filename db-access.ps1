<#
  Where the database password comes from.

  It used to be written inside every script, and those scripts are published in
  public repositories. It was only usable by somebody already logged on to that
  machine, so it was not an open door - but a government database password has
  no business sitting in a public repository, and I put it there.

  So the scripts no longer carry it. This finds it instead, in this order:

    1. the PGPASSWORD environment variable, if something already set it
    2. C:\HCIS\db-password.txt on this machine
    3. asks, once, with the typing hidden - and offers to save it to (2)
       so nothing ever has to ask again

  Step 2 is deliberately a fixed place on the machine rather than next to the
  script. Packages get downloaded fresh and extracted to new folders; the box
  does not change. Set it once and every later package finds it.

  Dot-source this from a script:   . "$PSScriptRoot\db-access.ps1"
  then call:                       Set-DbPassword
#>

function Get-DbPasswordPath {
    # Alongside the HCIS installation, which is where everything else lives.
    $root = if ($env:HCIS_ROOT) { $env:HCIS_ROOT } else { 'C:\HCIS' }
    return (Join-Path $root 'db-password.txt')
}

function Set-DbPassword {
    param(
        [switch]$Quiet,
        # Lets a test drive this without typing. Not for real use.
        [string]$Password = ''
    )

    function Note($m, $c = 'Gray') { if (-not $Quiet) { Write-Host "  $m" -ForegroundColor $c } }

    # ---- one place that answers "does this password actually work?" --------
    #
    # Every route into $env:PGPASSWORD goes through this. The first version of
    # this fix only tested the password somebody TYPED, and went on trusting
    # whatever was in the saved file - which was the exact thing that had just
    # wasted an hour on the government box. Half a fix is its own kind of bug.
    function Test-DbPassword {
        # HCIS_PGBIN first: it lets this be TESTED, and it covers a box where
        # PostgreSQL sits somewhere unusual. Without it the search below only
        # matches on Windows, so the check silently did not run at all.
        $pgbin = $null
        if ($env:HCIS_PGBIN -and (Test-Path -LiteralPath $env:HCIS_PGBIN -ErrorAction SilentlyContinue)) {
            $pgbin = $env:HCIS_PGBIN
        } else {
            foreach ($cand in @('C:\PostgreSQL\16\bin', 'C:\PostgreSQL\17\bin',
                                'C:\Program Files\PostgreSQL\16\bin',
                                'C:\Program Files\PostgreSQL\17\bin')) {
                $probe = $cand.TrimEnd('\') + '\psql.exe'
                try { if (Test-Path -LiteralPath $probe -ErrorAction SilentlyContinue) { $pgbin = $cand; break } } catch { }
            }
        }
        # No psql means this cannot be answered here. Say "cannot tell" rather
        # than "fine" - the caller carries on and the real command reports the
        # real error, which is better than a confident wrong yes.
        if (-not $pgbin) { return $null }

        $exe = Join-Path $pgbin 'psql'
        if (-not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) {
            $exe = Join-Path $pgbin 'psql.exe'
        }
        if (-not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) { return $null }

        $dbName = if ($env:HCIS_DB) { $env:HCIS_DB } else { 'hcis_db' }
        & $exe -U postgres -d $dbName -c 'select 1' *> $null
        return ($LASTEXITCODE -eq 0)
    }

    # 1. already set for this window - trusted, because whoever set it meant to
    if ($env:PGPASSWORD) { return $true }

    # 2. saved on this machine - READ, THEN TESTED. Never trusted on sight.
    $file = Get-DbPasswordPath
    if (Test-Path -LiteralPath $file) {
        $saved = (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue)
        if ($saved) {
            # A file written by Notepad usually ends with a newline, and a
            # password with a stray newline on the end is simply the wrong
            # password - with no error that says so.
            $env:PGPASSWORD = $saved.Trim("`r", "`n", " ", "`t")
            if ($env:PGPASSWORD) {
                $ok = Test-DbPassword
                if ($ok -eq $false) {
                    Note "The password saved in $file is NOT accepted by the database." 'Red'
                    Note 'Ignoring it and asking you instead. Delete that file when you have a moment.' 'Yellow'
                    $env:PGPASSWORD = ''
                } else {
                    Note "Using the database password saved in $file"
                    return $true
                }
            }
        } else {
            Note "$file is empty - ignoring it." 'Yellow'
        }
    }

    # 3. ask
    if ($Password) {
        $env:PGPASSWORD = $Password
    } else {
        Write-Host ''
        Note 'This needs the DATABASE password (the postgres one).' 'Yellow'
        Note 'It is not your HCIS login. You will see asterisks, or nothing at all - both are normal.' 'Yellow'
        $secure = Read-Host '  Database password' -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }

    if (-not $env:PGPASSWORD) {
        Note 'Nothing typed. Stopping rather than hanging at a prompt later.' 'Red'
        return $false
    }

    # Prove it before offering to keep it.
    $ok = Test-DbPassword
    if ($ok -eq $false) {
        Write-Host ''
        Note 'That password was not accepted by the database.' 'Red'
        Note 'Nothing has been saved and nothing has been changed.' 'Red'
        Write-Host ''
        Note 'It is the POSTGRES password, not your HCIS login. Try again,' 'Yellow'
        Note 'or tell me and we will reset it on this machine - that takes' 'Yellow'
        Note 'about ten minutes and loses no data.' 'Yellow'
        $env:PGPASSWORD = ''
        return $false
    }
    if ($ok -eq $true) { Note 'Password accepted by the database.' 'Green' }

    # offer to remember it, so this is the last time - only now that it works
    if (-not $Password) {
        Write-Host ''
        $yn = Read-Host '  Save it on this machine so you are not asked again? (y/n)'
        if ($yn -match '^(y|Y)') {
            try {
                $dir = Split-Path -Parent (Get-DbPasswordPath)
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                # -NoNewline matters: a trailing newline would be read back as
                # part of the password by anything less careful than the reader
                # above.
                Set-Content -LiteralPath (Get-DbPasswordPath) -Value $env:PGPASSWORD -NoNewline -Encoding ASCII
                # Readable only by this account and administrators, not by every
                # user of the machine. Its own try: the password is already
                # saved by this point, so failing to tighten the permissions is
                # worth saying out loud but is not a failure to save.
                try {
                    & icacls (Get-DbPasswordPath) /inheritance:r /grant:r "$env:USERNAME:(R,W)" "Administrators:(F)" 2>&1 | Out-Null
                } catch {
                    Note 'Saved, but could not restrict who may read the file.' 'Yellow'
                }
                Note ("Saved to " + (Get-DbPasswordPath) + " - you will not be asked again.") 'Green'
            } catch {
                Note ("Could not save it: " + $_.Exception.Message) 'Yellow'
                Note 'Not a problem - it will just ask again next time.' 'Yellow'
            }
        }
    }
    return $true
}
