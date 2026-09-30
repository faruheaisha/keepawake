<#
    A leg's process bookkeeping: the job object that marks the leg's tree, and the rules around it.

    Why this exists (2026-09-28/29): four false results, each one a CI cycle spent on a process that
    had nothing to do with the probe it was blamed for (and the blamed probe had printed its own PROBE
    OK) - wps.exe/wpscloudsvr.exe (the user's office suite, blamed on a leg by a stale parent entry),
    the machine's own worker pid 21688, CompatTelRunner.exe, and then a whole Windows servicing burst
    (TiWorker.exe, TrustedInstaller.exe, MoUsoCoreWorker.exe, three svchost.exe, CompatTelRunner.exe)
    plus, locally, Git's `sleep.exe`, started by the tooling that was watching the run. All of it came
    from reconstructing a leg's ancestry out of pids: a pid->ppid entry is evidence only about the
    process that held that pid when the entry was written, and a chain stitched through a recycled pid
    can land on the leg's cmd by coincidence.

    So the walk is no longer trusted on its own. Each leg runs inside a Job object, every descendant
    inherits the membership, and the members come back from one query. The walk is kept as the second
    source, because each one is blind to exactly what the other catches - the job cannot see a process
    the shell launches (measured on CI: the deliberate GUI leak was missing from the job while alive) -
    and it carries the guards described in tests/ka-procwalk.ps1. The cases below pin both sources, and
    each of the four rules has a run that injects into the one line it lives on, so a green here cannot
    survive that line being put back to its old, wrong form.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lib = if ($env:KA_PROCWALK_LIB) { $env:KA_PROCWALK_LIB } else { Join-Path $PSScriptRoot 'ka-procwalk.ps1' }
$asChild = ("$env:KA_PROCWALK_CHILD" -eq '1')
$selfPath = $PSCommandPath
if (-not (Test-Path -LiteralPath $lib)) { Write-Output ('PROBE FAILED: no library at ' + $lib); exit 1 }
. $lib

$bad = @()
function Bad([string]$m) { $script:bad += $m; Write-Output ('  FAIL ' + $m) }
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }

$sentinelRoot = 999999   # the leg's cmd pid in the hand-made maps below; a number, not a process
$deadHop = 999998        # a pid no live process holds - the dead middle hop in the walk cases

$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Start-Sleeper { param([int]$Seconds = 90)
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-Command', ("Start-Sleep -Seconds $Seconds")) -WindowStyle Hidden -PassThru
}

$job = [Ka.LegJob]::Create()
if ($job -eq [IntPtr]::Zero) { Write-Output 'PROBE FAILED: CreateJobObject returned 0 - nothing below could be tested'; exit 1 }
$mine = Start-Sleeper 90
$wmi = $null
try {
    Write-Output '--- 1. a process this script starts and assigns is in the job'
    $err = [Ka.LegJob]::Assign($job, [int]$mine.Id)
    if ($err) { Bad ("Assign failed: $err") }
    $ans = Get-KaLegPids $job
    if (-not $ans.Ok) { Bad ('the job query failed with Win32 ' + $ans.Err) }
    $pids = @($ans.Pids)
    if ($pids -contains [int]$mine.Id) { Ok ("member: $($mine.Id)") }
    else { Bad ("the assigned process is not listed by the job (" + ($pids -join ',') + ")") }

    Write-Output '--- 2. a process created through WMI is not a member (the CI failure shape)'
    # Its parent is WmiPrvSE.exe, so it is born inside the leg's window and unrelated to this tree -
    # exactly what CompatTelRunner.exe and Git's sleep.exe were.
    $wmi = [int](Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = ('"' + $ps + '" -NoProfile -Command "Start-Sleep -Seconds 85"') }).ProcessId
    Start-Sleep -Milliseconds 700
    $pids2 = @((Get-KaLegPids $job).Pids)
    if (-not $wmi) { Ok 'SKIP: WMI could not create a process here, so this shape was not exercised' }
    elseif ($pids2 -contains $wmi) { Bad ("a WMI-created process is listed as a member: $wmi - this is the false positive the job removes") }
    else { Ok ("the unrelated process $wmi (parent: WmiPrvSE) is not a member") }

    Write-Output '--- 3. a member that exits is gone from the list'
    try { Stop-Process -Id $mine.Id -Force -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 600
    $pids3 = @((Get-KaLegPids $job).Pids)
    if ($pids3 -contains [int]$mine.Id) { Bad 'a process that exited is still listed as a member' }
    else { Ok 'the exited member is no longer listed' }

    Write-Output '--- 4. the age window still partitions what may be reported'
    $second = Start-Sleeper 90
    $null = [Ka.LegJob]::Assign($job, [int]$second.Id)
    $inWin = @(Get-OwnLeftovers @([int]$second.Id) (Get-Date).AddMinutes(-5) (Get-Date).AddMinutes(1))
    if ($inWin -contains [int]$second.Id) { Ok 'a member born inside the window is kept' } else { Bad 'a live member born just now was dropped by the window' }
    $outWin = @(Get-OwnLeftovers @([int]$second.Id) (Get-Date).AddMinutes(10) (Get-Date).AddMinutes(20))
    if ($outWin.Count -eq 0) { Ok 'a member born outside the window is dropped' } else { Bad 'the window let a process born later through' }

    Write-Output '--- 5. kill terminates the members (the timeout path)'
    $null = [Ka.LegJob]::Kill($job)
    Start-Sleep -Milliseconds 900
    $alive = Get-Process -Id $second.Id -ErrorAction SilentlyContinue
    if ($alive) { Bad ('TerminateJobObject left the member running: ' + $second.Id) } else { Ok 'the job kill took its members with it' }
    $pids5 = @((Get-KaLegPids $job).Pids)
    if ($pids5 -contains [int]$second.Id) { Bad 'the killed member is still listed' } else { Ok 'and it is no longer listed' }

    Write-Output '--- 6. the other source: a hand-made chain through the reconstruction is named'
    # The job cannot see a process the shell launched (measured on CI: the deliberate GUI leak was
    # missing from the job while alive), so the union the runner reports depends on this source too.
    $sentinelRoot = 999999
    $walk = Start-Sleeper 60
    $rows = @(Get-ProcessRows)
    $real = @{}
    foreach ($r in $rows) { try { $real[[int]$r.ProcessId] = [long]$r.CreationDate.Ticks } catch { } }
    if (-not $real.ContainsKey([int]$walk.Id)) { Bad 'the sleeper is not in the row set - the reconstruction case could not be set up' }
    else {
        $hist = @{ [int]$walk.Id = $sentinelRoot }
        $born = @{ [int]$walk.Id = $real[[int]$walk.Id] }
        $nm = @{ [int]$walk.Id = 'ka-procwalk-synthetic' }
        $got = @(Get-LeakedDescendants $sentinelRoot $hist $nm $born)
        if ($got -contains [int]$walk.Id) { Ok ("the reconstruction names it: $($walk.Id)") }
        else { Bad 'the reconstruction did not name a chain that reaches the root - the union would lose the shell-launched shape' }

        Write-Output '   - the same entry once that pid has changed hands'
        $bornRecycled = @{ [int]$walk.Id = $real[[int]$walk.Id] - 36000000000 }
        $got2 = @(Get-LeakedDescendants $sentinelRoot $hist $nm $bornRecycled)
        if ($got2 -contains [int]$walk.Id) { Bad 'a pid rehanded since the entry was written was followed anyway' }
        else { Ok 'refused: the pid alive now is not the process the entry was written about' }

        Write-Output '   - a dead hop WITH a recorded creation time (the shell-launched shape)'
        $deadWithRecord = @{ [int]$walk.Id = $deadHop; $deadHop = $sentinelRoot }
        $bornDead = @{ [int]$walk.Id = $real[[int]$walk.Id]; $deadHop = 1 }
        $got3 = @(Get-LeakedDescendants $sentinelRoot $deadWithRecord $nm $bornDead)
        if ($got3 -contains [int]$walk.Id) { Ok 'crossed: the middle process is gone but was sampled while it lived' }
        else { Bad 'a dead hop with a recorded creation time broke the chain - the shell-launched leftover would be lost' }

        Write-Output '   - a dead hop with NO record (the class the first guard left open)'
        $bornNoHop = @{ [int]$walk.Id = $real[[int]$walk.Id] }
        $got4 = @(Get-LeakedDescendants $sentinelRoot $deadWithRecord $nm $bornNoHop)
        if ($got4 -contains [int]$walk.Id) {
            Bad 'a hop whose pid has no record at all was followed - that is the dead-and-recycled bridge that named an unrelated process'
        } else { Ok 'refused: nothing was ever recorded about who held that pid' }

        # The two cases below exist because of run 36679927952, where the sampler recorded tick 0 for
        # images CIM would not time and both guards then read 0 as a real answer. This box has none of
        # those images (measured 2026-09-30: 334 rows, 0 with no CreationDate), so the shape is handed
        # to the walk the only way it can be here - a row set that mirrors the runner's. The guard
        # cannot tell where a row came from; the sleeper is real and alive, only its time is withheld.
        & {
            $stubId = [int]$walk.Id
            $stubBorn = $real[$stubId]
            function Get-ProcessRows {
                return @([pscustomobject]@{ ProcessId = $stubId; ParentProcessId = $sentinelRoot; Name = 'ka-procwalk-untimed'; CreationDate = $null })
            }

            Write-Output '   - a live pid the sampler cannot time (the guard must not be skipped for it)'
            $nmStub = @{ $stubId = 'ka-procwalk-untimed' }
            $histStub = @{ $stubId = $sentinelRoot }
            $bornStub = @{ $stubId = $stubBorn }
            $got5 = @(Get-LeakedDescendants $sentinelRoot $histStub $nmStub $bornStub)
            if ($got5 -contains $stubId) {
                Bad 'followed a live pid whose creation time cannot be read now - that is the fail-open that named a servicing burst (TiWorker.exe, TrustedInstaller.exe, svchost.exe) as a 6-minute leg''s leftovers'
            } else { Ok 'refused: alive now but not provably the same process' }

            Write-Output '   - and the sampler records no time at all for such a row'
            $h5 = @{ }; $n5 = @{ }; $b5 = @{ }
            Update-ProcessHistory $h5 $n5 $b5
            if (-not $h5.ContainsKey($stubId)) { Bad 'the mirrored row set never reached the sampler - the case below would be vacuous' }
            elseif ($b5.ContainsKey($stubId)) {
                Bad ('a process CIM gave no CreationDate for was recorded as created at tick ' + $b5[$stubId] + ' - the 0 sentinel is a present key with a real-looking value, so it disarms the guard instead of firing it')
            } else { Ok 'no time recorded for a row that has none, so the guard can fire' }
        }
    }
    try { Stop-Process -Id $walk.Id -Force -ErrorAction Stop } catch { }
} finally {
    try { Stop-Process -Id $mine.Id -Force -ErrorAction Stop } catch { }
    if ($wmi) { try { Stop-Process -Id $wmi -Force -ErrorAction Stop } catch { } }
    [Ka.LegJob]::Close($job)
}

if ($asChild) {
    # Running as the guard's own red check: report and stop. No second level of mutation.
    foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
    if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
    Write-Output 'PROBE OK (child): the library under test behaves'
    exit 0
}

# ---------------------------------------------------------------- the query's own red
# Replace the one line that asks the job with "everything alive" and require case 2 to go red. Anchored
# on exact text and counted first: a silent miss would make this half vacuous, which is the failure mode
# this file exists to avoid.
Write-Output '--- 7. the injection: the job query replaced by a list of everything alive'
$anchor = '    $pids = [Ka.LegJob]::Pids($Job)'
$libText = [IO.File]::ReadAllText($lib)
$hits = ([regex]::Matches($libText, [regex]::Escape($anchor))).Count
if ($hits -ne 1) { Write-Output ("PROBE FAILED: the query anchor matches $hits time(s), expected 1 - the injection would not test what we think"); exit 1 }
$mutant = Join-Path $root ('_tmp/procwalk-allpids-' + [guid]::NewGuid().ToString('N') + '.ps1')
$mutText = $libText.Replace($anchor, '    $pids = @(Get-ProcessRows | ForEach-Object { [int]$_.ProcessId })')
$enc = New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($mutant, $mutText, $enc)
$out = Join-Path $env:TEMP ('ka-procwalk-child-' + [guid]::NewGuid().ToString('N') + '.out')
try {
    $prevLib = $env:KA_PROCWALK_LIB
    $prevChild = $env:KA_PROCWALK_CHILD
    $env:KA_PROCWALK_LIB = $mutant
    $env:KA_PROCWALK_CHILD = '1'
    $p = Start-Process -FilePath $ps -NoNewWindow -PassThru -RedirectStandardOutput $out `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $selfPath + '"')
    $deadline = (Get-Date).AddSeconds(180)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $timedOut = -not $p.HasExited
    if ($timedOut) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    $text = (@(Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) -join "`n")   # Get-Content: the redirect handle is still ours
    if ($prevLib) { $env:KA_PROCWALK_LIB = $prevLib } else { Remove-Item Env:KA_PROCWALK_LIB -ErrorAction SilentlyContinue }
    if ($prevChild) { $env:KA_PROCWALK_CHILD = $prevChild } else { Remove-Item Env:KA_PROCWALK_CHILD -ErrorAction SilentlyContinue }
    if ($timedOut) {
        Bad 'the injected child did not finish in 180s'
    } elseif ($text -notlike '*false positive the job removes*') {
        Bad 'with the job query replaced by everything alive, case 2 still passed - the WMI case does not depend on it'
        foreach ($l in ($text -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
    } else {
        Ok 'the WMI case goes red the moment the answer stops coming from the job'
    }
} finally {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mutant -Force -ErrorAction SilentlyContinue
}

Write-Output '--- 8. the injection: the walk''s record rule deleted'
$anchor2 = '            if (-not $Born.ContainsKey($up)) { break }'
$libText2 = [IO.File]::ReadAllText($lib)
$hits2 = ([regex]::Matches($libText2, [regex]::Escape($anchor2))).Count
if ($hits2 -ne 1) { Write-Output ("PROBE FAILED: the walk anchor matches $hits2 time(s), expected 1 - the injection would not test what we think"); exit 1 }
$mutant2 = Join-Path $root ('_tmp/procwalk-norecord-' + [guid]::NewGuid().ToString('N') + '.ps1')
$out2 = Join-Path $env:TEMP ('ka-procwalk-child-' + [guid]::NewGuid().ToString('N') + '.out')
try {
    [IO.File]::WriteAllText($mutant2, $libText2.Replace($anchor2, '            if ($false) { break }'), $enc)
    $prevLib2 = $env:KA_PROCWALK_LIB; $prevChild2 = $env:KA_PROCWALK_CHILD
    $env:KA_PROCWALK_LIB = $mutant2; $env:KA_PROCWALK_CHILD = '1'
    $p2 = Start-Process -FilePath $ps -NoNewWindow -PassThru -RedirectStandardOutput $out2 `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $selfPath + '"')
    $deadline2 = (Get-Date).AddSeconds(180)
    while (-not $p2.HasExited -and (Get-Date) -lt $deadline2) { Start-Sleep -Milliseconds 100; $p2.Refresh() }
    $timedOut2 = -not $p2.HasExited
    if ($timedOut2) { try { Stop-Process -Id $p2.Id -Force -ErrorAction Stop } catch { } }
    $text2 = (@(Get-Content -LiteralPath $out2 -Raw -ErrorAction SilentlyContinue) -join "`n")
    if ($prevLib2) { $env:KA_PROCWALK_LIB = $prevLib2 } else { Remove-Item Env:KA_PROCWALK_LIB -ErrorAction SilentlyContinue }
    if ($prevChild2) { $env:KA_PROCWALK_CHILD = $prevChild2 } else { Remove-Item Env:KA_PROCWALK_CHILD -ErrorAction SilentlyContinue }
    if ($timedOut2) { Bad 'the record-rule child did not finish in 180s' }
    elseif ($text2 -notlike '*dead-and-recycled bridge*') {
        Bad 'with the record rule deleted the child still passed - the no-record case does not depend on it'
        foreach ($l in ($text2 -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
    } else { Ok 'the no-record case goes red the moment that rule is deleted' }
} finally {
    Remove-Item -LiteralPath $out2 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mutant2 -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------- the 0-sentinel's own red (run 36679927952)
# The two rules repaired on 2026-09-30 each get reverted here, one at a time, and each mutant child is
# required to redden the case that owns its rule.
function New-LibMutant([string]$From, [string]$To, [string]$Slug) {
    # Anchored on exact text and counted first: a silent miss would make the injection vacuous, which is
    # the failure mode this file exists to avoid - so a miss ends the run here, like legs 7 and 8 do,
    # and it is not reported through Bad(): Bad writes to the pipeline, and a helper that returns a path
    # must not also return text (the two would be glued into one array).
    $text = [IO.File]::ReadAllText($lib)
    $hits = ([regex]::Matches($text, [regex]::Escape($From))).Count
    if ($hits -ne 1) { Write-Output ("PROBE FAILED: the anchor for '$Slug' matches $hits time(s), expected 1 - the injection would not test what we think"); exit 1 }
    $path = Join-Path $root ('_tmp/procwalk-' + $Slug + '-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($path, $text.Replace($From, $To), (New-Object Text.UTF8Encoding($true)))
    return $path
}

function Invoke-InjectedChild([string]$LibPath) {
    # This probe, run again as a child against the mutated library. The child reports on its own
    # assertions; the leg here only asks whether it went red for the reason under test. $null means it
    # did not finish, and the deadline is what turns a silent hang into one named line.
    $out = Join-Path $env:TEMP ('ka-procwalk-child-' + [guid]::NewGuid().ToString('N') + '.out')
    $prevLib = $env:KA_PROCWALK_LIB
    $prevChild = $env:KA_PROCWALK_CHILD
    $env:KA_PROCWALK_LIB = $LibPath
    $env:KA_PROCWALK_CHILD = '1'
    try {
        $p = Start-Process -FilePath $ps -NoNewWindow -PassThru -RedirectStandardOutput $out `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $selfPath + '"')
        $deadline = (Get-Date).AddSeconds(180)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
        if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } ; return $null }
        return (@(Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) -join "`n")   # Get-Content: the redirect handle is still ours
    } finally {
        if ($prevLib) { $env:KA_PROCWALK_LIB = $prevLib } else { Remove-Item Env:KA_PROCWALK_LIB -ErrorAction SilentlyContinue }
        if ($prevChild) { $env:KA_PROCWALK_CHILD = $prevChild } else { Remove-Item Env:KA_PROCWALK_CHILD -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

Write-Output '--- 9. the injection: the 0-sentinel guard in the sampler deleted'
$mutant9 = New-LibMutant `
    '        try { $t = [long]$r.CreationDate.Ticks; if ($t -gt 0) { $Born[$id] = $t } } catch { }' `
    '        try { $Born[$id] = [long]$r.CreationDate.Ticks } catch { }' `
    'nulltime'
try {
    $text9 = Invoke-InjectedChild $mutant9
    if ($null -eq $text9) { Bad 'the 0-sentinel child did not finish in 180s' }
    elseif ($text9 -notlike '*0 sentinel*') {
        Bad 'with the 0-sentinel guard deleted the child still passed - the sampler case does not depend on it'
        foreach ($l in ($text9 -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
    } else { Ok 'the sampler case goes red the moment a no-time row is recorded as tick 0' }
} finally { Remove-Item -LiteralPath $mutant9 -Force -ErrorAction SilentlyContinue }

Write-Output '--- 10. the injection: the walk''s guard reverted to its fail-open one-liner'
# One line, and it is the whole of the old rule: gating on "a time was read now" instead of "alive now"
# turns an unreadable current time into a skip rather than a stop.
$mutant10 = New-LibMutant `
    '            if ($liveNow.ContainsKey($up)) {' `
    '            if ($nowBorn.ContainsKey($up)) {' `
    'guard2'
try {
    $text10 = Invoke-InjectedChild $mutant10
    if ($null -eq $text10) { Bad 'the guard-2 child did not finish in 180s' }
    elseif ($text10 -notlike '*followed a live pid whose creation time cannot be read*') {
        Bad 'with guard 2 reverted to its fail-open one-liner the child still passed - the live-but-unprovable case does not depend on it'
        foreach ($l in ($text10 -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
    } else { Ok 'the live-but-unprovable case goes red the moment guard 2 skips an unreadable time' }
} finally { Remove-Item -LiteralPath $mutant10 -Force -ErrorAction SilentlyContinue }

foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: the job lists what this leg started and assigned, does not list a WMI-created stranger, drops an exited member and takes its members with it when killed; the walk names a chain to the leg root, refuses a rehanded pid, a hop nothing is recorded about and a live pid whose time it cannot read, still crosses a dead hop it did sample; the sampler records no time for a row that has none; and each of the four rules has an injection that reddens its own case'
