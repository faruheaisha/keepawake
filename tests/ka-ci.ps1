<#
    The one runner behind every CI step, and the reason the workflow files stay short.

    Each gate, probe and suite script is started as its own powershell.exe, because that is how
    they were written and how they were measured by hand: they set $env:KA_DATA, capture
    $PSScriptRoot and leave scheduled tasks behind, so sharing one session between two of them
    would test a situation nobody has ever run. A child also gives an unambiguous exit code.

    Failures are collected, not fatal on the first one: a red CI that names every red script is
    one round trip instead of one per run.

    HOW THE WAIT WORKS, and why it is not one call. Four shapes were run against one child that
    prints a marker line, leaves a grandchild asleep for 6 s, and then `exit 5` - all four in a
    single run, all three columns read from the same log (_tmp/wait-table-run1.log; the one-off
    drivers around it are no longer on disk, and the 2026-09-30 reruns below are the second,
    re-readable source):

        shape                                        child's text    blind to the     code
                                                   reaches the log   grandchild?      reported
        Start-Process -PassThru, HasExited poll     yes              yes   (0.7 s)    $null -> 0 (lies)
        Start-Process -PassThru, WaitForExit()      yes              yes   (0.8 s)    $null -> 0 (lies)
        Start-Process -Wait -PassThru               yes              no    (8.1 s)    5  (true)
        [Diagnostics.Process]::Start, stdout
            redirected and never read, WaitForExit  NO - lost        yes   (0.8 s)    5  (true)

    The 0 in rows 1/2 is the launch switches, not the read position (corrected a second time on
    2026-09-30; the sentence before this one said "read position decides" and was wrong - it had
    rerun the bare shape and dropped the switches, which is the one variable that matters). The
    measured rule, three independent drivers, two shapes of child: a non-waited Start-Process
    object answers a silent $null while the child still runs (any shape), and after your own
    poll/WaitForExit()/WaitForExit(ms) it answers the real code ONLY when the launch carried
    neither -NoNewWindow nor a standard-stream redirect. With either switch it stays a silent
    $null even though HasExited is True - Refresh() and re-waiting do not help; the process is
    gone and the code is unrecoverable. Rows 1/2 read $null after their polls because their
    driver needed the child's text in the log, and text in the log is exactly -NoNewWindow.
    (_tmp/exitcode-switch-matrix-20260930.txt T1-T10, reruns in -switch-verify- and
    -switch-recheck-, pinned in -switch-pin- W1-W7.) What still separates the shapes: -Wait pays
    with the leftover's lifetime (row 3), and .NET with an undrained stdout pipe loses the
    child's text (row 4) - which is what a CI log is.

    -Wait also blocks on what the child leaves behind, and how far depends on the shape of the
    leftover. Same three leftovers, this time varying only the window style (_tmp/ws-outer2.log, no
    redirect; the driver's default -Life 6 is not echoed into that log, so the leftover length is
    read off the console row): a console powershell blocked -Wait for 9.1 s and had waited its
    leftover out ("leftover-after=gone"), a -WindowStyle Hidden powershell for 10.1 s and the same,
    but a GUI process with no console (notepad) only 1.0 s - "leftover-after=alive", still running
    when the wait returned. With -RedirectStandardOutput instead (_tmp/ws-outer.log, 6 s leftovers):
    7.1 s / 7.1 s / 1.0 s, and the two poll shapes came back in 0.6 s and 0.7 s with their leftover
    still alive and still holding the redirect file open ("redirect=HELD" - the collector could not
    read its own child's text back until the grandchild let go).

    So the thing that cancelled run 36242306473 was a leftover holding a console, and it was not by
    itself the five orphan msedge processes that run's cleanup listed where the green run before it
    had none: a browser is exactly the shape -Wait lets go. The log names neither, so the blocking
    process stays unidentified - what is identified is the shape.
    Either way -Wait pays for its truth with somebody else's lifetime, and a step that pays it for
    29m47s until GitHub cancels it is the outcome this file exists to avoid. The collector that ran
    the table above is itself an illustration: every row's cmd took 8.1 s end to end while the shape
    inside it had returned in 0.7 s, because the collector waited with -Wait on a console grandchild.

    So the direct child here is cmd.exe, which exits the moment the script does (blind to whatever
    the script left alive), whose console the script's text reaches (it is Start-Process -NoNewWindow
    all the way down), and which writes the script's own ERRORLEVEL into a verdict file. The file
    beats reading the object's .ExitCode on two counts: this launch carries -NoNewWindow, and an
    object from that shape answers a silent $null even after the exit - the read could not be made
    real from here at all (see the note above) - and after a deadline kill the number would belong
    to the kill, while the file is written by the script's own completion - evidence whose
    existence cannot be misordered.
    The loop then polls HasExited with a deadline; on the deadline it kills the whole tree with
    TerminateJobObject, so a hanging script names itself instead of eating the step and cannot drag its
    leftovers into the next one. That, and the answer to "which processes did this leg leave behind?",
    both come from the same Windows Job object every leg is started inside, unioned with the guarded
    pid->ppid walk - see tests/ka-procwalk.ps1 for the four false results that forced the union and for
    why each source is needed. No verdict file
    is never treated as a zero: it is a red that says so, which is the same rule
    tests/probe-bat-entry.ps1 fact 4 runs on.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-ci.ps1 -Gates
        ... -Probes | -Suite | -Only <regex on file name>
        ... (no switch) = -Gates -Probes
        ... -Dir <folder> -TimeoutSec <n> -Only <regex>   (how tests/probe-ci-harness.ps1 points
            this runner at one-off fixtures instead of copying this waiting logic somewhere else)

    -Suite is the full tests/ka-tests.ps1. It is deliberately opt-in: it is the slow one, and it
    is the only step that touches the machine it runs on (power settings, scheduled tasks), so
    running it locally is a decision, not a reflex.
#>
[CmdletBinding()]
param(
    [switch]$Gates,
    [switch]$Probes,
    [switch]$Suite,
    [string]$Only = '',
    [string]$Dir = '',
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$here = if ($Dir) { (Resolve-Path -LiteralPath $Dir).Path } else { $PSScriptRoot }
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmd = Join-Path $env:windir 'System32\cmd.exe'
$selected = @()
if (-not ($Gates -or $Probes -or $Suite)) { $Gates = $true; $Probes = $true }
if ($Gates) {
    # ka-release-files.ps1 is a manifest (it prints a list), ka-procwalk.ps1 is the library of
    # functions for the leftover walk (dot-sourced below, never run on its own), ka-tests.ps1 is the
    # suite and ka-ci.ps1 is this script - none of them is a gate, and globbing them would be a loop.
    $selected += @(Get-ChildItem -LiteralPath $here -Filter 'ka-*.ps1' -File |
        Where-Object { $_.Name -notmatch '^(ka-procwalk|ka-release-files|ka-tests|ka-ci)\.ps1$' } |
        Sort-Object Name)
}
if ($Probes) { $selected += @(Get-ChildItem -LiteralPath $here -Filter 'probe-*.ps1' -File | Sort-Object Name) }
if ($Suite) { $selected += @(Get-Item -LiteralPath (Join-Path $here 'ka-tests.ps1')) }
if ($Only) { $selected = @($selected | Where-Object { $_.Name -match $Only }) }
if (-not $selected.Count) { Write-Host 'nothing selected - check the -Only pattern'; exit 1 }

# The leg's process bookkeeping lives in its own file so tests/probe-procwalk.ps1 can drive it
# directly: it is the subtlest logic in this runner, and the pid->ppid reconstruction it replaced had
# been fooled four times (see that file's header). It defines functions, it is not a gate, which is
# also why it is excluded from the gate glob above.
# $PSScriptRoot, not $here: -Dir points the *selection* at one-off fixtures (that is how
# tests/probe-ci-harness.ps1 drives the shipped runner), and the library is not there. Measured:
# 'The term ...\_tmp\ci-harness-fixtures\ka-procwalk.ps1 is not recognized'.
. (Join-Path $PSScriptRoot 'ka-procwalk.ps1')
$bad = @()

function Invoke-Leg([object]$f) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $codeFile = Join-Path $env:TEMP ('kaci-' + [guid]::NewGuid().ToString('N') + '.code')
    # /v:on because !ERRORLEVEL! has to be read after the script ran; cmd expands %VAR% when it
    # parses the line, which is before anything has happened.
    $line = '/v:on /c ""' + $ps + '" -NoProfile -ExecutionPolicy Bypass -File "' + $f.FullName + '" & echo !ERRORLEVEL!> "' + $codeFile + '"'
    # A hair before the cmd exists: the lower edge of the window a leftover has to fall in. Taken
    # early on purpose - a bound a few ms too generous cannot drop a real leftover, while one a few
    # ms too tight can.
    $legBorn = Get-Date
    # The leg's tree is marked by construction: a job object holds the cmd and everything it creates,
    # so "which processes are this leg's" is a query instead of an archaeology of pids. It is the exact
    # half of the union; the walk below is the other half, because the job cannot see a process the
    # shell launches. See tests/ka-procwalk.ps1 for the four false results that forced the union.
    $job = [Ka.LegJob]::Create()
    if ($job -eq [IntPtr]::Zero) { throw 'CreateJobObject failed - the leftover check has no meaning without it' }
    $child = Start-Process -FilePath $cmd -NoNewWindow -PassThru -ArgumentList $line
    $childPid = [int]$child.Id
    $assignErr = [Ka.LegJob]::Assign($job, $childPid)
    if ($assignErr) {
        # Fatal rather than a red leg: without the assignment every later answer would be a guess, and
        # a guess that silently passes is the failure mode this file has spent four rounds removing.
        [Ka.LegJob]::Close($job)
        throw ("could not put the leg (pid $childPid) into its job: $assignErr")
    }

    # HasExited on the cmd we started: truthful (2.5 s for a child that lived 2 s) and blind to
    # descendants (0.5 s while a 6 s grandchild was still alive). The deadline is what turns a silent
    # 30-minute hang into one named line. The pid->ppid history is sampled in the same loop, one query
    # every 2 s: it is what lets the reconstruction see a leftover the job cannot - a process the shell
    # launched, which is not our child and inherits nothing.
    $exited = $false
    $hist = @{ }
    $names = @{ }
    $born = @{ }
    $nextSample = 0.0
    $seenAt = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($child.HasExited) { $exited = $true; $seenAt = Get-Date; break }
        if ($sw.Elapsed.TotalMilliseconds -ge $nextSample) {
            Update-ProcessHistory $hist $names $born
            $nextSample = $sw.Elapsed.TotalMilliseconds + 2000
        }
        Start-Sleep -Milliseconds 200
    }
    Update-ProcessHistory $hist $names $born
    if (-not $seenAt) { $seenAt = Get-Date }

    $answer = Get-KaLegPids $job
    if (-not $answer.Ok) {
        [Ka.LegJob]::Close($job)
        throw ("QueryInformationJobObject failed for the leg (pid $childPid, Win32 $($answer.Err)) - the leftover check cannot answer")
    }
    # Both sources, and the union is the point: the job knows the tree exactly but is blind to anything
    # the shell launched (measured on CI, run 36534077753 - the deliberate GUI leak was missing from the
    # job while being alive and visible), and the reconstruction sees those but needs its two guards.
    # Neither source can silently shrink the report; each covers the other's blind spot.
    $members = @(@($answer.Pids) + @(Get-LeakedDescendants $childPid $hist $names $born) | Select-Object -Unique)
    # One query, after the alive check, supplies the names for whatever survives. The job identifies
    # the tree; the age window is belt-and-braces around a pid recycled *within* the leg.
    $consoleHosts = @('conhost.exe', 'OpenConsole.exe')
    # conhost.exe and OpenConsole.exe are pseudo-console hosts Windows starts for a process that gets
    # its own window station: a member of the leg's job, but not a leftover anybody can act on - they
    # die with the session, hold no port, no power request and no file handle. Skipping them is a
    # deliberate, named blind spot (a console host orphaned by its exited parent goes unseen), the same
    # one the pid-walk version carried.
    $leftIds = @(Get-OwnLeftovers $members $legBorn $seenAt | Where-Object { $consoleHosts -notcontains $names[[int]$_] })
    if (-not $exited) {
        # taskkill /T walks a tree that may already be gone; the job knows its members regardless.
        [void][Ka.LegJob]::Kill($job)
        Start-Sleep -Milliseconds 400
        $seenAt = Get-Date
        $answer = Get-KaLegPids $job
        if ($answer.Ok) {
            $members = @(@($answer.Pids) + @(Get-LeakedDescendants $childPid $hist $names $born) | Select-Object -Unique)
            $leftIds = @(Get-OwnLeftovers $members $legBorn $seenAt | Where-Object { $consoleHosts -notcontains $names[[int]$_] })
        }
    }
    $sw.Stop()
    $tag = '{0,-26} {1,5:0}s' -f $f.Name, $sw.Elapsed.TotalSeconds
    # one query after the alive check supplies a name for everything that can still be printed
    $names = @{ }
    foreach ($r in @(Get-ProcessRows)) { $names[[int]$r.ProcessId] = [string]$r.Name }
    $left = @(Format-Leftovers $leftIds $names)
    # After the check, and closing does not kill anything: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is
    # deliberately not set, because the leftover is the finding and has to outlive this handle.
    [Ka.LegJob]::Close($job)

    $code = $null
    if (Test-Path -LiteralPath $codeFile) {
        $raw = ('' + [IO.File]::ReadAllText($codeFile)).Trim()
        if ($raw -match '^-?\d+$') { $code = [int]$raw }
    }
    Remove-Item -LiteralPath $codeFile -Force -ErrorAction SilentlyContinue

    if (-not $exited) {
        $script:bad += ('{0} timed out after {1}s' -f $f.Name, $TimeoutSec)
        Write-Host ('FAIL ' + $tag + ' TIMEOUT after ' + $TimeoutSec + 's, tree killed' +
            $(if ($left.Count) { ' - still listed alive: ' + ($left -join ', ') } else { '' })) -ForegroundColor Red
        return
    }
    if ($null -eq $code) {
        # Not a zero. cmd can die after the script ran (its own parent killed, the volume gone), and
        # then the only truthful statement is that the code is unknown. tests/probe-ci-harness.ps1
        # puts the runner in exactly that state with a fixture that stops its own parent cmd.
        $script:bad += ('{0} exited without writing a verdict (cmd line: {1})' -f $f.Name, $line)
        Write-Host ('FAIL ' + $tag + ' no verdict file - the code is unknown, so this leg is not a pass') -ForegroundColor Red
        return
    }
    if ($code -ne 0) {
        $script:bad += ('{0} exit={1}' -f $f.Name, $code)
        Write-Host ('FAIL ' + $tag + ' exit=' + $code) -ForegroundColor Red
        return
    }
    if ($left.Count -gt 0 -and $f.Name -eq 'ka-tests.ps1') {
        # Reported, not asserted: ka-tests.ps1 is the one script whose children are the machine's own
        # workers and scheduled tasks, and no run of this runner against it has ever been observed
        # here (it does not run locally), so an assertion would be a claim rather than a check.
        Write-Host ('ok   ' + $tag + '   info left ' + $left.Count + ' descendant(s) alive: ' + ($left -join ', ') + ' - reported, not asserted')
        return
    }
    if ($left.Count -gt 0) {
        $script:bad += ('{0} returned but left {1} process(es) alive: {2}' -f $f.Name, $left.Count, ($left -join ', '))
        Write-Host ('FAIL ' + $tag + ' left ' + $left.Count + ' descendant(s) alive: ' + ($left -join ', ')) -ForegroundColor Red
        return
    }
    Write-Host ('ok   ' + $tag)
}

foreach ($f in $selected) {
    # A leg that throws is a red for that leg and nothing else. Without this the bug that made
    # tests/probe-ci-harness.ps1 exist - a parameter binding error on the first script - killed the
    # whole run and left the other 24 unjudged, which is the opposite of what a collector is for.
    try {
        Invoke-Leg $f
    } catch {
        $script:bad += ('{0} the runner threw: {1}' -f $f.Name, $_.Exception.Message)
        Write-Host ('FAIL ' + ('{0,-26}' -f $f.Name) + ' THREW: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
Write-Host ('----- {0} run, {1} red' -f $selected.Count, $bad.Count)
foreach ($b in $bad) { Write-Host ('  RED ' + $b) -ForegroundColor Red }
if ($bad.Count) { exit 1 }
exit 0
