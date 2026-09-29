<#
    A leg's leftover bookkeeping: the two sources of "which processes are this leg's", and how they are
    reported.

    Two sources, because each one is blind to exactly what the other catches - and both halves of that
    sentence are measured, not reasoned:

      * the JOB object (below, C#): tests/ka-ci.ps1 creates one per leg, puts the cmd it starts into it,
        and every descendant inherits the membership. Exact, immune to pid reuse, one query, no
        sampling. Measured blind spot: the deliberate GUI-leak fixture was NOT named by it on the CI
        runner (run 36534077753: "our own look: 1 alive: 5216" while the runner said "1 run, 0 red"),
        because that fixture spawns its leftover through Diagnostics.Process with UseShellExecute - the
        same shape as the browser hand-off the whole check exists for. A process launched by the shell
        is not our child and inherits nothing.
      * the RECONSTRUCTION (Get-LeakedDescendants): walks up from every live process through a
        pid->ppid history sampled every 2 s. It sees the shell-launched leftover (the history recorded
        the leg's script as its parent while it was alive) and it is the only source that can. It needs
        the two guards below, which is what four CI cycles of false reds bought: a pid->ppid entry is
        evidence only about the process that held that pid when the entry was written, so a pid that
        has changed hands since is not followed, and an alive pid with no recorded creation time stops
        the walk. The class left open by the first version of those guards was a hop through a *dead and
        recycled* pid, where nothing was left to compare against - it is closed by requiring a recorded
        creation time for *every* hop the walk follows: a pid we never sampled while it lived is a pid we
        cannot say anything about, so the walk stops there instead of following its recorded parent. A
        dead hop we *did* sample is still crossed, which is exactly what keeps the shell-launched
        leftover (whose parent is the leg's own script, alive and sampled for seconds) visible.

    The union is deliberately a union: the job can add a member the walk would have missed, and the
    walk can add one the job never had. A missing source therefore cannot silently shrink the report;
    it can only make it smaller than the truth in the shapes the other source owns.

    tests/probe-procwalk.ps1 drives both directly (a job member is named, a WMI-created stranger is not,
    an exited member is gone, the job kill takes its members, a hand-made chain through the
    reconstruction is named, a recycled pid is refused, a dead ancestor is still crossed, the query
    line and the guard both have an injection that reddens their own case).
#>
if (-not ('Ka.LegJob' -as [type])) {
    Add-Type -Namespace Ka -Name LegJob -MemberDefinition @'
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint len, out uint ret);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr h);

    private const int JobObjectBasicProcessIdList = 3;
    private const uint PROCESS_SET_QUOTA = 0x0100;
    private const uint PROCESS_TERMINATE = 0x0001;

    public static IntPtr Create() { return CreateJobObject(IntPtr.Zero, null); }

    // Returns null on success, otherwise the Win32 error as text. The caller must treat a failure as
    // fatal: the whole leftover check depends on the assignment having happened.
    public static string Assign(IntPtr job, int pid) {
        IntPtr p = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid);
        if (p == IntPtr.Zero) { return "OpenProcess(" + pid + ") failed: " + Marshal.GetLastWin32Error(); }
        try {
            if (!AssignProcessToJobObject(job, p)) { return "AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error(); }
            return null;
        } finally { CloseHandle(p); }
    }

    // The pids currently in the job. A member that exited is simply not listed any more.
    public static int LastErr = 0;
    public static int[] Pids(IntPtr job) {
        uint size = 64 * 1024;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            uint ret;
            if (!QueryInformationJobObject(job, JobObjectBasicProcessIdList, buf, size, out ret)) {
                LastErr = Marshal.GetLastWin32Error();
                return null;
            }
            int n = Marshal.ReadInt32(buf, 4);            // NumberOfProcessIdsInList
            if (n < 0 || n > 8000) { LastErr = -1; return null; }   // a sane ceiling: 400 is plenty
            int[] pids = new int[n];
            for (int i = 0; i < n; i++) { pids[i] = Marshal.ReadInt32(buf, 8 + i * IntPtr.Size); }
            return pids;
        } finally { Marshal.FreeHGlobal(buf); }
    }

    public static bool Kill(IntPtr job) { return TerminateJobObject(job, 0); }
    public static void Close(IntPtr job) { if (job != IntPtr.Zero) { CloseHandle(job); } }
'@
}

function Get-KaLegPids([IntPtr]$Job) {
    # The single answer the leftover check depends on: the members of this leg's job, or a failure the
    # caller must not be able to mistake for "nothing leaked". Returns a hashtable rather than an array
    # because of a trap this file already paid for once: an *empty* array returned from a PowerShell
    # function flattens to $null on the way out, so a leg that left nothing (the common, healthy case)
    # would look exactly like a failed query - and the first version of this wrapper threw on it for
    # every leg. Ok is therefore explicit, never inferred from the value.
    # A thin wrapper on purpose: tests/probe-procwalk.ps1 injects into the line below ("everything
    # alive" instead of the job's members) to prove the WMI case depends on it.
    $pids = [Ka.LegJob]::Pids($Job)
    $err = [Ka.LegJob]::LastErr
    return @{ Ok = ($null -ne $pids); Pids = @($pids); Err = $err }
}

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
            # The guard, and it is deliberately two rules deep.
            # (1) No recorded creation time for this pid at all = no evidence about who held it when the
            #     entry was written, so stop. CI paid for this on 2026-09-28: a Windows servicing burst
            #     (TiWorker.exe, TrustedInstaller.exe, MoUsoCoreWorker.exe, three svchost.exe,
            #     CompatTelRunner.exe) was named as a 435 s leg's leftovers, because CIM answers no
            #     CreationDate for those images and a guard that compared only *available* times was
            #     skipped for them. This also closes the class the first version left open - a hop whose
            #     pid is dead *and was recycled*: nothing is left to compare against, and following its
            #     recorded parent is exactly the guess that invented a bed for an unrelated process
            #     (locally: Git's sleep.exe). A dead hop we *did* sample is still crossed, which is what
            #     keeps the shell-launched leftover (whose parent chain is the leg's own script) visible.
            if (-not $Born.ContainsKey($up)) { break }
            # (2) If the pid is alive now, it must still be the process the entry was written about.
            if ($nowBorn.ContainsKey($up) -and $nowBorn[$up] -ne [long]$Born[$up]) { break }
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
