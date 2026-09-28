$ErrorActionPreference = 'Stop'
<#
    Does tests/probe-ci-harness.ps1 actually check the runner, or is it green because it asserts
    nothing?

    It has been seen red three times this round - once for a missing function, twice for fixtures
    that silently never started - and a red caused by the probe being broken is not evidence that
    the probe can catch the runner being broken. So this file weakens the runner instead, twice, in
    two different places, and requires the probe to notice each one separately.

    Arm 1 - the leftover report switched off. One line is added to the copy, guarded by an
    environment variable, that throws the leftover list away at the exact site that turns a leftover
    into a red:

        if ("$env:KA_CIH_SABOTAGE" -eq '1') { $left = @() }

    With the variable on, the copy passes every leaking script it is handed - which is precisely the
    behaviour that let a 29m47s cancelled CI step report green - and probe-ci-harness.ps1 has to go
    red naming the two leaking legs and only those.

    Arm 2 - a leftover named that cannot belong to the leg. The copy is told a pid through
    KA_CIH_OLDPID and appends it to every leftover report; this file passes its OWN pid, which is
    old by construction because the probe it launches starts after it. That is the shape of the
    defect ka-ci.ps1's Get-OwnLeftovers birth window exists to stop: a local -Gates -Probes run
    (_tmp/ci-gates-probes-run1.log) named pid 21688 - this box's live worker, started hours earlier -
    as a leftover of probe-server-hint.ps1, because a recycled pid number made the ancestry walk run
    through it. The window's own red cannot be provoked in a fixture (asking Windows for a specific
    freed pid is not something a script can do), so the injection stands in for the coincidence and
    proves the assertion has teeth.

    A third run, the same copy with both variables unset, is what makes the two reds above mean
    something: without it each red could have come from the copy living in _tmp rather than from the
    sabotage.

    Each child gets its own fixture directory (KA_CIH_FXSUB) and this file's own copy is named after
    its pid, so two sweeps on one machine cannot overwrite or delete each other's subject mid-leg.
    Nothing here touches the product, the machine's power state, a scheduled task, or the running
    worker and panel - the opposite: naming that worker is the bug under test.
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$probe = Join-Path $here 'probe-ci-harness.ps1'
$src = Join-Path $here 'ka-ci.ps1'
# The mutant lives in its own directory with a copy of the walk library beside it. ka-ci.ps1
# dot-sources tests/ka-procwalk.ps1 from $PSScriptRoot, so a copy sitting alone in _tmp dies on that
# line (measured: 'The term ...\_tmp\ka-procwalk.ps1 is not recognized') and the control leg would go
# red for a reason that has nothing to do with the sabotage. A per-pid directory rather than a shared
# filename, so two sweeps on one machine cannot delete each other's subject mid-leg.
$mutDir = Join-Path $root ('_tmp/ci-harness-mutant-' + $PID)
$mut = Join-Path $mutDir 'ka-ci-mutant.ps1'

# Arm 1: the leftover report, blind.
$anchorBlind = '    if ($left.Count -gt 0) {'
$injectBlind = '    if ("$env:KA_CIH_SABOTAGE" -eq ''1'') { $left = @() }' + "`n" + $anchorBlind
# Arm 2: an old pid added to the report.
$anchorOld = '    $left = @(Format-Leftovers $leftIds $names)'
$injectOld = $anchorOld + "`n" + '    if ($env:KA_CIH_OLDPID) { $left += (''{0}:powershell.exe'' -f [int]$env:KA_CIH_OLDPID) }'

$text = [IO.File]::ReadAllText($src)
foreach ($pair in @(, @($anchorBlind, 'arm 1 (leftover report)')) + @(, @($anchorOld, 'arm 2 (old pid)'))) {
    $hits = [regex]::Matches($text, [regex]::Escape($pair[0])).Count
    if ($hits -ne 1) { throw "$hits copies of the $($pair[1]) site found in ka-ci.ps1 - the mutant would test nothing" }
}
$body = $text.Replace($anchorBlind, $injectBlind).Replace($anchorOld, $injectOld)
if ($body -eq $text) { throw 'no sabotage was applied' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mut) | Out-Null
[IO.File]::WriteAllText($mut, $body.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($true)))
Copy-Item -LiteralPath (Join-Path $here 'ka-procwalk.ps1') -Destination (Join-Path $mutDir 'ka-procwalk.ps1') -Force
Write-Output ('mutant written: ' + (Split-Path -Leaf $mut) + ' (+' + (([IO.File]::ReadAllLines($mut)).Count - ([IO.File]::ReadAllLines($src)).Count) + ' lines, 2 arms), with the walk library copied beside it')

function Run-Probe([hashtable]$Env, [string]$Sub) {
    # The whole probe, as its own process, against the sabotaged copy. -Wait is safe here: every
    # leftover this probe makes is waited out by the probe's own cleanup before it exits, and a child
    # that had to be killed would be the finding rather than an obstacle to measuring it.
    $f = Join-Path $env:TEMP ('ka-cih-selftest-' + $Sub + '-' + [guid]::NewGuid().ToString('N') + '.out')
    $env:KA_CIH_RUNNER = $mut
    $env:KA_CIH_FXSUB = $Sub
    $env:KA_CIH_SABOTAGE = $Env['SABOTAGE']
    $env:KA_CIH_OLDPID = $Env['OLDPID']
    try {
        $p = Start-Process -FilePath $ps -Wait -NoNewWindow -PassThru -RedirectStandardOutput $f `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $probe + '"')
        @{ Exit = [int]$p.ExitCode; Text = [IO.File]::ReadAllText($f) }
    } finally {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $root ('_tmp/ci-harness-fixtures-' + $Sub)) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$bad = @()
function Bad([string]$what, [string]$why) {
    $script:bad += ('{0}: {1}' -f $what, $why)
    Write-Output ('  FAIL ' + $what + ' - ' + $why)
}

function Show([string]$Label, [hashtable]$Run) {
    Write-Output ('--- ' + $Label + ' (exit=' + $Run.Exit + ')')
    Write-Output ($Run.Text -split "`r?`n" | Where-Object { $_ } | ForEach-Object { '  | ' + $_ })
}

Write-Output ('this process: pid ' + $PID + ', started ' + (Get-Process -Id $PID).StartTime.ToString('HH:mm:ss'))

$blind = Run-Probe @{ SABOTAGE = '1'; OLDPID = '' } 'arm1-blind'
Show 'arm 1, leftover report switched off' $blind

$old = Run-Probe @{ SABOTAGE = ''; OLDPID = '' + $PID } 'arm2-oldpid'
Show 'arm 2, a pid older than the probe named as a leftover' $old

$intact = Run-Probe @{ SABOTAGE = ''; OLDPID = '' } 'control-intact'
Write-Output ('--- the same copy with both arms switched off: exit=' + $intact.Exit +
    $(if ($intact.Text -match 'PROBE OK') { ', PROBE OK' } else { ', no verdict' }))

Remove-Item -LiteralPath $mutDir -Recurse -Force -ErrorAction SilentlyContinue

# ---- arm 1: the two leaking legs must be the only things that move. Naming them matters: a probe
# that goes red for a reason unrelated to the weakening would leave the leftover check untested.
if ($blind.Exit -eq 0) { Bad 'arm 1' 'the copy passed a script that leaves a process alive - probe-ci-harness.ps1 never noticed' }
if ($blind.Text -notmatch 'PROBE FAILED') { Bad 'arm 1' 'the run was red without a failure report, so it is a crash and not a judgement' }
foreach ($leg in 'gui-leak leg', 'console-leak leg') {
    if ($blind.Text -notmatch ('FAIL ' + [regex]::Escape($leg))) { Bad 'arm 1' ("the sabotage did not redden '{0}' - that leg does not check leftovers" -f $leg) }
}
if ($blind.Text -notmatch 'ok\s+ka-d-leak\.ps1') { Bad 'arm 1' "'ka-d-leak' was not marked ok under the sabotage, so the sabotaged runner was never actually handed a leftover" }
if ($blind.Text -match 'before this probe started at') { Bad 'arm 1' 'the age-window finding fired under arm 1, which names no pid at all - the two findings are not independent' }
foreach ($leg in 'clean leg', 'code leg', 'hang leg', 'verdict leg', 'summary', 'order', 'control', 'fixture', 'output') {
    if ($blind.Text -match ('FAIL ' + [regex]::Escape($leg))) { Bad 'arm 1' ("'{0}' went red too - the discrimination is not confined to the leftover assertion" -f $leg) }
}

# ---- arm 2: the age assertion must be the thing that reddens it.
if ($old.Exit -eq 0) { Bad 'arm 2' 'a leftover born before the probe was named and the age window let it through' }
foreach ($leg in 'gui-leak leg', 'console-leak leg') {
    if ($old.Text -notmatch ('FAIL ' + [regex]::Escape($leg))) { Bad 'arm 2' ("the injected old pid did not redden '{0}'" -f $leg) }
}
$ageHits = @([regex]::Matches($old.Text, 'before this probe started at')).Count
if ($ageHits -lt 2) { Bad 'arm 2' ('the age finding appeared ' + $ageHits + ' time(s); both leaking legs name the old pid, so it should appear on each') }
if ($old.Text -notmatch ('it named pid ' + $PID)) { Bad 'arm 2' ('the finding did not name the pid that was injected (' + $PID + ') - it reddened on something else') }
if ($old.Text -match 'ok\s+ka-a-clean\.ps1' -and $old.Text -notmatch 'FAIL (clean leg|code leg|hang leg|verdict leg|summary|order|control|fixture|output)') {
    # Expected: only the two leaking legs move. The check is the absence, stated as a pass condition
    # so a red here means a leg moved that arm 2 does not touch.
    Write-Output ('  | arm 2 moved only the legs it touches (' + $ageHits + ' age findings, no other leg red)')
}

# ---- control: without this, both reds above could be the copy being broken.
if ($intact.Text -notmatch 'PROBE OK') {
    Show 'control output' $intact
    Bad 'control' 'the copy is red even with both arms switched off, so the reds above prove nothing about the sabotage'
}
if ($intact.Exit -ne 0) { Bad 'control' ('the un-sabotaged copy exited ' + $intact.Exit + ' - probe-ci-harness.ps1 is not green through this path') }
if ($blind.Exit -ne 0 -and $old.Exit -eq 0) { Bad 'control' 'arm 1 was red and arm 2 green - one of the two arms is not wired' }

foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output ('PROBE OK: probe-ci-harness.ps1 reddens exactly the two leftover legs when the runner stops reporting leftovers, reddens them on the age window when a pid predating the probe is named as a leftover (' + $ageHits + ' findings), and stays green through the same copy with both reports restored')
exit 0
