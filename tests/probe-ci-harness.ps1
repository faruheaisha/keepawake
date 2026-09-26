$ErrorActionPreference = 'Stop'
<#
    Self-test for tests/ka-ci.ps1, the runner every CI step goes through.

    Its waiting logic was rewritten after run 36242306473 was cancelled with its own probe long
    finished and the step still running (the measurement behind that is in ka-ci.ps1's header). A
    rewrite that has only ever been seen green checks nothing, so this probe writes six one-off
    fixtures under _tmp/ and puts the real runner into each of the states it claims to tell apart:

        ka-a-clean    exits 0, leaves nothing        -> the leg must be ok
        ka-b-five     exits 5                        -> 'exit=5', not a silent 0
        ka-c-hang     sleeps 600 s                   -> named TIMEOUT at the deadline, loop carries on
        ka-d-leak     exits 0, leaves a GUI leftover -> the leftover, named with pid and image
        ka-e-nocmd    kills the cmd that started it  -> an unknown code is a red, never a pass
        ka-f-ghost    exits 0, leaves a console child-> same, and it is the shape that hung that run

    Two legs are differentials rather than expectations. ka-c-hang and ka-e-nocmd share one runner
    invocation, and the summary line has to count both - a runner that died or hung at the deadline
    would leave the count short. And ka-f-ghost is run twice over: once through the shipped runner,
    once through the `Start-Process -Wait` shape ka-ci.ps1 used before, on the same fixture. Measured
    on this box against a leftover that lives 14 s, the old shape takes 14 s and reports exit code 0;
    the shipped one takes about 3 s and reports the leftover by pid. Slow-and-silent versus
    fast-and-named, both numbers in one run.

    The clean leg is not filler either. The first version of this runner printed
    'left 1 descendant(s) alive: ' - count one, nothing after the colon - for a script that left
    nothing, because an empty result came back as the empty string and @('') holds one element; and
    it listed the fixture's conhost.exe beside the powershell.exe that mattered, where conhost is 23
    of the 402 process rows on this box at rest. Either defect would have reddened real CI steps that
    leak nothing, so both are assertions here.

    Nothing touches the product: no power setting, no scheduled task, no browser, no worker or panel.
    The leftovers are processes this probe's own fixtures start, they are matched by a path under
    _tmp that nothing else can carry, and they are waited out before this probe ends.

    That this file can go red is the claim tests/probe-ci-harness-selftest.ps1 checks: it copies
    ka-ci.ps1 with the leftover assertion switched off by an environment variable and requires this
    probe to notice, on exactly the two leaking legs and on nothing else.
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Both overridable for tests/probe-ci-harness-selftest.ps1, which runs this whole probe against a
# sabotaged copy of the runner. The copy has to live somewhere else and its fixtures have to live
# somewhere else, or the two runs share a directory and neither result is attributable.
$runner = if ($env:KA_CIH_RUNNER) { $env:KA_CIH_RUNNER } else { Join-Path $here 'ka-ci.ps1' }
$fxDir = Join-Path $root ('_tmp/ci-harness-fixtures' + $(if ($env:KA_CIH_FXSUB) { '-' + $env:KA_CIH_FXSUB } else { '' }))
$gcSleep = 14          # how long a leftover outlives the script that left it
$hangTimeout = 8       # -TimeoutSec handed to the runner; ka-c-hang sleeps 600 s
$blockThreshold = 8    # anything the shipped runner returns in must stay under this
$probeBorn = Get-Date  # every pid the runner may name as a leftover has to postdate this moment

$bad = @()
function Bad([string]$what, [string]$why) {
    $script:bad += ('{0}: {1}' -f $what, $why)
    Write-Output ('  FAIL ' + $what + ' - ' + $why)
}

function Write-Fixture([string]$Name, [string]$Body) {
    # With a BOM, and LF. These files carry absolute paths that can contain non-ASCII characters -
    # this very directory does - and a BOM is what makes Windows PowerShell 5.1 read them as UTF-8
    # whatever the machine's ANSI codepage is. (This box runs 65001, so a BOM-less file happens to
    # survive here; a runner at 1252 with a CJK checkout path would not.) _tmp/ is not one of the
    # byte-shape families tests/ka-encoding.ps1 scans, so the shape costs nothing.
    [IO.File]::WriteAllText((Join-Path $fxDir $Name), $Body.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($true)))
}

New-Item -ItemType Directory -Force -Path $fxDir | Out-Null
$gcPath = Join-Path $fxDir 'zz-gc-child.ps1'
$ghostPath = Join-Path $fxDir 'zz-ghost-child.ps1'
Write-Fixture 'ka-a-clean.ps1' @'
Write-Output 'CIH-TOKEN-CLEAN'
exit 0
'@
Write-Fixture 'ka-b-five.ps1' @'
Write-Output 'CIH-TOKEN-FIVE'
exit 5
'@
Write-Fixture 'ka-c-hang.ps1' @'
Write-Output 'CIH-TOKEN-HANG'
Start-Sleep -Seconds 600
exit 0
'@
Write-Fixture 'zz-gc-child.ps1' @"
Start-Sleep -Seconds $gcSleep
Write-Output 'CIH-TOKEN-GC'
"@
Write-Fixture 'zz-ghost-child.ps1' @"
Start-Sleep -Seconds $gcSleep
Write-Output 'CIH-TOKEN-GHOST'
"@
# A GUI leftover, started the way the product's own browser open is started (ShellExecute, nobody
# waiting). It holds no console and inherits no handle, so it is invisible to a waiting parent and
# lives on regardless - which is how five of them were still there when run 36242306473 was cancelled.
Write-Fixture 'ka-d-leak.ps1' @"
Write-Output 'CIH-TOKEN-LEAK'
`$si = New-Object Diagnostics.ProcessStartInfo
`$si.FileName = '$ps'
`$si.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "$gcPath"'
`$si.UseShellExecute = `$true; `$si.WindowStyle = 'Hidden'
`$null = [Diagnostics.Process]::Start(`$si)
Start-Sleep -Seconds 2
exit 0
"@
# A console leftover: started with -NoNewWindow, so it shares this console and outlives the script.
# This is the shape of a panel or a worker, and the shape that blocked `Start-Process -Wait`.
Write-Fixture 'ka-f-ghost.ps1' @"
Write-Output 'CIH-TOKEN-GHOSTLEAK'
`$null = Start-Process -FilePath '$ps' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "$ghostPath"' -NoNewWindow
exit 0
"@
# Stop-Process on the parent kills the cmd before its `& echo` runs, and the child that asked for it
# lives long enough to finish. That is the state itself, not an approximation: cmd died after the
# script ran, so the exit code is genuinely unknown rather than zero.
Write-Fixture 'ka-e-nocmd.ps1' @'
Write-Output 'CIH-TOKEN-NOCMD'
$parent = [int](Get-CimInstance Win32_Process -Filter ("ProcessId=" + $PID)).ParentProcessId
Stop-Process -Id $parent -Force
exit 0
'@

function Get-OwnLeftovers {
    # Anything started from a script inside our own fixture directory. The path is the identifier:
    # it is under _tmp, it is created by this probe, and no process belonging to anybody else can
    # carry it. Never match on a browser or on a name a user could have.
    @(Get-CimInstance Win32_Process -Property ProcessId, CommandLine -ErrorAction SilentlyContinue |
        Where-Object { "$($_.CommandLine)".Contains($fxDir) } | ForEach-Object { [int]$_.ProcessId })
}

function Run-Runner([string]$Only, [int]$TimeoutSec) {
    # The shipped runner, started the way the workflow starts it. -Wait is safe for these legs only
    # because no fixture in them leaves anything alive; the leaking fixtures go through
    # Run-RunnerTimed, where waiting would be the thing under test rather than the tool measuring it.
    $f = Join-Path $env:TEMP ('ka-cih-' + [guid]::NewGuid().ToString('N') + '.out')
    $argText = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '" -Gates -Dir "' + $fxDir + '" -TimeoutSec ' + $TimeoutSec
    if ($Only) { $argText += ' -Only ' + $Only }   # bare: measured, a quoted -Only selects nothing
    try {
        $p = Start-Process -FilePath $ps -Wait -NoNewWindow -PassThru -RedirectStandardOutput $f -ArgumentList $argText
        @{ Exit = [int]$p.ExitCode; Text = (Get-RunnerText $f) }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function Run-RunnerTimed([string]$Only, [int]$TimeoutSec, [int]$BudgetSec) {
    # Same runner, timed, and NOT waited on: waiting would block on the leftover and hide the very
    # property being measured. The object's exit code is deliberately not read here - row 1 of the
    # table in ka-ci.ps1's header says a non-waiting Start-Process reports 0 whatever the child
    # exited. The verdict comes from the summary line the runner prints itself.
    $f = Join-Path $env:TEMP ('ka-cih-' + [guid]::NewGuid().ToString('N') + '.out')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath $ps -NoNewWindow -PassThru -RedirectStandardOutput $f `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '" -Gates -Dir "' + $fxDir + '" -TimeoutSec ' + $TimeoutSec + ' -Only ' + $Only)
        while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $BudgetSec) { Start-Sleep -Milliseconds 100 }
        $sw.Stop()
        @{ Exited = [bool]$p.HasExited; Sec = [double]$sw.Elapsed.TotalSeconds; Text = (Get-RunnerText $f) }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function Get-RunnerText([string]$File) {
    # Not ReadAllText. A leftover the runner just named can still hold this redirect handle open -
    # measured: after a poll-shaped run the file answered 'HELD' to an exclusive-open probe while its
    # writer was long gone - and File.OpenRead asks for a share mode that such a holder denies.
    # Read with share ReadWrite, retrying briefly, and return whatever is flushed so far.
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    for ($i = 0; $i -lt 10; $i++) {
        $fs = $null
        try {
            $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object IO.StreamReader($fs)
            $fs = $null
            return $sr.ReadToEnd()
        } catch { Start-Sleep -Milliseconds 200 }
        finally { if ($fs) { $fs.Dispose() } }
    }
    return ''
}

function Show([string]$Text) { $Text -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Output ('  | ' + $_) } }

function Assert-NamedAreYoung([string]$Text, [string]$Label) {
    <#
        Every pid the runner names as a leftover must have been born after this probe started: the
        runner itself was started after that moment, so a process older than it predates every leg the
        runner ran and cannot be something a leg left behind.

        This is the invariant behind the birth window in ka-ci.ps1's Get-OwnLeftovers, and the window's
        red was not manufactured - a local -Gates -Probes run (_tmp/ci-gates-probes-run1.log) printed
        'FAIL probe-server-hint.ps1 ... left 1 descendant(s) alive: 21688:powershell.exe', and 21688 is
        this box's own running worker, started hours before the run. No fixture can provoke that: the
        only route for an old process into that list is a recycled pid number, which is not something a
        script can ask Windows for. So the fixtures check the invariant holds for what the runner does
        name, and tests/probe-ci-harness-selftest.ps1 checks it can fail, by injecting a pid that is
        old by construction (the harness's own).
    #>
    $ids = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch 'alive: ') { continue }
        foreach ($m in [regex]::Matches($line, '(\d+):[A-Za-z0-9_.-]+')) { $ids += [int]$m.Groups[1].Value }
    }
    $ids = @($ids | Sort-Object -Unique)
    if (-not $ids.Count) { Bad $Label 'the runner named no leftover here, so this leg does not exercise the age window' ; return }
    $judged = 0
    foreach ($id in $ids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $p) { Write-Output ('  | pid ' + $id + ' had already exited, so its age cannot be judged'); continue }
        $judged++
        if ($p.StartTime -lt $probeBorn) {
            Bad $Label ('it named pid ' + $id + ' (' + $p.ProcessName + '), born ' + $p.StartTime.ToString('HH:mm:ss') +
                ' - before this probe started at ' + $probeBorn.ToString('HH:mm:ss') + ', so it is not a leftover of any leg')
        }
    }
    if ($judged -eq 0) { Bad $Label 'every pid it named had already exited, so the age window was checked against nothing' }
}

function Format-Seen([int[]]$Ids) {
    # Its own function because `$Ids.Count + ' alive'` is a real trap: the left operand is an Int32,
    # so PowerShell casts the string to Int32 and throws instead of concatenating. Every path here
    # returns a string, the empty one included - and @('') has Count 1, so emptiness is tested on the
    # array, not on a joined string.
    if (-not $Ids -or $Ids.Count -eq 0) { return 'NONE alive' }
    return ($Ids.Count.ToString() + ' alive: ' + ($Ids -join ', '))
}

# ---------------------------------------------------------------- leg 1: four states, one run
Write-Output '--- shipped runner over clean / five / hang / no-cmd'
$a = Run-Runner '^ka-[abce]-' $hangTimeout
Show $a.Text
foreach ($t in 'CIH-TOKEN-CLEAN', 'CIH-TOKEN-FIVE', 'CIH-TOKEN-HANG', 'CIH-TOKEN-NOCMD') {
    if (-not $a.Text.Contains($t)) { Bad 'output' ("$t never reached the log - the runner is losing its children's text") }
}
if ($a.Text -notmatch '(?m)^ok   ka-a-clean\.ps1') { Bad 'clean leg' 'the script that leaves nothing did not come back ok' }
if ($a.Text -notmatch '(?m)^FAIL ka-b-five\.ps1\s+\d+s exit=5') { Bad 'code leg' 'exit=5 was not reported as exit=5' }
if ($a.Text -notmatch ('(?m)^FAIL ka-c-hang\.ps1\s+\d+s TIMEOUT after ' + $hangTimeout + 's, tree killed')) {
    Bad 'hang leg' "no named TIMEOUT at ${hangTimeout}s - a hanging script still eats the step"
}
if ($a.Text -notmatch '(?m)^FAIL ka-e-nocmd\.ps1\s+\d+s no verdict file') {
    Bad 'verdict leg' 'cmd died before writing its verdict and the leg was not called red for an unknown code'
}
$hangAt = $a.Text.IndexOf('ka-c-hang')
$nocmdAt = $a.Text.IndexOf('ka-e-nocmd')
if ($hangAt -lt 0 -or $nocmdAt -lt 0) { Bad 'order' 'one of the two legs never printed at all' }
elseif ($nocmdAt -lt $hangAt) { Bad 'order' 'the no-verdict leg printed before the hang, so the run did not continue past the deadline' }
$failLines = @([regex]::Matches($a.Text, '(?m)^FAIL ')).Count
if ($a.Text -notmatch '(?m)^----- 4 run, (\d+) red') { Bad 'summary' 'no summary line for the 4 scripts that were selected' }
elseif ([int]$Matches[1] -ne $failLines) { Bad 'summary' ("the summary counts {0} red but {1} red lines were printed" -f $Matches[1], $failLines) }
if ($a.Exit -eq 0) { Bad 'summary' 'three legs were named red and the runner still exited 0' }

# ---------------------------------------------------------------- leg 2: a GUI leftover is named
Write-Output '--- shipped runner over the GUI leftover (ka-d-leak)'
$b = Run-RunnerTimed '^ka-d-' $hangTimeout 60
$seenB = @(Get-OwnLeftovers)
Write-Output ('  | our own look: ' + (Format-Seen $seenB))
if (-not $seenB.Count) { Bad 'fixture' 'ka-d-leak left no process alive, so this leg cannot judge the runner either way' }
Show $b.Text
$mB = [regex]::Match($b.Text, '(?m)^FAIL ka-d-leak\.ps1\s+\d+s left (\d+) descendant\(s\) alive: (\d+):powershell\.exe')
if (-not $mB.Success) { Bad 'gui-leak leg' ('the leftover was not named with its pid and image: ' + $b.Text) }
else {
    if ([int]$mB.Groups[1].Value -ne 1) { Bad 'gui-leak leg' ("it left one process and the runner counted {0}" -f $mB.Groups[1].Value) }
    if ($seenB -notcontains [int]$mB.Groups[2].Value) { Bad 'gui-leak leg' ("the pid it named ({0}) is not one of the leftovers we can see ({1})" -f $mB.Groups[2].Value, ($seenB -join ',')) }
}
if ($b.Text -match 'conhost') { Bad 'gui-leak leg' 'the console host was listed as a leftover - every clean script could go red on it' }
Assert-NamedAreYoung $b.Text 'gui-leak leg'
if (-not $b.Exited) { Bad 'gui-leak leg' ("the runner was still alive after {0:0}s - it waited for the leftover it was reporting" -f $b.Sec) }
elseif ($b.Sec -ge $blockThreshold) { Bad 'gui-leak leg' ('the runner took {0:0}s for a script that exits in 2s, so it blocked on the leftover' -f $b.Sec) }

# ---------------------------------------------------------------- leg 3: a console leftover is named
Write-Output '--- shipped runner over the console leftover (ka-f-ghost)'
$d = Run-RunnerTimed '^ka-f-' $hangTimeout 60
$seenD = @(Get-OwnLeftovers)
Write-Output ('  | our own look: ' + (Format-Seen $seenD))
if (-not $seenD.Count) { Bad 'fixture' 'ka-f-ghost left no process alive, so this leg cannot judge the runner either way' }
Show $d.Text
$mD = [regex]::Match($d.Text, '(?m)^FAIL ka-f-ghost\.ps1\s+\d+s left (\d+) descendant\(s\) alive: (\d+):powershell\.exe')
if (-not $mD.Success) { Bad 'console-leak leg' ('the console leftover was not named with its pid and image: ' + $d.Text) }
Assert-NamedAreYoung $d.Text 'console-leak leg'
if (-not $d.Exited) { Bad 'console-leak leg' ("the runner was still alive after {0:0}s - it waited for the console child" -f $d.Sec) }
elseif ($d.Sec -ge $blockThreshold) { Bad 'console-leak leg' ('the runner took {0:0}s for a script that exits at once, so it blocked on the console child' -f $d.Sec) }

# ---------------------------------------------------------------- leg 4: what the old shape did
Write-Output '--- old Start-Process -Wait over the same console leftover (control)'
$sw = [Diagnostics.Stopwatch]::StartNew()
$gp = Start-Process -FilePath $ps -Wait -NoNewWindow -PassThru `
    -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $fxDir 'ka-f-ghost.ps1') + '"')
$sw.Stop()
$oldSec = [double]$sw.Elapsed.TotalSeconds
Write-Output ('  | old shape: {0:0}s, exit code {1}' -f $oldSec, [int]$gp.ExitCode)
if ($oldSec -lt $blockThreshold) {
    Bad 'control' ("Start-Process -Wait came back in {0:0}s although the leftover lives {1}s - the differential in leg 3 would then prove nothing" -f $oldSec, $gcSleep)
}
if ([int]$gp.ExitCode -ne 0) { Bad 'control' ("the old shape reported exit {0} for a leftover; it reported 0 the whole time run 36242306473 was hanging" -f [int]$gp.ExitCode) }
$dVerdict = if ($mD.Success) { 'red' } else { 'green' }
$cmp = '  | one leftover, two waiters: old -Wait {0:0}s and silent, shipped runner {1:0}s and {2} (the leftover lives {3}s)'
Write-Output ($cmp -f $oldSec, $d.Sec, $dVerdict, $gcSleep)

# ---------------------------------------------------------------- cleanup: leave nothing of our own
Write-Output '--- cleanup'
$waited = [Diagnostics.Stopwatch]::StartNew()
$alive = @(Get-OwnLeftovers)
while ($alive.Count -and $waited.Elapsed.TotalSeconds -lt ($gcSleep + 20)) {
    Start-Sleep -Milliseconds 500
    $alive = @(Get-OwnLeftovers)
}
if ($alive.Count) {
    Bad 'cleanup' ("our own fixtures were still alive after {0:0}s: {1} - stopping them" -f $waited.Elapsed.TotalSeconds, ($alive -join ', '))
    foreach ($id in $alive) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    $still = @(Get-OwnLeftovers)
    if ($still.Count) { Bad 'cleanup' ("still alive after Stop-Process: {0}" -f ($still -join ', ')) }
}
Remove-Item -LiteralPath $fxDir -Recurse -Force -ErrorAction SilentlyContinue

if ($bad.Count) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: the runner names a wrong exit code, a hang, a GUI leftover, a console leftover and a missing verdict; stays green for the script that leaves nothing; and returns in a fifth of the time the old -Wait shape takes on the same leftover it says nothing about'
exit 0
