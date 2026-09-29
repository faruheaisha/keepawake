<#
    A leg's process bookkeeping: which processes belong to the leg, and how they are reported.

    The name is historical. This file used to hold a walk that reconstructed a leg's tree out of a
    pid->ppid history, and that walk was fooled four times, all false, each costing a CI cycle by
    naming a process unrelated to the probe it was blamed on (and the blamed probe had printed its own
    PROBE OK): wps.exe/wpscloudsvr.exe (the user's office suite), the machine's own worker pid 21688,
    CompatTelRunner.exe, and then a whole Windows servicing burst (TiWorker.exe, TrustedInstaller.exe,
    MoUsoCoreWorker.exe, three svchost.exe, CompatTelRunner.exe). Two rules were added - a pid->ppid
    entry is followed only while the pid still holds the process recorded there, and an alive pid with
    no recorded creation time stops the walk - and CI went green (run 36528628613). The class was
    still not closed: a hop through a *dead and recycled* pid has nothing left to compare against, and
    that is measured rather than theoretical (locally a Git `sleep.exe`, started by the tooling that
    was watching the run, was named as a 384 s leg's leftover).

    So the reconstruction is gone. A leg's tree is marked **by construction**: tests/ka-ci.ps1 creates
    a Job object, puts the cmd it starts into it, and every descendant inherits the membership. Asking
    the job for its process list is exact, cannot be fooled by pid reuse, and needs no sampling:
    membership survives the exit of the parent that created it, which is exactly the leftover shape
    (a browser whose whole ancestry had already exited) the old walk existed for.

    Deliberately NOT set: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. Closing the job's last handle must not
    kill the leftovers - the leftover is the finding, so it has to outlive the check that reports it.
    Killing is explicit (TerminateJobObject) and only on the timeout path, where `taskkill /T` ran.

    Cross-checks: tests/probe-procwalk.ps1 drives these helpers directly (a real child is in the job, a
    process created through WMI is not, an exited member is gone, kill terminates the members, the age
    window still partitions, and replacing the job query with "everything alive" turns the WMI case
    red), while tests/probe-ci-harness.ps1 keeps requiring that the deliberate leak fixtures are still
    named through the runner - that is the integration half.
#>

# The point of this file is that the answer is exact, so the interop is written once, in C#, with the
# struct marshalling spelled out instead of assembled in PowerShell.
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
    # CreationDate is no longer needed (the job identifies a leg's tree now), so the projection is back
    # to the cheaper three; the pid->name map it feeds is built once per leg, at check time.
    @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction SilentlyContinue)
}

function Get-OwnLeftovers([int[]]$ProcIds, [datetime]$BornNoEarlierThan, [datetime]$BornNoLaterThan) {
    # The window is deliberately generous at the edges: a process whose start time cannot be read
    # (access denied, or a protected service) is kept, because losing a real leftover is worse than a
    # red that names something for a human to go look at. With the job as the source of the pids this
    # window is belt-and-braces rather than the guard it used to be - everything in the job was created
    # by this leg - and it stays because a pid recycled *within* the leg is exactly the shape it
    # catches.
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
    # first fixture run. The caller builds $Names from one query taken after the alive check, so it has
    # a name for everything that can be printed.
    if (-not $ProcIds.Count) { return @() }
    return @(foreach ($id in $ProcIds) { ('{0}:{1}' -f $id, $Names[$id]) })
}
