$ErrorActionPreference = 'Continue'
<#
    Panel handles, measured with two real panels on two real ports.

    The bug this exists for had two halves, and both were silent. `.server.json` was one file
    shared by every panel instance: the second panel overwrote the first's pid at start, and
    whichever panel exited first deleted the file - leaving a still-running, still-answering
    panel with no handle at all. Then `stop-server` printed "面板没有在运行" (in green) for the
    case where it had found no process *and* for the case where a panel was answering on the
    port, because nothing distinguished them.

    So the probe runs two panels side by side and requires: two handle files, both panels
    findable, and - after one of them stops - the *other* one's handle still there and still
    findable. It then puts a panel that this data root cannot see on the port this data root
    calls its own, and requires the verdict to say "a port is answering" rather than "not
    running".

    Legs 6-9 chase the second half of the same mistake: ownership. A panel is ours only if its
    handle lives in OUR data root or its command line names OUR data root - not merely because it
    was started from the same program folder. One of those legs is a measurement, not a thought
    experiment: before that test existed, a scratch run of the shipped ka.ps1 with only KA_DATA
    moved matched this machine's own panel by program path, read its port off its command line,
    POSTed /api/server/stop to it and the panel obeyed (ka.log 2026-09-27 01:12:47 `SERVER EXIT
    pid=28208`). A stop is now never aimed at a port nobody has evidence for, and `serve` reports
    "a panel answers on that port" instead of taking it over.

    Everything runs against staged copies of the shipped files with their own KA_DATA, so a panel
    the user left running from the real install is never touched.
#>
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root ('_tmp/server-hint-' + [guid]::NewGuid().ToString('N'))   # scratch stays in the ignored _tmp
$ps64 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$null = New-Item -ItemType Directory -Force -Path $work

. (Join-Path $root 'tests/ka-release-files.ps1')
$files = @(Get-KaReleaseFile)
$bad = @()
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }
function Bad([string]$m) { $script:bad += $m; Write-Output ('  FAIL ' + $m) }

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try { $l.Start(); return $l.LocalEndpoint.Port } finally { try { $l.Stop() } catch { } }
}
function Stage-ProgramDir([string]$Dir) {
    # A real directory of shipped files: the panel's ownership test keys on the program root,
    # so measuring this from the live clone would match the user's own panel by path.
    $null = New-Item -ItemType Directory -Force -Path $Dir
    foreach ($f in $files) {
        $src = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $src)) { Bad "$f is missing from the source tree"; continue }
        $dst = Join-Path $Dir $f
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $dst)
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    return $Dir
}
$childSrc = Join-Path $work 'hint-child.ps1'
@'
param([switch]$Hints, [switch]$Servers, [switch]$Stop, [switch]$Port, [switch]$Serve)
. (Join-Path $PSScriptRoot 'ka-core.ps1')
if ($Port) { Write-Output ("PORT=" + [int](Get-KaConfig).port); exit 0 }
if ($Hints) {
    foreach ($h in @(Get-KaServerHints)) { Write-Output ("HINT pid=" + $h.Pid + " port=" + $h.Port + " name=" + (Split-Path -Leaf $h.Path)) }
    exit 0
}
if ($Servers) {
    foreach ($s in @(Get-KaServer)) {
        Write-Output ("SERVER pid=" + $s.Pid + " port=" + $s.Port + " ours=" + [bool]$s.Ours + " clData=" + $s.DataDir)
    }
    exit 0
}
if ($Serve) {
    # Called directly rather than through ka.ps1 `serve`: the CLI branch adds the browser hand-off,
    # and on a runner that tab is a leftover of this tree (see probe-bat-entry.ps1).
    $r = Start-KaServer
    $answer = Get-KaText 'cli.panelAnswering' @{ ports = [int](Get-KaConfig).port }
    Write-Output ('SERVE ok=' + [bool]$r.Ok + ' newly=' + [bool]$r.Newly + ' pid=' + $r.Pid +
                  ' reasonIsAnswering=' + [bool]("$($r.Reason)" -eq $answer))
    exit 0
}
if ($Stop) {
    $r = Stop-KaServer
    $t = Get-KaStopServerText $r
    Write-Output ('STOP stopped=' + [int]$r.Stopped + ' found=' + [int]$r.Found + ' left=' + [int]$r.Left +
                  ' answering=' + (@($r.Answering) -join '+'))
    # Compared as a verdict, not as a string: the child and this assertion run in whatever
    # language this box resolves, so "is it the not-running sentence" is the culture-proof form.
    Write-Output ('NOT_RUNNING=' + [bool]($t -eq (Get-KaText 'cli.panelNotRunning')))
    exit 0
}
'@ | Set-Content -LiteralPath $childSrc -Encoding UTF8
function Install-Child([string]$Dir) {
    Copy-Item -LiteralPath $childSrc -Destination (Join-Path $Dir 'hint-child.ps1') -Force
}
function Invoke-Child([string]$Dir, [string]$Data, [string]$ChildArgs) {
    # Not "$Args": the automatic $args shadows a parameter of that name, and the switch
    # we pass would vanish before the child ever saw it.
    $prev = $env:KA_DATA
    $env:KA_DATA = $Data
    $out = Join-Path $env:TEMP ('ka-hint-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $p = Start-Process -FilePath $ps64 -NoNewWindow -PassThru -RedirectStandardOutput $out `
             -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'hint-child.ps1') + '" ' + $ChildArgs)
        # Deliberately NOT -Wait. .NET's WaitForExit() waits for the redirected stdout pipe to reach
        # EOF, and a panel this child starts inherits the write end, so EOF never comes - the same
        # hang tests/ka-ci.ps1 was rebuilt for (#65), and this probe walked into it: with the 'claim'
        # mutant in place, leg 7's serve really does launch a panel, and the sweep sat on that call
        # for nine minutes instead of failing (measured 2026-09-28, pid 6944, scratch panels
        # 55196/55141 still alive). A timeout is written into the output as a marker so the caller's
        # own assertions go red with a reason, never silent.
        $deadline = (Get-Date).AddSeconds(90)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $p.Refresh()
        }
        $timedOut = -not $p.HasExited
        $lines = @((Get-Content -LiteralPath $out -ErrorAction SilentlyContinue) | Where-Object { $_.Trim() })
        if ($timedOut) {
            $lines += ('CHILD_TIMEOUT after 90s: ' + $ChildArgs)
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        }
        # Lines only, and no exit code key: this launch carries -NoNewWindow and a redirect, and an
        # object from that shape answers a silent $null even after the exit (measured 2026-09-30,
        # _tmp/exitcode-switch-matrix-20260930.txt T2/T4). A $null key that nothing consumes would
        # only be a trap for the next reader; a timeout is already a named line above.
        @{ Lines = $lines }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    }
}
function Start-Panel([string]$Dir, [string]$Data, [int]$Port) {
    # Port 0 means "pass no -Port at all", which is the hand-started shape: ka-server.ps1:43 then
    # takes the port out of its own data root's config. Leg 9 needs exactly that, because the whole
    # point of it is a panel whose port the caller cannot read from anywhere.
    $tail = if ($Port -gt 0) { ' -Port ' + $Port } else { '' }
    return Start-Process -FilePath $ps64 -PassThru -WindowStyle Hidden `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'ka-server.ps1') +
                       '" -DataDir "' + $Data + '"' + $tail)
}
function Test-Ping([int]$Port) {
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/api/ping") -UseBasicParsing -TimeoutSec 3 `
             -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}
function Wait-Ping([int]$Port, [switch]$Down, [int]$Sec = 30) {
    $deadline = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $deadline) {
        $up = Test-Ping $Port
        if ($Down -and -not $up) { return $true }
        if (-not $Down -and $up) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
function HintFile([string]$Data, [int]$Port) { Join-Path $Data ('.server-{0}.json' -f $Port) }

$progA = Stage-ProgramDir (Join-Path $work 'progA')
$progB = Stage-ProgramDir (Join-Path $work 'progB')
$dataA = Join-Path $work 'dataA'
$dataB = Join-Path $work 'dataB'
# C and D share progA with A on purpose. progB is a second program dir, so legs 1-5 could never
# see the "another data root, same program folder" case at all - and that is the case a person
# reaches for by setting KA_DATA, and the one a scratch probe walks into without noticing.
$dataC = Join-Path $work 'dataC'
foreach ($d in @($dataA, $dataB, $dataC)) { $null = New-Item -ItemType Directory -Force -Path $d }
Install-Child $progA
Install-Child $progB
$P1 = Get-FreePort
$P2 = Get-FreePort
if ($P1 -eq $P2) { Bad "the two free ports came back identical ($P1) - the whole probe would be vacuous" }
# The scratch config has to point at $P1, otherwise Stop-KaServer probes the built-in default
# and a panel the user left running on it answers for us.
@{ port = $P1 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataA 'config.json') -Encoding UTF8
# The same rule holds for every root in this file, not just the one under test: Stop-KaServer puts
# [int]$cfg.port into the ports it asks (ka-core.ps1:2699), so a scratch root with no config.json
# falls back to the built-in 8791 - which is exactly where a real panel on this machine answers.
# Run 1 of this probe caught leg 8 printing `answering=8791`, i.e. a scratch stop-server had just
# pinged the user's panel. That is the mild form. The sharp form is aimed at probe-server-hint-selftest
# 's portfallback mutant, which re-aims the shutdown request at $cfg.port: with a configless root and
# one of OUR panels in hand, that POST goes to 8791 and the real panel obeys - the 01:12:47 incident
# reproduced by a test harness instead of by accident. Every root here names a port this file allocated.
@{ port = $P1 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataB 'config.json') -Encoding UTF8
$effPort = (Invoke-Child $progA $dataA '-Port').Lines | Where-Object { $_ -like 'PORT=*' }
if ("$effPort" -ne "PORT=$P1") { Bad "scratch config did not take: wanted PORT=$P1, got [$effPort]" }
if ($bad) {
    foreach ($m in $bad) { Write-Output ('  note ' + $m) }
    Write-Output 'PROBE FAILED: setup'
    # `exit` here would skip the finally below, so the staged copy goes with it.
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$pids = @()
try {
    Write-Output '--- 1. two panels, two ports, two handles'
    $a1 = Start-Panel $progA $dataA $P1
    $a2 = Start-Panel $progA $dataA $P2
    $pids += @($a1.Id, $a2.Id)
    if (-not (Wait-Ping $P1)) { Bad "panel 1 never answered on $P1" }
    if (-not (Wait-Ping $P2)) { Bad "panel 2 never answered on $P2" }
    if (-not (Test-Path -LiteralPath (HintFile $dataA $P1))) { Bad "no .server-$P1.json - the panel wrote no handle for itself" }
    if (-not (Test-Path -LiteralPath (HintFile $dataA $P2))) { Bad "no .server-$P2.json - two panels still share one handle file" }
    else { Ok ".server-$P1.json and .server-$P2.json exist side by side" }
    $hints = @((Invoke-Child $progA $dataA '-Hints').Lines | Where-Object { $_ -like 'HINT *' })
    if ($hints.Count -lt 2) { Bad "Get-KaServerHints saw $($hints.Count) handle(s), not 2 : $($hints -join ' | ')" }
    else { Ok "Get-KaServerHints lists both: $($hints -join ' | ')" }
    $srv = @((Invoke-Child $progA $dataA '-Servers').Lines | Where-Object { $_ -like 'SERVER *' })
    $seen = @($srv | ForEach-Object { ($_ -replace '.*pid=(\d+).*', '$1') })
    if ($seen.Count -lt 2) { Bad "Get-KaServer found $($seen.Count) of the 2 running panels: $($srv -join ' | ')" }
    else { Ok "Get-KaServer finds both panels: $($srv -join ' | ')" }

    Write-Output '--- 2. stopping one must not orphan the other'
    [void](Invoke-WebRequest -Uri "http://127.0.0.1:$P1/api/server/stop" -Method POST -UseBasicParsing -TimeoutSec 5 `
            -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -ErrorAction SilentlyContinue)
    if (-not (Wait-Ping $P1 -Down)) { Bad "panel 1 still answers on $P1 after being asked to stop" }
    if (-not (Wait-Ping $P2)) { Bad 'panel 2 died with panel 1 - they were not independent' }
    if (Test-Path -LiteralPath (HintFile $dataA $P1)) { Bad ".server-$P1.json survived its own process - it will mislead discovery" }
    if (-not (Test-Path -LiteralPath (HintFile $dataA $P2))) {
        Bad ".server-$P2.json is gone although panel 2 is still running - this is the original bug: one shared file"
    } else { Ok "panel 1's handle is gone, panel 2's handle survived" }
    $srv2 = @((Invoke-Child $progA $dataA '-Servers').Lines | Where-Object { $_ -like 'SERVER *' })
    if ($srv2.Count -ne 1) { Bad "after one stop, Get-KaServer returned $($srv2.Count) panel(s), expected the 1 still running : $($srv2 -join ' | ')" }
    elseif ("$srv2" -notlike "*pid=$($a2.Id) *") { Bad "the surviving handle points at another pid than panel 2 ($($a2.Id)): $srv2" }
    else { Ok "the surviving panel is still findable by itself: $srv2" }

    Write-Output '--- 3. stop-server with nothing of ours left'
    $r3 = (Invoke-Child $progA $dataA '-Stop').Lines
    $line3 = ($r3 | Where-Object { $_ -like 'STOP *' }) -join ''
    if ($line3 -notmatch 'stopped=1') { Bad "stopping the last panel reported [$line3]" }
    if ($line3 -notmatch 'answering=$') { Bad "Stop-KaServer still probes a live port after everything stopped: [$line3]" }
    if ((Get-ChildItem -LiteralPath $dataA -Filter '.server*.json' -File -ErrorAction SilentlyContinue).Count) {
        Bad 'a handle survived with no process behind it'
    } else { Ok "last panel stopped gracefully and no handle is left: $line3" }

    Write-Output '--- 4. the legacy shared file is still cleaned up'
    $legacy = Join-Path $dataA '.server.json'
    @{ pid = 999999; port = $P2; url = "http://127.0.0.1:$P2/"; startedEpoch = 0; data = $dataA } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $legacy -Encoding UTF8
    if (Get-Process -Id 999999 -ErrorAction SilentlyContinue) { Bad 'precondition failed: pid 999999 is a real process here' }
    $r4 = ((Invoke-Child $progA $dataA '-Stop').Lines | Where-Object { $_ -like 'STOP *' }) -join ''
    if (Test-Path -LiteralPath $legacy) { Bad ".server.json from an older version was left behind: [$r4]" }
    else { Ok "a legacy handle whose process does not exist is swept by stop-server: [$r4]" }

    Write-Output '--- 5. a panel we cannot see, on the port we call ours'
    $b1 = Start-Panel $progB $dataB $P1
    $pids += $b1.Id
    if (-not (Wait-Ping $P1)) { Bad "the foreign panel never answered on $P1" }
    $r5 = (Invoke-Child $progA $dataA '-Stop').Lines
    $line5 = ($r5 | Where-Object { $_ -like 'STOP *' }) -join ''
    $verdict5 = ($r5 | Where-Object { $_ -like 'NOT_RUNNING=*' }) -join ''
    if ($line5 -notmatch 'stopped=0') { Bad "stop-server stopped a panel belonging to another data root: [$line5]" }
    if ($line5 -notmatch ("answering=" + $P1)) { Bad "it did not report that $P1 is answering: [$line5]" }
    if ($verdict5 -ne 'NOT_RUNNING=False') {
        Bad "the user-facing verdict still says 面板没有在运行 while $P1 answers: [$verdict5 | $line5]"
    } else { Ok "found=0 / stopped=0 but the port answers, and the verdict says so: [$line5 | $verdict5]" }
    $h5 = @((Invoke-Child $progA $dataA '-Hints').Lines | Where-Object { $_ -like 'HINT *' })
    if ($h5.Count) { Bad "the foreign data root's handle leaked into ours: $($h5 -join ' | ')" }
    else { Ok 'the foreign handle stays in the foreign data root' }

    Write-Output '--- 6. same program folder, different data root (the case legs 1-5 could not reach)'
    # Legs 1-5 keep the foreign panel in a second program dir, so `Get-KaServer` never even saw it.
    # This one is started out of progA - the shape a person gets by setting KA_DATA, and the shape
    # a scratch run walks into when it calls the shipped ka.ps1 with only KA_DATA moved. Measured
    # consequence before the ownership test existed: a scratch `serve`/`stop-server` matched this
    # machine's own panel by program path, read its port off that panel's command line, POSTed
    # /api/server/stop to it and the panel obeyed (ka.log 2026-09-27 01:12:47 `SERVER EXIT pid=28208`).
    $P3 = Get-FreePort
    if ($P3 -eq $P1 -or $P3 -eq $P2) { Bad "Get-FreePort handed back a port already in use here ($P3)" }
    @{ port = $P3 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataC 'config.json') -Encoding UTF8
    $c1 = Start-Panel $progA $dataC $P3
    $pids += $c1.Id
    if (-not (Wait-Ping $P3)) { Bad "the shared-folder panel never answered on $P3" }
    $srv6 = @((Invoke-Child $progA $dataA '-Servers').Lines | Where-Object { $_ -like 'SERVER *' })
    $claimed6 = @($srv6 | Where-Object { $_ -like '*ours=True*' })
    if ($srv6.Count -lt 1) {
        Bad "dataA does not even list the shared-folder panel - this is no longer the shape the leg is about: $($srv6 -join ' | ')"
    } elseif ($claimed6.Count) {
        Bad "dataA claims a panel that answers to dataC: $($claimed6 -join ' | ')"
    } else { Ok "dataA sees it and refuses it: $($srv6 -join ' | ')" }
    $r6 = ((Invoke-Child $progA $dataA '-Stop').Lines | Where-Object { $_ -like 'STOP *' }) -join ''
    if ($r6 -notmatch 'stopped=0') { Bad "stop-server from dataA stopped a panel of dataC: [$r6]" }
    if (-not (Wait-Ping $P3 -Sec 5)) { Bad "the dataC panel is gone - dataA reached across data roots and shut it down" }
    else { Ok "dataA's stop-server leaves the dataC panel answering on $P3 : [$r6]" }

    Write-Output '--- 7. serve from the second root neither adopts it nor evicts it'
    @{ port = $P3 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataA 'config.json') -Encoding UTF8
    $line7 = ((Invoke-Child $progA $dataA '-Serve').Lines | Where-Object { $_ -like 'SERVE *' }) -join ''
    if ($line7 -match 'pid=(\d+)') { $p7 = [int]$Matches[1]; if ($p7 -gt 0) { $pids += $p7 } }
    if ($line7 -notmatch 'ok=False') { Bad "serve accepted the dataC panel as dataA's own: [$line7]" }
    if ($line7 -notmatch 'reasonIsAnswering=True') { Bad "serve refused without naming the port that answers: [$line7]" }
    $h7 = @((Invoke-Child $progA $dataA '-Hints').Lines | Where-Object { $_ -like 'HINT *' })
    if ($h7.Count) { Bad "serve left a handle in dataA for a panel it does not own: $($h7 -join ' | ')" }
    if (-not (Wait-Ping $P3 -Sec 5)) { Bad 'the dataC panel died while dataA was serving' }
    else { Ok "dataA is told the port is held, and nothing changes: [$line7]" }

    Write-Output '--- 8. the control: its own data root can still stop it'
    # Without this the two legs above could be green because the panel was never real.
    $r8 = ((Invoke-Child $progA $dataC '-Stop').Lines | Where-Object { $_ -like 'STOP *' }) -join ''
    if ($r8 -notmatch 'stopped=1') { Bad "dataC could not stop its own panel, so legs 6-7 proved nothing: [$r8]" }
    if (-not (Wait-Ping $P3 -Down)) { Bad "the dataC panel still answers on $P3 after its own root stopped it" }
    else { Ok "the fixture was alive and stoppable by who owns it [$r8]" }

    Write-Output '--- 9. an unreadable port is not a licence to guess'
    # This panel is ours, but nothing says which port it holds: no handle (removed below - the
    # `server-hint-unwritable` shape ka-server.ps1:421 logs for real) and no -Port on its command
    # line. Stop-KaServer used to fall back to "the port we would have used" and hand a working
    # shutdown request to whoever was listening there. f9 is that somebody, in another data root.
    $P4 = Get-FreePort
    $P5 = Get-FreePort
    if ($P4 -eq $P5) { Bad "the two free ports came back identical ($P4) - leg 9 would be vacuous" }
    @{ port = $P5 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataA 'config.json') -Encoding UTF8
    $a9 = Start-Panel $progA $dataA 0        # no -Port: it reads $P5 out of dataA's config
    $pids += $a9.Id
    if (-not (Wait-Ping $P5)) { Bad "our own panel never answered on $P5" }
    $f9 = Start-Panel $progB $dataB $P4
    $pids += $f9.Id
    if (-not (Wait-Ping $P4)) { Bad "the panel squatting dataA's new port never answered on $P4" }
    $h9 = HintFile $dataA $P5
    if (-not (Test-Path -LiteralPath $h9)) { Bad "there is no .server-$P5.json to remove - leg 9 lost its precondition" }
    Remove-Item -LiteralPath $h9 -Force -ErrorAction SilentlyContinue
    @{ port = $P4 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataA 'config.json') -Encoding UTF8
    $r9 = ((Invoke-Child $progA $dataA '-Stop').Lines | Where-Object { $_ -like 'STOP *' }) -join ''
    if (Get-Process -Id $a9.Id -ErrorAction SilentlyContinue) { Bad "our own panel survived our own stop-server: [$r9]" }
    if (-not (Wait-Ping $P4 -Sec 5)) { Bad "the panel on $P4 was shut down by a stop-server that only wanted its own: [$r9]" }
    else { Ok "our panel is gone, the stranger on $P4 is untouched [$r9]" }
} finally {
    # Graceful first, and by every root this file used: a panel a child process started is not in
    # $pids (only its parent is), and a hidden powershell.exe left running outlives the scratch
    # directory it was reading - ka-ci's leftover check would name it, and rightly.
    foreach ($pair in @(@($progA, $dataA), @($progA, $dataC), @($progB, $dataB))) {
        try { [void](Invoke-Child $pair[0] $pair[1] '-Stop') } catch { }
    }
    foreach ($procId in $pids) { try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Milliseconds 400
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: two panels hold two handles, a foreign root''s panel is never stopped or adopted by us, an unreadable port is never guessed, and a port that answers is never called "not running"'
