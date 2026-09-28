<#
    The leftover check's process walk, in its own file so it can be tested directly.

    tests/ka-ci.ps1 starts every leg through cmd.exe and then asks "which live process can be traced
    back to that cmd?" by walking UP from everything alive through a pid->ppid history sampled every
    2 s. Walking DOWN from the child is blind - the leftover that hung CI was a browser whose whole
    ancestry (cmd, ka.ps1, the panel's powershell) had exited before anyone looked, and Windows keeps
    no record of a dead process's parent. That is why the history exists.

    This walk is the subtlest thing in the runner and it has been fooled three times, all false:
      * wps.exe / wpscloudsvr.exe, the user's office suite: their parent pid was one of ours from
        before ours died and the history still held that mapping. Fixed with the upper age bound.
      * pid 21688, the machine's own running worker: older than the leg, whose parent slot had been
        reused by the cmd this leg started. Fixed with the lower age bound.
      * svchost.exe + CompatTelRunner.exe (Windows' compatibility telemetry) named as descendants of
        probe-server-hint-selftest (run 36443663108), and CompatTelRunner.exe of probe-encoding-selftest
        (run 36440936247, a 13 s leg). Both live, both unrelated to any probe. The age window cannot
        exclude them - they really were born inside the leg's window - so the error was in the walk: a
        pid->ppid entry is evidence about the process that held that pid *when the entry was recorded*,
        and nothing else. When a different process holds the pid now, following the entry stitches two
        unrelated ancestries together and the chain can land on the leg's root by coincidence. Hence
        the guard below: follow an entry only while the pid still holds the very process recorded
        there, compared by creation time.

    tests/probe-procwalk.ps1 drives these functions directly with hand-made maps, so the guard has a
    red of its own and the dead-tail case it must not break has a green of its own.

    The function names are the ones tests/ka-ci.ps1 used before they moved here, because
    tests/probe-ci-harness-selftest.ps1 anchors a mutation on the exact line that calls
    Format-Leftovers - renaming would have broken that anchor for no gain.
#>

$consoleHosts = @('conhost.exe', 'OpenConsole.exe')

function Get-ProcessRows {
    # 155 ms median measured on this host with ProcessId, ParentProcessId, Name against 278 ms for the
    # same query without Name and 192 ms for the unprojected table (6 samples each, 402 rows).
    # CreationDate was added later for the recycling guard; measured again on 2026-09-28 at 197 ms
    # median over 6 samples (same host, 430 rows) - ~0.4% of a core at one query every 2 s.
    @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction SilentlyContinue)
}

function Update-ProcessHistory([hashtable]$History, [hashtable]$Names, [hashtable]$Born) {
    # One query fills all three maps: pid->ppid is what the walk crosses, pid->name is what it prints,
    # and pid->creation-ticks is what tells a recycled pid from the process an entry was written about.
    foreach ($r in @(Get-ProcessRows)) {
        $id = [int]$r.ProcessId
        $History[$id] = [int]$r.ParentProcessId
        $Names[$id] = [string]$r.Name
        try { $Born[$id] = [long]$r.CreationDate.Ticks } catch { }
    }
}

function Get-LeakedDescendants([int]$RootId, [hashtable]$History, [hashtable]$Names, [hashtable]$Born) {
    # Walk UP from everything alive now, through a pid->ppid history, instead of down from the child
    # that is already gone. Down is blind here: the leftover that hung CI was a browser whose whole
    # ancestry - cmd, ka.ps1, the panel's powershell - had exited before anyone looked, and Windows
    # keeps no record of a dead process's parent. Up through the history reaches it.
    # Blind spot, stated rather than hidden: a process born and buried between two samples leaves no
    # entry, so its own child is invisible to this walk.
    $rows = @(Get-ProcessRows)
    $nowBorn = @{ }
    foreach ($r in $rows) {
        try { $nowBorn[[int]$r.ProcessId] = [long]$r.CreationDate.Ticks } catch { }
    }
    $out = @()
    foreach ($r in $rows) {
        $pidNow = [int]$r.ProcessId
        # conhost.exe (23 of 402 rows on this host at rest) and OpenConsole.exe are pseudo-console
        # hosts Windows starts for a process that gets its own window station. They die with the
        # session they were made for, hold no port, no power request and no file handle, and in the
        # one fixture that leaks on purpose they showed up next to the leftover that caused them.
        # Asserting on them would only add a way for a clean run to go red by accident. The blind
        # spot this opens is small and named: a console host orphaned by a parent that died between
        # two samples is dropped unseen.
        if ($consoleHosts -contains [string]$r.Name) { continue }
        $up = $pidNow
        for ($i = 0; $i -lt 40; $i++) {
            if (-not $History.ContainsKey($up)) { break }
            # The guard. A pid that is alive now but did not exist when this entry was recorded is a
            # different process that inherited the number, so the entry says nothing about it and the
            # walk stops instead of following it. A pid that is gone now keeps its recorded parent -
            # that dead tail is the whole reason this history exists (and it is also the class this
            # guard cannot close: see the header).
            if ($Born.ContainsKey($up) -and $nowBorn.ContainsKey($up) -and $nowBorn[$up] -ne [long]$Born[$up]) {
                break
            }
            $up = [int]$History[$up]
            if ($up -eq $RootId) { $out += $pidNow; break }
            if ($up -eq 0) { break }
        }
    }
    return @($out | Sort-Object -Unique)
}

function Get-OwnLeftovers([int[]]$ProcIds, [datetime]$BornNoEarlierThan, [datetime]$BornNoLaterThan) {
    # The window is deliberately generous at the edges: a process whose start time cannot be read
    # (access denied, or a protected service) is kept, because losing a real leftover is worse than a
    # red that names something for a human to go look at.
    # $BornNoLaterThan is the moment the poll noticed the exit, not the exit itself: measured in
    # tests/ka-ci.ps1, a non-waited Start-Process object answers $null (without throwing) for ExitTime
    # and ExitCode once the child is gone, so there is nothing better to use. The gap is the poll's
    # own 200 ms.
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
    # Nothing to name returns an empty array, not '': an empty string inside @() is one element, and
    # 'left 1 descendant(s) alive: ' with nothing after the colon is exactly what it printed on the
    # first fixture run. Only a pid present in $History can be reported, and both maps are filled from
    # the same rows, so $Names has a name for everything printed.
    if (-not $ProcIds.Count) { return @() }
    return @(foreach ($id in $ProcIds) { ('{0}:{1}' -f $id, $Names[$id]) })
}
