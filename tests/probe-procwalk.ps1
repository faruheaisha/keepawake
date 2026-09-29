<#
    The leftover walk's attribution rules, and the guard that keeps the reconstruction from stitching
    two unrelated ancestries together.

    Why this exists (2026-09-28/29): CI went red twice naming processes that had nothing to do with the
    probe blamed for them - `svchost.exe` + `CompatTelRunner.exe`, Windows' compatibility telemetry and
    its service host (runs 36440936247 and 36443663108, the blamed probes having printed PROBE OK
    themselves) - and then locally naming `sleep.exe`, which is Git for Windows' `sleep`, started by
    the very tooling that was watching that run. The age window cannot exclude such processes: they
    really are born inside the leg's window. The reconstruction was at fault, because a pid->ppid
    entry is evidence only about the process that held that pid when the entry was written; when
    another process holds the pid now, following the entry can land on the leg's cmd pid by chance.

    The guard below (creation time recorded vs live) closes the case where the pid has changed hands
    since it was written. It does NOT close the case of a *dead-and-recycled* hop in the middle of a
    chain, where no live process is left to compare against - that class stays open, named in the
    CHANGELOG and in task #70 together with the measured reason the obvious fix (claim only what a
    live observation saw) is not usable as-is: sampling cannot see a leak whose parent dies inside one
    sampling interval, and doing exactly that dropped the deliberate console-leak fixture
    (`ka-f-ghost`) and turned probe-ci-harness red. The remaining sound option is to mark the leg's
    tree by construction - run each leg inside a Windows Job object and ask the job for its process
    list - instead of reconstructing a tree out of pids after the fact.

    The cases below pin the reconstruction's contract; the last run deletes the guard from a copy of
    the library and requires that copy to fail case 2. Without that half a green here would say
    nothing about whether the guard does anything.
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

$sentinelRoot = 999999   # the leg's cmd pid in these hand-made maps; a number, not a process
$deadHop = 999998        # an ancestor that no longer exists - the tail the history exists for

$child = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
try {
    $rows = @(Get-ProcessRows)
    foreach ($r in $rows) {
        if ([int]$r.ProcessId -eq $sentinelRoot -or [int]$r.ProcessId -eq $deadHop) {
            Bad ("pid $($r.ProcessId) is a real process here - the hand-made map would collide with it")
        }
    }
    $live = @{}
    foreach ($r in $rows) { try { $live[[int]$r.ProcessId] = [long]$r.CreationDate.Ticks } catch { } }
    if (-not $live.ContainsKey([int]$child.Id)) { Bad 'the child is not in the live row set - nothing below could be named' }
    $realTicks = $live[[int]$child.Id]

    Write-Output '--- 1. a recorded parent chain that reaches the leg root names the process'
    $hist = @{ [int]$child.Id = $sentinelRoot }
    $born = @{ [int]$child.Id = $realTicks }
    $names = @{ [int]$child.Id = 'ka-procwalk-fixture' }
    $got = @(Get-LeakedDescendants $sentinelRoot $hist $names $born)
    if ($got -contains [int]$child.Id) { Ok ("named: $($child.Id)") } else { Bad 'the intact chain was not followed - the reconstruction cannot name a real leftover' }

    Write-Output '--- 2. the same entry, but its pid now holds a different process (creation time differs)'
    $bornRecycled = @{ [int]$child.Id = $realTicks - 36000000000 }   # a full hour earlier: not this process
    $got2 = @(Get-LeakedDescendants $sentinelRoot $hist $names $bornRecycled)
    if ($got2 -contains [int]$child.Id) {
        Bad 'a recycled pid was followed anyway - this is the bug that named svchost.exe/CompatTelRunner.exe in CI'
    } else { Ok 'stopped at the recycled pid instead of following the stale entry' }

    Write-Output '--- 3. a dead hop in the middle is still crossed (the guard must not break this)'
    $hist3 = @{ [int]$child.Id = $deadHop; $deadHop = $sentinelRoot }
    $got3 = @(Get-LeakedDescendants $sentinelRoot $hist3 $names $born)
    if ($got3 -contains [int]$child.Id) { Ok 'two-hop chain through a dead process still reaches the root' }
    else { Bad 'a dead ancestor broke the reconstruction - real leftovers whose parents already exited would be missed' }

    Write-Output '--- 4. the age window still decides what counts as this leg''s'
    $inWindow = @(Get-OwnLeftovers @([int]$child.Id) (Get-Date).AddMinutes(-5) (Get-Date).AddMinutes(1))
    if ($inWindow -contains [int]$child.Id) { Ok 'a process born inside the window is kept' } else { Bad 'a live child born just now was dropped by the window' }
    $outWindow = @(Get-OwnLeftovers @([int]$child.Id) (Get-Date).AddMinutes(10) (Get-Date).AddMinutes(20))
    if ($outWindow.Count -eq 0) { Ok 'a process born outside the window is dropped' } else { Bad 'the window let a process born later through' }
    Write-Output '--- 5. an alive pid with no recorded creation time stops the walk'
    $bornNoEntry = @{}
    $got5 = @(Get-LeakedDescendants $sentinelRoot $hist $names $bornNoEntry)
    if ($got5.Contains([int]$child.Id) -or $got5.Count -gt 0) {
        Bad 'a pid that is alive with no recorded creation time was followed anyway - that is how CI named a servicing burst'
    } else { Ok 'with no record of that pid, the chain is not followed' }
} finally {
    try { Stop-Process -Id $child.Id -Force -ErrorAction Stop } catch { }
}

if ($asChild) {
    # Running as the guard's own red check: report and stop. No second level of mutation.
    foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
    if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
    Write-Output 'PROBE OK (child): the library under test behaves'
    exit 0
}

# ---------------------------------------------------------------- the guard's own red
# Delete the guard from a copy of the library and require the copy to fail case 2. Anchored on the
# exact text and counted first: a silent miss would make this half vacuous, which is the failure mode
# this file exists to avoid.
Write-Output '--- 6. the injection: the same library with the recycling guard deleted'
$anchor = 'if ($nowBorn.ContainsKey($up)) {'
$libText = [IO.File]::ReadAllText($lib)
$hits = ([regex]::Matches($libText, [regex]::Escape($anchor))).Count
if ($hits -ne 1) { Write-Output ("PROBE FAILED: the guard anchor matches $hits time(s), expected 1 - the injection would not test what we think"); exit 1 }
$mutant = Join-Path $root ('_tmp/procwalk-noguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
$mutText = $libText.Replace($anchor, 'if ($false) {')
$enc = New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($mutant, $mutText, $enc)
$out = Join-Path $env:TEMP ('ka-procwalk-child-' + [guid]::NewGuid().ToString('N') + '.out')
try {
    $prevLib = $env:KA_PROCWALK_LIB
    $prevChild = $env:KA_PROCWALK_CHILD
    $env:KA_PROCWALK_LIB = $mutant
    $env:KA_PROCWALK_CHILD = '1'
    $p = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -NoNewWindow -PassThru -RedirectStandardOutput $out `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $selfPath + '"')
    $deadline = (Get-Date).AddSeconds(180)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $timedOut = -not $p.HasExited
    if ($timedOut) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    $text = (@(Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) -join "`n")   # Get-Content: the redirect handle is still ours
    if ($prevLib) { $env:KA_PROCWALK_LIB = $prevLib } else { Remove-Item Env:KA_PROCWALK_LIB -ErrorAction SilentlyContinue }
    if ($prevChild) { $env:KA_PROCWALK_CHILD = $prevChild } else { Remove-Item Env:KA_PROCWALK_CHILD -ErrorAction SilentlyContinue }
    if ($timedOut) {
        Bad 'the guard-less child did not finish in 180s'
    } elseif ($text -notlike '*recycled pid was followed anyway*') {
        Bad 'with the guard deleted the child still passed - case 2 does not actually depend on the guard'
        foreach ($l in ($text -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
    } else {
        Ok 'without the guard, case 2 goes red on the recycling bug it names'
    }
} finally {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mutant -Force -ErrorAction SilentlyContinue
}

foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: the walk follows a chain that reaches the leg root, stops at a pid that was rehanded since the entry was written and at one it has no creation time for, still crosses a dead ancestor, keeps the age window, and loses case 2 the moment the guard is deleted'
