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
    single run, all three columns read from the same log (_tmp/wait-table-run1.log, drivers
    _tmp/wait-table.ps1 and _tmp/wait-table-one.ps1, leftover _tmp/wait-shape-gc.ps1):

        shape                                        child's text    blind to the     code
                                                   reaches the log   grandchild?      reported
        Start-Process -PassThru, HasExited poll     yes              yes   (0.7 s)    $null -> 0 (lies)
        Start-Process -PassThru, WaitForExit()      yes              yes   (0.8 s)    $null -> 0 (lies)
        Start-Process -Wait -PassThru               yes              no    (8.1 s)    5  (true)
        [Diagnostics.Process]::Start, stdout
            redirected and never read, WaitForExit  NO - lost        yes   (0.8 s)    5  (true)

    No single shape has all three properties. -Wait is the only way a Start-Process object reports
    the child's real code (rows 1 and 2 report $null, and `[int]$null` is 0 - which is how a step
    that exited 5 gets logged as a pass), and a process started through .NET loses its text whenever
    its stdout is handed a pipe nobody drains - which is what a CI log is.

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
    all the way down), and which writes the script's own ERRORLEVEL into a verdict file (what a
    non-waiting Start-Process object reports for a child that exited 5 is $null - rows 1 and 2 above,
    and `[int]$null` is the 0 that would have been printed as a pass).
    The loop then polls HasExited with a deadline; on the deadline it kills the whole tree by
    taskkill /T, so a hanging script names itself instead of eating the step and cannot drag its
    leftovers into the next one. No verdict file is never treated as a zero: it is a red that says
    so, which is the same rule tests/probe-bat-entry.ps1 fact 4 runs on.

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
$taskkill = Join-Path $env:windir 'System32\taskkill.exe'

$selected = @()
if (-not ($Gates -or $Probes -or $Suite)) { $Gates = $true; $Probes = $true }
if ($Gates) {
    # ka-release-files.ps1 is a manifest (it prints a list), ka-tests.ps1 is the suite and
    # ka-ci.ps1 is this script - none of them is a gate, and globbing them would be a loop.
    $selected += @(Get-ChildItem -LiteralPath $here -Filter 'ka-*.ps1' -File |
        Where-Object { $_.Name -notmatch '^(ka-release-files|ka-tests|ka-ci)\.ps1$' } |
        Sort-Object Name)
}
if ($Probes) { $selected += @(Get-ChildItem -LiteralPath $here -Filter 'probe-*.ps1' -File | Sort-Object Name) }
if ($Suite) { $selected += @(Get-Item -LiteralPath (Join-Path $here 'ka-tests.ps1')) }
if ($Only) { $selected = @($selected | Where-Object { $_.Name -match $Only }) }
if (-not $selected.Count) { Write-Host 'nothing selected - check the -Only pattern'; exit 1 }

function Get-ProcessRows {
    # 155 ms median measured on this host with the three properties below, against 278 ms for the
    # same query without Name and 192 ms for the unprojected table (6 samples each, 402 rows).
    # Name is in the projection because the walk below needs to recognise a console host.
    @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction SilentlyContinue)
}

# conhost.exe (23 of the 402 rows on this host at rest) and OpenConsole.exe are pseudo-console
# hosts Windows starts for a process that gets its own window station. They die with the session
# they were made for, hold no port, no power request and no file handle, and in the one fixture
# that leaks on purpose they showed up next to the leftover that caused them. Asserting on them
# would only add a way for a clean run to go red by accident. The blind spot this opens is small
# and named: a console host orphaned by a parent that died between two samples is dropped unseen.
$consoleHosts = @('conhost.exe', 'OpenConsole.exe')

function Get-LeakedDescendants([int]$RootId, [hashtable]$History, [hashtable]$Names) {
    # Walk UP from everything alive now, through a pid->ppid history, instead of down from the
    # child that is already gone. Down is blind here: the leftover that hung CI was a browser whose
    # whole ancestry - cmd, ka.ps1, the panel's powershell - had exited before anyone looked, and
    # Windows keeps no record of a dead process's parent. Up through the history reaches it.
    # Blind spot, stated rather than hidden: a process born and buried between two samples leaves
    # no entry, so its own child is invisible to this walk.
    $out = @()
    foreach ($r in @(Get-ProcessRows)) {
        $pidNow = [int]$r.ProcessId
        if ($consoleHosts -contains [string]$r.Name) { continue }
        $up = $pidNow
        for ($i = 0; $i -lt 40; $i++) {
            if (-not $History.ContainsKey($up)) { break }
            $up = [int]$History[$up]
            if ($up -eq $RootId) { $out += $pidNow; break }
            if ($up -eq 0) { break }
        }
    }
    return @($out | Sort-Object -Unique)
}

function Get-OwnLeftovers([int[]]$ProcIds, [datetime]$BornNoEarlierThan, [datetime]$BornNoLaterThan) {
    # A pid is a recycled number, and this walk was fooled from both directions.
    #  - tests/probe-ci-harness.ps1 caught it naming wps.exe and wpscloudsvr.exe - the user's office
    #    suite - as a test script's descendants: their parent pid was one of ours from before ours
    #    died, and the history still had that mapping. Nothing born after this leg's child was seen
    #    to exit can be its descendant, so $BornNoLaterThan drops them.
    #  - a local -Gates -Probes run (_tmp/ci-gates-probes-run1.log) named pid 21688, the machine's
    #    own running worker, as a leftover of probe-server-hint.ps1. Same hazard, other direction: a
    #    process older than the leg whose parent slot was reused by the cmd this leg started. The
    #    upper bound alone cannot see that, because a long-lived process satisfies 'born no later
    #    than the exit' by definition, so a descendant needs a lower bound as well - nothing that
    #    predates the leg can have been left behind by it.
    # $BornNoLaterThan is the moment the poll noticed the exit, not the exit itself: measured here,
    # a non-waited Start-Process object answers $null (without throwing) for ExitTime and ExitCode
    # once the child is gone, so there is nothing better to use. The gap is the poll's own 200 ms.
    # The window is deliberately generous at the edges: a process whose start time cannot be read
    # (access denied, or a protected service) is kept, because losing a real leftover is worse than
    # a red that names something for a human to go look at.
    $keep = @()
    foreach ($id in $ProcIds) {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        try {
            if ($proc.StartTime -gt $BornNoLaterThan) { continue }
            if ($proc.StartTime -lt $BornNoEarlierThan) { continue }
            $keep += [int]$proc.Id
        } catch {
            $keep += [int]$proc.Id
        }
    }
    return @($keep)
}

function Format-Leftovers([int[]]$ProcIds, [hashtable]$Names) {
    # Nothing to name returns an empty array, not '': an empty string inside @() is one element,
    # and 'left 1 descendant(s) alive: ' with nothing after the colon is exactly what it printed
    # on the first fixture run. Only a pid present in $History can be reported, and both maps are
    # filled from the same rows, so $Names has a name for everything printed.
    if (-not $ProcIds.Count) { return @() }
    return @(foreach ($id in $ProcIds) { ('{0}:{1}' -f $id, $Names[$id]) })
}

function Update-ProcessHistory([hashtable]$History, [hashtable]$Names) {
    # One query fills both maps: pid->ppid is what the walk crosses, pid->name is what it prints.
    foreach ($r in @(Get-ProcessRows)) {
        $History[[int]$r.ProcessId] = [int]$r.ParentProcessId
        $Names[[int]$r.ProcessId] = [string]$r.Name
    }
}

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
    $child = Start-Process -FilePath $cmd -NoNewWindow -PassThru -ArgumentList $line
    $childPid = [int]$child.Id

    # HasExited on the cmd we started: truthful (2.5 s for a child that lived 2 s) and blind to
    # descendants (0.5 s while a 6 s grandchild was still alive). The deadline is what turns a
    # silent 30-minute hang into one named line. The pid->ppid history is sampled in the same loop,
    # one query every 2 s: at the 155 ms measured above per query that is under a tenth of a core,
    # and it is what makes the walk below able to cross a parent that already died.
    $exited = $false
    $hist = @{ }
    $names = @{ }
    $nextSample = 0.0
    $seenAt = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($child.HasExited) { $exited = $true; $seenAt = Get-Date; break }
        if ($sw.Elapsed.TotalMilliseconds -ge $nextSample) {
            Update-ProcessHistory $hist $names
            $nextSample = $sw.Elapsed.TotalMilliseconds + 2000
        }
        Start-Sleep -Milliseconds 200
    }
    Update-ProcessHistory $hist $names
    if (-not $seenAt) { $seenAt = Get-Date }
    $leftIds = @(Get-OwnLeftovers @(Get-LeakedDescendants $childPid $hist $names) $legBorn $seenAt)
    if (-not $exited) {
        & $taskkill '/T' '/F' '/PID' $childPid 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
        $seenAt = Get-Date
        Update-ProcessHistory $hist $names
        $leftIds = @(Get-OwnLeftovers @(Get-LeakedDescendants $childPid $hist $names) $legBorn $seenAt)
    }
    $sw.Stop()
    $tag = '{0,-26} {1,5:0}s' -f $f.Name, $sw.Elapsed.TotalSeconds
    $left = @(Format-Leftovers $leftIds $names)

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
