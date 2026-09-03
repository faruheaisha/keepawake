<#
.SYNOPSIS
    Shared library for 防休眠 Keep-Awake. Dot-source this from every entry point.

.DESCRIPTION
    Owns the three things that must not be duplicated (and previously were wrong):

      * the Win32 surface (power request + synthetic input + power/battery/idle state)
      * configuration and machine detection, including the powercfg text parser
      * worker lifecycle: discovery is authoritative (process command line), never a
        PID file, and stopping is cooperative so the worker can clean up after itself.

    Everything here is read-only unless a function name starts with Start-/Stop-/Set-.
#>

# The ConstrainedLanguage check does NOT live here, and cannot: ka-gate.ps1 has to run before
# this file (Add-Type below is the first thing that mode forbids) and `exit` inside a dot-sourced
# script does not stop the script that dot-sourced it, so the refusal has to be issued by each
# entry point in its own top level.

# ---------------------------------------------------------------- native surface
if (-not ('Ka.Native' -as [type])) {
    try {
        Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Collections;
using System.Runtime.InteropServices;

namespace Ka {

public static class Native {

    // ---- power request -------------------------------------------------------
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS        = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED   = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED  = 0x00000002;
    public const uint ES_AWAYMODE_REQUIRED = 0x00000040;

    public static uint ApplyPowerRequest(uint flags) {
        return SetThreadExecutionState(ES_CONTINUOUS | flags);
    }
    // The documented stop path: learn.microsoft.com's SetThreadExecutionState example
    // clears everything with exactly this call - `SetThreadExecutionState(ES_CONTINUOUS)`
    // - ("Clear EXECUTION_STATE flags to disable away mode and allow the system to idle
    // to sleep normally"). No extra one-shot call is needed or documented anywhere; the
    // return value is the PREVIOUS thread execution state, so the caller can record what
    // was actually held when it was released.
    public static uint ClearPowerRequest() {
        return SetThreadExecutionState(ES_CONTINUOUS);
    }

    // ---- power capabilities ----------------------------------------------------
    // Layout reference is the SDK's own um/winnt.h (verified on disk, 10.0.26100.0):
    // SYSTEM_POWER_CAPABILITIES is FLATTENED - one BOOLEAN (= 1 byte) per member, no
    // bitfields - and is 76 bytes total. The native struct is 76; the buffer is bigger
    // than that on purpose, an [out] param never writes past what it needs.
    [DllImport("PowrProf.dll")]
    static extern bool GetPwrCapabilities(byte[] lpspc);

    public static byte[] GetPowerCapabilitiesRaw() {
        var buf = new byte[128];
        return GetPwrCapabilities(buf) ? buf : null;
    }

    // ---- UIPI / integrity ------------------------------------------------------
    // Synthetic input from a lower-integrity process is silently dropped when the
    // foreground window belongs to a higher-integrity one: no error reaches the
    // sender, so the heartbeat would count pulses that land nowhere. -1 means
    // "could not measure" and is a distinct, honest answer - only a measured
    // mismatch may suppress a pulse.
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);

    const int TokenIntegrityLevelClass = 25;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint TOKEN_QUERY = 0x0008;

    // Last SID sub-authority of the TokenIntegrityLevel label = the IL RID
    // (0x1000 low, 0x2000 medium, 0x3000 high, 0x4000 system).
    static int TokenIntegrityRid(IntPtr token) {
        var buf = new byte[256];
        var h = GCHandle.Alloc(buf, GCHandleType.Pinned);
        try {
            int retLen;
            if (!GetTokenInformation(token, TokenIntegrityLevelClass, h.AddrOfPinnedObject(), buf.Length, out retLen)) return -1;
            IntPtr sidPtr = Marshal.ReadIntPtr(h.AddrOfPinnedObject());
            if (sidPtr == IntPtr.Zero) return -1;
            int count = Marshal.ReadByte(sidPtr, 1);
            if (count < 1) return -1;
            return Marshal.ReadInt32(sidPtr, 8 + (count - 1) * 4);
        } finally { h.Free(); }
    }

    public static int SelfIntegrityRid() {
        IntPtr tok;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, TOKEN_QUERY, out tok)) return -1;
        try { return TokenIntegrityRid(tok); } finally { CloseHandle(tok); }
    }

    public static uint ForegroundPid() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }

    public static int ProcessIntegrityRid(uint pid) {
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) return -1;
        try {
            IntPtr tok;
            if (!OpenProcessToken(proc, TOKEN_QUERY, out tok)) return -1;
            try { return TokenIntegrityRid(tok); } finally { CloseHandle(tok); }
        } finally { CloseHandle(proc); }
    }

    // ---- user idle -----------------------------------------------------------
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    static extern ulong GetTickCount64();

    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    public static double SecondsSinceInput() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) return -1;
        // dwTime lives on the legacy 32-bit tick clock. Subtract there and only then
        // reinterpret as signed, otherwise an uptime past the 49.7-day wrap turns a
        // 5-second idle into a 49-day one.
        uint now32 = (uint)(GetTickCount64() & 0xFFFFFFFFL);
        int delta;
        unchecked { delta = (int)(now32 - info.dwTime); }
        if (delta < 0) delta = 0;
        return (double)delta / 1000.0;
    }

    // ---- synthetic input via SendInput --------------------------------------
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int nIndex);

    const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    const uint MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001, KEYEVENTF_KEYUP = 0x0002;
    const int  SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
    const int  SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData;
                        public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags;
                        public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }

    // VK_F15 with its real scan code. F13-F24 are extended keys, so E0 is required
    // for apps that read the scan code rather than the virtual key.
    public static bool PulseF15() {
        int size = Marshal.SizeOf(typeof(INPUT));
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = 0x7E; inputs[0].u.ki.wScan = 0x64;
        inputs[0].u.ki.dwFlags = KEYEVENTF_EXTENDEDKEY;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = 0x7E; inputs[1].u.ki.wScan = 0x64;
        inputs[1].u.ki.dwFlags = KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP;
        return SendInput((uint)inputs.Length, inputs, size) == (uint)inputs.Length;
    }

    // Absolute, always stepping inward, and restoring the exact saved point, so the
    // cursor cannot drift when it sits at a screen edge. MOUSEEVENTF_MOVE goes through
    // the input stack, which is what resets the idle timer (SetCursorPos alone does not).
    public static bool NudgeMouse() {
        POINT p;
        if (!GetCursorPos(out p)) return false;
        int ox = GetSystemMetrics(SM_XVIRTUALSCREEN), oy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int w  = GetSystemMetrics(SM_CXVIRTUALSCREEN), h  = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (w < 2 || h < 2) return false;

        int nx = p.X + (p.X - ox >= w - 2 ? -1 : 1);
        int ny = p.Y + (p.Y - oy >= h - 2 ? -1 : 1);
        if (nx < ox) nx = ox + 1;
        if (ny < oy) ny = oy + 1;

        int size = Marshal.SizeOf(typeof(INPUT));
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[1].type = INPUT_MOUSE;
        inputs[0].u.mi.dx = NormX(nx, ox, w); inputs[0].u.mi.dy = NormY(ny, oy, h);
        inputs[1].u.mi.dx = NormX(p.X, ox, w); inputs[1].u.mi.dy = NormY(p.Y, oy, h);
        for (int i = 0; i < 2; i++) {
            inputs[i].u.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
        }
        SendInput((uint)inputs.Length, inputs, size);
        POINT back;
        return GetCursorPos(out back) && back.X == p.X && back.Y == p.Y;
    }

    // SendInput absolute coordinates are 0..65535 across the virtual desktop.
    static int NormX(int x, int ox, int w) {
        double f = (double)(x - ox) / (double)(w - 1);
        if (f < 0) f = 0; if (f > 1) f = 1;
        return (int)Math.Round(f * 65535.0);
    }
    static int NormY(int y, int oy, int h) {
        double f = (double)(y - oy) / (double)(h - 1);
        if (f < 0) f = 0; if (f > 1) f = 1;
        return (int)Math.Round(f * 65535.0);
    }

    // ---- battery / power status ---------------------------------------------
    [DllImport("kernel32.dll")]
    static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS sps);

    struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus; public byte BatteryFlag;
        public byte BatteryLifePercent; public byte SystemStatus;
        public int BatteryLifeTime; public int BatteryFullLifeTime;
    }

    public static Hashtable PowerStatus() {
        SYSTEM_POWER_STATUS s;
        Hashtable h = new Hashtable();
        if (!GetSystemPowerStatus(out s)) { h["known"] = false; return h; }
        bool noBattery = (s.BatteryFlag == 128 || s.BatteryFlag == 255);
        h["known"] = true;
        h["acOnline"] = (s.ACLineStatus == 1);
        h["hasBattery"] = !noBattery;
        h["percent"] = (int)(s.BatteryLifePercent > 100 ? -1 : s.BatteryLifePercent);
        h["low"] = (s.BatteryFlag & 4) != 0;
        h["critical"] = (s.BatteryFlag & 8) != 0;
        h["onBatterySaver"] = (s.SystemStatus & 8) != 0;
        return h;
    }

    // ---- session state -------------------------------------------------------
    // Declared in wtsapi32.h, but exported by kernel32.dll - referencing wtsapi32 here
    // throws EntryPointNotFoundException at call time.
    [DllImport("kernel32.dll")]
    static extern uint WTSGetActiveConsoleSessionId();

    public static int ActiveConsoleSession() {
        // 0xFFFFFFFF means no session is attached to the console; hand back -1 so no
        // caller has to cast an out-of-range UInt32 to Int32.
        return unchecked((int)WTSGetActiveConsoleSessionId());
    }

    // (Lock-screen detection lives in Get-KaSession: logonui.exe presence is a good
    //  non-elevated proxy for "the secure desktop owns the input queue".)
}

}
'@
    } catch {
        # Already registered in this AppDomain is success. Only a real compile or
        # load failure may leave the type missing - and that is worth seeing.
        if (-not ('Ka.Native' -as [type])) { throw }
    }
}

# ---------------------------------------------------------------- paths / io
# Three roots, because a downloaded tool has to survive being put anywhere:
#
#   program  $PSScriptRoot. Scripts only. It may legitimately be read-only -
#            C:\Program Files, a read-only share, a USB stick, a locked-down lab box.
#            Nothing that has to be written lives here any more, which is the whole
#            point: an install that cannot write its own state.json used to report
#            "start failed" while the worker was in fact holding the power request.
#   data     per-user state (config, intent, state, log, stop flag, panel hint).
#            %LOCALAPPDATA%\KeepAwake rather than %APPDATA%: a 512 KB log and a
#            stop.flag have no business riding along in a roaming domain profile,
#            where they would follow the user to another machine and fight the worker
#            running there.
#   machine  facts about *this computer* written by an elevated run. The lid backup
#            lives here because `apply` may run as another (elevated) account while
#            `restore` has to find it, and what it protects is the machine's power plan.
#
# Captured while this file is being dot-sourced, so $PSScriptRoot is unambiguously
# the project directory rather than whatever called into it.
$script:KaProgramRoot = $PSScriptRoot
$script:KaVersion = '3.0.0'
$script:KaLogMaxBytes = 512KB
$script:KaDataRoot = $null
$script:KaDataError = $null
$script:KaMachineRoot = $null
$script:KaMachineError = $null
$script:KaLastWriteError = $null
$script:KaLastWriteCode = $null
$script:KaLogFailed = $false

function Get-KaProgramRoot { $script:KaProgramRoot }

function Test-KaPathWritable {
    <#
        Test-Path cannot see ACLs, read-only media or "AppData writes blocked by the
        AV", all of which look exactly like an existing directory. So probe for real:
        make the directory, write a file, delete it. Never throws - the caller has to
        be able to ask about a path it cannot touch.
    #>
    param([string]$Dir)
    $r = @{ Ok = $false; Error = ''; Code = ''; Path = $Dir }
    try {
        if (-not (Test-Path -LiteralPath $Dir)) {
            New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Dir ('.ka-probe-{0}' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
        # The type name is the locale-proof half of the answer: it reaches the log, the
        # panel payload and the translated sentence, where the OS's own prose would not.
        $r.Code = $_.Exception.GetType().Name
    }
    return $r
}

function Initialize-KaDataRoot {
    <#
        KA_DATA is the documented override (same convention as KA_LANG) and is taken at
        its word: when it is set, it is used even if it turns out to be unwritable,
        because a probe or a test that asked for that directory must see what happens
        there instead of quietly getting somewhere else. Without it there is exactly one
        candidate, and if that one is unwritable we keep its path so every message can
        name the place that failed, and let the alerts say so.
    #>
    if ($script:KaDataRoot) { return $script:KaDataRoot }
    $dir = $null
    if ($env:KA_DATA) {
        $dir = $env:KA_DATA
    } else {
        try { $dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'KeepAwake' } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = Join-Path $env:TEMP 'KeepAwake'
        $script:KaDataError = 'no-localappdata'
    }
    $probe = Test-KaPathWritable $dir
    if (-not $probe.Ok) { $script:KaDataError = $probe.Code }
    $script:KaDataRoot = $dir
    Initialize-KaMigration | Out-Null
    return $script:KaDataRoot
}

function Get-KaDataRoot { Initialize-KaDataRoot }

function Initialize-KaMigration {
    <#
        First run after the upgrade: copy the files that used to live beside the scripts
        into the data root. Copy, never move - the old clone has to keep working, the
        history must survive a half-finished migration (so it can simply be redone), and
        a move would delete the evidence the tests compare against. The marker is written
        last, so an interrupted run migrates again.
    #>
    $data = $script:KaDataRoot
    if (-not $data) { return $false }
    $marker = Join-Path $data '.migrated.json'
    if (Test-Path -LiteralPath $marker) { return $false }
    $from = Get-KaProgramRoot
    $copied = @()
    foreach ($name in @('config.json', 'machine.json', 'intent.json', 'state.json', 'ka.log', 'ka.log.1')) {
        $src = Join-Path $from $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        try {
            Copy-Item -LiteralPath $src -Destination (Join-Path $data $name) -Force -ErrorAction Stop
            $copied += $name
        } catch { }
    }
    # The lid backup is a machine fact, so it goes to the machine root - and only if
    # nothing is there yet. It is the sole evidence for "we changed the lid action and
    # this is what happened afterwards"; dropping it would silently reset that answer to
    # "never changed anything", which is the opposite of honest.
    $lidSrc = Join-Path $from 'ka-lid-backup.json'
    $lidDest = (Get-KaPath).lidBackup
    if ((Test-Path -LiteralPath $lidSrc) -and -not (Test-Path -LiteralPath $lidDest)) {
        try {
            Copy-Item -LiteralPath $lidSrc -Destination $lidDest -Force -ErrorAction Stop
            $copied += 'ka-lid-backup.json'
        } catch { }
    }
    Write-KaJson $marker @{ from = $from; copied = $copied; at = (Get-Date).ToString('o'); version = $script:KaVersion } -Depth 3 | Out-Null
    return $true
}

function Get-KaMachineRoot {
    if ($script:KaMachineRoot) { return $script:KaMachineRoot }
    $dir = $null
    try { $dir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'KeepAwake' } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path (Get-KaProgramRoot) 'machine-data' }
    $probe = Test-KaPathWritable $dir
    if (-not $probe.Ok) {
        # Unlike the data root this does fall back, because the program directory is
        # where the lid backup has always lived and a machine that already has one
        # must still be able to restore it.
        $script:KaMachineError = $probe.Code
        $dir = Join-Path (Get-KaProgramRoot) 'machine-data'
        $probe2 = Test-KaPathWritable $dir
        if (-not $probe2.Ok) { $script:KaMachineError = "$($script:KaMachineError)|program:$($probe2.Code)" }
    }
    $script:KaMachineRoot = $dir
    return $dir
}

function Get-KaIdentitySuffix {
    <#
        Mutex names may not contain '\', hence the hash. Keyed on the data root plus the
        user SID, not the install folder: the data root is what the workers would fight
        over (one state.json, one stop.flag), and the SID keeps two users of the same
        machine-wide install from serialising each other.
    #>
    param([string]$Prefix)
    $sid = ''
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    $key = "$(Get-KaDataRoot)|$sid".ToLower()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hex = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))) -replace '-', ''
    } finally { $sha.Dispose() }
    return "$Prefix-$($hex.Substring(0, 12))"
}

function Get-KaPath {
    $root = Get-KaProgramRoot
    $data = Get-KaDataRoot
    @{
        # root stays the program directory: the panel compares a recorded server pid
        # against it, and the watchdog task's working directory has to be where the
        # scripts are. Workers are attributed by it too (see Get-KaWorker).
        root       = $root
        program    = $root
        data       = $data
        machineRoot = (Get-KaMachineRoot)
        worker     = Join-Path $root 'ka-worker.ps1'
        cli        = Join-Path $root 'ka.ps1'
        server     = Join-Path $root 'ka-server.ps1'
        tray       = Join-Path $root 'ka-tray.ps1'
        guard      = Join-Path $root 'ka-guard.ps1'
        lid        = Join-Path $root 'ka-lid.ps1'
        dashboard  = Join-Path $root 'dashboard'
        config     = Join-Path $data 'config.json'
        machine    = Join-Path $data 'machine.json'
        intent     = Join-Path $data 'intent.json'
        state      = Join-Path $data 'state.json'
        stopFlag   = Join-Path $data 'stop.flag'
        log        = Join-Path $data 'ka.log'
        serverInfo = Join-Path $data '.server.json'
        lidBackup  = Join-Path (Get-KaMachineRoot) 'ka-lid-backup.json'
    }
}

function Get-KaEpoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function ConvertFrom-KaEpoch([long]$e) {
    if ($e -le 0) { return $null }
    try { ([DateTimeOffset]::FromUnixTimeSeconds($e)).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { $null }
}

function Read-KaJson {
    param([string]$Path)
    # Deliberately never throws: a half-written or foreign file must not take down
    # the worker. Returns $null when unreadable.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $raw = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Write-KaJson {
    param([string]$Path, $Object, [int]$Depth = 8, [switch]$Pretty)
    # write-then-move so a concurrent reader never sees a truncated file.
    # The failure is recorded, not just returned: a caller that ignores the boolean still
    # cannot make "we wrote it" and "we could not" look identical to the next reader.
    $script:KaLastWriteError = $null
    $script:KaLastWriteCode = $null
    try {
        $json = if ($Pretty) { $Object | ConvertTo-Json -Depth $Depth }
                else { $Object | ConvertTo-Json -Depth $Depth -Compress }
        $tmp = "$Path.tmp"
        [IO.File]::WriteAllText($tmp, $json,
            (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch {
        # Type name, not Message: this string ends up in ka.log and inside a translated
        # sentence, and Windows writes its IO errors in the OS language.
        $script:KaLastWriteCode = $_.Exception.GetType().Name
        $script:KaLastWriteError = "$Path :: $script:KaLastWriteCode"
        try { Remove-Item "$Path.tmp" -Force -ErrorAction SilentlyContinue } catch {}
        return $false
    }
}

function Get-KaLastWriteError { $script:KaLastWriteError }
function Get-KaLastWriteCode { $script:KaLastWriteCode }

function Add-KaLog {
    param([string]$Message, [switch]$Important)
    # A log write must never be able to kill the protection. That single change fixes
    # the failure mode where a locked or read-only log directory silently ended a run.
    # What it must not do is fail in silence as well: if the only record of what the
    # tool did cannot be written, whoever is watching the console has to hear about it.
    try {
        $p = Get-KaPath
        if ((Test-Path -LiteralPath $p.log) -and ((Get-Item -LiteralPath $p.log).Length -gt $script:KaLogMaxBytes)) {
            $older = "$($p.log).1"
            if (Test-Path -LiteralPath $older) { Remove-Item -LiteralPath $older -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $p.log -Destination $older -Force -ErrorAction SilentlyContinue
        }
        # Invariant on purpose: Get-KaEvidence reads these stamps back with ParseExact under
        # InvariantCulture, and a Thai-locale machine writes 2569 through the current culture's
        # Buddhist calendar, which then parses as year 2569 and puts the whole timeline 543
        # years in the future. Writer and reader have to use one calendar.
        $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $Message
        [IO.File]::AppendAllText($p.log, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        if ($Important) { Write-Host $line }
        $script:KaLogFailed = $false
    } catch {
        if (-not $script:KaLogFailed) {
            # Once per process: a detached worker has no console to spam, and a CLI that
            # cannot write its log must say so before it says anything else.
            $script:KaLogFailed = $true
            try { Write-Host ("LOG-FAILED {0}" -f $_.Exception.GetType().Name) -ForegroundColor DarkYellow } catch { }
        }
    }
}

# ---------------------------------------------------------------- configuration
# Enum-typed config keys in one place. The reader below falls back quietly (config.json
# can be hand-edited or written by an older version, and the tool must still start);
# Set-KaConfig refuses outright, because a value someone just typed or clicked is not a
# mystery value and rewriting it in silence is a lie about what will run.
$script:KaConfigEnums = @{
    antiLockMethod = @{ values = @('key', 'mouse'); default = 'key' }
    language       = @{ values = @('auto', 'zh', 'en'); default = 'auto' }
}

function Get-KaDefaultConfig {
    @{
        version                = 3
        port                   = 8791
        language               = 'auto'    # auto | zh | en
        keepDisplayOn          = $true
        antiLock               = $true
        antiLockMethod         = 'key'      # key | mouse
        antiLockIntervalSec    = 240
        reassertSec            = 60
        # false stays: the explicit screen-off -> real-sleep chain fires despite
        # 0x80000003 on this box (2026-08-31, live, +6s); whether ES_AWAYMODE would
        # stop it was never measured - the B arm was skipped while user-held
        # protection was running. No evidence, no default change.
        awayMode               = $false
        batteryFloorPercent    = 20
        batteryAllowDisplayOff = $true
        logMaxKb               = 512
    }
}

function Get-KaConfig {
    $cfg = Get-KaDefaultConfig
    $saved = Read-KaJson (Get-KaPath).config
    if ($saved) {
        foreach ($k in @($cfg.Keys)) {
            $v = $saved.$k
            if ($null -ne $v) { $cfg[$k] = $v }
        }
    }
    # validation, because an invalid value used to make the child die at parameter
    # binding while the parent still reported success.
    foreach ($k in @($cfg.Keys)) {
        $spec = $script:KaConfigEnums[$k]
        if (-not $spec) { continue }
        $v = "$($cfg[$k])".Trim().ToLowerInvariant()
        if ($v -notin $spec.values) { $v = $spec.default }
        $cfg[$k] = $v
    }
    $cfg.port = [int](Get-KaBounded $cfg.port 1024 65534 8791)
    $cfg.reassertSec = [int](Get-KaBounded $cfg.reassertSec 15 3600 60)
    $cfg.antiLockIntervalSec = [int](Get-KaBounded $cfg.antiLockIntervalSec 10 3600 240)
    $cfg.batteryFloorPercent = [int](Get-KaBounded $cfg.batteryFloorPercent 0 90 20)
    $cfg.logMaxKb = [int](Get-KaBounded $cfg.logMaxKb 64 20480 512)
    $script:KaLogMaxBytes = $cfg.logMaxKb * 1KB
    $cfg.keepDisplayOn = [bool]$cfg.keepDisplayOn
    $cfg.antiLock = [bool]$cfg.antiLock
    $cfg.awayMode = [bool]$cfg.awayMode
    $cfg.batteryAllowDisplayOff = [bool]$cfg.batteryAllowDisplayOff
    return $cfg
}

function Get-KaBounded($value, [double]$min, [double]$max, $fallback) {
    # A missing value must fall back, not clamp to the minimum: 0 and "not configured"
    # are different facts, and the minimum is often the most destructive reading.
    if ($null -eq $value -or ("$value").Trim() -eq '') { return $fallback }
    try {
        $d = [double]$value
        if ($d -lt $min) { return $min }
        if ($d -gt $max) { return $max }
        return $d
    } catch { return $fallback }
}

function Set-KaConfig {
    param([hashtable]$Patch)
    $clean = @{}
    foreach ($k in $Patch.Keys) {
        $v = $Patch[$k]
        $spec = $script:KaConfigEnums[$k]
        if ($spec) {
            $s = "$v".Trim().ToLowerInvariant()
            if ($s -notin $spec.values) {
                throw (Get-KaText 'config.enum' @{
                    key      = $k
                    allowed  = ($spec.values -join ' | ')
                    received = "$v"
                })
            }
            $v = $s
        }
        $clean[$k] = $v
    }
    $cfg = Get-KaDefaultConfig
    $saved = Read-KaJson (Get-KaPath).config
    if ($saved) { foreach ($k in @($cfg.Keys)) { if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k } } }
    foreach ($k in $clean.Keys) { if ($cfg.ContainsKey($k)) { $cfg[$k] = $clean[$k] } }
    $ok = Write-KaJson (Get-KaPath).config ([hashtable]$cfg) -Pretty
    return $ok
}

function Get-KaOsUiLanguages {
    <#
        The language Windows actually renders in, as BCP-47 tags. Registry first because
        that is what the "Windows 显示语言 / Windows display language" setting writes:
        measured on this box, MuiCached says zh-CN while [CultureInfo]::CurrentUICulture
        says en-US, so the two are not the same signal and only the registry one is what
        the user sees. Culture stays as the last resort, not the first choice.
        Key names and value data are both locale-invariant - which is the whole point.
    #>
    $list = @()
    try {
        $v = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\MuiCached' `
                              -Name MachinePreferredUILanguages -ErrorAction Stop).MachinePreferredUILanguages
        if ($v) { $list = @($v) }
    } catch { }
    if (-not $list.Count) {
        try {
            $v = (Get-ItemProperty 'HKCU:\Control Panel\International\User Profile' `
                                  -Name Languages -ErrorAction Stop).Languages
            if ($v) { $list = @($v) }
        } catch { }
    }
    if (-not $list.Count) {
        try { $list = @([Globalization.CultureInfo]::CurrentUICulture.Name) } catch { }
    }
    return @($list | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
}

function Resolve-KaLanguage {
    <#
        Decides the language of human-facing strings. Priority:
        -Explicit > KA_LANG (force it without touching config) > -Configured > the OS display language.

        Only the FIRST entry of the OS list counts: that is the display language the user
        picked, and a second entry is just fallback for uninstalled components. A detached
        worker or a scheduled task can inherit a culture that has nothing to do with what
        the person sees, so any surface that can judge better passes -Explicit and treats
        this as the fallback only.

        Anything not Chinese resolves to English: on a German or Japanese machine Chinese
        strings would be worse than English ones, and English is the fallback every
        zero-dependency CLI uses.
    #>
    param([string]$Explicit, [string]$Configured)
    foreach ($cand in @($Explicit, $env:KA_LANG, $Configured)) {
        $v = "$cand".Trim().ToLowerInvariant()
        if ($v -eq 'zh' -or $v -eq 'en') { return $v }
    }
    foreach ($tag in Get-KaOsUiLanguages) {
        if ($tag -like 'zh*') { return 'zh' }
        return 'en'
    }
    return 'zh'
}

# ---------------------------------------------------------------- ui messages
# Two parallel dictionaries, same keys. zh is the authored language; en is what a
# German or Japanese machine gets. A key missing from en falls back to zh and stays
# visible as Chinese rather than disappearing - tests/ka-tests.ps1 asserts the key sets
# are identical, so the fallback should never fire in a shipped build.
$script:KaUi = @{
    zh = @{
        'worker.note.lock-screen'   = '系统处于锁屏/安全桌面：心跳无法到达用户会话（电源请求仍然有效）'
        'worker.note.il-mismatch'   = '前台窗口属于更高完整性（管理员）进程：心跳输入会被 UIPI 静默丢弃，已跳过（电源请求仍然有效）'
        'worker.note.battery-floor' = '电池 {pct}% 低于阈值 {floor}%：改为只保系统不休眠，允许熄屏以保住续航与数据安全'
        'worker.error.settes-zero'  = 'SetThreadExecutionState 返回 0（{why}）：Windows 拒绝了电源请求'
        'worker.error.settes-throw' = 'SetThreadExecutionState 调用异常（{why}）'
        'guard.path.current'        = '计划任务指向当前目录'
        'guard.path.moved'          = '计划任务指向其它路径（目录可能被移动过），建议卸载后重装'
        'guard.infoFail'            = '运行记录读取失败'
        'guard.defFail'             = '读取计划任务定义失败：{msg}'
        'guard.never'               = '从未'
        'guard.noNext'              = '无排期'
        'guard.nextDisabled'        = '禁用中，不会触发'
        'guard.line'                = '看门狗: {action} (intent={intent} worker={workers} alive={alive})'
        'config.enum'               = '配置项 {key} 只接受 {allowed}，收到：{received}'
        'config.empty'              = '没有要修改的配置项'
        'config.writeFail'          = '配置写不进 {path}（{error}）：改动没有保存'
        'api.unknown'               = '未知接口'
        'api.method'                = '方法不允许'
        'api.noFile'                = '没有这个文件'
        'api.dashMissing'           = '面板文件缺失，请检查 dashboard 目录是否完整'
        'api.internal'              = '服务器内部错误'
        'api.host'                  = 'Host 头不是本机回环地址：{host}'
        'api.origin'                = 'Origin 非本机：{origin}'
        'api.client'                = '缺少 X-Ka-Client 头（跨站页面无法发送该头，这是有意为之）'
        'api.serialize'             = '序列化失败'
        'api.badJson'               = '请求体不是合法 JSON：{msg}'
        'time.empty'                = '没有输入时间'
        'time.unparsed'             = '无法识别的时刻。支持 HH:mm、HH:mm:ss、yyyy-MM-dd HH:mm、yyyy-MM-dd'
        'time.past'                 = '{at} 不在将来，那等于不要到期时间 —— 请写一个将来的时刻'
        'proc.noScript'             = '找不到 {file}：{path}'
        'proc.noStart'              = '无法启动进程：{msg}'
        'proc.noLine'               = '子进程未上报状态'
        'proc.noReport'             = 'worker 启动后没有回报（{why}）'
        'proc.earlyExit'            = 'worker 上报后立即退出了：{why}'
        'proc.earlyExitNoLine'      = 'worker 几秒内就退出了，日志里没有它的原因'
        'server.noStart'            = '无法启动面板进程：{msg}'
        'server.noPing'             = '面板进程未能在 {sec} 秒内响应 /api/ping'
        'server.lastLog'            = '面板日志（本次启动）：{line}'
        'server.bodyTooBig'         = '请求体过大（{size} 字节）'
        'server.console.cantListen' = '无法监听 127.0.0.1:{port}。'
        'server.console.portBusy'   = '端口可能被占用（改 config.json 里的 port），或前一次面板进程还没退出。'
        'server.console.ready'      = '防休眠面板已就绪： http://127.0.0.1:{port}/   (Ctrl+C 退出，保护本身会继续运行)'
        'server.console.exited'     = '面板已退出。'
        'fmt.seconds'               = '{n} 秒'
        'fmt.minutes'               = '{n} 分钟'
        'fmt.hours'                 = '{n} 小时'
        'fmt.never'                 = '从不'
        'fmt.unknown'               = '未知'
        'task.neverRun'             = '从未运行'
        'task.unparsable'           = '结果 {v}'
        'task.ok'                   = '0x0 · 成功'
        'task.nonzero'              = '0x{hex} · 非零退出'
        'report.why.no-lock-timer'      = '未发现空闲锁屏计时器，使用默认 240 秒'
        'report.why.half-of-lock-timer' = '最短锁屏计时 {secs} 秒的一半（上限 240 秒）'
        'report.risk.modern-standby'    = '本机为 S0 现代待机（Modern Standby）：SetThreadExecutionState 可抑制空闲待机，但合盖、电池耗尽或平台策略仍可能强制进入待机。'
        'report.risk.lid-hidden'        = '合盖动作设置在本机被隐藏/不可读：合盖行为只能实测确认，无人值守时请保持开盖或外接显示器。'
        'report.risk.lid-action'        = '合盖动作当前为 {value}（并非 0=不采取任何操作）：合盖即待机，任何防休眠软件都无法阻止。'
        'report.risk.hybrid-sleep'      = '启用了快速启动/混合睡眠：关机并非完全断电，唤醒行为可能异常。'
        'report.risk.lock-policy'       = '存在无人操作锁屏策略（{minutes} 分钟）：多为组织策略，心跳只能延后不能永久压制。'
        'report.risk.battery'           = '当前使用电池（{pct}%）：达到 {floor}% 阈值后显示保护会自动降级。'
        'report.risk.override-self'     = 'requestsoverride 命中了本工具的镜像（{names}）：内核会静默忽略本工具发出的全部电源请求，保护名存实亡；需要管理员权限重新配置或清除该条目。'
        'report.head'                   = '本机环境适配报告'
        'report.label.os'               = '系统'
        'report.label.ps'               = 'PowerShell'
        'report.label.power'            = '电源'
        'report.label.machine'          = '机器类型'
        'report.label.sleep'            = '睡眠状态'
        'report.label.planSleep'        = '计划休眠'
        'report.label.planVideo'        = '计划熄屏'
        'report.label.unattended'       = '无人值守'
        'report.label.lid'              = '合盖动作'
        'report.label.lockReq'          = '唤醒需密码'
        'report.label.policy'           = '锁屏策略'
        'report.label.ss'               = '屏保'
        'report.label.idle'             = '当前空闲'
        'report.label.eng1'             = '引擎1目标'
        'report.label.reco'             = '建议心跳'
        'report.label.config'           = '当前配置'
        'report.machine.laptop'         = '笔记本（有电池）'
        'report.machine.desktop'        = '台式机（无电池）'
        'report.machine.unknown'        = '无法判定（电源状态读不到）'
        'report.power.ac'               = '交流电（电池 {pct}）'
        'report.power.battery'          = '电池 {pct}{saver}'
        'report.power.saver'            = '，节能模式'
        'report.power.none'             = '不适用（本机无电池）'
        'report.sleepRow'               = 'S0现代待机={ms}  S3传统待机={s3}  休眠={hib}'
        'report.acdc'                   = '交流 {ac} / 电池 {dc}'
        'report.unattended'             = '{sec}（唤醒后无人操作时的额外待机延时）'
        'report.lid.hidden'             = '隐藏/不可读'
        'report.lid.vals'               = '交流 {ac} / 电池 {dc}（0=不采取任何操作）'
        'report.lid.nolid'              = '本机没有盖开关（内核能力位已确认），合盖动作不适用'
        'report.lid.has'                = '内核能力位确认本机有盖开关'
        'report.lid.unknown'            = '无法判定本机是否有盖开关（内核能力位读不到）：上面的合盖动作值照实列出，但说不出这台机器有没有盖可合'
        'lid.action.0'                  = '不采取任何操作'
        'lid.action.1'                  = '睡眠'
        'lid.action.2'                  = '休眠（Hibernate）'
        'lid.action.3'                  = '关机'
        'lid.hidden'                    = '隐藏/不可读'
        'lid.unknown'                   = '未知值 {v}'
        'report.label.lidHas'           = '盖开关'
        'report.label.lidNow'           = '现在合盖'
        'report.label.lidVerify'        = '设置实测'
        'report.lidnow.hidden'          = '档位读不出来（powercfg 查询失败），合盖会发生什么未知'
        'report.lidnow.tier-ac'         = '当前插着电（电量 {pct}），交流档生效'
        'report.lidnow.tier-dc'         = '当前用电池（电量 {pct}），电池档生效'
        'report.lidnow.action'          = '{tier} —— 合盖会执行：{action}'
        'report.lidnow.verify-none'     = '没有「lid apply 写入」的记录（从没改过）—— 上面就是系统原配'
        'report.lidnow.verify-unobserved' = '上次写入 {apply}，之后没有合盖时刻可复核 —— 写入成功不等于平台遵守，合一次盖再回来看这里'
        'report.lidnow.verify-no-sleep' = '上次写入 {apply}；写入后最近一次合盖时刻 {when}（事件口径），那一次没有跟着合盖待机 —— 只证明那一次，不是永久保证'
        'report.lidnow.verify-slept'    = '上次写入 {apply}；写入后 {when} 仍发生过合盖待机（事件口径）—— 平台没有遵守写入，或动作本身就是睡眠'
        'report.lidnow.verify-unknown'  = '事件日志读取失败，实测状态未知'
        'lid.elev.no'                   = '需要管理员权限，但未授权提升（-NoElevate 或非交互会话）。请以管理员身份重新运行：ka.ps1 lid -LidAction {action}'
        'lid.elev.fail'                 = '无法提权：{msg}。若本账户不是管理员，请让管理员执行一次：powercfg /setacvalueindex SCHEME_CURRENT {sub} {set} 0'
        'lid.relaunch'                  = '已在新的管理员窗口中继续，请在该窗口完成操作。'
        'lid.out.scheme'                = '合盖动作（当前方案 {scheme}）: 交流={ac} 电池={dc}'
        'lid.out.backup'                = '备份文件 : {path}'
        'lid.out.none'                  = '无'
        'lid.out.result'                = '结果 : {reason}'
        'lid.out.verified'              = '已确认生效。'
        'lid.status.hidden'             = '该方案下合盖动作被隐藏或不可读（现代待机 OEM 镜像的常见状态）。运行 apply 会先取消隐藏再设置。'
        'lid.status.notzero'            = '合盖仍会触发睡眠/休眠：任何防休眠软件都拦不住合盖动作，需要 apply。'
        'lid.status.ok'                 = '合盖已经是不采取任何操作。'
        'lid.status.nolid'              = '内核能力位显示本机没有盖开关（台式机或虚拟机）：上面的合盖值因此不适用，除非这台机器实际带盖。'
        'lid.apply.nolid'               = '内核能力位显示本机没有盖开关（台式机或虚拟机），合盖动作不适用，未做任何修改。确实要强行写入请运行：ka.bat lid apply -Force'
        'lid.apply.writefail'           = 'powercfg 写入失败：{msg}'
        'lid.apply.ok'                  = '合盖动作已设为「不采取任何操作」，写后重新读取确认。这只证明设置值写进去了，不证明内核会照做 —— 部分现代待机固件接受写入却仍然进待机。'
        'lid.apply.verify'              = '要确认它真的管用：合上盖子等 10 秒再打开，然后运行 ka.bat evidence —— 这段时间出现待机事件就说明平台没采纳（保持开盖是唯一可靠做法）。'
        'lid.apply.heat'                = '设成不操作后，合盖不再让机器休眠，它照常发热：不要把合着盖的电脑塞进包里或放在被子上。'
        'lid.apply.unreadable'          = '取消隐藏后仍读不到该设置：这台机器的固件可能不提供合盖动作控制。请保持开盖，或改用电源按钮设置。'
        'lid.apply.ignored'             = '写入后读回为 交流={ac} 电池={dc}：平台接受了写入但没有采纳。'
        'lid.restore.nobackup'          = '没有备份文件（{path}），无法还原：本工具从未改过这台机器的合盖动作。'
        'lid.restore.scheme'            = '备份来自方案「{old}」（{oldguid}），当前方案是「{new}」（{newguid}）。先切回原方案再还原，否则会把值写到另一个方案上。'
        'lid.restore.ok'                = '已还原到修改前的值，备份文件已删除。'
        'lid.restore.okkeep'            = '已还原到修改前的值（备份文件未能删除：{msg}）'
        'lid.restore.mismatch'          = '写入后读回不一致（期望 交流={expac} 电池={expdc}，实际 交流={ac} 电池={dc}）：请手动在电源选项里核对。'
        'lid.pause'                     = '按回车关闭'
        'st.head'                       = '防休眠 Keep-Awake'
        'st.label.state'                = '状态'
        'st.label.mode'                 = '模式'
        'st.label.up'                   = '已运行'
        'st.label.left'                 = '剩余'
        'st.label.pulse'                = '心跳'
        'st.label.lockSkip'             = '锁屏跳过'
        'st.label.ilSkip'               = 'UIPI 跳过'
        'st.label.error'                = '错误'
        'st.label.note'                 = '说明'
        'st.label.evidence'             = '有效性'
        'st.label.intent'               = '意图'
        'st.label.last'                 = '上次'
        'st.label.idle'                 = '当前空闲'
        'st.label.power'                = '电源'
        'st.label.session'              = '会话'
        'st.label.guard'                = '看门狗'
        'st.label.competitors'          = '同类软件'
        'st.label.orphans'              = '异常'
        'st.label.alert'                = '提醒'
        'st.running'                    = '运行中  pid={pid}  flags=0x{flags}'
        'st.mode.display'               = '屏幕常亮'
        'st.mode.displayDown'           = '屏幕常亮（已因电池策略降级）'
        'st.mode.systemOnly'            = '仅禁止系统休眠'
        'st.mode.antilock'              = '防锁屏心跳 {method}@{interval}s'
        'st.left.minutes'               = '{n} 分钟（到期自动释放）'
        'st.left.manual'                = '直到手动停止'
        'st.pulse.sent'                 = '已发 {n} 次，上次 {last}  结果={result}'
        'st.pulse.pending'              = '尚未发送，首次将在约 {next}s 后（间隔 {interval}s）'
        'st.lockSkips'                  = '{n} 次（安全桌面下输入无法到达会话）'
        'st.lockSkipsAt'                = '{n} 次（安全桌面下输入无法到达会话，最后 {last}）'
        'st.ilSkips'                    = '{n} 次（前台为更高完整性进程，UIPI 会丢弃注入输入）'
        'st.evidence.ok'                = '本次运行期间内核电源日志没有待机记录 —— 保护确实生效'
        'st.label.reason'               = '待机原因'
        # Names follow Microsoft's POWER_MONITOR_REQUEST_REASON enum, and stay
        # direction-neutral: the same token labels a sleep cause on 506 and a wake source
        # on 507, and whichever line shows it already says which.
        # 'unknown' is the enum's own 0 - the kernel answered "no reason". 'no-reason' means
        # the record had no readable Reason field at all: a different schema question, and
        # lumping them would hide whether the field exists on this build.
        'st.reason.unknown'             = '内核未给出原因'
        'st.reason.no-reason'           = '事件未附带原因字段'
        'st.reason.remote-connection'   = '远程连接'
        'st.reason.sc-monitorpower'     = '应用请求熄屏（SC_MONITORPOWER）'
        'st.reason.sets'                = '电源请求变更（SETS）'
        'st.reason.screen-off-request'  = '屏幕熄灭请求（微软只给了名字，未文档化来源）'
        'st.reason.video-idle'          = '屏幕空闲超时'
        'st.reason.lid'                 = '合盖'
        'st.reason.sx-transition'       = '休眠/关机转换'
        'st.reason.system-idle'         = '系统空闲超时'
        'st.reason.input-keyboard'      = '键盘输入'
        'st.reason.input-mouse'         = '鼠标输入'
        'st.reason.input-touchpad'      = '触摸板输入'
        'st.evidence.screenOnly'        = '本次运行期间内核记录 {n} 次熄屏，没有一次真睡眠 —— 屏幕灭了，机器没走'
        'st.evidence.bad'               = '本窗口内真睡眠 {n} 次，且当时电源请求正被持有 —— 平台在这些时刻绕过了它'
        'st.evidence.unprotected'       = '本窗口内真睡眠 {n} 次，都不在保护区间内（那些时刻没有任何请求，谈不上被绕过）'
        'st.evidence.spanUnknown'       = '另有 {n} 次真睡眠无法判定（ka.log 保留的历史没这么长，保护区间未知）'
        # An absent record is only evidence of absence where a record would have been left.
        # On a machine whose sleep states produce nothing this tool reads, "no standby logged"
        # has to be reported as unproven, never as the green ok line above.
        'st.evidence.blind'             = '无法证实：本机声明的睡眠态里至少有一种不会留下本工具读得到的记录 —— 「没有记录」不等于「没有睡」，见下方读数源'
        # Kernel-Power 42 logs a transition into a sleep state; it does not testify to how long
        # the machine stayed there or that the display was not what the user turned off. Naming
        # the record and its split is as much as the kernel supports.
        'st.evidence.s3'                = '睡眠进入记录（Kernel-Power 42）：本窗口 {n} 次 —— 请求正被持有 {bypass} 次、当时无请求 {out} 次、无法判定 {unknown} 次'
        'st.label.instrument'           = '读数源'
        'ev.label.s3Enters'             = '进入睡眠的转换记录（Kernel-Power 42）'
        'ev.label.s3Exits'              = '退出睡眠的恢复报告（本机声明 S3）'
        'ev.label.s3Bypasses'           = '其中请求正被持有（被绕过）'
        'ev.label.s3Unprotected'        = '其中当时无请求（不算被绕过）'
        'ev.label.s3SpanUnknown'        = '其中无法判定是否保护区间内'
        'ev.instrument.full'            = '566 会话事件：能区分熄屏与真睡'
        'ev.instrument.both'            = '566 会话事件 + Kernel-Power 42（混合机型，两套计数各算各的）'
        'ev.instrument.s3-only'         = '仅 Kernel-Power 42：本机不产生 566 会话事件'
        'ev.instrument.no-session-events'= '无 566 会话事件，本机也未声明需要它的睡眠态'
        'ev.instrument.blind'           = '盲区：本机声明的睡眠态至少有一种留不下本工具可读的记录'
        'st.foreign'                    = '本目录未运行，但另有 worker 在保着电脑不睡 —— 见下方「异常」'
        'st.notRunning'                 = '未运行 —— 电脑将按系统电源计划休眠/熄屏'
        'st.unrecorded'                 = '保护中但未记录（pid {pid}）—— 电源请求仍然有效，只是状态写不下来 —— 见下方提醒'
        'st.intentAwake'                = 'intent.json 要求保护，但 worker 不在：运行 ka.ps1 start，或等看门狗下次自检拉起'
        'st.expired'                    = '定时保护已到期并自行释放（不是故障）'
        'st.power.ac'                   = '交流电，电池 {pct}'
        'st.power.battery'              = '电池 {pct}{suffix}'
        'st.power.crit'                 = '，临界！'
        'st.power.low'                  = '，偏低'
        'st.power.unknown'              = '电源状态不可读（原生调用失败），无法判断本机有无电池'
        'st.power.none'                 = '本机无电池（台式机或虚拟机）—— 电池下限与低电降档均不适用'
        'st.power.noneOdd'              = '本机无电池（台式机或虚拟机），但交流电状态读作断开：这类读数常见于虚拟机，电源相关建议仅供参考'
        'st.session.active'             = '本会话正占用控制台'
        'st.session.other'              = '控制台被其它会话占用（快速用户切换/RDP），合成按键可能到不了锁屏界面'
        'st.session.none'               = '当前没有会话占用控制台'
        'st.session.unreadable'         = '无法读取会话状态（原生调用失败）'
        'st.session.unknown'            = '未知'
        'st.session.lock'               = '；锁屏界面正在显示'
        'st.guard.installed'            = '已安装（{detail}）'
        'st.guard.disabled'             = '计划任务已安装但处于禁用（{names}）—— 它不会被触发，重启或进程被强杀后没有东西会把保护拉回来'
        'st.guard.missing'              = '未安装：重启或进程被强杀后不会自动恢复'
        'st.competitors'                = '检测到 {list} —— 停止本工具后电脑可能仍不休眠，那是它们的效果'
        'st.orphans'                    = '发现 {n} 个 worker，运行 ka.ps1 start 会自动收敛为 1 个'
        'ev.head'                       = '最近 {n} 小时的电源事件（内核电源日志）'
        'ev.label.fail'                 = '查询失败'
        'ev.label.enters'               = '低功耗会话事件（506，含单纯熄屏）'
        'ev.label.realSleeps'           = '其中真睡眠（会话切到 sleep）'
        'ev.label.offToSleep'           = '熄屏后 2 分钟内入睡'
        'ev.offToSleep.detail'          = '（最近一次熄屏后 {n}s）'
        'ev.label.exits'                = '唤醒/恢复'
        'ev.truncated'                  = '事件已达 {n} 条上限，更早的没算进来'
        'ev.label.bypasses'             = '保护区间内的真睡眠（请求当时正被持有 → 被绕过）'
        'ev.label.unprotected'          = '保护区间外的真睡眠（当时没有请求，不算被绕过）'
        'ev.label.spanUnknown'          = '无法判定是否保护区间内'
        'ev.label.spans'                = '按 ka.log 重建出的保护区间'
        'ev.spans.partial'              = 'ka.log 只保留到 {time}，更早的区间无从判断'
        'ev.spans.unknown'              = '无从判断（ka.log 为空或不可读，看不出那些时刻有没有请求）'
        'ev.none'                       = '    （这段时间没有任何待机/唤醒事件）'
        'cli.pairFormat'                = '配置格式应为 key=value，收到：{pair}'
        'cli.bothMins'                  = '-Minutes 与 -ExpireAt 只能给一个：一个说"跑多久"，一个说"几点到"。'
        'cli.expireAt'                  = "-ExpireAt '{text}'：{reason}"
        'cli.willRelease'               = '将于 {at} 释放电源请求（约 {mins} 分钟）'
        'cli.startFail'                 = '启动失败：{reason}'
        'cli.startFailHint'             = '查看 ka.log 与 ka.ps1 report 获取更多线索。'
        'cli.alreadyRunning'            = '保护已在运行（pid {pid}），参数未变化，无需重启。'
        'cli.restarted'                 = '参数已变化，worker 已重启为新配置（pid {pid}）。'
        'cli.started'                   = '保护已启动（pid {pid}）。'
        'cli.startedUnrecorded'         = '保护已启动（pid {pid}），但状态写不下来：{path}'
        'cli.startedUnrecordedHint'     = '  写入错误 {detail} —— 电脑不会休眠，但面板与 status 会把它显示成没在跑，看门狗也无法对账。把数据目录改成可写（默认 %LOCALAPPDATA%\KeepAwake，可用 KA_DATA 指到别处）后重新 start。'
        'cli.stopNone'                  = '当前没有运行中的 worker。'
        'cli.stopped'                   = '已停止 {n} 个 worker。'
        'cli.stoppedForced'             = ' 其中 {n} 个未响应协作退出、被强制结束（其 finally 未执行，请确认 ka.log 有 STOPPED）。'
        'cli.stopUncooperative'         = '  协作退出不可用（{detail}）：stop.flag 写不下，只能直接结束进程，其 finally 未执行。'
        'cli.intentUnwritable'          = '  intent 未能写入 {path}：看门狗不记得这次改动，重启后也不会恢复。'
        'cli.intentOff'                 = 'intent 已置为 off：看门狗不会再把保护拉起来。'
        'cli.machineWritten'            = '  machine.json 已写入：{path}'
        'cli.intervalHint'              = '  当前心跳 {cur}s 大于建议 {rec}s：ka.ps1 config -Set antiLockIntervalSec={rec}'
        'cli.configWriteFail'           = '配置写入失败'
        'cli.saved'                     = '已保存。'
        'cli.configHead'                = '生效配置（config.json + 校验/夹取）'
        'cli.configHint'                = '  改动只有在下次 start 时生效；若已有 worker 在跑，参数不同会自动重启它。'
        'cli.guardInstalled'            = '看门狗已安装：开机登录自动启动保护（按 intent），每 10 分钟自检并拉起。'
        'cli.guardBootS4u'              = '开机任务 KeepAwake-Boot 已注册（S4U）：通电即保护，无需登录；登录前心跳不可用，只有"不睡眠"生效，登录后看门狗会把 worker 迁回桌面会话。'
        'cli.guardBootInteractive'      = '开机任务 KeepAwake-Boot 已注册（交互式）：要等有人登录后才会真正开始保护——标准账户注册不了 S4U（实测 Access is denied）。'
        'cli.guardBootDenied'           = '开机任务注册被拒绝（{reason}）。标准账户无权注册开机触发器；无人值守恢复请依赖 BIOS 断电自启 + 自动登录，KeepAwake-Logon 会在登录时接管。'
        'cli.guardTaskRow'              = 'state={state} 上次={last} 结果={result} 下次={next}'
        'cli.guardFail'                 = '安装失败：{reason}'
        'cli.guardFailHint'             = '常见原因：注册计划任务需要当前用户对 Task Scheduler 的写权限。'
        'cli.unguarded'                 = '已移除：{list}'
        'cli.unguardFail'               = '移除失败：{reason}'
        'cli.noLogYet'                  = '还没有日志：{path}'
        'cli.serveFail'                 = '无法启动本地面板：{reason}'
        'cli.panelUrl'                  = '面板地址：{url}'
        'cli.panelOpening'              = '首次启动，正在打开浏览器…'
        'cli.panelManual'               = '请手动打开：{url}'
        'cli.panelStopped'              = '面板已关闭（{n} 个进程）。'
        'cli.panelNotRunning'           = '面板没有在运行。'
        'cli.missingTray'               = '缺少 ka-tray.ps1'
        'cli.trayStarted'               = '托盘图标已启动（系统托盘区）。'
        'cli.requestsHead'              = '当前电源请求（powercfg /requests，需管理员）'
        'cli.requestsFail'              = '  读取失败：{msg}'
        'cli.requestsHint'              = '  请以管理员身份运行，或改用 ka.ps1 status 的同类软件检测。'
        'cli.overridesHead'             = '电源请求替代（powercfg /requestsoverride；命中本工具 = 请求被静默忽略）'
        'cli.overridesNone'             = '  （无条目 —— 本工具的电源请求不会被替代规则拦截）'
        'cli.overridesSelf'             = '  危险：上面有命中本工具镜像（{names}）的条目 —— 本工具的请求会被内核静默吞掉；清除需要管理员权限。'
        'cli.missingLid'                = '缺少 ka-lid.ps1（合盖动作工具）'
        'tray.mi.headerLoading'         = '读取中…'
        'tray.mi.start'                 = '启动保护（用当前设置）'
        'tray.mi.stop'                  = '停止保护'
        'tray.mi.duration'              = '按时长启动'
        'tray.mi.display'               = '屏幕常亮'
        'tray.mi.antilock'              = '防锁屏心跳'
        'tray.mi.method'                = '心跳方式'
        'tray.mi.methodNow'             = '心跳方式（{method}）'
        'tray.mi.key'                   = '按键 F15'
        'tray.mi.mouse'                 = '移动鼠标'
        'tray.mi.interval'              = '心跳间隔'
        'tray.mi.intervalNow'           = '心跳间隔（当前 {n}s）'
        'tray.mi.open'                  = '打开控制面板'
        'tray.mi.guard'                 = '开机看门狗（登录自启 + 每 10 分钟自检）'
        'tray.mi.stopServer'            = '关闭面板进程'
        'tray.mi.quit'                  = '退出托盘（不影响已运行的保护）'
        'tray.dur.unlimited'            = '不限时长'
        'tray.rem.expiring'             = '即将到期'
        'tray.rem.h'                    = '剩余 {h} 小时 {m} 分'
        'tray.rem.m'                    = '剩余 {m} 分'
        'tray.bal.started'              = '保护已启动'
        'tray.bal.endsIn'               = '{n} 分钟后自动结束'
        'tray.bal.startFail'            = '启动失败'
        'tray.bal.stopped'              = '已停止'
        'tray.bal.stoppedBody'          = '结束了 {n} 个 worker{extra}，电源请求已释放。'
        'tray.bal.forcedExtra'          = '（{n} 个未响应协作退出，其收尾未执行）'
        'tray.bal.stopFail'             = '停止失败'
        'tray.bal.savedNotApplied'      = '设置已保存，但未能应用到运行中的 worker'
        'tray.bal.applyFail'            = '设置失败'
        'tray.bal.openFail'             = '打开面板失败'
        'tray.bal.guardOff'             = '看门狗已卸载'
        'tray.bal.uninstallFail'        = '卸载失败'
        'tray.bal.guardOffBody'         = '重启或进程被强杀后不会再自动恢复保护。'
        'tray.bal.guardOn'              = '看门狗已安装'
        'tray.bal.installFail'          = '安装失败'
        'tray.bal.guardOnBody'          = '登录自动启动，每 10 分钟按 intent.json 自检。'
        'tray.bal.guardFail'            = '看门狗操作失败'
        'tray.bal.panel'                = '面板'
        'tray.bal.panelClosed'          = '已关闭 {n} 个面板进程。'
        'tray.bal.panelNone'            = '没有正在运行的面板进程。'
        'tray.state.stale'              = 'worker 已停止上报（看门狗会接管）'
        'tray.state.display'            = '保护中 · 屏幕常亮'
        'tray.state.degraded'           = '保护中 · 电池降级，已允许熄屏'
        'tray.state.systemOnly'         = '保护中 · 仅禁止系统休眠'
        'tray.state.unrecorded'         = '保护中但未记录（{path} 写不下）· 电源请求仍然有效，心跳读数缺失'
        'tray.state.unrecordedShort'    = '保护中但未记录 · 电源请求仍有效'
        'tray.state.wantOn'             = '未运行 —— intent 要求保护，等看门狗拉起'
        'tray.state.expired'            = '定时保护已到期并自行释放（不是故障）'
        'tray.state.off'                = '未运行 —— 电脑按系统电源计划行动'
        'tray.state.pulse'              = '心跳 {method}@{interval}s · 已发 {n} 次'
        'tray.state.hint'               = '右键菜单可启动保护'
        'tray.state.readFail'           = '状态读取失败：{msg}'
        'tray.state.readFailShort'      = '状态读取失败'
        'tray.selftest.fail'            = '托盘自检：菜单或图标未正确构建'
        'report.lock.hidden'            = '不可读（平台隐藏该设置）'
        'report.lock.will'              = '会锁屏（值 {v}）'
        'report.lock.wont'              = '不会锁屏（值 {v}）'
        'report.policy.has'             = '{min} 分钟无人操作（组策略）'
        'report.policy.none'            = '未发现组策略锁屏'
        'report.ss.vals'                = '{exe} / {timeout} / {secure}'
        'report.ss.secure'              = '唤醒需密码'
        'report.ss.open'                = '不锁屏'
        'report.ss.none'                = '无'
        'report.idle.vals'              = '{dur}（自上次真实键鼠输入）'
        'report.eng1.vals'              = '需压制的待机/熄屏计时 = {dur}（由 SetThreadExecutionState 承担，与心跳无关）'
        'report.eng1.never'             = '本机计划本就是从不（无需压制任何计时）'
        'report.reco.vals'              = '{sec} 秒（{why}）'
        'report.config.vals'            = 'antiLockIntervalSec={interval}  keepDisplayOn={display}  antiLock={antiLock}/{method}  awayMode={away}  batteryFloor={floor}%'
        'report.note.noLockTimer'       = '注: 未发现任何空闲锁屏计时器（组策略与需密码的屏保都没有）——动态锁 (Dynamic Lock) 无法从本机读取，若仍被锁屏请调小心跳间隔。'
        'report.riskHead'               = '风险提示:'
        'alert.foreignWorkers'          = '另有 {count} 个 worker 属于别的目录（{roots}），本工具无法停止它 —— 关掉这里后电脑仍不会休眠'
        'alert.batteryFloor'            = '电池 {pct}% 且未插电，显示保护已按策略降级'
        'alert.sleepEvidence'           = '保护运行期间有 {n} 次真睡眠发生在电源请求正被持有时 —— 平台在这些时刻绕过了它'
        'alert.evidenceBlind'           = '本机声明的睡眠态里至少有一种不会留下本工具读得到的记录 —— 界面上的绿色只代表「没有记录」，不代表「没有睡」；本机能读到什么写在证据区'
        'alert.standbyLid'              = '本窗口内有 {count} 次低功耗会话由合盖触发 —— 合盖会绕过电源请求直接进待机，唤醒后 Windows 默认要求登录；需要远程访问请保持开盖（但开盖只是必要不充分：本机大多数待机是盖子开着时的空闲超时，那一半才是本工具管得住的），或运行 ka.bat lid apply 把合盖动作改成「不进行操作」（改完请真的合一次盖验证：部分平台接受写入却仍然进待机）'
        'alert.sessionLocked'           = '会话当前处于锁屏/安全桌面：电源请求仍然有效、电脑不会休眠，但远程接入只会看到锁屏（心跳已跳过 {count} 次）'
        'alert.uipiBlocked'             = '心跳输入正被 UIPI 丢弃：前台是更高完整性（管理员）的程序，空闲锁屏计时压不住（电源请求仍有效，电脑不会休眠）。要么关掉那个管理员程序，要么以管理员身份重新运行本工具 —— 已跳过 {count} 次，前台解除后下一次心跳自动恢复'
        'alert.multiWorker'             = '检测到 {count} 个 worker 进程，正常应为 1 个'
        'alert.staleState'              = 'worker 已停止上报状态，保护可能已经失效'
        'alert.guardDisabled'           = '看门狗计划任务处于禁用（{names}）：它不会被触发，重启或 worker 被强杀之后没有东西会把保护拉回来。运行 ka.bat guard 重新安装即可恢复'
        'alert.dataDirUnwritable'       = '数据目录 {path} 不可写（{error}）：状态、意图与停止信号都落不了地，面板会把正在运行的保护显示成没在跑'
        'alert.machineDirUnwritable'    = '机器数据目录 {path} 不可写（{error}）：合盖备份与机器级状态无法保存'
        'alert.stateUnrecorded'         = '{count} 个 worker 正在运行，但读不到 {path} —— 电源请求仍然有效，只是没有记录（保护是真的，只是看不见）'
        'competitor.powerToys'          = 'PowerToys (可能包含 Awake 模块)'
        'competitor.presentation'       = 'Windows 演示模式 (presentationsettings)'
        'competitor.confirm'            = 'powercfg /requests（需以管理员身份运行）'
    }
    en = @{
        'worker.note.lock-screen'   = 'Session is locked or on the secure desktop: the heartbeat cannot reach it (the power request still holds)'
        'worker.note.il-mismatch'   = 'Foreground window is a higher-integrity (elevated) process: UIPI silently drops the heartbeat input, so it is skipped (the power request still holds)'
        'worker.note.battery-floor' = 'Battery {pct}% is under the {floor}% floor: sleep is still blocked, but the display may blank to protect runtime and the lock screen'
        'worker.error.settes-zero'  = 'SetThreadExecutionState returned 0 ({why}): Windows refused the power request'
        'worker.error.settes-throw' = 'SetThreadExecutionState threw ({why})'
        'guard.path.current'        = 'The scheduled task points at this folder'
        'guard.path.moved'          = 'The scheduled task points elsewhere (the folder was moved) - uninstall and reinstall it'
        'guard.infoFail'            = 'Run history unreadable'
        'guard.defFail'             = 'Could not read the task definition: {msg}'
        'guard.never'               = 'never'
        'guard.noNext'              = 'none scheduled'
        'guard.nextDisabled'        = 'will not fire while disabled'
        'guard.line'                = 'Watchdog: {action} (intent={intent} worker={workers} alive={alive})'
        'config.enum'               = 'Config key {key} accepts only {allowed}, got {received}'
        'config.empty'              = 'Nothing to change - no config key was sent'
        'config.writeFail'          = 'the config could not be written to {path} ({error}): the change was not saved'
        'api.unknown'               = 'Unknown endpoint'
        'api.method'                = 'Method not allowed'
        'api.noFile'                = 'No such file'
        'api.dashMissing'           = 'A dashboard file is missing - check that the dashboard folder is complete'
        'api.internal'              = 'Internal server error'
        'api.host'                  = 'The Host header is not a loopback address: {host}'
        'api.origin'                = 'The Origin header is not this machine: {origin}'
        'api.client'                = 'Missing the X-Ka-Client header (a cross-site page cannot send one - that is the point)'
        'api.serialize'             = 'Could not serialize the response'
        'api.badJson'               = 'Request body is not valid JSON: {msg}'
        'time.empty'                = 'No time was given'
        'time.unparsed'             = 'Unrecognised time. Accepted: HH:mm, HH:mm:ss, yyyy-MM-dd HH:mm, yyyy-MM-dd'
        'time.past'                 = '{at} is not in the future, which is the same as no expiry at all - give a future moment'
        'proc.noScript'             = 'Cannot find {file}: {path}'
        'proc.noStart'              = 'Could not start the process: {msg}'
        'proc.noLine'               = 'the child process never reported'
        'proc.noReport'             = 'The worker never reported in ({why})'
        'proc.earlyExit'            = 'The worker reported once and then exited: {why}'
        'proc.earlyExitNoLine'      = 'The worker exited within a few seconds and the log carries no reason for it'
        'server.noStart'            = 'Could not start the panel process: {msg}'
        'server.noPing'             = 'The panel process did not answer /api/ping within {sec} s'
        'server.lastLog'            = 'Panel log from this attempt: {line}'
        'server.bodyTooBig'         = 'Request body too large ({size} bytes)'
        'server.console.cantListen' = 'Cannot listen on 127.0.0.1:{port}.'
        'server.console.portBusy'   = 'The port may be taken (change port in config.json), or a previous panel process has not exited yet.'
        'server.console.ready'      = 'Keep-awake panel is ready: http://127.0.0.1:{port}/   (Ctrl+C to quit; protection itself keeps running)'
        'server.console.exited'     = 'Panel exited.'
        'fmt.seconds'               = '{n} s'
        'fmt.minutes'               = '{n} min'
        'fmt.hours'                 = '{n} h'
        'fmt.never'                 = 'Never'
        'fmt.unknown'               = 'Unknown'
        'task.neverRun'             = 'Never ran'
        'task.unparsable'           = 'Result {v}'
        'task.ok'                   = '0x0 · success'
        'task.nonzero'              = '0x{hex} · non-zero exit'
        'report.why.no-lock-timer'      = 'No idle lock timer found, so the 240 s default is used'
        'report.why.half-of-lock-timer' = 'Half of the shortest lock timer ({secs} s), capped at 240 s'
        'report.risk.modern-standby'    = 'This machine uses S0 Modern Standby: SetThreadExecutionState suppresses idle standby, but closing the lid, a flat battery or a platform policy can still force it.'
        'report.risk.lid-hidden'        = 'The lid-close action is hidden or unreadable here: only a real test shows what the lid does, so leave the lid open or attach an external display for unattended runs.'
        'report.risk.lid-action'        = 'The lid-close action is currently {value} (not 0 = do nothing): closing the lid sleeps the machine and no keep-awake software can prevent that.'
        'report.risk.hybrid-sleep'      = 'Fast Startup / hybrid sleep is on: shutdown is not a full power-off, so resume behaviour can look odd.'
        'report.risk.lock-policy'       = 'An inactivity lock policy exists ({minutes} min): usually pushed by a domain policy, and a heartbeat can only delay it, not beat it forever.'
        'report.risk.battery'           = 'Running on battery ({pct}%): display protection steps down automatically once the {floor}% floor is reached.'
        'report.risk.override-self'     = 'A requestsoverride entry names this product''s image ({names}): the kernel silently ignores every power request the tool makes - protection is gone without any error. Removing or reconfiguring the entry needs elevation.'
        'report.head'                   = 'Environment compatibility report'
        'report.label.os'               = 'OS'
        'report.label.ps'               = 'PowerShell'
        'report.label.power'            = 'Power'
        'report.label.machine'          = 'Machine'
        'report.label.sleep'            = 'Sleep states'
        'report.label.planSleep'        = 'Plan sleep'
        'report.label.planVideo'        = 'Plan display-off'
        'report.label.unattended'       = 'Unattended'
        'report.label.lid'              = 'Lid action'
        'report.label.lockReq'          = 'Wake unlocks'
        'report.label.policy'           = 'Lock policy'
        'report.label.ss'               = 'Screensaver'
        'report.label.idle'             = 'Idle now'
        'report.label.eng1'             = 'Engine 1 target'
        'report.label.reco'             = 'Heartbeat'
        'report.label.config'           = 'Config now'
        'report.machine.laptop'         = 'Laptop (has a battery)'
        'report.machine.desktop'        = 'Desktop (no battery)'
        'report.machine.unknown'        = 'Cannot tell (power status unreadable)'
        'report.power.ac'               = 'AC (battery {pct})'
        'report.power.battery'          = 'Battery {pct}{saver}'
        'report.power.saver'            = ', battery saver'
        'report.power.none'             = 'Not applicable (this machine has no battery)'
        'report.sleepRow'               = 'S0 Modern Standby={ms}  S3 legacy={s3}  Hibernate={hib}'
        'report.acdc'                   = 'AC {ac} / DC {dc}'
        'report.unattended'             = '{sec} (extra standby delay after an unattended wake)'
        'report.lid.hidden'             = 'hidden / unreadable'
        'report.lid.vals'               = 'AC {ac} / DC {dc} (0 = take no action)'
        'report.lid.nolid'              = 'This machine has no lid switch (kernel capability bit) - the lid action does not apply'
        'report.lid.has'                = 'Kernel capability bit confirms this machine has a lid switch'
        'report.lid.unknown'            = 'Cannot tell whether this machine has a lid (the kernel capability bit could not be read): the lid action values above are listed as read, but nobody knows if there is a lid to close'
        'lid.action.0'                  = 'Take no action'
        'lid.action.1'                  = 'Sleep'
        'lid.action.2'                  = 'Hibernate'
        'lid.action.3'                  = 'Shut down'
        'lid.hidden'                    = 'hidden / unreadable'
        'lid.unknown'                   = 'unknown value {v}'
        'report.label.lidHas'           = 'Lid switch'
        'report.label.lidNow'           = 'Lid, right now'
        'report.label.lidVerify'        = 'Setting tested'
        'report.lidnow.hidden'          = 'LIDACTION unreadable (powercfg query failed) - what a lid close does is unknown'
        'report.lidnow.tier-ac'         = 'on AC now (battery {pct}), the AC tier applies'
        'report.lidnow.tier-dc'         = 'on battery now ({pct}), the battery tier applies'
        'report.lidnow.action'          = '{tier} - closing the lid runs: {action}'
        'report.lidnow.verify-none'     = 'No lid-apply write on record (never changed) - the values above are the machine''s factory setting'
        'report.lidnow.verify-unobserved' = 'Last write {apply}; no lid-closed moment since, inside the 14-day window, to inspect - a successful write is not a honored setting; close the lid once and check back here'
        'report.lidnow.verify-no-sleep' = 'Last write {apply}; the most recent lid-closed moment after it ({when}, event log) did not lead to a lid standby - that proves that one moment, not forever'
        'report.lidnow.verify-slept'    = 'Last write {apply}; a lid standby still happened at {when} after the write (event log) - the platform ignored it, or the configured action is sleep itself'
        'report.lidnow.verify-unknown'  = 'Event log unreadable; tested state unknown'
        'lid.elev.no'                   = 'Administrator rights are required, but elevation was not authorized (-NoElevate or a non-interactive session). Re-run as administrator: ka.ps1 lid -LidAction {action}'
        'lid.elev.fail'                 = 'Could not elevate: {msg}. If this account is not an administrator, have one run this once: powercfg /setacvalueindex SCHEME_CURRENT {sub} {set} 0'
        'lid.relaunch'                  = 'Continued in a new administrator window - finish the operation there.'
        'lid.out.scheme'                = 'Lid action (current plan {scheme}): AC={ac} battery={dc}'
        'lid.out.backup'                = 'Backup file: {path}'
        'lid.out.none'                  = 'none'
        'lid.out.result'                = 'Result: {reason}'
        'lid.out.verified'              = 'Verified by re-read.'
        'lid.status.hidden'             = 'The lid action is hidden or unreadable in this plan (common on Modern-Standby OEM images). Running apply will unhide it first, then set it.'
        'lid.status.notzero'            = 'Closing the lid still triggers sleep/hibernate: no keep-awake software can intercept the lid itself - apply is needed.'
        'lid.status.ok'                 = 'The lid already takes no action.'
        'lid.status.nolid'              = 'The kernel capability bit reports no lid switch on this machine (desktop or virtual machine): the lid values above do not apply unless it actually has one.'
        'lid.apply.nolid'               = 'The kernel capability bit reports no lid switch on this machine (desktop or virtual machine), so the lid action does not apply and nothing was changed. To write it anyway: ka.bat lid apply -Force'
        'lid.apply.writefail'           = 'powercfg write failed: {msg}'
        'lid.apply.ok'                  = 'The lid action is set to "take no action" and the re-read confirms the value. That only proves the write landed - it does not prove the kernel honours it: some Modern Standby firmware accepts the write and still enters standby.'
        'lid.apply.verify'              = 'To prove it works: close the lid for about 10 seconds, open it again, then run ka.bat evidence - a standby event inside that window means the platform ignored the setting (keeping the lid open is the only reliable answer).'
        'lid.apply.heat'                = 'With the lid set to do nothing the machine keeps producing heat while closed: never put it in a bag or leave it on a bed or blanket.'
        'lid.apply.unreadable'          = 'The setting is still unreadable after unhiding: this machine''s firmware may not expose the lid action. Keep the lid open, or use the power-button settings instead.'
        'lid.apply.ignored'             = 'After writing, read-back is AC={ac} battery={dc}: the platform accepted the write but did not adopt it.'
        'lid.restore.nobackup'          = 'No backup file ({path}) - cannot restore: this tool has never changed the lid action on this machine.'
        'lid.restore.scheme'            = 'The backup came from plan "{old}" ({oldguid}); the current plan is "{new}" ({newguid}). Switch back to the original plan before restoring, otherwise the values land in a different plan.'
        'lid.restore.ok'                = 'Restored to the pre-change values; the backup file was deleted.'
        'lid.restore.okkeep'            = 'Restored to the pre-change values (the backup file could not be deleted: {msg})'
        'lid.restore.mismatch'          = 'Read-back does not match what was written (expected AC={expac} battery={expdc}, got AC={ac} battery={dc}): please check the power options by hand.'
        'lid.pause'                     = 'Press Enter to close'
        'st.head'                       = 'Keep-Awake'
        'st.label.state'                = 'State'
        'st.label.mode'                 = 'Mode'
        'st.label.up'                   = 'Running for'
        'st.label.left'                 = 'Remaining'
        'st.label.pulse'                = 'Heartbeat'
        'st.label.lockSkip'             = 'Lock skips'
        'st.label.ilSkip'               = 'UIPI skips'
        'st.label.error'                = 'Error'
        'st.label.note'                 = 'Note'
        'st.label.evidence'             = 'Effective'
        'st.label.intent'               = 'Intent'
        'st.label.last'                 = 'Last'
        'st.label.idle'                 = 'Idle now'
        'st.label.power'                = 'Power'
        'st.label.session'              = 'Session'
        'st.label.guard'                = 'Watchdog'
        'st.label.competitors'          = 'Competing software'
        'st.label.orphans'              = 'Anomaly'
        'st.label.alert'                = 'Alert'
        'st.running'                    = 'running  pid={pid}  flags=0x{flags}'
        'st.mode.display'               = 'display held on'
        'st.mode.displayDown'           = 'display held on (stepped down per battery policy)'
        'st.mode.systemOnly'            = 'system sleep blocked only'
        'st.mode.antilock'              = 'anti-lock heartbeat {method}@{interval}s'
        'st.left.minutes'               = '{n} min (released automatically at expiry)'
        'st.left.manual'                = 'until stopped by hand'
        'st.pulse.sent'                 = '{n} sent, last {last}, result={result}'
        'st.pulse.pending'              = 'not yet sent; first in about {next}s (interval {interval}s)'
        'st.lockSkips'                  = '{n} time(s) (input cannot reach the session on the secure desktop)'
        'st.lockSkipsAt'                = '{n} time(s) (input cannot reach the session on the secure desktop, last {last})'
        'st.ilSkips'                    = '{n} time(s) (foreground runs at higher integrity; UIPI drops injected input)'
        'st.evidence.ok'                = 'no standby entries in the kernel power log for this run - the power request is really holding'
        'st.evidence.bad'               = '{n} real sleep(s) in this window with the power request held at that instant - the platform bypassed it there'
        'st.evidence.unprotected'       = '{n} real sleep(s) in this window, none inside a protected span (nothing was asking at those moments, so nothing was bypassed)'
        'st.evidence.spanUnknown'       = 'another {n} real sleep(s) cannot be placed (ka.log does not reach back that far, so the protected spans are unknown)'
        'st.evidence.blind'             = 'unproven: at least one sleep state this machine declares leaves no record this tool reads - "nothing logged" is not "it did not sleep", see the readout row below'
        'st.evidence.s3'                = 'sleep-entry records (Kernel-Power 42): {n} in this window - {bypass} with the power request held, {out} with none held, {unknown} not placeable'
        'st.label.instrument'           = 'Readout'
        'ev.label.s3Enters'             = 'Sleep-entry transitions (Kernel-Power 42)'
        'ev.label.s3Exits'              = 'Sleep-resume reports (this machine declares S3)'
        'ev.label.s3Bypasses'           = 'of those, request held at that instant (bypassed)'
        'ev.label.s3Unprotected'        = 'of those, no request held (not a bypass)'
        'ev.label.s3SpanUnknown'        = 'of those, not placeable in a protected span'
        'ev.instrument.full'            = '566 session events: tells a display-off from a real sleep'
        'ev.instrument.both'            = '566 session events + Kernel-Power 42 (hybrid machine, the two counters kept apart)'
        'ev.instrument.s3-only'         = 'Kernel-Power 42 only: this machine logs no 566 session events'
        'ev.instrument.no-session-events' = 'no 566 session events, and this machine declares no sleep state that would need them'
        'ev.instrument.blind'           = 'blind: at least one sleep state this machine declares leaves no record this tool reads'
        'st.label.reason'               = 'Standby reason'
        # Names follow Microsoft's POWER_MONITOR_REQUEST_REASON enum, and stay
        # direction-neutral: the same token labels a sleep cause on 506 and a wake source
        # on 507, and whichever line shows it already says which.
        'st.reason.unknown'             = 'kernel gave no reason'
        'st.reason.no-reason'           = 'record carried no reason field'
        'st.reason.remote-connection'   = 'remote connection'
        'st.reason.sc-monitorpower'     = 'app requested display off (SC_MONITORPOWER)'
        'st.reason.sets'                = 'power request change (SETS)'
        'st.reason.screen-off-request'  = 'screen off request (Microsoft documents the name, not the caller)'
        'st.reason.video-idle'          = 'display idle timeout'
        'st.reason.lid'                 = 'lid closed'
        'st.reason.sx-transition'       = 'hibernate/shutdown transition'
        'st.reason.system-idle'         = 'system idle timeout'
        'st.reason.input-keyboard'      = 'keyboard input'
        'st.reason.input-mouse'         = 'mouse input'
        'st.reason.input-touchpad'      = 'touchpad input'
        'st.evidence.screenOnly'        = 'the kernel logged {n} display-off(s) during this run and not one real sleep - the screen went dark, the machine stayed'
        'st.foreign'                    = 'not running from this folder, but a worker from another folder is holding the machine awake - see "Anomaly" below'
        'st.notRunning'                 = 'not running - the machine will sleep/blank per its power plan'
        'st.unrecorded'                 = 'protecting but unrecorded (pid {pid}) - the power request still holds, only the state record could not be written - see the notice below'
        'st.intentAwake'                = 'intent.json asks for protection but no worker is alive: run ka.ps1 start, or wait for the watchdog''s next self-check'
        'st.expired'                    = 'the timed protection ran out and released on its own (not a fault)'
        'st.power.ac'                   = 'AC, battery {pct}'
        'st.power.battery'              = 'battery {pct}{suffix}'
        'st.power.crit'                 = ', critical!'
        'st.power.low'                  = ', low'
        'st.power.unknown'              = 'power status unreadable (the native call failed) - cannot tell whether this machine has a battery'
        'st.power.none'                 = 'no battery (desktop or virtual machine) - the battery floor and the low-battery downgrade do not apply'
        'st.power.noneOdd'              = 'no battery (desktop or virtual machine) but the AC line reads disconnected: virtual machines report exactly this, so treat the power advice with care'
        'st.session.active'             = 'this session owns the console'
        'st.session.other'              = 'the console is owned by another session (fast user switching/RDP); synthetic input may not reach the lock screen'
        'st.session.none'               = 'no session owns the console right now'
        'st.session.unreadable'         = 'session state unreadable (native call failed)'
        'st.session.unknown'            = 'unknown'
        'st.session.lock'               = '; the lock screen is showing'
        'st.guard.installed'            = 'installed ({detail})'
        'st.guard.disabled'             = 'the scheduled tasks exist but are disabled ({names}) - nothing will trigger them, so nothing brings protection back after a reboot or a force-kill'
        'st.guard.missing'              = 'not installed: after a reboot or a killed process nothing restores protection automatically'
        'st.competitors'                = 'detected {list} - after stopping this tool the machine may stay awake anyway; that is theirs'
        'st.orphans'                    = '{n} worker processes found; ka.ps1 start converges them back to 1'
        'ev.head'                       = 'Power events of the last {n} h (kernel power log)'
        'ev.label.fail'                 = 'Query failed'
        'ev.label.enters'               = 'Low-power sessions (506, plain display-offs included)'
        'ev.label.realSleeps'           = 'of which real sleeps'
        'ev.label.offToSleep'           = 'Slept within 2 min of display off'
        'ev.offToSleep.detail'          = ' (last one {n}s after display off)'
        'ev.label.exits'                = 'Wake/resume'
        'ev.truncated'                  = 'Query hit the {n}-record cap; older events were left out'
        'ev.label.bypasses'             = 'Real sleeps inside a protected span (request held at that instant - bypassed)'
        'ev.label.unprotected'          = 'Real sleeps outside a protected span (nothing was asking; not a bypass)'
        'ev.label.spanUnknown'          = 'Real sleeps that cannot be placed'
        'ev.label.spans'                = 'Protected spans rebuilt from ka.log'
        'ev.spans.partial'              = 'ka.log only reaches back to {time}; spans before that cannot be known'
        'ev.spans.unknown'              = 'unknown (ka.log is empty or unreadable, so nothing was knowable about those moments)'
        'ev.none'                       = '    (no standby/wake events in this period)'
        'cli.pairFormat'                = 'config pairs are key=value, got: {pair}'
        'cli.bothMins'                  = 'Give -Minutes or -ExpireAt, not both: one says "how long", the other "until when".'
        'cli.expireAt'                  = "-ExpireAt '{text}': {reason}"
        'cli.willRelease'               = 'will release the power request at {at} (about {mins} min)'
        'cli.startFail'                 = 'start failed: {reason}'
        'cli.startFailHint'             = 'See ka.log and ka.ps1 report for more clues.'
        'cli.alreadyRunning'            = 'protection already running (pid {pid}); parameters unchanged, no restart needed.'
        'cli.restarted'                 = 'parameters changed; the worker restarted with the new ones (pid {pid}).'
        'cli.started'                   = 'protection started (pid {pid}).'
        'cli.startedUnrecorded'         = 'protection started (pid {pid}), but its state record could not be written: {path}'
        'cli.startedUnrecordedHint'     = '  write error {detail} - the machine will not sleep, yet the panel and status will show it as not running and the watchdog cannot reconcile it. Make the data directory writable (default %LOCALAPPDATA%\KeepAwake, or point KA_DATA somewhere else) and start again.'
        'cli.stopNone'                  = 'no worker is running.'
        'cli.stopped'                   = '{n} worker(s) stopped.'
        'cli.stoppedForced'             = ' {n} of them ignored the cooperative exit and were force-killed (their finally did not run; check ka.log for STOPPED).'
        'cli.stopUncooperative'         = '  the cooperative exit was unavailable ({detail}): stop.flag could not be written, so the process was killed outright and its finally block never ran.'
        'cli.intentUnwritable'          = '  intent could not be written to {path}: the watchdog will not remember this change and will not restore protection after a reboot.'
        'cli.intentOff'                 = 'intent is now off: the watchdog will not raise protection again.'
        'cli.machineWritten'            = '  machine.json written: {path}'
        'cli.intervalHint'              = '  the heartbeat ({cur}s) is slower than recommended ({rec}s): ka.ps1 config -Set antiLockIntervalSec={rec}'
        'cli.configWriteFail'           = 'could not write the config'
        'cli.saved'                     = 'Saved.'
        'cli.configHead'                = 'Effective config (config.json + validation/clamping)'
        'cli.configHint'                = '  changes take effect on the next start; a running worker with different parameters restarts itself.'
        'cli.guardInstalled'            = 'Watchdog installed: protection auto-starts at logon (per intent) and self-checks every 10 minutes.'
        'cli.guardBootS4u'              = 'Boot task KeepAwake-Boot registered (S4U): protection starts at power-on, no logon needed. The heartbeat cannot work pre-logon - only the no-sleep request is active, and the watchdog adopts the worker into the desktop session once you log on.'
        'cli.guardBootInteractive'      = 'Boot task KeepAwake-Boot registered (interactive): protection only really starts once someone logs on - a standard account cannot register S4U (verified: Access is denied).'
        'cli.guardBootDenied'           = 'Boot task registration denied ({reason}). Standard accounts cannot register boot triggers; for unattended recovery rely on BIOS auto-power-on + auto-logon, and KeepAwake-Logon takes over at logon.'
        'cli.guardTaskRow'              = 'state={state} last={last} result={result} next={next}'
        'cli.guardFail'                 = 'install failed: {reason}'
        'cli.guardFailHint'             = 'Common cause: registering a scheduled task needs Task Scheduler write permission for the current user.'
        'cli.unguarded'                 = 'removed: {list}'
        'cli.unguardFail'               = 'remove failed: {reason}'
        'cli.noLogYet'                  = 'no log yet: {path}'
        'cli.serveFail'                 = 'could not start the local panel: {reason}'
        'cli.panelUrl'                  = 'Panel URL: {url}'
        'cli.panelOpening'              = 'first start - opening a browser…'
        'cli.panelManual'               = 'please open by hand: {url}'
        'cli.panelStopped'              = 'panel closed ({n} process(es)).'
        'cli.panelNotRunning'           = 'the panel is not running.'
        'cli.missingTray'               = 'ka-tray.ps1 is missing'
        'cli.trayStarted'               = 'tray icon started (system tray area).'
        'cli.requestsHead'              = 'Current power requests (powercfg /requests; needs admin)'
        'cli.requestsFail'              = '  read failed: {msg}'
        'cli.requestsHint'              = '  run as administrator, or use the competing-software check in ka.ps1 status.'
        'cli.overridesHead'             = 'Power request overrides (powercfg /requestsoverride; an entry naming this tool = requests silently ignored)'
        'cli.overridesNone'             = '  (none - no override rule can swallow this tool''s requests)'
        'cli.overridesSelf'             = '  DANGER: an entry above names this tool''s image ({names}) - the kernel silently drops its requests; clearing the entry needs elevation.'
        'cli.missingLid'                = 'ka-lid.ps1 (the lid-action tool) is missing'
        'tray.mi.headerLoading'         = 'Reading…'
        'tray.mi.start'                 = 'Start protection (current settings)'
        'tray.mi.stop'                  = 'Stop protection'
        'tray.mi.duration'              = 'Start for a duration'
        'tray.mi.display'               = 'Keep display on'
        'tray.mi.antilock'              = 'Anti-lock heartbeat'
        'tray.mi.method'                = 'Heartbeat method'
        'tray.mi.methodNow'             = 'Method ({method})'
        'tray.mi.key'                   = 'Key F15'
        'tray.mi.mouse'                 = 'Move the mouse'
        'tray.mi.interval'              = 'Heartbeat interval'
        'tray.mi.intervalNow'           = 'Interval (now {n}s)'
        'tray.mi.open'                  = 'Open the dashboard'
        'tray.mi.guard'                 = 'Boot watchdog (auto-start at logon + self-check every 10 min)'
        'tray.mi.stopServer'            = 'Stop the panel process'
        'tray.mi.quit'                  = 'Quit the tray (running protection is unaffected)'
        'tray.dur.unlimited'            = 'No limit'
        'tray.rem.expiring'             = 'expiring now'
        'tray.rem.h'                    = '{h} h {m} min left'
        'tray.rem.m'                    = '{m} min left'
        'tray.bal.started'              = 'Protection started'
        'tray.bal.endsIn'               = 'ends automatically in {n} min'
        'tray.bal.startFail'            = 'Start failed'
        'tray.bal.stopped'              = 'Stopped'
        'tray.bal.stoppedBody'          = '{n} worker(s) stopped{extra}; the power request is released.'
        'tray.bal.forcedExtra'          = ' ({n} ignored the cooperative exit; their cleanup did not run)'
        'tray.bal.stopFail'             = 'Stop failed'
        'tray.bal.savedNotApplied'      = 'Setting saved, but it could not be applied to the running worker'
        'tray.bal.applyFail'            = 'Setting failed'
        'tray.bal.openFail'             = 'Could not open the panel'
        'tray.bal.guardOff'             = 'Watchdog removed'
        'tray.bal.uninstallFail'        = 'Remove failed'
        'tray.bal.guardOffBody'         = 'Nothing will restore protection after a reboot or a killed process.'
        'tray.bal.guardOn'              = 'Watchdog installed'
        'tray.bal.installFail'          = 'Install failed'
        'tray.bal.guardOnBody'          = 'Auto-starts at logon and self-checks against intent.json every 10 minutes.'
        'tray.bal.guardFail'            = 'Watchdog operation failed'
        'tray.bal.panel'                = 'Panel'
        'tray.bal.panelClosed'          = '{n} panel process(es) closed.'
        'tray.bal.panelNone'            = 'No panel process is running.'
        'tray.state.stale'              = 'the worker stopped reporting (the watchdog takes over)'
        'tray.state.display'            = 'protecting · display held on'
        'tray.state.degraded'           = 'protecting · battery step-down, display may turn off'
        'tray.state.systemOnly'         = 'protecting · system sleep blocked only'
        'tray.state.unrecorded'         = 'protecting but unrecorded ({path} is unwritable) · the power request still holds, heartbeat readings are missing'
        'tray.state.unrecordedShort'    = 'protecting but unrecorded - request still held'
        'tray.state.wantOn'             = 'not running - intent asks for protection; waiting for the watchdog'
        'tray.state.expired'            = 'the timed protection ran out and released on its own (not a fault)'
        'tray.state.off'                = 'not running - the machine follows its power plan'
        'tray.state.pulse'              = 'heartbeat {method}@{interval}s · {n} sent'
        'tray.state.hint'               = 'right-click to start protection'
        'tray.state.readFail'           = 'state read failed: {msg}'
        'tray.state.readFailShort'      = 'state read failed'
        'tray.selftest.fail'            = 'tray self-test: menu or icon did not build correctly'
        'report.lock.hidden'            = 'unreadable (this platform hides the setting)'
        'report.lock.will'              = 'locks the session (value {v})'
        'report.lock.wont'              = 'does not lock (value {v})'
        'report.policy.has'             = 'locks after {min} min idle (group policy)'
        'report.policy.none'            = 'no group-policy lock found'
        'report.ss.vals'                = '{exe} / {timeout} / {secure}'
        'report.ss.secure'              = 'needs a password'
        'report.ss.open'                = 'does not lock'
        'report.ss.none'                = 'none'
        'report.idle.vals'              = '{dur} since the last real key or mouse input'
        'report.eng1.vals'              = 'standby / display timers to suppress = {dur} (carried by SetThreadExecutionState, unrelated to the heartbeat)'
        'report.eng1.never'             = 'the plan already says never (nothing to suppress)'
        'report.reco.vals'              = '{sec} s ({why})'
        'report.config.vals'            = 'antiLockIntervalSec={interval}  keepDisplayOn={display}  antiLock={antiLock}/{method}  awayMode={away}  batteryFloor={floor}%'
        'report.note.noLockTimer'       = 'Note: no idle lock timer was found (neither a group policy nor a password-protected screensaver) - Dynamic Lock cannot be read from this machine, so lower the heartbeat interval if the session still locks.'
        'report.riskHead'               = 'Risk notes:'
        'alert.foreignWorkers'          = '{count} worker(s) belong to another folder ({roots}); this tool cannot stop them - the machine stays awake after you stop this one'
        'alert.batteryFloor'            = 'On battery at {pct}%: display protection stepped down as configured'
        'alert.sleepEvidence'           = 'While protection ran, {n} real sleep(s) happened with the power request held - the platform bypassed it at those moments'
        'alert.evidenceBlind'           = 'At least one sleep state this machine declares leaves no record this tool reads - green on the panel means nothing was logged, not that it did not sleep; what this machine does leave readable is written in the evidence section'
        'alert.standbyLid'              = '{count} low-power session(s) in this window came from the lid - closing the lid bypasses power requests and Windows asks for sign-in on wake; keep the lid open for unattended remote access, but that is necessary and not sufficient - most standbys on this box are idle timeouts with the lid open, and that half is what this tool can hold. Or run ka.bat lid apply to set the lid action to "do nothing" (verify it with a real lid close - some platforms accept the write and still enter standby)'
        'alert.sessionLocked'           = 'The session is on the lock screen / secure desktop right now: the power request still holds and the machine stays up, but a remote client only sees the lock screen ({count} heartbeats skipped)'
        'alert.uipiBlocked'             = 'The heartbeat input is being dropped by UIPI: the foreground app runs at higher integrity (elevated), so the idle lock-screen timer cannot be reset (the power request still holds - the machine does not sleep). Either close that elevated app or re-run this tool elevated - {count} pulses skipped, and the next successful pulse clears this'
        'alert.multiWorker'             = '{count} worker processes detected; there should be exactly 1'
        'alert.staleState'              = 'The worker stopped reporting state - protection may no longer be held'
        'alert.guardDisabled'           = 'The watchdog scheduled tasks are disabled ({names}): they will not fire, so nothing brings protection back after a reboot or a force-killed worker. Run ka.bat guard to re-register them'
        'alert.dataDirUnwritable'       = 'The data directory {path} is not writable ({error}): state, intent and the stop signal cannot be recorded, so the panel shows a running protection as stopped'
        'alert.machineDirUnwritable'    = 'The machine data directory {path} is not writable ({error}): the lid backup and machine-level state cannot be saved'
        'alert.stateUnrecorded'         = '{count} worker(s) are running but {path} cannot be read - the power request still holds, only the record is missing (the protection is real, just invisible)'
        'competitor.powerToys'          = 'PowerToys (may include the Awake module)'
        'competitor.presentation'       = 'Windows presentation mode (presentationsettings)'
        'competitor.confirm'            = 'powercfg /requests (run it elevated)'
    }
}
$script:KaUiLang = ''
$script:KaReqLang = ''

function Set-KaUiLanguage {
    param([string]$Lang)
    $script:KaUiLang = Resolve-KaLanguage -Explicit $Lang
}

function Get-KaUiLanguage {
    param([string]$Explicit)
    # -Explicit first, then the per-request override: a long-running panel server must not
    # cache a language the visitor just changed in the dashboard.
    if ($Explicit) { return Resolve-KaLanguage -Explicit $Explicit }
    if ($script:KaReqLang) { return Resolve-KaLanguage -Explicit $script:KaReqLang }
    if (-not $script:KaUiLang) {
        $cfg = 'auto'
        try { $cfg = (Get-KaConfig).language } catch { }
        $script:KaUiLang = Resolve-KaLanguage -Configured $cfg
    }
    return $script:KaUiLang
}

function Get-KaText {
    param([string]$Key, [hashtable]$Vars, [string]$Lang)
    $uiLang = Get-KaUiLanguage -Explicit $Lang
    $s = $script:KaUi[$uiLang][$Key]
    if ($null -eq $s) { $s = $script:KaUi.zh[$Key] }
    if ($null -eq $s) { return $Key }
    if ($Vars) {
        foreach ($k in $Vars.Keys) { $s = $s.Replace('{' + $k + '}', "$($Vars[$k])") }
    }
    return $s
}

function Get-KaNoteText {
    # state.json carries machine tokens (note=lock-screen, note=battery-floor) precisely so a
    # new worker version cannot smuggle an untranslatable sentence into every surface.
    # Unknown tokens pass through as-is: showing the raw token beats showing a dictionary key.
    param([string]$Token, [hashtable]$Vars)
    if (-not "$Token") { return '' }
    $key = "worker.note.$Token"
    if ($script:KaUi.zh.ContainsKey($key)) { return Get-KaText $key $Vars }
    return "$Token"
}

function Get-KaReasonText {
    # Standby-reason tokens are machine vocabulary (the POWER_MONITOR_REQUEST_REASON names
    # + raw code-N), same doctrine as notes: an unknown token shows raw instead of a
    # dictionary key.
    param([string]$Token)
    if (-not "$Token") { return '' }
    $key = "st.reason.$Token"
    if ($script:KaUi.zh.ContainsKey($key)) { return Get-KaText $key }
    return "$Token"
}

function Get-KaInstrumentText {
    # Same rule as the reason tokens: `instrument` is a machine token Update-KaSleepInstrument
    # emits. A name this build has no wording for has to reach the screen as itself - printing
    # 'ev.instrument.blind' because a dictionary entry is missing would put a key where a
    # diagnosis belongs.
    param([string]$Name)
    if (-not "$Name") { return '' }
    $key = "ev.instrument.$Name"
    if ($script:KaUi.zh.ContainsKey($key)) { return Get-KaText $key }
    return "$Name"
}

function Get-KaErrorText {
    # Error tokens are `code:context` (settes-zero:initial). The half after the colon is
    # already ASCII machine vocabulary - the -Why the worker passed - so it is interpolated
    # rather than looked up.
    param([string]$Token)
    if (-not "$Token") { return '' }
    $parts = "$Token" -split ':', 2
    $key = "worker.error.$($parts[0])"
    if (-not $script:KaUi.zh.ContainsKey($key)) { return "$Token" }
    return (Get-KaText $key @{ why = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) })
}

function Get-KaProse {
    <#
        A report entry is @{ id = 'report.risk.battery'; pct = 42; floor = 20 } - a dictionary
        key plus the numbers that fill its placeholders. Nothing on the wire is a sentence, so
        the CLI and the panel word the same fact in their own language, and each surface that
        cannot word it shows the raw id, which is greppable, rather than a hole. Strings pass
        through untouched: that is a payload from before this format.
    #>
    param($Entry, [string]$Lang)
    if ($null -eq $Entry) { return '' }
    if ($Entry -is [string]) { return $Entry }
    $vars = @{}
    $key = ''
    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($k in @($Entry.Keys)) {
            if ("$k" -eq 'id') { $key = "$($Entry[$k])" } else { $vars["$k"] = $Entry[$k] }
        }
    } else {
        foreach ($p in $Entry.PSObject.Properties) {
            if ($p.Name -eq 'id') { $key = "$($p.Value)" } else { $vars[$p.Name] = $p.Value }
        }
    }
    if (-not $key) { return ($vars | ConvertTo-Json -Compress) }
    if (-not $script:KaUi.zh.ContainsKey($key)) { return $key }
    return (Get-KaText $key $vars -Lang $Lang)
}

# ---------------------------------------------------------------- powercfg reader
function Get-PowerSetting {
    <#
        Returns @{ Ac=<sec-or-value>; Dc=<...>; Found=$true/$false; Source=... } for a power
        setting. Pass -Text to parse a captured powercfg dump instead of querying the machine.

        Two ways to find the two values that matter, in order:

          1. the 当前交流/当前直流 labels (zh + en);
          2. indentation, verified against real `powercfg /q` output on this machine: the
             per-setting attributes (最小/最大可能的设置、增量、单位) are indented 6 spaces,
             the two current indices exactly 4, and enumerated-value lines print as a bare
             "001" with no 0x so they never match the hex pattern at all.

        Rule 2 is what carries non-zh/en Windows. The fallback it replaces was "first two
        0x values in the output" - those are the setting's *bounds*, so every timeout read
        back as 0 ("never") no matter what the machine was configured to do. Falling through
        both rules returns Found=$false: an honest 未知 beats a plausible wrong number.
    #>
    param([string]$Subgroup, [string]$Setting, [string]$Text)

    $result = @{ Ac = $null; Dc = $null; Found = $false; Source = '' }
    try {
        $out = if ($PSBoundParameters.ContainsKey('Text')) { $Text }
               else { (& powercfg /q SCHEME_CURRENT $Subgroup $Setting 2>$null) -join "`n" }
        if (-not $out) { return $result }
        $lines = @($out -split "`r?`n" | ForEach-Object { "$_" })

        $acLine = @($lines | Where-Object { $_ -match '当前交流|Current AC' -and $_ -match '0x[0-9A-Fa-f]{8}' } | Select-Object -First 1)
        $dcLine = @($lines | Where-Object { $_ -match '当前直流|Current DC' -and $_ -match '0x[0-9A-Fa-f]{8}' } | Select-Object -First 1)
        if ($acLine.Count -or $dcLine.Count) {
            $result.Source = 'label'
        } else {
            $cur = @($lines | Where-Object { $_ -match '^ {4}\S' -and $_ -match '0x[0-9A-Fa-f]{8}' })
            $acLine = @($cur | Select-Object -First 1)
            $dcLine = @($cur | Select-Object -Skip 1 -First 1)
            $result.Source = 'indent'
        }
        if ($acLine.Count) { $result.Ac = [Convert]::ToInt64(([regex]::Match($acLine[0], '0x([0-9A-Fa-f]{8})')).Groups[1].Value, 16) }
        if ($dcLine.Count) { $result.Dc = [Convert]::ToInt64(([regex]::Match($dcLine[0], '0x([0-9A-Fa-f]{8})')).Groups[1].Value, 16) }
        $result.Found = ($null -ne $result.Ac)
        if (-not $result.Found) { $result.Source = '' }
        # powercfg uses 0xFFFFFFFF for "never" on some settings and 0 on others.
        if ($null -ne $result.Ac -and $result.Ac -ge 4294967295) { $result.Ac = 0 }
        if ($null -ne $result.Dc -and $result.Dc -ge 4294967295) { $result.Dc = 0 }
    } catch { }
    return $result
}

function Format-KaSeconds {
    param($sec, [string]$Lang)
    if ($null -eq $sec) { return (Get-KaText 'fmt.unknown' -Lang $Lang) }
    if ($sec -eq 0) { return (Get-KaText 'fmt.never' -Lang $Lang) }
    if ($sec -lt 60) { return (Get-KaText 'fmt.seconds' @{ n = $sec } -Lang $Lang) }
    $m = [math]::Round($sec / 60, 1)
    if ($m -lt 60) { return (Get-KaText 'fmt.minutes' @{ n = $m } -Lang $Lang) }
    return (Get-KaText 'fmt.hours' @{ n = ('{0:N1}' -f ($sec / 3600)) } -Lang $Lang)
}

function Format-KaDuration {
    <#
        Not interchangeable with Format-KaSeconds: there 0 is a power plan's "从不",
        here 0 is a real measurement ("input one second ago").

        The argument is parsed instead of compared directly: `Format-KaDuration -1` binds
        -1 as the *string* "-1", and culture-sensitive string ordering ignores the hyphen,
        so "-1" -lt 0 came back false and the idle-failure sentinel printed as "-1 秒".
    #>
    param($sec, [string]$Lang)
    $d = 0.0
    if ($null -eq $sec) { return (Get-KaText 'fmt.unknown' -Lang $Lang) }
    # A number goes straight through. Interpolating it first and parsing it back is what made
    # this function culture-dependent: under de-DE a double arrived as "1755,5" and a string
    # like "1755.0" read as seventeen thousand five hundred fifty (the dot is their group
    # separator), which under fr-FR did not parse at all and printed as "未知".
    if ($sec -is [double] -or $sec -is [int] -or $sec -is [long] -or $sec -is [single] -or $sec -is [decimal]) {
        $d = [double]$sec
    } elseif (-not [double]::TryParse("$sec", [Globalization.NumberStyles]::Float,
                                     [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return (Get-KaText 'fmt.unknown' -Lang $Lang)
    }
    if ($d -lt 0) { return (Get-KaText 'fmt.unknown' -Lang $Lang) }
    if ($d -lt 60) { return (Get-KaText 'fmt.seconds' @{ n = [int]$d } -Lang $Lang) }
    return (Format-KaSeconds -sec $d -Lang $Lang)
}

function Get-KaSleepStates {
    <#
        Returns @{ s0; s3; hibernate; modernStandby; known; raw }. Pass -Text to parse a
        captured `powercfg /a` dump instead of querying this machine.

        The section a state is listed in IS the answer, so finding the section boundary
        must not depend on a translated heading. The old code matched the Chinese or
        English "not available" title, and on any other language the split silently did
        nothing: the unavailable section's *reason* lines name S0 and S3 too, so a German
        or Japanese machine could be reported as supporting S3 it does not have.
        Structure instead: a heading is unindented and ends in a colon, a state line is
        indented 4 spaces, a reason line is tab-indented.

        Hibernation has no state code to match, so it comes from the registry
        (HibernateEnabled) - a key name is never localized; the label match stays as the
        fallback for a machine where that value is unreadable. With -Text the caller gave us
        a self-contained dump, so we parse only that and never let this machine's registry
        leak into a fixture's expected answer.
    #>
    param([string]$Text)
    $info = @{
        s0 = $false; s3 = $false; hibernate = $false; modernStandby = $false
        known = $false; hibSource = ''; raw = @()
    }
    try {
        $lines = if ($PSBoundParameters.ContainsKey('Text')) { @($Text -split "`r?`n") }
                 else { @(& powercfg /a 2>$null) }
        $lines = @($lines | ForEach-Object { "$_" })
        $info.raw = @($lines | Where-Object { $_.Trim() -ne '' })

        $section = 0
        $availableText = ''
        foreach ($ln in $lines) {
            if ($ln -match '^[^ \t]' -and $ln -match '[:：]\s*$') { $section++; continue }
            if ($section -eq 0) { continue }
            if ($section -eq 1) {
                $availableText += "`n$ln"
                if ($ln -match '^ {4}\S') {
                    if ($ln -match '[(（] *S0') { $info.s0 = $true }
                    if ($ln -match '[(（] *S3') { $info.s3 = $true }
                }
            }
        }
        $info.known = ($section -ge 1)
        $info.modernStandby = $info.s0 -and -not $info.s3

        $hib = $null
        if (-not $PSBoundParameters.ContainsKey('Text')) {
            try {
                $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled
            } catch { $hib = $null }
        }
        if ($null -ne $hib -and "$hib" -ne '') {
            $info.hibernate = ([int]$hib -ne 0); $info.hibSource = 'registry'
        } else {
            $info.hibernate = ($availableText -match '(休眠|Hibernate)')
            $info.hibSource = 'label'
        }
    } catch { }
    return $info
}

# ---------------------------------------------------------------- power capabilities
function Read-KaPowerCaps {
    <#
        Pure decoder for the raw GetPwrCapabilities buffer. Byte offsets are the
        SDK's um/winnt.h SYSTEM_POWER_CAPABILITIES layout (flattened, 1 byte per
        BOOLEAN): 2=LidPresent, 5=SystemS3, 6=SystemS4, 8=HiberFilePresent, 17=
        FastSystemS4, 18=Hiberboot, 20=AoAc ("S0 low power idle"), 22=HiberFileType,
        23=AoAcConnectivitySupported, 30=SystemBatteriesPresent. The offsets are pinned
        by a synthetic-buffer test and cross-validated live against powercfg /a - if
        either ever moves, the two disagree and the suite says so.
    #>
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Count -lt 31) { return $null }
    $bit = { param([int]$i) ([bool]$Bytes[$i]) }
    return @{
        lidPresent       = (& $bit 2)
        s1               = (& $bit 3)
        s2               = (& $bit 4)
        s3               = (& $bit 5)
        s4               = (& $bit 6)
        s5               = (& $bit 7)
        hiberFilePresent = (& $bit 8)
        fastSystemS4     = (& $bit 17)
        hiberboot        = (& $bit 18)
        aoAc             = (& $bit 20)
        hiberFileType    = [int]$Bytes[22]
        aoAcConnectivity = (& $bit 23)
        batteriesPresent = (& $bit 30)
    }
}

function Get-KaPowerCaps {
    <#
        The kernel's own answer about sleep states, lid and battery presence - no text
        parsing, no localization anywhere in the path. powercfg /a parsing stays as the
        fallback (source='powercfg') for the case the API call fails; Get-KaReport uses
        this as the primary and lets the suite watch the two for disagreement.
    #>
    try {
        $raw = [Ka.Native]::GetPowerCapabilitiesRaw()
        if ($raw) {
            $c = Read-KaPowerCaps -Bytes $raw
            if ($c) { $c.source = 'api'; return $c }
        }
    } catch { }
    return @{ source = 'powercfg' }
}

# ---------------------------------------------------------------- UIPI / integrity
function Test-KaInputBlocked {
    <#
        Pure UIPI decision: synthetic input is dropped when the sender's integrity is
        LOWER than the foreground process's. Anything unmeasured (-1) is NOT a mismatch
        - an unknown state must neither fake a skip nor discard a pulse that may well
        have landed. 0 = no foreground window, same treatment.
    #>
    param([int]$SelfIl, [int]$ForegroundIl)
    if ($SelfIl -lt 0x1000 -or $ForegroundIl -lt 0x1000) { return $false }
    return $ForegroundIl -gt $SelfIl
}

function Get-KaForegroundIntegrity {
    <#
        One probe per heartbeat tick: who owns the foreground window and at what
        integrity. Returns @{ selfIl; fgPid; fgIl; blocked } with the well-known
        SECURITY_MANDATORY RIDs (0x1000 low / 0x2000 medium / 0x3000 high / 0x4000
        system), -1 = could not measure.
    #>
    $r = @{ selfIl = -1; fgPid = 0; fgIl = -1; blocked = $false }
    try { $r.selfIl = [int][Ka.Native]::SelfIntegrityRid() } catch { }
    try { $r.fgPid = [int][Ka.Native]::ForegroundPid() } catch { }
    if ($r.fgPid -gt 0 -and $r.fgPid -ne $PID) {
        try { $r.fgIl = [int][Ka.Native]::ProcessIntegrityRid([uint32]$r.fgPid) } catch { }
    } elseif ($r.fgPid -eq $PID) {
        $r.fgIl = $r.selfIl
    }
    $r.blocked = Test-KaInputBlocked -SelfIl $r.selfIl -ForegroundIl $r.fgIl
    return $r
}

function Get-KaMinutesUntil {
    <#
        Turns "-ExpireAt 09:00" / "-ExpireAt 2026-08-30 07:30" into the duration the rest of
        the tool works with, so a timed run can be anchored to a wall clock instead of only
        to "how long from now".

        A bare time-of-day that has already passed means *tomorrow*, not "in the past" -
        that is what everyone means by "保护到 9 点". An explicit date in the past is refused:
        reading it as 0 would mean "no expiry", the opposite of what was asked.

        Returns @{ Ok; Minutes; At; Reason }.
    #>
    param([string]$Text, [datetime]$Now = (Get-Date))
    $r = @{ Ok = $false; Minutes = 0.0; At = $null; Reason = '' }
    $t = "$Text".Trim()
    if (-not $t) { $r.Reason = Get-KaText 'time.empty'; return $r }

    $ci = [Globalization.CultureInfo]::InvariantCulture
    $styles = [Globalization.DateTimeStyles]::None
    $d = [datetime]::MinValue

    # [string[]] is load-bearing: an untyped @(...) binds TryParseExact's *single*-format
    # overload (the array gets space-joined), so every exact parse silently returns false.
    if ([datetime]::TryParseExact($t, [string[]]@('H:mm', 'HH:mm', 'HH:mm:ss'), $ci, $styles, [ref]$d)) {
        $d = $Now.Date.Add($d.TimeOfDay)
    } elseif (-not [datetime]::TryParseExact(
            $t, [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy/M/d HH:mm:ss', 'yyyy/M/d HH:mm',
                  'yyyy-MM-dd', 'yyyy/M/d'), $ci, $styles, [ref]$d)) {
        if (-not [datetime]::TryParse($t, [ref]$d)) {
            $r.Reason = Get-KaText 'time.unparsed'
            return $r
        }
    }

    # No date separator in what they typed means a time of day, and a time of day already
    # past means tomorrow - that is what "保护到 9 点" always means.
    if ($d -le $Now -and $t -notmatch '[/-]') { $d = $d.AddDays(1) }
    if ($d -le $Now) {
        $r.Reason = Get-KaText 'time.past' @{ at = $d.ToString('yyyy-MM-dd HH:mm:ss') }
        return $r
    }
    $mins = ($d - $Now).TotalMinutes
    $r.Ok = $true
    $r.At = $d
    $r.Minutes = [math]::Round($mins, 2)
    return $r
}

function Get-KaPlan {
    $sleep = Get-PowerSetting 'SUB_SLEEP' 'STANDBYIDLE'
    $video = Get-PowerSetting 'SUB_VIDEO' 'VIDEOIDLE'
    $lid   = Get-PowerSetting '4f971e89-eebd-4455-a8de-9e59040e7347' '5ca83367-6e45-459f-a27b-476b1d01c936'
    $unatt = Get-PowerSetting 'SUB_SLEEP' 'UNATTENDSLEEP'
    # CONSOLELOCK has no powercfg alias, so it must be addressed by GUID. It is hidden
    # on many Modern Standby OEM images; Found=$false then means "cannot be read here",
    # not "sign-in on wake is off".
    $consoleLock = Get-PowerSetting 'fea3413e-7e05-4911-9a71-700331f1c294' '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0'
    $hybrid = Get-PowerSetting 'SUB_SLEEP' 'HYBRIDSLEEP'

    $ss = $null
    try {
        $desk = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
        if ($desk -and $desk.'SCRNSAVE.EXE' -and "$($desk.ScreenSaveActive)" -eq '1') {
            $ss = @{ exe = [IO.Path]::GetFileName("$($desk.'SCRNSAVE.EXE')"); timeoutSec = [int](Get-KaBounded $desk.ScreenSaveTimeOut 1 86400 600)
                     secure = ("$($desk.ScreenSaverIsSecure)" -eq '1') }
        }
    } catch { }

    $policy = $null
    try {
        $v = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
              -Name InactivityTimeoutSecs -ErrorAction SilentlyContinue
        if ($v -and $v.InactivityTimeoutSecs) { $policy = [int]$v.InactivityTimeoutSecs }
    } catch { }

    @{
        sleepAcSec = if ($sleep.Found) { $sleep.Ac } else { $null }
        sleepDcSec = if ($sleep.Found) { $sleep.Dc } else { $null }
        videoAcSec = if ($video.Found) { $video.Ac } else { $null }
        videoDcSec = if ($video.Found) { $video.Dc } else { $null }
        unattendedAcSec = if ($unatt.Found) { $unatt.Ac } else { $null }
        lidAc = if ($lid.Found) { $lid.Ac } else { $null }
        lidDc = if ($lid.Found) { $lid.Dc } else { $null }
        consoleLockAc = if ($consoleLock.Found) { $consoleLock.Ac } else { $null }
        hybridSleep = if ($hybrid.Found) { $hybrid.Ac } else { $null }
        screensaver = $ss
        inactivityPolicySec = $policy
    }
}

# ---------------------------------------------------------------- live system state
function Get-KaBattery {
    try { return [Ka.Native]::PowerStatus() } catch { return @{ known = $false } }
}

function Get-KaBatteryAction {
    <#
        The whole battery policy as one pure decision, so it can be tested without
        waiting for a laptop to discharge. It used to live inline in the worker's loop,
        which is exactly how the rule below shipped untested and broke protection.

        Two rules are load-bearing:
          * The critical bit is only honoured when the AC line is actually gone. Some
            firmware asserts it at 99% while plugged in, and an unconditional abort
            meant "keep awake" quietly became "nothing" one second after it started.
          * Restoring the display request uses a 10-point hysteresis (or any return to
            AC), so the request cannot flap when the charge sits on the threshold.

        Returns: Abort ('' | 'battery-critical'), Downgrade, Restore, Percent, Ac, OnBattery.
    #>
    param(
        $Status,
        [bool]$KeepDisplayOn,
        [bool]$BatteryAllowDisplayOff,
        [int]$FloorPercent,
        [bool]$Downgraded
    )
    $r = @{ Abort = ''; Downgrade = $false; Restore = $false; Percent = -1; Ac = $true; OnBattery = $false }
    if (-not $Status -or -not [bool]$Status.known) { return $r }
    $pct = [int]$Status.percent
    $ac  = [bool]$Status.acOnline
    $r.Percent = $pct
    $r.Ac = $ac
    $r.OnBattery = ((-not $ac) -and [bool]$Status.hasBattery)
    if ([bool]$Status.critical -and -not $ac) { $r.Abort = 'battery-critical'; return $r }
    $eligible = $KeepDisplayOn -and $BatteryAllowDisplayOff -and $r.OnBattery `
                -and ($pct -ge 0) -and ($pct -le $FloorPercent)
    if ($eligible -and -not $Downgraded) {
        $r.Downgrade = $true
    } elseif ((-not $eligible) -and $Downgraded) {
        if ($ac -or ($pct -ge ($FloorPercent + 10))) { $r.Restore = $true }
    }
    return $r
}

function Get-KaIdleSeconds {
    try { return [Ka.Native]::SecondsSinceInput() } catch { return -1 }
}

# ---------------------------------------------------------------- requestsoverride
function Read-KaRequestOverrides {
    <#
        Pure parser for `powercfg /requestsoverride` output. The empty shape is
        "[SERVICE]/[PROCESS]/[DRIVER]" headers; a populated list puts entries under
        them - but a populated list could not be sampled here (WRITING an override
        needs elevation, verified), so this stays conservative: any non-empty
        non-header line is an entry, kept verbatim in .line, and every consumer
        shows the raw text instead of pretending to know its column layout.
    #>
    param([string]$Text)
    $r = @()
    $scope = ''
    foreach ($line in ("$Text" -split '\r?\n')) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^\[([^\]]+)\]$') { $scope = $Matches[1]; continue }
        if (-not $scope) { continue }
        $r += @{ scope = $scope; line = $t }
    }
    # Plain return, no `,`-wrap: wrapping makes the array one pipeline item, so a
    # caller's @(Fn) always collected Count=1 - and a filtered-empty result still
    # looked non-empty, which fired report.risk.override-self on every machine.
    return $r
}

function Get-KaRequestOverrides {
    # An override entry naming our own image makes the kernel silently ignore every
    # request the worker makes: the tool reports "protecting" while the power manager
    # throws the request away, with no error anywhere. Listing is readable without
    # elevation (verified: exit 0 on a standard account; only WRITING needs admin).
    try {
        $out = (& powercfg /requestsoverride 2>$null) -join "`n"
        return (Read-KaRequestOverrides -Text $out)
    } catch { return @() }
}

function Get-KaSelfOverrides {
    <#
        The subset of overrides that hit this product's own image name. The worker
        runs as whatever host launched it (powershell.exe, or pwsh.exe under PS7), so
        the match is on the image name appearing as a token in the raw entry - and a
        false positive is acceptable here, because the display shows the raw line for
        the user to judge.
    #>
    param($Overrides)
    return @($Overrides | Where-Object { "$($_.line)" -match '\b(powershell|pwsh)\.exe\b' })
}

function Get-KaSessionAdoption {
    <#
        A boot-task (S4U) worker starts in session 0, which has no desktop: the power
        request holds, but a synthetic-input heartbeat there is noise forever. The first
        guard pass that runs in a real session (the logon trigger) must move the worker
        into it, and this pure decision is the whole rule - session 0 means "wrong
        place", anything else (console, RDP, another live session) already owns a
        desktop and is left alone, and -1 means "process already gone, nothing to adopt".
    #>
    param([int]$MySessionId, [int]$WorkerSessionId)
    return ($MySessionId -gt 0 -and $WorkerSessionId -eq 0)
}

function Get-KaSession {
    <#
        Best effort without elevation. Which session owns the console is decided by
        comparing session ids - `query session` output is locale-dependent and matched
        nothing here, so the field used to read "unknown" forever.

        logonui.exe is only up while the secure desktop owns the display, which is also
        exactly the state where a synthetic-input heartbeat can no longer reach the user
        session, so the worker watches that flag rather than trusting its own pulse.
    #>
    $s = @{ state = 'unknown'; consoleActive = $false; lockScreen = $false
            sessionId = -1; consoleSessionId = -1 }
    try {
        $console = [Ka.Native]::ActiveConsoleSession()
        $mine = [int](Get-Process -Id $PID).SessionId
        $s.consoleSessionId = $console
        $s.sessionId = $mine
        if ($console -lt 0) {
            $s.state = 'NoConsole'          # 0xFFFFFFFF: nobody is at the keyboard
        } else {
            $s.consoleActive = ($mine -eq $console)
            $s.state = if ($s.consoleActive) { 'Active' } else { 'OtherSession' }
        }
    } catch {
        $s.state = 'unreadable'   # the native call itself failed - not the same as "no console"
    }
    try {
        $s.lockScreen = [bool](Get-Process -Name logonui -ErrorAction SilentlyContinue)
    } catch { }
    return $s
}

# ---------------------------------------------------------------- worker lifecycle
function Get-KaWorkerRoot([string]$CommandLine) {
    # Start-KaWorker always quotes -File; a hand-launched worker usually does not.
    $m = [regex]::Match($CommandLine, '"?([A-Za-z]:[^"]*?ka-worker\.ps1)"?')
    if (-not $m.Success) { return '' }
    try { (Split-Path -Parent $m.Groups[1].Value).TrimEnd('\') } catch { '' }
}

function Get-KaWorkerData([string]$CommandLine) {
    # -DataDir is always quoted by the code that writes it; the unquoted form covers a
    # hand-started worker whose path has no spaces. '' means "it never said".
    $m = [regex]::Match($CommandLine, '-DataDir\s+"([^"]*)"')
    if (-not $m.Success) { $m = [regex]::Match($CommandLine, '-DataDir\s+([^\s"]+)') }
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value.TrimEnd('\')
}

function Test-KaOwnWorker {
    <#
        Ownership, and it has to fail *closed* towards "ours": a worker we cannot
        attribute must never be dropped from the scan, because an empty scan is what
        every surface here reads as "protection is off".

        The data root is the real identity - that is whose state.json, stop.flag and
        mutex this worker owns - so a worker that told us gets judged on what it told us.
        Two copies of the tool installed for the same user share a data root and can
        therefore never both protect; the second one exits on the mutex instead of
        holding a second power request nobody can stop.
        $root is empty when ka-core is dot-sourced from -Command instead of a file.
    #>
    param([string]$CommandLine, [string]$Root, [string]$Data)
    $wd = Get-KaWorkerData $CommandLine
    if ($wd) {
        if ([string]::IsNullOrEmpty($Data)) { return $true }
        return ($wd -ieq $Data)
    }
    if ([string]::IsNullOrEmpty($Root)) { return $true }
    $wr = Get-KaWorkerRoot $CommandLine
    # Unattributable (relative -File, a UNC path, something exotic): count it as ours.
    # Guessing "not mine" here would make the scan come up empty, and every surface
    # downstream reads an empty scan as "protection released".
    if ([string]::IsNullOrEmpty($wr)) { return $true }
    return ($wr -ieq $Root)
}

function Get-KaWorker {
    <#
        Authoritative worker discovery. A PID file is a cache, not a source of truth:
        it goes stale on a reboot, loses races, and orphans processes that keep holding
        the power request while the tool claims to be stopped.

        -AnyPath widens the scan to workers belonging to a *different* copy of the tool.
        Those are not ours to manage, but pretending they do not exist is a lie: one holds
        the power request, so this root reports "stopped" on a machine that will not sleep.
    #>
    param([switch]$AnyPath)
    $found = @()
    try {
        $root = Get-KaProgramRoot
        $data = Get-KaDataRoot
        $marker = 'ka-worker.ps1'
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            $cl = "$($proc.CommandLine)"
            if ($cl -notlike "*$marker*") { continue }
            $wr = Get-KaWorkerRoot $cl
            $wd = Get-KaWorkerData $cl
            $mine = Test-KaOwnWorker -CommandLine $cl -Root $root -Data $data
            if (-not $AnyPath -and -not $mine) { continue }
            if ([int]$proc.ProcessId -eq $PID) { continue }
            $startEpoch = 0
            try { $startEpoch = ([DateTimeOffset]::new($proc.CreationDate)).ToUnixTimeSeconds() } catch { }
            $found += [PSCustomObject]@{
                Pid      = [int]$proc.ProcessId
                StartEpoch = $startEpoch
                CommandLine = $cl
                Root     = $wr
                Data     = $wd
                Mine     = [bool]$mine
            }
        }
    } catch { }
    return $found
}

function Get-KaWorkerState {
    param([int]$MaxAgeSec = 90)
    $st = Read-KaJson (Get-KaPath).state
    if (-not $st) { return $null }
    $aliveIds = @(Get-KaWorker | ForEach-Object { $_.Pid })
    if ([int]$st.pid -notin $aliveIds) { return $null }
    $age = (Get-KaEpoch) - [long]$st.lastTickEpoch
    if ($age -gt $MaxAgeSec) {
        Add-Member -InputObject $st -NotePropertyName stale -NotePropertyValue $true -Force
    } else {
        Add-Member -InputObject $st -NotePropertyName stale -NotePropertyValue $false -Force
    }
    return $st
}

function Get-KaWorkerLastLine {
    <#
        The worker's own words about why it stopped, for a failure message. Returns ''
        when the log has nothing about that pid - callers must not invent a cause.
    #>
    param([string]$LogPath, [int]$WorkerPid)
    try {
        $m = @(Get-Content -LiteralPath $LogPath -Tail 8 -ErrorAction SilentlyContinue |
               Where-Object { $_ -like "*pid=$WorkerPid*" })
        if ($m.Count) { return "$($m[-1])" }   # interpolate: raw pipeline objects carry note properties into JSON
    } catch { }
    return ''
}

function Get-KaServerLastLine {
    <#
        What this panel process said last, for a failure message. Attributed by pid: the
        log outlives the process, and "the last line mentioning server" was usually the
        *previous* panel's successful SERVER line - a failed start then showed the user a
        reason that contradicted itself. The startup line is excluded for the same reason.
        Returns '' when the log holds nothing for that pid; callers must not invent a cause.
    #>
    param([string]$LogPath, [int]$ServerPid)
    try {
        $m = @(Get-Content -LiteralPath $LogPath -Tail 12 -ErrorAction SilentlyContinue |
               Where-Object { $_ -like "*pid=$ServerPid*" -and $_ -notmatch ' SERVER pid=' })
        if ($m.Count) { return "$($m[-1])" }   # interpolate: raw pipeline objects carry note properties into JSON
    } catch { }
    return ''
}

function Get-KaMutexName([string]$Prefix) { 'Local\' + (Get-KaIdentitySuffix $Prefix) }

function Test-KaWorkerMutex {
    <#
        Does a live worker hold the single-instance mutex? OpenExisting never takes
        ownership, so this can be asked without disturbing the holder. $null means the
        question is unanswerable here (named-object creation blocked, or a holder in
        another session - Local\ is per-session), which is precisely why the start
        verdict treats it as "unknown" and never as "not protecting".
    #>
    try {
        $m = [System.Threading.Mutex]::OpenExisting((Get-KaMutexName 'KA-Worker'))
        try { return $true } finally { $m.Dispose() }
    } catch [System.Threading.WaitHandleCannotBeOpenedException] { return $false }
      catch { return $null }
}

function Start-KaWorker {
    param([double]$Minutes = 0, [hashtable]$Override = @{})

    $cfg = Get-KaConfig
    foreach ($k in $Override.Keys) { if ($cfg.ContainsKey($k)) { $cfg[$k] = $Override[$k] } }
    $p = Get-KaPath

    $existing = @(Get-KaWorker)
    if ($existing.Count -gt 0) {
        $st0 = Read-KaJson $p.state
        $rr = @{ Ok = $true; AlreadyRunning = $true; Pid = $existing[0].Pid; Count = $existing.Count
                 StateRecorded = [bool]$st0 }
        if (-not $st0) {
            # Running-but-unrecorded has the same shape as a fresh start whose state write
            # failed, so it has to carry the same reason or the CLI prints an empty clause.
            $rr.Detail = (Test-KaPathWritable $p.data).Code
        }
        return $rr
    }
    if (-not (Test-Path -LiteralPath $p.worker)) {
        return @{ Ok = $false; Reason = (Get-KaText 'proc.noScript' @{ file = 'ka-worker.ps1'; path = $p.worker }) }
    }

    # a stale stop flag would make the new worker quit on its first tick
    try { Remove-Item -LiteralPath $p.stopFlag -Force -ErrorAction SilentlyContinue } catch { }

    # Integer-valued parameters on purpose: `powershell.exe -File` cannot bind
    # `-Switch:$false` style arguments, so booleans must not travel as switches.
    $a = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $p.worker),
        # -DataDir is not a convenience: the guard task can start in session 0 before the
        # interactive profile is fully resolved, and a worker that then fell back to some
        # other location would reconcile a different user's intent.json.
        '-DataDir',               ('"{0}"' -f $p.data),
        '-KeepDisplayOn',         $(if ($cfg.keepDisplayOn) { '1' } else { '0' }),
        '-AntiLock',              $(if ($cfg.antiLock) { '1' } else { '0' }),
        '-AwayMode',              $(if ($cfg.awayMode) { '1' } else { '0' }),
        '-BatteryAllowDisplayOff',$(if ($cfg.batteryAllowDisplayOff) { '1' } else { '0' }),
        '-AntiLockMethod',        $cfg.antiLockMethod,
        '-AntiLockIntervalSec',   [string]$cfg.antiLockIntervalSec,
        '-ReassertSec',           [string]$cfg.reassertSec,
        '-BatteryFloorPercent',   [string]$cfg.batteryFloorPercent,
        '-Minutes',               [string]$Minutes
    )
    try {
        $proc = Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden -PassThru
    } catch {
        return @{ Ok = $false; Reason = (Get-KaText 'proc.noStart' @{ msg = $_.Exception.Message }) }
    }

    # Verify by the worker's own report, not by "is the process still there".
    $deadline = (Get-Date).AddSeconds(25)
    $seen = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $seen = Read-KaJson $p.state
        if ($seen -and [int]$seen.pid -eq $proc.Id) { break }
        $seen = $null
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { break }
    }
    # Reported once and then died is the worse case: every surface would say "protection
    # running" about a process that no longer exists. Observed for real when firmware
    # asserted the battery-critical bit while the machine was plugged in at 99%.
    # Paid before the verdict, because the same four seconds answers "did it survive"
    # for the recorded and the unrecorded outcome alike.
    $confirmUntil = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $confirmUntil -and (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
        $reason = Get-KaWorkerLastLine -LogPath $p.log -WorkerPid $proc.Id
        Add-KaLog "EARLY-EXIT pid=$($proc.Id) $reason"
        $why = if ($reason) { Get-KaText 'proc.earlyExit' @{ why = $reason } } else { Get-KaText 'proc.earlyExitNoLine' }
        return @{ Ok = $false; EarlyExit = $true; Pid = $proc.Id
                  Reason = $why }
    }
    if (-not $seen) {
        # Alive and holding the mutex means it got past the single-instance gate and is
        # applying the request right now - the only thing that failed is the record. That
        # is a read-only or locked data directory, and calling it "start failed" would
        # have the user stop a protection that is working.
        if ((Test-KaWorkerMutex) -eq $true) {
            Add-KaLog "STARTED-UNRECORDED pid=$($proc.Id) state=$($p.state)"
            # The worker's own write error died with its process; this is what can be
            # established from here, and it names the directory the user has to fix.
            return @{ Ok = $true; StateRecorded = $false; AlreadyRunning = $false; Pid = $proc.Id; Count = 1
                      Detail = (Test-KaPathWritable $p.data).Code }
        }
        $reason = Get-KaWorkerLastLine -LogPath $p.log -WorkerPid $proc.Id
        if (-not $reason) { $reason = Get-KaText 'proc.noLine' }
        return @{ Ok = $false; Reason = (Get-KaText 'proc.noReport' @{ why = $reason }) }
    }
    return @{ Ok = $true; StateRecorded = $true; AlreadyRunning = $false; Pid = $proc.Id; Count = 1 }
}

function Stop-KaWorker {
    <#
        Cooperative first: the worker sees stop.flag, releases its own power request and
        logs it. Only processes still alive after the grace period get killed, and the
        sweep takes every discovered worker, not just one remembered PID.
        Cooperative=$false is a real finding, not a formality: it means stop.flag could
        not be written, so nothing released the request politely and the worker's finally
        block never ran.
    #>
    param([int]$GraceSec = 6, [string]$Reason = 'user')
    $p = Get-KaPath
    $workers = @(Get-KaWorker)
    if ($workers.Count -eq 0) { return @{ Stopped = 0; Forced = 0; Cooperative = $true } }

    $cooperative = Write-KaJson $p.stopFlag @{ epoch = (Get-KaEpoch); reason = $Reason } -Depth 3
    $left = @()
    $deadline = (Get-Date).AddSeconds($GraceSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $left = @(Get-KaWorker)
        if ($left.Count -eq 0) { break }
    }
    $forced = 0
    foreach ($w in $left) {
        try { Stop-Process -Id $w.Pid -Force -ErrorAction Stop; $forced++ } catch { }
    }
    try { Remove-Item -LiteralPath $p.stopFlag -Force -ErrorAction SilentlyContinue } catch { }
    if (-not $cooperative) { Add-KaLog "STOP-UNCOOPERATIVE forced=$forced write=$($p.stopFlag)" }
    return @{ Stopped = $workers.Count; Forced = $forced; Cooperative = [bool]$cooperative
              Detail = $(if ($cooperative) { '' } else { (Test-KaPathWritable $p.data).Code }) }
}

# ---------------------------------------------------------------- dashboard server
function Get-KaServer {
    $found = @()
    try {
        $p = Get-KaPath
        # .server.json is written by this project's own panel, so its pid identifies our
        # server without depending on the command line. Start-KaServer passes an absolute
        # path and is matched by root; a panel launched by hand from inside this folder
        # ("-File ka-server.ps1") is not - and was then impossible to stop, leaving the
        # port squatted and every restart failing with a prefix conflict.
        $ownPid = 0
        $info = Read-KaJson $p.serverInfo
        # Trust the recorded pid only when the hint says it belongs to *this* data root -
        # otherwise a leftover file from another user or another install could point us at
        # an unrelated process, and Stop-KaServer kills by pid.
        if ($info -and "$($info.data)" -eq "$($p.data)") { $ownPid = [int]$info.pid }
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            $cl = "$($proc.CommandLine)"
            if ($cl -notlike '*ka-server.ps1*') { continue }
            $byPath = ($cl -like "*$($p.root)*")
            $byInfo = ($ownPid -gt 0 -and [int]$proc.ProcessId -eq $ownPid)
            if (-not ($byPath -or $byInfo)) { continue }
            if ([int]$proc.ProcessId -eq $PID) { continue }
            $startEpoch = 0
            try { $startEpoch = ([DateTimeOffset]::new($proc.CreationDate)).ToUnixTimeSeconds() } catch { }
            $found += [PSCustomObject]@{ Pid = [int]$proc.ProcessId; StartEpoch = $startEpoch; CommandLine = $cl }
        }
    } catch { }
    return $found
}

function Test-KaUrl {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        # /api/* answers 403 to anything that is not the dashboard client - that is the
        # cross-site defence, not a fault. Probing as "probe" made a perfectly healthy
        # panel look dead, so Start-KaServer killed and respawned it on every call.
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Start-KaServer {
    $cfg = Get-KaConfig
    $p = Get-KaPath
    $url = "http://127.0.0.1:$($cfg.port)/"
    $ping = $url + 'api/ping'

    $existing = @(Get-KaServer)
    if ($existing.Count -gt 0) {
        $healthy = Test-KaUrl $ping
        if ($healthy) {
            return @{ Ok = $true; Newly = $false; Url = $url; Pid = $existing[0].Pid; Count = $existing.Count }
        }
        # A process that is up but not serving is worse than no process: it squats the
        # port and the browser shows a dead tab. Replace it.
        [void](Stop-KaServer)
    }
    if (-not (Test-Path -LiteralPath $p.server)) {
        return @{ Ok = $false; Reason = (Get-KaText 'proc.noScript' @{ file = 'ka-server.ps1'; path = $p.server }) }
    }

    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
           '-File', ('"{0}"' -f $p.server), '-DataDir', ('"{0}"' -f $p.data), '-Port', [string]$cfg.port)
    try {
        $proc = Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden -PassThru
    } catch {
        return @{ Ok = $false; Reason = (Get-KaText 'server.noStart' @{ msg = $_.Exception.Message }) }
    }

    $startAt = Get-Date
    # 30s, and it is only ever paid on the failure path - a healthy panel answers in about
    # a second. A cold-starting hidden powershell.exe on a loaded machine was measured
    # taking longer than 15s, which read as "the panel is broken" when nothing was broken.
    $pingSec = 30
    $deadline = $startAt.AddSeconds($pingSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if (Test-KaUrl $ping) {
            return @{ Ok = $true; Newly = $true; Url = $url; Pid = $proc.Id; Count = 1 }
        }
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { break }
    }
    $why = Get-KaText 'server.noPing' @{ sec = $pingSec }
    $last = Get-KaServerLastLine -LogPath $p.log -ServerPid $proc.Id
    if ($last) { $why = "$why " + (Get-KaText 'server.lastLog' @{ line = $last }) }
    return @{ Ok = $false; Reason = $why; Url = $url }
}

function Stop-KaServer {
    # Force-killing a panel leaves the http.sys prefix registration behind; the next
    # panel's first requests then stall ~10 s while the kernel cleans up. Asking the
    # panel to stop itself via /api/server/stop lets it call listener.Stop()/Close(),
    # which deregisters the prefix cleanly. Measured: a gracefully stopped panel lets
    # its successor answer the first request in under a second.
    $p = Get-KaPath
    $cfg = Get-KaConfig
    $servers = @(Get-KaServer)
    $graceful = 0
    $killed = 0
    foreach ($s in $servers) {
        $port = $cfg.port
        if ($s.CommandLine -match '-Port\s+(\d+)') { $port = $Matches[1] }
        $asked = $false
        try {
            $uri = "http://127.0.0.1:$port/api/server/stop"
            $r = Invoke-WebRequest -Uri $uri -Method POST -UseBasicParsing -TimeoutSec 3 `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -ErrorAction Stop
            $asked = ($r.StatusCode -eq 200)
        } catch { }
        if ($asked) {
            $deadline = (Get-Date).AddSeconds(4)
            $exited = $false
            while ((Get-Date) -lt $deadline) {
                if (-not (Get-Process -Id $s.Pid -ErrorAction SilentlyContinue)) { $exited = $true; break }
                Start-Sleep -Milliseconds 200
            }
            if ($exited) { $graceful++; continue }
        }
        try { Stop-Process -Id $s.Pid -Force -ErrorAction Stop; $killed++ } catch { }
    }
    if ($killed -gt 0) {
        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) {
            $aliveNow = @($servers | Where-Object { Get-Process -Id ([int]$_.Pid) -ErrorAction SilentlyContinue })
            if ($aliveNow.Count -eq 0) { break }
            Start-Sleep -Milliseconds 150
        }
    }
    # Keep the hint when a recorded panel is still alive: it is the only handle on a server
    # launched with a relative path, and deleting it would strand the port squatter for good.
    $info = Read-KaJson $p.serverInfo
    $alive = $false
    if ($info -and "$($info.data)" -eq "$($p.data)" -and [int]$info.pid -gt 0) {
        $alive = [bool](Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)
    }
    if (-not $alive) {
        try { Remove-Item -LiteralPath $p.serverInfo -Force -ErrorAction SilentlyContinue } catch { }
    }
    return @{ Stopped = ($graceful + $killed); Graceful = $graceful; Killed = $killed; Found = $servers.Count; Squatting = $alive }
}

# ---------------------------------------------------------------- desired state / watchdog
function Get-KaIntent {
    $i = Read-KaJson (Get-KaPath).intent
    if (-not $i) { return @{ desired = 'off'; expiresEpoch = 0; updatedAt = 0; minutes = 0; expired = $false } }
    $desired = "$($i.desired)"
    $exp = [long]$i.expiresEpoch
    $expired = $false
    # A timed run that finished is not protection that died. Reporting it as still
    # desired made the watchdog resurrect expired runs and made `status` cry wolf.
    if ($desired -eq 'awake' -and $exp -gt 0 -and (Get-KaEpoch) -ge $exp) {
        $desired = 'off'
        $expired = $true
    }
    return @{
        desired      = $desired
        expiresEpoch = $exp
        updatedAt    = [long]$i.updatedAt
        minutes      = [double]$i.minutes
        expired      = $expired
    }
}

function Set-KaIntent {
    param([string]$Desired, [double]$Minutes = 0)
    $exp = 0
    if ($Desired -eq 'awake' -and $Minutes -gt 0) { $exp = (Get-KaEpoch) + [long]($Minutes * 60) }
    return Write-KaJson (Get-KaPath).intent @{
        desired = $Desired; minutes = $Minutes; expiresEpoch = $exp; updatedAt = (Get-KaEpoch)
    } -Depth 4
}

$script:KaTaskNames = @('KeepAwake-Guard', 'KeepAwake-Logon')
# Optional and separate: only registered on request (ka.ps1 guard -Boot). A boot trigger
# is administrator-only for every principal - verified on a standard account with S4U,
# interactive and both-triggers registrations, all "Access is denied" - so it must never
# gate `installed`, which standard-account installs have to be able to report true.
$script:KaBootTaskName = 'KeepAwake-Boot'

function Format-KaTaskResult {
    <#
        Task Scheduler's LastTaskResult is a DWORD. NTSTATUS outcomes (0xC000013A when a
        run is interrupted, 0xC0000005 when it crashes) are above Int32.MaxValue, so the
        [int] cast this replaced threw - and because that throw escaped the whole reader,
        a machine with both tasks installed reported "看门狗 未安装". Formatting must never
        be able to change what exists.
    #>
    param($Value, [bool]$NeverRun, [string]$Lang)
    if ($null -eq $Value -or "$Value" -eq '') { return '-' }
    if ($NeverRun) { return (Get-KaText 'task.neverRun' -Lang $Lang) }
    $u = [uint64]0
    if (-not [uint64]::TryParse("$Value", [ref]$u)) { return (Get-KaText 'task.unparsable' @{ v = $Value } -Lang $Lang) }
    if ($u -eq 0) { return (Get-KaText 'task.ok' -Lang $Lang) }
    return (Get-KaText 'task.nonzero' @{ hex = ('{0:X}' -f $u) } -Lang $Lang)
}

function Get-KaGuardStatus {
    # Cached: Get-ScheduledTask costs ~1s per probe and the dashboard/tray poll this
    # path continuously. The cache also carries catalog prose, so it is keyed on language.
    param([int]$CacheSeconds = 25)
    $uiLang = Get-KaUiLanguage
    if ($script:KaGuardCache -and ((Get-KaEpoch) - [long]$script:KaGuardCacheEpoch) -lt $CacheSeconds -and
        $script:KaGuardCacheLang -eq $uiLang) {
        return $script:KaGuardCache
    }
    $r = @{ installed = $false; enabled = $false; disabled = @(); tasks = @(); detail = '' }
    foreach ($n in $script:KaTaskNames) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        $lastRun = '-'; $res = '-'; $nextRun = '-'
        try {
            $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            # A task that never ran reports LastRunTime 1999-11-30 (the scheduler's
            # "no value" sentinel), which reads to users as a broken clock.
            $neverRun = -not ($i.LastRunTime -and $i.LastRunTime.Year -ge 2000)
            $noNext = -not ($i.NextRunTime -and $i.NextRunTime.Year -ge 2000)
            $lastRun = if ($neverRun) { Get-KaText 'guard.never' } else { $i.LastRunTime.ToString('yyyy-MM-dd HH:mm') }
            $nextRun = if ($noNext) { Get-KaText 'guard.noNext' } else { $i.NextRunTime.ToString('yyyy-MM-dd HH:mm') }
            $res = Format-KaTaskResult -Value $i.LastTaskResult -NeverRun $neverRun
        } catch { $res = Get-KaText 'guard.infoFail' }
        # A Disabled task keeps its schedule and still reports a future NextRunTime; the
        # scheduler simply refuses to fire it. Printing that clock next to "Disabled"
        # promises a run that cannot happen.
        if ("$($t.State)" -eq 'Disabled') { $nextRun = Get-KaText 'guard.nextDisabled' }
        $r.tasks += [PSCustomObject]@{
            name = $n; state = "$($t.State)"
            lastRun = $lastRun; lastResult = $res; nextRun = $nextRun
        }
    }
    $r.installed = ($r.tasks.Count -eq $script:KaTaskNames.Count)
    # Existence and ability to run are different facts. -RestartCount asks the scheduler to
    # retry a failing task, group policy can disable them, and taskschd.msc is one click
    # away - so "Disabled" is a reachable state on a machine we never touched. A disabled
    # watchdog cannot honour intent.json, and every surface used to call that installed.
    $r.disabled = @($r.tasks | Where-Object { $_.state -eq 'Disabled' } | ForEach-Object { $_.name })
    $r.enabled = ($r.installed -and @($r.disabled).Count -eq 0)
    try {
        $p = Get-KaPath
        $guard = Get-ScheduledTask -TaskName $script:KaTaskNames[0] -ErrorAction SilentlyContinue
        if ($guard) {
            $exec = $guard.Actions[0].Execute
            $arg = "$($guard.Actions[0].Arguments)"
            $pointsHere = $arg -like "*$($p.guard)*"
            $r.detail = Get-KaText $(if ($pointsHere) { 'guard.path.current' } else { 'guard.path.moved' })
            if (-not $pointsHere) { $r.stalePath = $true }
            $r.exec = $exec
        }
    } catch { $r.detail = Get-KaText 'guard.defFail' @{ msg = $_.Exception.Message } }
    # Optional boot task, reported but never gated on: its registration is
    # administrator-only (verified), so most honest installs will not have it.
    $r.boot = @{ present = $false; mode = '' }
    try {
        $bootTask = Get-ScheduledTask -TaskName $script:KaBootTaskName -ErrorAction SilentlyContinue
        if ($bootTask) {
            $r.boot.present = $true
            $r.boot.mode = if ("$($bootTask.Principal.LogonType)" -eq 'S4U') { 's4u' } else { 'interactive' }
        }
    } catch { }
    $script:KaGuardCache = $r
    $script:KaGuardCacheEpoch = Get-KaEpoch
    $script:KaGuardCacheLang = $uiLang
    return $r
}

function Install-KaGuard {
    param([int]$IntervalMin = 10, [switch]$WithBoot)
    $ErrorActionPreferenceOld = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $p = Get-KaPath
        $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # -DataDir travels in the task arguments on purpose. A guard started in session 0,
        # or before this user's profile is fully resolved, would otherwise pick a data root
        # for itself and reconcile an intent.json that belongs to somebody else.
        $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($p.guard)`" " +
               "-DataDir `"$($p.data)`""

        $action = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $p.root
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)

        # -AtLogOn without -User means "at the logon of ANY user", and that is an
        # administrator-only task. A standard account got "Access is denied" until this
        # was scoped to the current user - the whole point is that no elevation is needed.
        $me = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name
        if (-not $me) { $me = $env:USERNAME }

        $trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
        $trigGuard = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

        Register-ScheduledTask -TaskName $script:KaTaskNames[1] -Action $action -Trigger $trigLogon -Settings $settings -Force | Out-Null
        Register-ScheduledTask -TaskName $script:KaTaskNames[0] -Action $action -Trigger $trigGuard -Settings $settings -Force | Out-Null
        # "Run ka.bat guard" is the advice alert.guardDisabled prints, so re-registering has to
        # actually clear the Disabled state. Enable it explicitly rather than betting on what
        # -Force leaves behind; a standard account can always enable its own tasks.
        foreach ($n in $script:KaTaskNames) {
            Enable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Out-Null
        }
        Add-KaLog "guard installed interval=$IntervalMin"

        $boot = $null
        if ($WithBoot) {
            # A boot trigger covers the unattended chain the logon trigger cannot: a
            # power cut rebooted the box and it is waiting at the logon screen. S4U is
            # the only principal that runs there without a stored password, and on a
            # standard account even an interactive-principal boot task is denied, so
            # this degrades stepwise and reports which mode actually registered.
            $boot = @{ mode = ''; ok = $false; reason = '' }
            $trigBoot = New-ScheduledTaskTrigger -AtStartup
            try {
                $pS4u = New-ScheduledTaskPrincipal -UserId $me -LogonType S4U -RunLevel Limited
                Register-ScheduledTask -TaskName $script:KaBootTaskName -Action $action -Trigger $trigBoot `
                    -Settings $settings -Principal $pS4u -Force -ErrorAction Stop | Out-Null
                $boot.mode = 's4u'; $boot.ok = $true
            } catch {
                try {
                    Register-ScheduledTask -TaskName $script:KaBootTaskName -Action $action -Trigger $trigBoot `
                        -Settings $settings -User $me -Force -ErrorAction Stop | Out-Null
                    $boot.mode = 'interactive'; $boot.ok = $true
                } catch {
                    # Scheduler exception messages end with a newline; the reason goes
                    # into a sentence, so it has to arrive trimmed.
                    $boot.mode = 'denied'; $boot.reason = "$($_.Exception.Message)".Trim()
                    Add-KaLog "guard boot-task denied: $($boot.reason)"
                }
            }
            if ($boot.ok) { Add-KaLog "guard boot task installed mode=$($boot.mode)" }
        }
        $script:KaGuardCache = $null
        return @{ Ok = $true; Status = (Get-KaGuardStatus); Boot = $boot }
    } catch {
        return @{ Ok = $false; Reason = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $ErrorActionPreferenceOld
    }
}

function Uninstall-KaGuard {
    $removed = @()
    foreach ($n in (@($script:KaTaskNames) + $script:KaBootTaskName)) {
        try {
            if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop
                $removed += $n
            }
        } catch { return @{ Ok = $false; Reason = $_.Exception.Message } }
    }
    Add-KaLog "guard uninstalled ($($removed -join ', '))"
    $script:KaGuardCache = $null
    return @{ Ok = $true; Removed = $removed }
}

# ---------------------------------------------------------------- efficacy evidence
function Get-KaEventDataMap {
    <#
        Named EventData of one event as name -> text. Read by name from the event XML,
        never from localized message text, so it holds on any UI language. An unreadable
        event yields an empty map instead of throwing: one odd record must not cost the
        user the whole timeline.
    #>
    param($Event)
    $map = @{}
    try {
        foreach ($n in @([xml]$Event.ToXml()).Event.EventData.Data) {
            if ($n -and $n.Name) { $map["$($n.Name)"] = "$($n.InnerText)" }
        }
    } catch { }
    return $map
}

function Get-KaStandbyReasonToken {
    <#
        Kernel-Power 506/507/566 carry a NAMED 'Reason' property, read here from the
        event's named XML data - never from localized message text, so this holds on any
        UI language.

        The numbers are Microsoft's POWER_MONITOR_REQUEST_REASON enum (ntpoapi), the same
        table the SleepStudy exit-reason list publishes. Tokens are that enum's own names,
        so they are traceable to a document rather than to one operator's guess. Codes
        measured on this box (Dell G15 5511, Win11 build 26200) and how each was
        cross-checked. Counts are a snapshot of a ROLLING 14-day window (re-measured
        2026-08-31: 38 enters = 33x12 + 3x3 + 1x11 + 1x15) and will drift - the identity
        sum(reasons) == enters is what is asserted, never the counts:
          3  sc-monitorpower    - produced deliberately (3 seen) by posting WM_SYSCOMMAND
                                  SC_MONITORPOWER, and the kernel's name for it is exactly
                                  that API.
          11 screen-off-request - documented name only; which component raises it is not
                                  documented. Seen once in 14 days, at the incident, and
                                  that one entry has LidOpenState=true.
          12 video-idle         - 33 events, matches the real display-off timeout
                                  (600 s AC / 180 s DC).
          15 lid                - cross-checked by an independent field: every 15 event
                                  also carries LidOpenState=false, and no other code does
                                  (re-verified 2026-08-31 over all 506s: 1/1 and 0
                                  violations). Both 507 exits carrying LidOpenState=false
                                  belong to the same incident - the machine woke lid-shut.
          31/32/33              - on 507 these are the wake source: keyboard, mouse,
                                  touchpad.
        Anything else surfaces as raw "code-N" - greppable, never a guessed label.
    #>
    param([int]$Code)
    switch ($Code) {
        0  { 'unknown' }
        2  { 'remote-connection' }
        3  { 'sc-monitorpower' }
        8  { 'sets' }
        11 { 'screen-off-request' }
        12 { 'video-idle' }
        15 { 'lid' }
        20 { 'sx-transition' }
        21 { 'system-idle' }
        31 { 'input-keyboard' }
        32 { 'input-mouse' }
        33 { 'input-touchpad' }
        default { 'code-{0}' -f $Code }
    }
}

function Get-KaProtectedSpan {
    <#
        "The machine slept" and "the machine slept while a power request was held" are
        different facts, and only the log can tell them apart: it is the one record of when
        this folder's worker asked and when it let go. Without this, a window covering a
        deliberate stop (or an experiment, or the time before the tool was ever started)
        accuses the platform of ignoring a request that nobody had made - which is the same
        class of dishonesty as software claiming it never slept.

        STARTED opens a span. The worker's own STOPPED / EXIT / EARLY-EXIT closes it, and a
        STOP line closes every open span, because that is the CLI stopping all of them at
        once (and it logs its own pid, not theirs, so it cannot be matched per worker).
        Nothing closed a span: it is the live worker if state.json still names that pid and
        the process exists; otherwise the process died without its finally block, so close
        at the last line that mentioned it - "it stopped when we last saw it" beats
        pretending it is still holding the machine awake.

        coveredFrom is bookkeeping for the honest case: rotation keeps one generation, so a
        14-day window only has span data for the tail of it. The whole retained log is
        scanned; the caller decides what to do with coveredFrom.

        state.json is the one exception, and only for the live run: a worker that has been
        holding the machine awake longer than the log reaches would otherwise get no span at
        all, and the UI would call the middle of its own protection "unprotected".
    #>
    $p = Get-KaPath
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $livePid = 0
    $liveStarted = 0
    try {
        $st = Read-KaJson $p.state
        if ($st -and [int]$st.pid -gt 0 -and (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)) {
            $livePid = [int]$st.pid
            $liveStarted = [long]$st.startedEpoch
        }
    } catch { }
    $lines = @()
    foreach ($f in @("$($p.log).1", $p.log)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $lines += @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction Stop) } catch { }
    }
    $spans = @(); $open = @{}; $lastSeen = @{}; $first = 0
    $culture = [Globalization.CultureInfo]::InvariantCulture
    foreach ($line in $lines) {
        if ("$line" -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$') { continue }
        $epoch = 0
        try {
            $dt = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $culture)
            $epoch = [DateTimeOffset]::new($dt).ToUnixTimeSeconds()
        } catch { continue }
        if ($first -eq 0 -or $epoch -lt $first) { $first = $epoch }
        $body = $Matches[2]
        if ($body -match '^STOP\s') {
            # The CLI's own pid is on this line, so it cannot be matched to a worker - but
            # what it did was stop every worker this folder had. STOPPED / STOP-REQUEST are
            # different words and must not be caught here: the request only sets the flag,
            # the release happens when the worker writes STOPPED.
            foreach ($k in @($open.Keys)) { $spans += ,@([long]$open[$k], [long]$epoch); $open.Remove($k) }
            continue
        }
        if ($body -notmatch 'pid=(\d+)') { continue }
        $who = [int]$Matches[1]
        if ($body -match '^STARTED\b') {
            if (-not $open.ContainsKey($who)) { $open[$who] = $epoch }
            $lastSeen[$who] = $epoch
            continue
        }
        if ($open.ContainsKey($who)) { $lastSeen[$who] = $epoch }
        if ($body -match '^(STOPPED|EXIT|EARLY-EXIT)\b' -and $open.ContainsKey($who)) {
            $spans += ,@([long]$open[$who], [long]$epoch)
            $open.Remove($who)
        }
    }
    foreach ($k in @($open.Keys)) {
        $to = $(if ([int]$k -eq $livePid) { $now } elseif ($lastSeen.ContainsKey($k)) { [long]$lastSeen[$k] } else { [long]$open[$k] })
        if ($to -gt [long]$open[$k]) { $spans += ,@([long]$open[$k], $to) }
    }
    if ($livePid -gt 0 -and $liveStarted -gt 0 -and -not $lastSeen.ContainsKey($livePid)) {
        # Live pid, but the log no longer holds its STARTED line. "The request is held right
        # now" is then a fact from state.json plus Get-Process, not a guess - so the span
        # starts at the reported start instead of vanishing.
        $spans += ,@($liveStarted, $now)
        if ($first -eq 0 -or $liveStarted -lt $first) { $first = $liveStarted }
    }
    # Merge, so "inside a span" is one sorted scan and the panel draws one bar.
    $merged = @()
    foreach ($s in @($spans | Sort-Object { $_[0] })) {
        if ($merged.Count -and [long]$s[0] -le [long]$merged[-1][1]) {
            if ([long]$s[1] -gt [long]$merged[-1][1]) { $merged[-1][1] = [long]$s[1] }
        } else { $merged += ,@([long]$s[0], [long]$s[1]) }
    }
    return [PSCustomObject]@{
        spans       = @($merged | ForEach-Object { [PSCustomObject]@{ from = [long]$_[0]; to = [long]$_[1] } })
        coveredFrom = [long]$first
        known       = ($first -gt 0)
    }
}

function Get-KaSpanMatch {
    <#
        1 = inside a protected span, 0 = covered time with no span, -1 = not covered by the
        retained log. The third answer has to stay separate: "we cannot tell" reported as
        "nothing was asking" is how a tool starts believing its own alibi.
    #>
    param([long]$Epoch, $Spans, [long]$CoveredFrom)
    if ($Epoch -lt $CoveredFrom) { return -1 }
    foreach ($sp in @($Spans)) {
        if ($Epoch -ge [long]$sp.from -and $Epoch -le [long]$sp.to) { return 1 }
    }
    return 0
}

function Get-KaSleepEventKind {
    <#
        Pure: event id + provider name -> the kind this tool counts by, $null for an event it
        does not count. No machine access, no dictionary, so a fixture can drive it.

        Microsoft-Windows-Kernel-Power 42 is "the system is entering a sleep state" and is the
        only record a classic S3 machine leaves behind. It used to map to `sleepResume`, which
        put every real S3 entry into `exits` and left `enters` at zero - a laptop that slept
        every night was reported as "no standby recorded, the protection is working".
        Power-Troubleshooter 42 is the resume report of that same episode. The two ids are
        identical and only the provider name tells them apart, so an id must never classify
        alone.
    #>
    param([int]$Id, [string]$ProviderName)
    $pn = "$ProviderName"
    switch ($Id) {
        506 { 'standbyEnter' }
        507 { 'standbyExit' }
        566 { 'session' }
        42  { if ($pn -like '*Power-Troubleshooter*') { 'sleepResume' }
              elseif ($pn -like 'Microsoft-Windows-Kernel-Power*') { 's3Enter' } }
        1   { if ($pn -like '*Power-Troubleshooter*') { 'wakeFromSleep' } }
        131 { 'resumeFromModernStandby' }
    }
}

function Add-KaSleepCount {
    <#
        Pure: one normalised event into the accumulator $R, mutated in place. $Evt carries what
        the query loop read off the record - kind, epoch, reason token, lid, session types and
        `prot` (1 = a request was held at that instant, 0 = none was, -1 = the retained log
        cannot say).

        Two instrument families, two identities, deliberately not merged:
          bypasses + unprotectedSleeps + spanUnknown == realSleeps   (566 session instrument)
          s3Bypasses + s3Unprotected + s3SpanUnknown == s3Enters     (Kernel-Power 42)
        Folding S3 into `enters` would make the first identity false on every pure-S3 box,
        where 506 never fires at all - and those identities are what makes every other number
        here trustworthy. `s3Exits` counts resume reports (Power-Troubleshooter 42) only where
        the machine declares S3; on a hybrid box a resume report cannot be attributed to one
        sleep state, so that number is a bound and the interface must not present it as a
        pairing.
    #>
    param($R, $Evt, [bool]$CapsS3 = $false)
    $kind = "$($Evt.kind)"
    if ($kind -eq 'standbyEnter') {
        # Only entries feed the aggregate, so sum(reasons) == enters holds. A 506 without a
        # readable Reason goes into its own bucket rather than disappearing - the identity is
        # what makes every other number trustworthy.
        $R['enters'] += 1
        $token = $(if ($Evt.reason) { "$($Evt.reason)" } else { 'no-reason' })
        $R['reasons'][$token] = 1 + [int]$R['reasons'][$token]
    }
    if ($kind -eq 's3Enter') {
        $R['s3Enters'] += 1
        if ([int]$Evt.prot -eq 1) { $R['s3Bypasses'] += 1 }
        elseif ([int]$Evt.prot -eq 0) { $R['s3Unprotected'] += 1 }
        else { $R['s3SpanUnknown'] += 1 }
    }
    if ($kind -eq 'sleepResume' -and $CapsS3) { $R['s3Exits'] += 1 }
    if ($kind -eq 'session') {
        $R['sessionKnown'] = $true
        if ([int]$Evt.to -eq 1) {
            $R['screenOffs'] += 1
            $R['lastScreenOffEpoch'] = [long]$Evt.epoch
        } elseif ([int]$Evt.to -eq 2) {
            $R['realSleeps'] += 1
            if ([int]$Evt.prot -eq 1) { $R['bypasses'] += 1 }
            elseif ([int]$Evt.prot -eq 0) { $R['unprotectedSleeps'] += 1 }
            else { $R['spanUnknown'] += 1 }
            # The gap that matters for remote access: display off, then the machine leaves.
            # Anything past two minutes is a different story and is not counted as one chain.
            $last = [long]$R['lastScreenOffEpoch']
            $delta = [long]$Evt.epoch - $last
            if ($last -gt 0 -and $delta -ge 0 -and $delta -le 120) {
                $R['screenOffToSleep'] += 1
                $R['lastScreenOffToSleepSecs'] = $delta
                # One display-off accounts for one departure, never two.
                $R['lastScreenOffEpoch'] = 0
            }
        } elseif ($null -ne $Evt.to) {
            # Back to an active session: that display-off episode is closed, so a later sleep
            # must not be charged to it. ($null -eq 0 is true in PowerShell, hence the
            # explicit null test.)
            $R['lastScreenOffEpoch'] = 0
        }
    }
    if ($kind -in @('standbyExit', 'sleepResume', 'wakeFromSleep', 'resumeFromModernStandby')) { $R['exits'] += 1 }
    return $R
}

function Update-KaSleepInstrument {
    <#
        Declares what this machine's own power states made observable, so the interface can
        say "I could not see it" instead of "it did not happen". `canSee` is the whole point:
        it is true exactly when every sleep state this machine declares would leave a record
        this code reads. It is not a claim that the machine did not sleep.

        Pure by construction - the caller hands in the capability bits and the build number,
        so a fixture can walk every machine class without a powercfg call.
    #>
    param($R, [bool]$CapsS3, [bool]$CapsS0Idle, [bool]$CapsKnown, [int]$OsBuild)
    $R['capsS3'] = [bool]$CapsS3
    $R['capsS0Idle'] = [bool]$CapsS0Idle
    $R['capsKnown'] = [bool]$CapsKnown
    $R['hybridSleep'] = ([bool]$CapsS3 -and [bool]$CapsS0Idle)
    $R['osBuild'] = $OsBuild
    $classes = @()
    if ($CapsS0Idle) { $classes += 's0-idle' }
    if ($CapsS3) { $classes += 's3' }
    if (-not $CapsKnown) { $classes = @('unknown') }
    $R['sleepClasses'] = $classes
    # The 42 instrument needs a readable Kernel-Power log - that is what `queriesOk` already
    # means. The 566 instrument either produced session records or it did not, and on an
    # S0-idle machine nothing else answers "did it leave or did the screen just go dark".
    $canSee = [bool]$CapsKnown -and
              (-not $CapsS3 -or [bool]$R['queriesOk']) -and
              (-not $CapsS0Idle -or [bool]$R['sessionKnown'])
    $R['canSee'] = $canSee
    $R['instrument'] = $(if (-not $canSee) { 'blind' }
        elseif ($R['sessionKnown'] -and $CapsS3) { 'both' }
        elseif ($R['sessionKnown']) { 'full' }
        elseif ($CapsS3) { 's3-only' }
        else { 'no-session-events' })
    return $R
}

function Get-KaSleepEvidence {
    <#
        The point of the product is "the machine did not fall asleep". That is only a
        claim until it is checked against the kernel power log, which a normal user can
        read. Returns how often the machine entered Modern Standby / slept since $Since.

        Two sources, because one is not enough. 506 says "a low-power session began" and
        fires for a plain display-off too, so `enters` alone overstates sleeping - that
        cost this repo a wrong post-mortem. 566 names the session it moved between
        (PreviousSessionType/NextSessionType: 0=active, 1=screen off, 2=sleep), which is
        what separates "the screen went dark" from "the machine actually left me", and it
        is where `screenOffs` / `realSleeps` come from. `sessionKnown` says whether 566
        exists on this platform at all, so a UI never concludes "it only dimmed" from an
        absence of records.

        A real sleep is only a bypass if this tool was holding a request at that instant.
        Get-KaProtectedSpan answers that from ka.log; `spanUnknown` counts the sleeps this
        box cannot place (outside the log's retained history), so the UI can say "not known"
        instead of picking between blame and innocence.

        A third instrument covers the machines 506 and 566 never speak for. Microsoft-Windows-
        Kernel-Power 42 is the record a classic S3 box leaves when it enters sleep, and it is
        the only one - so on such a machine the two counters above both stay at zero while the
        laptop sleeps every night. That is counted in `s3Enters`, with its own parallel
        identity, and never folded into `enters`. Update-KaSleepInstrument then states which
        of these instruments this machine's own declared sleep states made observable, so a
        green "no sleep recorded" can only appear where something would have recorded it.
    #>
    param([DateTime]$Since, [int]$Max = 1000)
    $r = @{ queriesOk = $false; enters = 0; exits = 0; wakeups = 0; events = @(); reasons = @{}
            reason = ''; screenOffs = 0; realSleeps = 0; sessionKnown = $false
            screenOffToSleep = 0; lastScreenOffToSleepSecs = 0; truncated = $false; max = $Max
            bypasses = 0; unprotectedSleeps = 0; spanUnknown = 0
            spans = @(); spansCoveredFrom = 0; spansKnown = $false
            lastScreenOffEpoch = 0
            s3Enters = 0; s3Exits = 0; s3Bypasses = 0; s3Unprotected = 0; s3SpanUnknown = 0
            instrument = ''; canSee = $false; capsS3 = $false; capsS0Idle = $false
            capsKnown = $false; hybridSleep = $false; osBuild = 0; sleepClasses = @() }
    $spans = @()
    try {
        $spanInfo = Get-KaProtectedSpan
        $spans = @($spanInfo.spans)
        $r.spans = $spans
        $r.spansCoveredFrom = [long]$spanInfo.coveredFrom
        $r.spansKnown = [bool]$spanInfo.known
    } catch { }
    # What this machine says it is capable of, before any log is read. Get-KaPowerCaps is the
    # kernel's own answer and costs no subprocess; the localized powercfg /a parse only runs
    # when that call is unavailable, same order Get-KaReport uses.
    $capsS3 = $false; $capsS0Idle = $false; $capsKnown = $false; $osBuild = 0
    try {
        $caps = Get-KaPowerCaps
        if ($caps.source -eq 'api') {
            $capsS3 = [bool]$caps.s3; $capsS0Idle = [bool]$caps.aoAc; $capsKnown = $true
        } else {
            $states = Get-KaSleepStates
            $capsS3 = [bool]$states.s3; $capsS0Idle = [bool]$states.s0; $capsKnown = [bool]$states.known
        }
        # A value name, not a label: unaffected by language, and cheaper than a WMI query on
        # a path the panel polls every couple of seconds. 0 means "not read", not "old OS".
        try {
            $b = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber
            if ("$b" -match '^\d+$') { $osBuild = [int]$b }
        } catch { }
    } catch { }
    try {
        # Filter on the ids the classifier below can use. Asking for "every Kernel-Power
        # record since $Since" let unrelated events eat the -MaxEvents budget and silently
        # dropped the oldest 506s: 37 real enters read back as 25 over 14 days.
        $ev = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'System'
                    ProviderName = 'Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-Power-Troubleshooter'
                    Id = @(1, 42, 131, 506, 507, 566)
                    StartTime = $Since
                } -ErrorAction SilentlyContinue -MaxEvents $Max)
        $r.queriesOk = $true
        $r.truncated = ($ev.Count -ge $Max)
        # Newest-first is what Get-WinEvent hands back; the chain below walks forward in
        # time and remembers the previous display-off, so it needs ascending order.
        $ev = @($ev | Sort-Object TimeCreated)
        foreach ($e in $ev) {
            # Id alone cannot classify: 42 means "entering sleep" from Kernel-Power and
            # "here is the resume report" from Power-Troubleshooter.
            $kind = Get-KaSleepEventKind -Id ([int]$e.Id) -ProviderName $e.ProviderName
            if (-not $kind) { continue }
            $epoch = [DateTimeOffset]::new($e.TimeCreated).ToUnixTimeSeconds()
            $data = Get-KaEventDataMap $e
            # LidOpenState and ExternalMonitorConnectedState are named properties, so no
            # message text is parsed. Absent fields stay '' - "not read" is not the same
            # answer as the actual value.
            $lid = ''
            if ($data['LidOpenState'] -eq 'true') { $lid = 'open' }
            elseif ($data['LidOpenState'] -eq 'false') { $lid = 'closed' }
            $extMon = ''
            if ($data['ExternalMonitorConnectedState'] -eq 'true') { $extMon = 'true' }
            elseif ($data['ExternalMonitorConnectedState'] -eq 'false') { $extMon = 'false' }
            $evtReason = ''
            # One enum names both directions: on 506 what pushed the machine into a
            # low-power session, on 507 what pulled it out of one (31 = keyboard input).
            if ($data['Reason'] -match '^\d+$') { $evtReason = Get-KaStandbyReasonToken -Code ([int]$Matches[0]) }
            # Was this instant inside a run where the request was actually held? -1 means
            # the log does not reach back this far, which is neither blame nor innocence.
            $prot = $(if ($r.spansKnown) { Get-KaSpanMatch -Epoch $epoch -Spans $spans -CoveredFrom ([long]$r.spansCoveredFrom) } else { -1 })
            $from = $null; $to = $null
            if ($kind -eq 'session') {
                if ($data['PreviousSessionType'] -match '^\d+$') { $from = [int]$Matches[0] }
                if ($data['NextSessionType'] -match '^\d+$') { $to = [int]$Matches[0] }
            }
            $evt = [PSCustomObject]@{
                epoch = $epoch
                id = [int]$e.Id
                kind = $kind
                reason = $evtReason
                lid = $lid
                extMon = $extMon
                from = $from
                to = $to
                prot = $prot
            }
            $r = Add-KaSleepCount -R $r -Evt $evt -CapsS3 $capsS3
            $r['events'] += $evt
        }
        $r['events'] = @($r['events'] | Sort-Object epoch)
        if (-not $r.sessionKnown) {
            # No 566 on this platform, so "did it really sleep" has no answer and `enters`
            # is the best available proxy. Classify those by span so the blame/innocence
            # split still exists here - same subset as `enters`, so the numbers add up.
            foreach ($e in @($r.events)) {
                if ($e.kind -ne 'standbyEnter') { continue }
                if ($e.prot -eq 1) { $r['bypasses'] += 1 }
                elseif ($e.prot -eq 0) { $r['unprotectedSleeps'] += 1 }
                else { $r['spanUnknown'] += 1 }
            }
        }
    } catch {
        # Some error records arrive with an empty Message (observed live: the panel then read
        # "unknown reason"). The type name is still a machine token and still better than silence.
        $msg = "$($_.Exception.Message)".Trim()
        if (-not $msg) { $msg = "$($_.Exception.GetType().FullName)" }
        $r.reason = $msg
    }
    # Outside the try: a failed query is exactly the case that has to be declared blind, and
    # skipping the call there would leave `instrument` '' - which no surface can render.
    $r = Update-KaSleepInstrument -R $r -CapsS3 $capsS3 -CapsS0Idle $capsS0Idle `
                                  -CapsKnown $capsKnown -OsBuild $osBuild
    return $r
}

# ---------------------------------------------------------------- competing requests
function Get-KaCompetitor {
    <#
        If another keep-awake tool holds its own power request, stopping ours will not
        let the machine sleep, and the user will blame this tool for it. Name matching
        can only say "suspected"; `powercfg /requests` is the authoritative list and
        needs elevation, so we hand the user the exact command.
    #>
    $known = @{
        'PowerToys.Awake' = 'PowerToys Awake'
        'PowerToys'       = @{ id = 'competitor.powerToys' }
        'awake'           = 'AWake / Awake'
        'caffeine'        = 'Caffeine'
        'MouseJiggler'    = 'Mouse Jiggler'
        'moujie64'        = 'Mouse Jiggler'
        'KeepAwake'       = 'KeepAwake'
        'SleepBlocker'    = 'SleepBlocker'
        'presentationsettings' = @{ id = 'competitor.presentation' }
    }
    $found = @()
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            $n = $proc.ProcessName
            if ($known.ContainsKey($n)) {
                $found += [PSCustomObject]@{ name = $n; label = $known[$n]; pid = $proc.Id }
            }
        }
    } catch { }
    return [PSCustomObject]@{
        suspected = @($found)
        confirm   = @{ id = 'competitor.confirm' }
    }
}

# ---------------------------------------------------------------- composite state
function Get-KaFullState {
    param([switch]$Quiet)
    $p = Get-KaPath
    $cfg = Get-KaConfig
    # One process enumeration, then partition: the panel polls this every few seconds and
    # a second Win32_Process query per poll is pure waste.
    $all = @(Get-KaWorker -AnyPath)
    $workers = @($all | Where-Object { $_.Mine })
    $alien = @($all | Where-Object { ($_.Root -or $_.Data) -and -not $_.Mine } | ForEach-Object {
        [PSCustomObject]@{ pid = $_.Pid; root = $_.Root; data = $_.Data
                           startEpoch = $_.StartEpoch
                           startedAt = (ConvertFrom-KaEpoch $_.StartEpoch) }
    })
    $st = Read-KaJson $p.state
    $live = ($workers.Count -gt 0) -and $st -and ([int]$st.pid -in @($workers | ForEach-Object { $_.Pid }))
    $bat = Get-KaBattery
    $idle = Get-KaIdleSeconds
    $intent = Get-KaIntent
    # One reading, shared by the payload below and the alert: the panel polls this every
    # couple of seconds, and logonui.exe presence is the same fact either way.
    $session = Get-KaSession

    $stateAge = if ($live) { (Get-KaEpoch) - [long]$st.lastTickEpoch } else { 0 }

    $sinceEpoch = 0
    if ($live) { $sinceEpoch = [long]$st.startedEpoch }
    $since = if ($sinceEpoch -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds($sinceEpoch)).LocalDateTime } else { (Get-Date).AddHours(-2) }
    $evidence = if ($Quiet -or -not $live) { $null } else { Get-KaSleepEvidence -Since $since }

    $expiresEpoch = if ($live) { [long]$st.expiresEpoch } else { 0 }
    $minutesLeft = if ($expiresEpoch -gt 0) { [math]::Max(0, [int][math]::Ceiling(($expiresEpoch - (Get-KaEpoch)) / 60)) } else { 0 }

    $alert = @()
    # Deliberately outside `if ($live)`: the dangerous case is this copy saying "stopped"
    # while a second one still holds the power request. Shaped exactly like Get-KaReport's
    # risk entries - an id plus the numbers - so no surface can be handed a sentence it
    # cannot translate.
    if ($alien.Count -gt 0) {
        $where = (@($alien | ForEach-Object { if ($_.data) { $_.data } else { $_.root } }) | Select-Object -Unique) -join ' | '
        $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.foreignWorkers'
                                     count = $alien.Count; roots = $where }
    }
    # The record layer failing is a different fact from the protection failing, and both
    # have to be said. A worker that is running but cannot write state.json looks exactly
    # like "not running" to every other surface, so this pair of alerts is what keeps the
    # read-only-install case honest instead of merely green or merely red.
    if ($script:KaDataError) {
        $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.dataDirUnwritable'
                                     path = $p.data; error = $script:KaDataError }
    }
    if ($workers.Count -gt 0 -and -not $st) {
        $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.stateUnrecorded'
                                     count = $workers.Count; path = $p.state }
    }
    if ($script:KaMachineError) {
        $alert += [PSCustomObject]@{ level = 'warn'; id = 'alert.machineDirUnwritable'
                                     path = $p.machineRoot; error = $script:KaMachineError }
    }
    # A watchdog that exists but is switched off is not a watchdog. Existence used to be the
    # whole test, so a machine whose tasks were disabled - by the scheduler's failure policy,
    # by group policy, or by a person in taskschd.msc - still read "installed" on all three
    # surfaces while nothing would ever re-raise protection again.
    $guard = Get-KaGuardStatus
    if ($guard.installed -and -not $guard.enabled) {
        $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.guardDisabled'
                                     names = (@($guard.disabled) -join ', ') }
    }
    if ($live) {
        if ($bat.hasBattery -and -not $bat.acOnline -and $bat.percent -ge 0 -and $bat.percent -le $cfg.batteryFloorPercent) {
            $alert += [PSCustomObject]@{ level = 'warn'; id = 'alert.batteryFloor'; pct = $bat.percent }
        }
        if ($evidence) {
            # `enters` counts 506, and a 506 fires for a plain display-off too, so alerting on
            # it accused the platform of ignoring the request every time the monitor timed out -
            # and on a classic-S3 box, which logs no 506 at all, it stayed silent no matter how
            # often the machine slept. Only a sleep that happened while the request was held is
            # a bypass, and each instrument has its own count of those.
            $byp = [int]$evidence.bypasses + [int]$evidence.s3Bypasses
            if ($byp -gt 0) {
                $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.sleepEvidence'; n = $byp }
            }
            # "I could not see it" is a different fact from "it did not happen", and the panel
            # has to carry it while protection is running or its green looks like a guarantee.
            if (-not $evidence.canSee) {
                $alert += [PSCustomObject]@{ level = 'warn'; id = 'alert.evidenceBlind'
                                             instrument = "$($evidence.instrument)"
                                             queriesOk = [bool]$evidence.queriesOk }
            }
            $lidN = 0
            if ($evidence.reasons -and $evidence.reasons['lid']) { $lidN = [int]$evidence.reasons['lid'] }
            if ($lidN -gt 0) {
                # The lid is the one standby path a power request cannot block (hardware
                # panel-off). Naming it turns a bare count into something the user can act
                # on: keep the lid open for unattended remote access.
                $alert += [PSCustomObject]@{ level = 'warn'; id = 'alert.standbyLid'; count = $lidN }
            }
        }
        if ($session.lockScreen) {
            # The one failure mode where every other readout still says "protected": the
            # power request holds, the machine stays up, and the remote client meets a
            # lock screen. Say it while it is true instead of leaving it to a counter.
            $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.sessionLocked';
                                         count = [int]$st.lockSkips }
        }
        if ("$($st.note)" -eq 'il-mismatch') {
            # UIPI swallowing the heartbeat is the same class of blind failure: the power
            # request holds, every engine reads green, and only the lock screen proves it
            # happened. Fire on the live note, not on the cumulative ilSkips - a cycle
            # that reaches the input API clears the note, so this alert walks itself back
            # once the elevated foreground app is gone, while a counter-based alert would
            # nag forever for a one-time skip.
            $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.uipiBlocked';
                                         count = [int]$st.ilSkips }
        }
        if ($workers.Count -gt 1) {
            $alert += [PSCustomObject]@{ level = 'bad'; id = 'alert.multiWorker'; count = $workers.Count }
        }
        if ($live -and $stateAge -gt 45) {
            $alert += [PSCustomObject]@{ level = 'warn'; id = 'alert.staleState' }
        }
    }

    $elevated = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    return [PSCustomObject]@{
        nowEpoch      = Get-KaEpoch
        version       = $script:KaVersion
        running       = [bool]$live
        workerCount   = $workers.Count
        foreignWorkers = $alien
        worker        = if ($live) { $st } else { $null }
        orphans       = @($workers | ForEach-Object { @{ pid = $_.Pid; startEpoch = $_.StartEpoch } })
        idleSec       = [int]$idle
        battery       = $bat
        session       = $session
        config        = $cfg
        intent        = $intent
        minutesLeft   = $minutesLeft
        guard         = $guard
        evidence      = $evidence
        competitors   = if ($Quiet) { $null } else { Get-KaCompetitor }
        alert         = @($alert)
        elevated      = $elevated
        root          = $p.root
        programRoot   = $p.program
        dataRoot      = $p.data
        machineRoot   = $p.machineRoot
        dataError     = $script:KaDataError
    }
}

# ---------------------------------------------------------------- orchestration
function Start-KaProtection {
    <#
        The one entry point for "protect now" - CLI, dashboard, tray and watchdog all
        call this so they cannot drift apart.

        A live worker cannot be re-parameterised from outside. The previous build answered
        a second start with "already running", so config edits appeared to apply and then
        silently did nothing. Here a differing request restarts the worker instead.
    #>
    param([double]$Minutes = 0, [hashtable]$Override = @{})

    $cfg = Get-KaConfig
    foreach ($k in $Override.Keys) { if ($cfg.ContainsKey($k)) { $cfg[$k] = $Override[$k] } }

    $p = Get-KaPath
    $restarted = $false
    $existing = @(Get-KaWorker)
    if ($existing.Count -gt 0) {
        $st = Read-KaJson $p.state
        $wantExp = if ($Minutes -gt 0) { (Get-KaEpoch) + [long]($Minutes * 60) } else { 0 }
        $differs = $false
        if (-not $st) {
            # A worker exists but never reported: cannot reason about its parameters.
            $differs = $true
        } else {
            foreach ($pair in @(
                    @([bool]$st.keepDisplayOn, [bool]$cfg.keepDisplayOn),
                    @([bool]$st.antiLock,      [bool]$cfg.antiLock),
                    @([bool]$st.awayMode,      [bool]$cfg.awayMode),
                    @([string]$st.antiLockMethod, [string]$cfg.antiLockMethod),
                    @([int]$st.antiLockInterval,  [int]$cfg.antiLockIntervalSec),
                    @([int]$st.batteryFloor,      [int]$cfg.batteryFloorPercent),
                    @([long]$st.expiresEpoch,     [long]$wantExp))) {
                if ($pair[0] -ne $pair[1]) { $differs = $true; break }
            }
        }
        if ($differs) {
            [void](Stop-KaWorker -Reason 'restart')
            $restarted = $true
        }
    }

    $r = Start-KaWorker -Minutes $Minutes -Override $Override
    if ($r.Ok) {
        $intentOk = Set-KaIntent -Desired 'awake' -Minutes $Minutes
        $r['intentWritten'] = [bool]$intentOk
        if (-not $intentOk) {
            # Losing the intent is not losing the protection, but it does mean the next
            # reboot or the next guard pass has nothing to honour. Say it while it is true.
            Add-KaLog "INTENT-WRITE-FAILED pid=$PID want=awake err=$((Get-KaLastWriteError))"
        }
        $r['restarted'] = $restarted
        $r['applied'] = @{
            keepDisplayOn = [bool]$cfg.keepDisplayOn
            antiLock      = [bool]$cfg.antiLock
            antiLockMethod = $cfg.antiLockMethod
            antiLockIntervalSec = [int]$cfg.antiLockIntervalSec
            awayMode      = [bool]$cfg.awayMode
            batteryFloorPercent = [int]$cfg.batteryFloorPercent
            batteryAllowDisplayOff = [bool]$cfg.batteryAllowDisplayOff
        }
    }
    return $r
}

function Stop-KaProtection {
    param([string]$Reason = 'user')
    # Intent first: if the guard task fires between the stop and the kill it must read
    # "off", otherwise it starts the worker straight back up again.
    $intentOk = Set-KaIntent -Desired 'off'
    $r = Stop-KaWorker -Reason $Reason
    $r['intentWritten'] = [bool]$intentOk
    if (-not $intentOk) {
        Add-KaLog "INTENT-WRITE-FAILED pid=$PID want=off err=$((Get-KaLastWriteError))"
        # The one consequence worth spelling out in the log: this stop can lose the race.
        Add-KaLog "STOP-INTENT-UNRECORDED forced=$($r.Forced) reason=$Reason"
    }
    Add-KaLog "STOP pid=$PID forced=$($r.Forced) reason=$Reason"
    return $r
}

function Reconcile-KaProtection {
    <#
        The watchdog's whole job, as a comparison between two facts:
          intent.json  = what the user last asked for
          a live worker = what is actually running
        Starting protection unconditionally - which is what the old guard did - resurrects
        protection the user deliberately stopped, so `stop` could never win a race with
        the 10 minute timer. Returns what it did so the caller can log it.
    #>
    param([int]$StaleTickSec = 90)
    $intent = Get-KaIntent
    $workers = @(Get-KaWorker)
    $now = Get-KaEpoch
    $intentUnwritable = $false
    $wantOn = ("$($intent.desired)" -eq 'awake')
    $minutes = 0

    if ($intent.expired) {
        # Persist once so the file on disk stops claiming a run the user timed out.
        if (-not (Set-KaIntent -Desired 'off')) {
            $intentUnwritable = $true
            Add-KaLog "INTENT-WRITE-FAILED pid=$PID want=off-expired err=$((Get-KaLastWriteError))"
        }
    }
    if ($wantOn) {
        $exp = [long]$intent.expiresEpoch
        if ($exp -gt 0 -and $exp -gt $now) {
            $minutes = [math]::Round(($exp - $now) / 60.0, 2)
        }
    }

    $st = Read-KaJson (Get-KaPath).state
    $livePids = @($workers | ForEach-Object { $_.Pid })
    $alive = ($livePids.Count -gt 0)
    if ($alive -and $st -and ([int]$st.pid -in $livePids) -and (($now - [long]$st.lastTickEpoch) -gt $StaleTickSec)) {
        $alive = $false      # wedged: reporting stopped, so treat it as dead and replace it
        # Reap it first. Start-KaWorker matches workers by command line, not by the state
        # file, so it would otherwise answer "already running" about the very process we
        # just declared dead - and the guard would log a recovery that never happened.
        [void](Stop-KaWorker -Reason 'guard:stale')
        $livePids = @()
    }

    $action = 'none'
    if ($wantOn -and -not $alive) {
        $r = Start-KaWorker -Minutes $minutes
        $action = if ($r.Ok) { 'started' } else { "start-failed: $($r.Reason)" }
    } elseif (-not $wantOn -and $alive) {
        [void](Stop-KaWorker -Reason 'guard:intent-off')
        $action = 'stopped'
    } elseif ($wantOn -and $alive) {
        $keep = if ($st -and ([int]$st.pid -in $livePids)) { [int]$st.pid } else { $livePids[0] }
        # Adopt a session-0 worker left by the optional boot task. Must run before the
        # dedup branch: adoption restarts the keeper itself, and deduping around it
        # would reconcile the duplicates first and then kill the one we just moved.
        $workerSess = -1
        $mySess = -1
        try { $workerSess = [int](Get-Process -Id $keep -ErrorAction Stop).SessionId } catch { }
        try { $mySess = [int](Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { }
        if (Get-KaSessionAdoption -MySessionId $mySess -WorkerSessionId $workerSess) {
            [void](Stop-KaWorker -Reason 'guard:session')
            $r = Start-KaWorker -Minutes $minutes
            $action = if ($r.Ok) { 'adopted-session' } else { "adopt-failed: $($r.Reason)" }
        } elseif ($livePids.Count -gt 1) {
            # Keep the worker the state file reports — that is the one holding the mutex and
            # therefore the power request. Reaping it while a hollow duplicate survived would
            # silently lose protection, and only the mutex owner ever writes state.json.
            $failed = 0
            foreach ($extra in @($livePids | Where-Object { $_ -ne $keep })) {
                try { Stop-Process -Id $extra -Force -ErrorAction Stop } catch { $failed++ }
            }
            $action = if ($failed -eq 0) { 'deduped' } else { "dedup-incomplete left=$failed" }
        }
    }

    return @{
        action   = $action
        wantOn   = $wantOn
        alive    = $alive
        workers  = $livePids.Count
        minutes  = $minutes
        at       = $now
        intentUnwritable = [bool]$intentUnwritable
    }
}

# ---------------------------------------------------------------- environment report
function Get-KaLidRisk {
    <#
        SETS cannot intercept a lid close: the lid action runs at firmware/ACPI level,
        above any power request, so the only honest defence is to say so. The lid's
        open/closed STATE is not readable without OEM-specific WMI (probed: root/wmi
        ships no standard lid class), so this reports the CONFIGURED action per power
        source and never invents a state read. $LidPresent is three-valued: the kernel
        capability bit can prove a lid present, prove it absent, or be unreadable ($null),
        and only a proven-absent lid drops the risk.
    #>
    param($LidAc, $LidDc, $LidPresent)
    # Only a proven-absent lid suppresses the risk. $null means the capability bit could not be
    # read, and a laptop we failed to probe still deserves the warning.
    if ($null -ne $LidPresent -and -not [bool]$LidPresent) { return @() }
    if ($null -eq $LidAc -and $null -eq $LidDc) {
        return @(@{ id = 'report.risk.lid-hidden' })
    }
    $vals = @()
    if ($null -ne $LidAc -and [int]$LidAc -ne 0) { $vals += "ac=$([int]$LidAc)" }
    if ($null -ne $LidDc -and [int]$LidDc -ne 0) { $vals += "dc=$([int]$LidDc)" }
    if (-not $vals.Count) { return @() }
    return @(@{ id = 'report.risk.lid-action'; value = ($vals -join '/') })
}

function Get-KaLidForecast {
    <#
        The one question a lid owner asks before closing it: "what happens if I close
        it NOW?" Assembled from facts that need no elevation and no real-time lid
        sensor (there is no standard non-admin lid-state read - probed repeatedly):
        the CONFIGURED LIDACTION per power tier (powercfg), which tier is live right
        now (GetSystemPowerStatus), and the event log's per-event LidOpenState as
        HISTORY, never presented as a live reading. "Has this setting been tested"
        is deliberately three-valued, because absence of evidence is not success:
          none       no ka-lid-backup.json (never written via lid apply)
          unobserved an apply record exists, but no lid-closed event followed it yet
          no-sleep   a lid-closed event after the apply, and that moment did NOT
                     produce a lid standby - one observed moment, not a guarantee
          slept      a lid standby happened after the apply - the platform ignored
                     the write, or the configured action itself is sleep
          unknown    the event log could not be read
    #>
    param($LidAc, $LidDc, $LidPresent, $Battery)

    if ($null -ne $LidPresent -and -not [bool]$LidPresent) {
        return @{ lidPresent = $false; lidKnown = $true }
    }

    $f = @{
        # $null is a claim of ignorance, not a falsy "no": the consumer has to say it could
        # not tell, because a lidless reading and an unreadable bit lead to different advice.
        lidPresent     = $(if ($null -eq $LidPresent) { $null } else { $true })
        lidKnown       = ($null -ne $LidPresent)
        readable       = ($null -ne $LidAc)
        actionAc       = $LidAc
        actionDc       = $LidDc
        acOnline       = $true
        batteryPercent = -1
    }
    if ($Battery -and $Battery.known) {
        $f.acOnline = [bool]$Battery.acOnline
        $f.batteryPercent = [int]$Battery.percent
    }

    $apply = 0
    try {
        $bp = Get-Content (Get-KaPath).lidBackup -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($bp.capturedAt) { $apply = [DateTimeOffset]::Parse("$($bp.capturedAt)", [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() }
    } catch { }
    $f.lastApplyEpoch = [long]$apply

    $f.historyKnown = $false
    $f.verified = 'unknown'
    $f.lastClosed = $null
    $f.lastLidStandby = $null
    try {
        $ev = Get-KaSleepEvidence -Since (Get-Date).AddDays(-14)
        if ($ev.queriesOk) {
            $f.historyKnown = $true
            $lastClosed = $null; $lastLidStandby = $null
            foreach ($e in $ev.events) {
                if ("$($e.lid)" -eq 'closed') { $lastClosed = $e }
                if ("$($e.kind)" -eq 'standbyEnter' -and "$($e.reason)" -eq 'lid') { $lastLidStandby = $e }
            }
            if ($lastClosed) {
                $f.lastClosed = @{ epoch = [long]$lastClosed.epoch; kind = "$($lastClosed.kind)"; reason = "$($lastClosed.reason)" }
            }
            if ($lastLidStandby) {
                $f.lastLidStandby = @{ epoch = [long]$lastLidStandby.epoch }
            }
            if ($apply -gt 0) {
                if ($lastClosed -and [long]$lastClosed.epoch -ge $apply) {
                    $f.verified = if ($lastLidStandby -and [long]$lastLidStandby.epoch -ge $apply) { 'slept' } else { 'no-sleep' }
                } else { $f.verified = 'unobserved' }
            } else { $f.verified = 'none' }
        }
    } catch { }
    return $f
}

function Get-KaReport {
    <#
        What the machine is actually configured to do, plus the heartbeat interval that
        follows from it. check-machine.ps1 used to print this only as console text and
        derive the recommendation from values it had mis-parsed, so the product shipped
        tuned for a machine it had not read.
    #>
    param([switch]$Refresh)

    $cfg = Get-KaConfig
    $plan = Get-KaPlan
    $states = Get-KaSleepStates
    $bat = Get-KaBattery

    # The kernel's capability flags are the primary answer (no text, no localization);
    # the localized powercfg /a parse above remains as the fallback and as the suite's
    # cross-check. AoAc IS the S0-low-power-idle fact the text only implies.
    $caps = Get-KaPowerCaps
    if ($caps.source -eq 'api') {
        $states.s0 = $caps.aoAc
        $states.s3 = $caps.s3
        $states.modernStandby = $caps.aoAc
    }
    $states.caps = $caps

    $osCaption = $env:OS; $osVer = ''
    try {
        $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osCaption = "$($o.Caption)".Trim()
        $osVer = "$($o.Version) build $($o.BuildNumber)"
    } catch { }

    # Two different clocks. The heartbeat only defends against an idle *lock*, so it is
    # sized from lock timers; the sleep / display-off timeouts are what engine 1 suppresses
    # and are reported separately as context.
    $lockCandidates = @()
    if ($plan.inactivityPolicySec) { $lockCandidates += [int]$plan.inactivityPolicySec }
    if ($plan.screensaver -and $plan.screensaver.secure) { $lockCandidates += [int]$plan.screensaver.timeoutSec }
    $lockTightest = if ($lockCandidates.Count) { [int](($lockCandidates | Measure-Object -Minimum).Minimum) } else { 0 }

    $powerCandidates = @()
    foreach ($sec in @($plan.sleepAcSec, $plan.sleepDcSec, $plan.videoAcSec, $plan.videoDcSec, $plan.unattendedAcSec)) {
        if ($null -ne $sec -and [int]$sec -gt 0) { $powerCandidates += [int]$sec }
    }
    $powerTightest = if ($powerCandidates.Count) { [int](($powerCandidates | Measure-Object -Minimum).Minimum) } else { 0 }

    $recommended = 240
    $why = @{ id = 'report.why.no-lock-timer' }
    if ($lockTightest -gt 0) {
        $recommended = [int](Get-KaBounded ([math]::Floor($lockTightest / 2)) 10 240 240)
        $why = @{ id = 'report.why.half-of-lock-timer'; secs = [int]$lockTightest }
    }

    $risk = @()
    if ($states.modernStandby) { $risk += @{ id = 'report.risk.modern-standby' } }
    # Unknown lid presence (powercfg fallback) keeps the lid risk evaluation; the
    # kernel bit is the only source that can rule it out. It stays $null rather than
    # becoming $true, because "no bit read" and "this machine has a lid" are different facts.
    $lidPresent = if ($caps.source -eq 'api') { [bool]$caps.lidPresent } else { $null }
    foreach ($lr in (Get-KaLidRisk -LidAc $plan.lidAc -LidDc $plan.lidDc -LidPresent $lidPresent)) { $risk += $lr }
    if ($plan.hybridSleep -eq 1) { $risk += @{ id = 'report.risk.hybrid-sleep' } }
    if ($plan.inactivityPolicySec) { $risk += @{ id = 'report.risk.lock-policy'; minutes = [int]($plan.inactivityPolicySec / 60) } }
    if ($bat.hasBattery -and -not $bat.acOnline) {
        # -1 is the "no reading" sentinel, not a charge level: printing it would invent a number
        # for exactly the state where the number is missing.
        $batPct = if ([int]$bat.percent -ge 0) { [int]$bat.percent } else { '?' }
        $risk += @{ id = 'report.risk.battery'; pct = $batPct; floor = [int]$cfg.batteryFloorPercent }
    }
    $selfOvr = @(Get-KaSelfOverrides (Get-KaRequestOverrides))
    if ($selfOvr.Count) {
        $risk += @{ id = 'report.risk.override-self'; names = (@($selfOvr | ForEach-Object { "$($_.scope): $($_.line)" }) -join ' | ') }
    }

    $report = @{
        generatedAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        generatedEpoch       = Get-KaEpoch
        os                   = "$osCaption $osVer"
        psVersion            = "$($PSVersionTable.PSVersion)"
        sleepStates          = @{ s0 = $states.s0; s3 = $states.s3; modernStandby = $states.modernStandby; hibernate = $states.hibernate; caps = $states.caps }
        plan                 = $plan
        battery              = $bat
        idleSec              = (Get-KaIdleSeconds)
        lockTightestSec      = [int]$lockTightest
        powerTightestSec     = [int]$powerTightest
        recommendedIntervalSec = [int]$recommended
        recommendedWhy       = $why
        config               = $cfg
        risk                 = $risk
        lid                  = (Get-KaLidForecast -LidAc $plan.lidAc -LidDc $plan.lidDc -LidPresent $lidPresent -Battery $bat)
    }

    if ($Refresh) {
        $snap = @{ generatedAt = $report.generatedAt; os = $report.os; sleepStates = $report.sleepStates
                   plan = $report.plan; lockTightestSec = $report.lockTightestSec
                   recommendedIntervalSec = $report.recommendedIntervalSec }
        [void](Write-KaJson (Get-KaPath).machine $snap -Depth 6)
    }
    return $report
}
