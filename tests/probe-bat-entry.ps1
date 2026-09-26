param(
    [switch]$Power,
    [switch]$Show,
    [switch]$SelfTest,
    [string]$Mutate = ''
)
$ErrorActionPreference = 'Stop'
<#
    The five double-click entries are executed here. None of them had ever been executed anywhere.

    release.yml's own text tells a downloader to "unzip it and double-click on.bat", README gives
    the same instruction, and every check in this repository goes through ka.ps1 instead: the suite
    and the packaging smoke call `ka.ps1 status -Json`, probe-motw runs the powershell line ka.bat
    would have run, and nothing had ever started cmd.exe on on.bat / off.bat / panel.bat / tray.bat.
    The entry point a person actually uses sat outside every gate - the same shape as the tray
    -SelfTest body that turned out never to have run (probe-tray-selftest), one layer further out.

    Two facts about .bat files were measured while writing this, and they decide the shape of every
    assertion below.

      1. ERRORLEVEL is not a verdict. Three copies of one batch that runs a powershell script
         exiting 5, all measured through the same cmd /c: ending in `pause` -> 0, ending in
         `exit /b %ERRORLEVEL%` -> 5, ending with nothing after the call -> 5. on/off/panel/tray.bat
         are the first shape, so a leg that asserted "exit != 0" on them would be blind by
         construction; every one of those legs asserts an *artifact* instead - the intent.json the
         command was supposed to write, the process it was supposed to leave running, the port it was
         supposed to open, the byte count of the file it was supposed to serve. ka.bat is the third
         shape (it is pure pass-through), so its exit code is used there.
         Reading either of those correctly is its own trap: Start-Process -PassThru then
         WaitForExit(30000) reports ExitCode 0 for `cmd /c exit 3` - the object is cached and
         unsynchronised. [Diagnostics.Process]::Start with UseShellExecute=false reports 3.

      2. Start-Process -Wait with -RedirectStandardOutput hangs the moment the child leaves a
         grandchild behind. panel.bat starts a hidden ka-server.ps1; that grandchild inherits the
         write end of the pipe; .NET's WaitForExit() waits for the stream to reach EOF, which never
         happens because the panel is the point. The first version of this file hung on exactly
         that. So every command's output goes to a file through cmd's own `>` redirection and cmd
         itself is waited on with a timeout, never on a stream.

      3. An instant is not a verdict either. The second tray.bat *does* start a process, and it does
         exit when it finds the live icon - measured here as 20000, then "20000 + 16564", then 20000
         again a second later - so a count taken the moment the batch returns shows two. The tray leg
         waits for that to settle and then checks which pid survived, not just how many.

    What each leg pins:

      ka.bat    both branches - no argument and `status` - must agree, and `-Json` must report the
                scratch data root. That is the KA_DATA override surviving the .bat layer, which is
                what build.ps1 -Smoke asserts one level below.
      off.bat   safe when nothing is protecting: it says so and writes intent=off, and it must not
                touch a worker belonging to another data root. That last part is asserted globally:
                every Keep-Awake process on the machine is inventoried before and after and
                required identical, so "this probe left the protection you are running alone" is a
                measurement instead of a promise.
      panel.bat a real panel on a real port, and then the thing the release manifest cannot check:
                every file the zip ships under dashboard/ has to be *reachable* over HTTP. The
                manifest now discovers dashboard/** from the tree while $staticMap in ka-server.ps1
                stays a hand-typed list of routes, so a file can ship and still 404 - the favicon
                defect pointed the other way. The names come from the tree and from index.html's own
                src=/href= attributes, never from a list typed here.
      tray.bat  the icon process actually starts, and tray.bat's promise that a second run is
                ignored while the first icon is alive.
      on.bat    -Power only. It starts protection, and ka-worker.ps1:152 fires the anti-lock pulse
                on the worker's *first* tick, so a scratch worker on a machine in use types a key
                into somebody's session. On a GitHub runner that is meaningless and it runs; on a
                desk it is skipped out loud unless -Power is given.

    -SelfTest re-runs this file as a child once per injected defect, one defect per run, and
    requires each to go red inside its own leg - and the un-defected run to stay green.
#>

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$work = Join-Path $root '_tmp/bat-entry'
$tree = Join-Path $work 'tree'
$data = Join-Path $work 'data'
$self = Join-Path $here 'probe-bat-entry.ps1'
$ps51 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Set before anything can start: every process below inherits it. Without it the .bat entries would
# run against %LOCALAPPDATA%\KeepAwake, which is where the machine's *own* worker and panel live -
# off.bat would then find that worker by its data root, judge it ours, and stop the protection this
# box is running. ka-core.ps1:354 is the read this line feeds.
$env:KA_DATA = $data

. (Join-Path $root 'tests/ka-release-files.ps1')

$onCi = ("$($env:GITHUB_ACTIONS)".ToLowerInvariant() -eq 'true')
$runPower = [bool]($Power -or $onCi)
$script:bad = @()

function Bad([string]$Leg, [string]$Msg) {
    $script:bad += ('[' + $Leg + '] ' + $Msg)
    Write-Host ('  FAIL [' + $Leg + '] ' + $Msg)
}

# ------------------------------------------------------------------ scratch tree
function Mutate-Tree([string]$Mode) {
    # Each defect is a line replacement in the staged copy; the shipped tree is never touched.
    # CRLF is preserved because cmd.exe is what reads these files next.
    if (-not $Mode) { return }
    $enc = New-Object Text.UTF8Encoding($false)
    switch ($Mode) {
        'badentry' {
            $f = Join-Path $tree 'panel.bat'
            $l = [IO.File]::ReadAllLines($f)
            for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -like '*" serve') { $l[$i] = ($l[$i] -replace 'serve$', 'serveX') } }
            [IO.File]::WriteAllText($f, (($l -join "`r`n") + "`r`n"), $enc)
        }
        'wrongtarget' {
            $f = Join-Path $tree 'ka.bat'
            $l = [IO.File]::ReadAllLines($f)
            for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -like '*ka.ps1"*') { $l[$i] = ($l[$i] -replace 'ka\.ps1', 'ka-nope.ps1') } }
            [IO.File]::WriteAllText($f, (($l -join "`r`n") + "`r`n"), $enc)
        }
        'badminutes' {
            $f = Join-Path $tree 'on.bat'
            $l = [IO.File]::ReadAllLines($f)
            for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -like '*-Minutes*') { $l[$i] = ($l[$i] -replace '-Minutes', '-Minute') } }
            [IO.File]::WriteAllText($f, (($l -join "`r`n") + "`r`n"), $enc)
        }
        'unreachable' {
            # Shipped by discovery (it is under dashboard/), unreachable by $staticMap (nothing
            # names it): the zip carries a file the panel refuses to serve.
            $svg = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"></svg>'
            [IO.File]::WriteAllText((Join-Path $tree 'dashboard\selftest-extra.svg'), ($svg + "`r`n"), $enc)
        }
        'missingasset' {
            # index.html asks for /i18n.js by name. Take the file away and the panel serves a page
            # whose script never loads - the favicon defect, one layer up.
            Remove-Item -LiteralPath (Join-Path $tree 'dashboard\i18n.js') -Force
        }
        default { throw ("unknown mutation '{0}'" -f $Mode) }
    }
    # An injection that did not land turns the leg into an assertion about nothing.
    $landed = $false
    if ($Mode -eq 'badentry') { $landed = [IO.File]::ReadAllText((Join-Path $tree 'panel.bat')) -like '*serveX*' }
    if ($Mode -eq 'wrongtarget') { $landed = [IO.File]::ReadAllText((Join-Path $tree 'ka.bat')) -like '*ka-nope.ps1*' }
    if ($Mode -eq 'badminutes') {
        $t = [IO.File]::ReadAllText((Join-Path $tree 'on.bat'))
        $landed = (($t -like '*-Minute %*') -and -not ($t -like '*-Minutes*'))
    }
    if ($Mode -eq 'unreachable') { $landed = Test-Path -LiteralPath (Join-Path $tree 'dashboard\selftest-extra.svg') }
    if ($Mode -eq 'missingasset') { $landed = -not (Test-Path -LiteralPath (Join-Path $tree 'dashboard\i18n.js')) }
    if (-not $landed) { throw ("mutation '{0}' did not land in the staged tree" -f $Mode) }
}

function New-Tree([string]$Mode) {
    # A release tree is exactly what the manifest names, which also proves the manifest can still
    # build one - probe-build-selftest checks that by a different route.
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $tree, $data
    $names = @(Get-KaReleaseFile)
    foreach ($n in $names) {
        $src = Join-Path $root ($n -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { throw ("the manifest cannot build a tree: {0} is missing" -f $n) }
        $d = Join-Path $tree ($n -replace '/', '\')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $d)
        Copy-Item -LiteralPath $src -Destination $d -Force
    }
    # Checked before the mutation, because a mutation like missingasset deletes a manifest member on
    # purpose; comparing afterwards would throw about the tree instead of reporting the leg.
    $nfile = @(Get-ChildItem -LiteralPath $tree -Recurse -File).Count
    if ($nfile -lt $names.Count) { throw ("the staged tree holds {0} files, the manifest names {1}" -f $nfile, $names.Count) }
    Mutate-Tree $Mode
    $nfile = @(Get-ChildItem -LiteralPath $tree -Recurse -File).Count
    Write-Host ('  staged tree: ' + $nfile + ' files, data root ' + $data + $(if ($Mode) { ', mutation ' + $Mode } else { '' }))
}

# ------------------------------------------------------------------ helpers
function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return [int]$p
}

function Read-FileLoose([string]$Path) {
    # The panel and the tray inherit cmd's redirection handle, so the file can still be open for
    # writing when we read it. ReadWrite sharing is what makes that readable.
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    for ($try = 0; $try -lt 5; $try++) {
        try {
            $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try { $r = New-Object IO.StreamReader($fs); return $r.ReadToEnd() } finally { $fs.Dispose() }
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return ''
}

function Invoke-Cmd([string]$Line, [int]$TimeoutMs = 120000) {
    <#
        Two ways to wait on cmd measured here, and one of them lies. Start-Process -PassThru hands
        back a cached, unsynchronised Process: after its WaitForExit(int) overload returns, ExitCode
        reads 0 for `cmd /c exit 3` - and so does WaitForExit() with no timeout. [Diagnostics.Process]
        ::Start with UseShellExecute=false waits on the real handle: the same line gives 3. So the
        exit codes below come from that path (measured: ka.bat with a broken target -> 5, the same
        batch with `pause` appended -> 0, which is fact 1).
    #>
    $si = New-Object Diagnostics.ProcessStartInfo
    $si.FileName = Join-Path $env:windir 'System32\cmd.exe'
    $si.Arguments = $Line
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($si)
    try {
        if ($p.WaitForExit($TimeoutMs)) {
            $p.WaitForExit()
            return @{ TimedOut = $false; Exit = [int]$p.ExitCode }
        }
        try { [void]$p.Kill() } catch { }
        return @{ TimedOut = $true; Exit = -1 }
    } finally {
        $p.Dispose()
    }
}

function Invoke-Bat([string]$File, [string]$Tail) {
    <#
        How a double-click runs: cmd.exe /c on the batch file. `<nul` answers the trailing `pause`
        (measured: with stdin redirected from NUL, pause returns and ERRORLEVEL ends up 0 - which is
        why nothing below reads the exit code of those four as a verdict).
    #>
    $out = Join-Path $env:TEMP ('kabat-' + [guid]::NewGuid().ToString('N') + '.out')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $line = '/c ""' + (Join-Path $tree $File) + '" ' + $Tail + ' > "' + $out + '" 2>&1 <nul"'
        $r = Invoke-Cmd $line 90000
        $text = Read-FileLoose $out
        $one = ($text -replace "`r`n", ' | ').Trim()
        if ($Show) { Write-Host ('----- ' + $File + ' ' + $Tail + ' (timedOut=' + $r.TimedOut + ' exit=' + $r.Exit + ') -----'); Write-Host $one }
        return @{ TimedOut = $r.TimedOut; Exit = $r.Exit; Text = $one; Raw = $text; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

function Get-ScratchProc([string]$Needle) {
    # Every process this scratch tree started, found by the staged path inside its own command line
    # - never by the script name alone, because the machine's real worker and real panel carry the
    # same names.
    $out = @()
    $pat = ('*' + $tree + '*' + '*' + $Needle + '*')
    foreach ($r in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        $cl = "$($r.CommandLine)"
        if ($cl -like $pat) { $out += [int]$r.ProcessId }
    }
    return @($out)
}

function Get-MachineKaProc {
    # Inventory of every Keep-Awake-shaped process NOT belonging to the staged tree: the machine's
    # own worker, panel, tray. A probe run must not add or remove one of these.
    $out = @()
    foreach ($r in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        $cl = "$($r.CommandLine)"
        $m = [regex]::Match($cl, 'ka-(worker|server|tray)\.ps1')
        if (-not $m.Success) { continue }
        if ($cl -like ('*' + $tree + '*')) { continue }
        $out += ([int]$r.ProcessId).ToString() + ':' + $m.Value
    }
    return @($out | Sort-Object)
}

function Stop-Scratch {
    foreach ($needle in @('ka-worker.ps1', 'ka-server.ps1', 'ka-tray.ps1')) {
        foreach ($procId in @(Get-ScratchProc $needle)) {
            try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { }
        }
    }
    for ($i = 0; $i -lt 40; $i++) {
        if (@(Get-ScratchProc '.ps1').Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
}

function Invoke-Route([int]$Port, [string]$Path) {
    <#
        A real request against a real listener, through HttpWebRequest rather than
        Invoke-WebRequest. Measured reason: 5.1's Invoke-WebRequest reports a served 404 as an error
        record whose .Response is not reachable, so the first run of this file read "Status=0" for a
        request ka-server.ps1 had answered with 404 + a body (ka-server.ps1:334). A WebException
        carries the live response. The body is drained either way, because a 200 with an empty body
        is a file nobody can see and the byte count is compared against the file on disk.
    #>
    $r = @{ Status = 0; Type = ''; Bytes = 0; Error = '' }
    try {
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + $Path)
        $req.Timeout = 8000
        $req.ReadWriteTimeout = 8000
        $req.UserAgent = 'ka-probe-bat-entry'
        $req.Headers.Add('X-Ka-Client', 'ka-dashboard')
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $e = $_.Exception
        if (-not $e.Response) { $r.Error = $e.Message; return $r }
        $resp = $e.Response
    } catch {
        $r.Error = $_.Exception.Message
        return $r
    }
    try {
        $r.Status = [int]$resp.StatusCode
        $r.Type = "$($resp.ContentType)"
        $ms = New-Object IO.MemoryStream
        $s = $resp.GetResponseStream()
        $s.CopyTo($ms)
        $r.Bytes = [int]$ms.Length
    } catch { $r.Error = $_.Exception.Message } finally {
        try { $resp.Close() } catch { }
    }
    return $r
}

function Wait-Port([int]$Port, [switch]$Down, [int]$Sec = 40) {
    for ($i = 0; $i -lt $Sec; $i++) {
        $up = ((Invoke-Route -Port $Port -Path '/api/ping').Status -eq 200)
        if ($Down -and -not $up) { return $true }
        if (-not $Down -and $up) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Read-FileLoose $Path
    if (-not $raw.Trim()) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

# ------------------------------------------------------------------ legs
function Invoke-Legs {
    $port = Get-FreePort
    # The panel's port comes from config.json in the data root. 8791 is already held by the panel
    # this machine runs, and a probe that collides with it measures nothing.
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $data 'config.json'), ('{"version":3,"port":' + $port + '}' + "`n"), $enc)
    Write-Host ('  scratch panel port: ' + $port)

    # ---- ka.bat: the no-argument branch has to land on the same thing `status` does
    $a = Invoke-Bat 'ka.bat' ''
    $b = Invoke-Bat 'ka.bat' 'status'
    if ($a.TimedOut) { Bad 'ka' 'ka.bat with no argument never returned' }
    if ($b.TimedOut) { Bad 'ka' 'ka.bat status never returned' }
    # ka.bat is the one entry with no trailing pause, so its exit code is the batch's own.
    if (-not $a.TimedOut -and $a.Exit -ne 0) { Bad 'ka' ("ka.bat exited {0} - text: {1}" -f $a.Exit, $a.Text) }
    if (-not $b.TimedOut -and $b.Exit -ne 0) { Bad 'ka' ("ka.bat status exited {0} - text: {1}" -f $b.Exit, $b.Text) }
    if (-not $a.TimedOut -and -not $b.TimedOut) {
        # Line by line, and a number is allowed to change the unit word it is written with. Measured
        # here: this machine has a live worker the scratch tree reports, and between the two calls its
        # idle reading crossed the minute boundary, so the default branch printed `62 秒` where
        # `status` printed `1.0 分钟`. A single folded string hid that difference; comparing whole
        # lines without that tolerance turned the leg red on an intact tree (the first -SelfTest run
        # caught it, which is what the run is for). Every other character on the line still has to
        # match, so "the default branch is not status" remains a red line - and the failure names the
        # line number and both texts.
        $la = @(Get-OutputLines $a.Raw)
        $lb = @(Get-OutputLines $b.Raw)
        if ($la.Count -lt 3) { Bad 'ka' ("ka.bat printed {0} non-empty line(s) - the comparison below proves nothing" -f $la.Count) }
        if ($la.Count -ne $lb.Count) {
            Bad 'ka' ("the no-argument branch of ka.bat printed {0} lines, `status` printed {1}" -f $la.Count, $lb.Count)
        } else {
            $diff = @()
            for ($i = 0; $i -lt $la.Count; $i++) {
                if ($la[$i] -eq $lb[$i]) { continue }
                if ((Norm-Output $la[$i]) -eq (Norm-Output $lb[$i])) { continue }
                $diff += ('line {0}: [{1}] vs [{2}]' -f ($i + 1), $la[$i], $lb[$i])
            }
            if ($diff.Count) {
                Bad 'ka' ("the no-argument branch of ka.bat is not `status`: " + ($diff -join ' ; '))
            }
        }
    }

    # ---- ka.bat status -Json: the data root the .bat layer actually reached
    $j = Invoke-Bat 'ka.bat' 'status -Json'
    $state = $null
    # Parsed from the raw bytes, not the folded one-liner above: a pretty-printed JSON document
    # folded with ' | ' between its lines is no longer JSON.
    if ($j.Raw) { try { $state = ($j.Raw | ConvertFrom-Json) } catch { Bad 'ka' ("status -Json is not JSON: {0}" -f $_.Exception.Message) } }
    if (-not $state) {
        if (-not $j.TimedOut) { Bad 'ka' ("status -Json produced no parseable state (exit={0})" -f $j.Exit) }
    } else {
        if (("$($state.dataRoot)").TrimEnd('\') -ine $data) {
            Bad 'ka' ("ka.bat status -Json reports dataRoot '{0}', not the KA_DATA scratch root '{1}' - the override is lost through the .bat layer" -f $state.dataRoot, $data)
        }
        if (("$($state.root)").TrimEnd('\') -ine $tree) {
            Bad 'ka' ("ka.bat status -Json reports root '{0}', not the staged release tree '{1}'" -f $state.root, $tree)
        }
        if ("$($state.version)" -eq '') { Bad 'ka' 'status -Json has no version' }
        if ($state.running -ne $false) { Bad 'ka' 'the scratch data root already reports a running worker before any leg started one' }
    }

    # ---- off.bat when nothing is protecting
    if (@(Get-ScratchProc 'ka-worker.ps1').Count -ne 0) { Bad 'off-idle' 'a scratch worker existed before off.bat ran - the leg is not what it claims to be' }
    $o = Invoke-Bat 'off.bat' ''
    if ($o.TimedOut) { Bad 'off-idle' 'off.bat never returned' }
    $intent = Read-JsonFile (Join-Path $data 'intent.json')
    if (-not $intent) { Bad 'off-idle' ("off.bat left no intent.json in the scratch data root (text: {0})" -f $o.Text) }
    elseif ("$($intent.desired)" -ne 'off') { Bad 'off-idle' ("off.bat wrote intent desired='{0}', not off" -f $intent.desired) }
    if (@(Get-ScratchProc 'ka-worker.ps1').Count -ne 0) { Bad 'off-idle' 'off.bat left a scratch worker running' }

    # ---- panel.bat: a real panel, and every shipped dashboard file reachable over HTTP
    $pp = Invoke-Bat 'panel.bat' ''
    if ($pp.TimedOut) { Bad 'panel' 'panel.bat never returned' }
    if (-not (Wait-Port $port)) {
        Bad 'panel' ("panel.bat never brought a panel up on port {0} (text: {1})" -f $port, $pp.Text)
    } else {
        $dashRoot = Join-Path $tree 'dashboard'
        $dash = @(Get-ChildItem -LiteralPath $dashRoot -File -Recurse)
        if ($dash.Count -lt 4) { Bad 'panel' ("only {0} dashboard files in the staged tree - the reachability loop below is about almost nothing" -f $dash.Count) }
        foreach ($f in $dash) {
            $rel = $f.FullName.Substring($dashRoot.Length).Replace('\', '/').TrimStart('/')
            $r = Invoke-Route -Port $port -Path ('/' + $rel)
            if ($r.Status -ne 200) {
                Bad 'panel' ("{0} ships in the release but the panel answers it with {1}{2} - a name no route list holds is a file nobody can load" -f `
                    $rel, $r.Status, $(if ($r.Error) { ' (no response: ' + $r.Error + ')' } else { '' }))
            } elseif ($r.Bytes -ne $f.Length) {
                # ka-server.ps1:340 sends File.ReadAllBytes, so the browser is meant to receive the
                # exact bytes the zip carried. A different count is a truncated or rewritten file.
                Bad 'panel' ("{0} is served as {1} bytes but the file in the release is {2}" -f $rel, $r.Bytes, $f.Length)
            }
        }
        # What the page itself asks for, read out of index.html rather than typed here.
        $html = Read-FileLoose (Join-Path $dashRoot 'index.html')
        $asked = @([regex]::Matches($html, '(?:src|href)="(/[^"#][^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($asked.Count -lt 3) { Bad 'panel' ("index.html only asked for {0} root-relative paths - the attribute scan has stopped reading the page" -f $asked.Count) }
        foreach ($u in $asked) {
            $r = Invoke-Route -Port $port -Path $u
            if ($r.Status -ne 200) { Bad 'panel' ("index.html asks for {0} and the panel answers {1}" -f $u, $r.Status) }
        }
        $n = Invoke-Route -Port $port -Path '/selftest-never-shipped.svg'
        if ($n.Status -ne 404) { Bad 'panel' ("an unknown name answered {0}, not 404 - the server is resolving paths it was never told about" -f $n.Status) }
        $st = Invoke-Route -Port $port -Path '/api/state'
        if ($st.Status -ne 200) { Bad 'panel' ("the dashboard's own /api/state answered {0}" -f $st.Status) }

        # ka.bat reaches the stop, because that is how a person closes the panel.
        $s = Invoke-Bat 'ka.bat' 'stop-server'
        if ($s.TimedOut) { Bad 'stop-server' 'ka.bat stop-server never returned' }
        if (-not $s.TimedOut -and $s.Exit -ne 0) { Bad 'stop-server' ("ka.bat stop-server exited {0} - text: {1}" -f $s.Exit, $s.Text) }
        if (-not (Wait-Port $port -Down -Sec 25)) { Bad 'stop-server' ("ka.bat stop-server left port {0} answering" -f $port) }
        $hints = @(Get-ChildItem -LiteralPath $data -Filter '.server*' -File -Force -ErrorAction SilentlyContinue)
        if ($hints.Count -gt 0) { Bad 'stop-server' ("stop-server left {0} handle file(s) behind: {1}" -f $hints.Count, (($hints | ForEach-Object { $_.Name }) -join ', ')) }
    }

    # ---- tray.bat: the icon process, and its one-instance promise
    $t = Invoke-Bat 'tray.bat' ''
    if ($t.TimedOut) { Bad 'tray' 'tray.bat never returned' }
    $trayPids = @()
    for ($i = 0; $i -lt 20; $i++) {
        $trayPids = @(Get-ScratchProc 'ka-tray.ps1')
        if ($trayPids.Count -gt 0) { break }
        Start-Sleep -Milliseconds 1000
    }
    if ($trayPids.Count -eq 0) { Bad 'tray' ("tray.bat started no tray process from the staged tree (text: {0})" -f $t.Text) }
    else {
        [void](Invoke-Bat 'tray.bat' '')
        # Counting the instant tray.bat returns is wrong and measured so: the second instance does
        # start, does find the live icon, and exits about a second later (measured here: 20000 then
        # "20000, 16564" then 20000 again). The promise is about who is left standing, so the leg
        # waits for that and then also requires the *original* process to be the one still there -
        # a second tray.bat that replaced the icon instead of ignoring it would pass a bare count.
        $again = @()
        $settled = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Milliseconds 1000
            $again = @(Get-ScratchProc 'ka-tray.ps1')
            if ($again.Count -eq $trayPids.Count) { $settled = $true; break }
        }
        if (-not $settled) {
            Bad 'tray' ("a second tray.bat left {0} tray processes where the first left {1} ({2})" -f $again.Count, $trayPids.Count, ($again -join ', '))
        } else {
            $kept = @($trayPids | Where-Object { $again -contains $_ })
            if ($kept.Count -ne $trayPids.Count) {
                Bad 'tray' ("the second tray.bat replaced the live icon ({0} -> {1}) instead of ignoring it" -f ($trayPids -join ', '), ($again -join ', '))
            }
        }
    }

    # ---- on.bat / off.bat for real. -Power only, and the reason is measured, not polite:
    #      ka-worker.ps1:152 sets nextPulse to *now*, so the anti-lock key fires on the first tick.
    if ($runPower) {
        $on = Invoke-Bat 'on.bat' ''
        $w = @()
        for ($i = 0; $i -lt 30; $i++) {
            $w = @(Get-ScratchProc 'ka-worker.ps1')
            if ($w.Count -gt 0) { break }
            Start-Sleep -Milliseconds 1000
        }
        $i2 = Read-JsonFile (Join-Path $data 'intent.json')
        if ($w.Count -eq 0) { Bad 'on' ("on.bat started no worker (text: {0})" -f $on.Text) }
        if (-not $i2 -or "$($i2.desired)" -ne 'awake') {
            Bad 'on' ("on.bat left intent desired='{0}' - protection was never asked for" -f $(if ($i2) { $i2.desired } else { 'no intent.json' }))
        }
        $sj = Invoke-Bat 'ka.bat' 'status -Json'
        $s2 = $null
        if ($sj.Raw) { try { $s2 = ($sj.Raw | ConvertFrom-Json) } catch { } }
        if (-not $s2) { Bad 'on' 'status -Json after on.bat is not JSON' }
        elseif ($s2.running -ne $true) { Bad 'on' ("status -Json says running={0} right after on.bat" -f $s2.running) }
        elseif ($w.Count -and [int]$s2.worker.pid -ne [int]$w[0]) { Bad 'on' ("status -Json names worker pid {0}, the process on disk is {1}" -f $s2.worker.pid, ($w -join ',')) }

        [void](Invoke-Bat 'off.bat' '')
        $gone = $false
        for ($i = 0; $i -lt 20; $i++) {
            if (@(Get-ScratchProc 'ka-worker.ps1').Count -eq 0) { $gone = $true; break }
            Start-Sleep -Milliseconds 1000
        }
        if (-not $gone) { Bad 'off' 'off.bat did not take the worker started by on.bat down' }

        $on2 = Invoke-Bat 'on.bat' '5'
        $i3 = $null
        for ($i = 0; $i -lt 20; $i++) {
            $i3 = Read-JsonFile (Join-Path $data 'intent.json')
            if ($i3 -and "$($i3.desired)" -eq 'awake') { break }
            Start-Sleep -Milliseconds 1000
        }
        if (-not $i3 -or "$($i3.desired)" -ne 'awake') {
            Bad 'on-minutes' ("on.bat 5 did not record an awake intent (text: {0})" -f $on2.Text)
        } elseif ([int]$i3.minutes -ne 5) {
            Bad 'on-minutes' ("on.bat 5 wrote minutes={0}, not 5 - the argument never reached -Minutes" -f $i3.minutes)
        } elseif ([int]$i3.expiresEpoch -le [int]$i3.updatedAt) {
            Bad 'on-minutes' ("on.bat 5 recorded expiresEpoch={0} updatedAt={1} - a timed run with no end" -f $i3.expiresEpoch, $i3.updatedAt)
        }
        [void](Invoke-Bat 'off.bat' '')
        for ($i = 0; $i -lt 20; $i++) {
            if (@(Get-ScratchProc 'ka-worker.ps1').Count -eq 0) { break }
            Start-Sleep -Milliseconds 1000
        }
    } else {
        Write-Host '  SKIP on.bat / off.bat - the worker fires its anti-lock pulse on the first tick'
        Write-Host "       (ka-worker.ps1:152), so running protection here would type a key into the"
        Write-Host '       session of a machine in use. They run on a GitHub runner, or with -Power.'
    }
}

function Get-OutputLines([string]$raw) {
    # Non-empty lines only: cmd's own blank padding is not something the two branches can disagree on.
    return @((($raw -replace "`r", '') -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Norm-Output([string]$line) {
    # A number and the unit word standing next to it are the same measurement written twice; see the
    # ka leg for the reading that made this necessary. Whitespace collapses, nothing else does.
    $x = $line -replace '[0-9][0-9.,]*', '#'
    $x = $x -replace '#\s*\S*', '#'
    return ($x -replace '\s+', ' ').Trim()
}

# ------------------------------------------------------------------ self-test
function Get-Mutants {
    # Which defect can be injected at all depends on whether the power legs run: badminutes breaks
    # the argument of a command that never executes without -Power.
    $m = @('badentry', 'wrongtarget', 'unreachable', 'missingasset')
    if ($runPower) { $m += 'badminutes' }
    return @($m)
}

function Run-Child([string]$Mode) {
    $out = Join-Path $env:TEMP ('kabatchild-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $argl = '/c ""' + $ps51 + '" -NoProfile -ExecutionPolicy Bypass -File "' + $self + '"'
        if ($Mode) { $argl += (' -Mutate "{0}"' -f $Mode) }
        if ($Power) { $argl += ' -Power' }
        $argl += (' > "{0}" 2>&1"' -f $out)
        # The trailing quote closes cmd's /c string and is load-bearing: with an odd number of quotes
        # cmd answers "The filename, directory name, or volume label syntax is incorrect." and exits
        # 0. Measured on the first run of this -SelfTest, where every child died on that line and the
        # harness reported a green un-defected run - which is why the verdict below is read from the
        # child's own PROBE OK / PROBE FAILED marker and not from its exit code alone.
        $r = Invoke-Cmd $argl 600000
        $text = Read-FileLoose $out
        $fails = @()
        foreach ($l in ($text -split "`n")) {
            $x = $l.Trim()
            if ($x.StartsWith('FAIL [')) { $fails += $x.Substring(5) }
        }
        return @{ Exit = $r.Exit; Text = $text; Fails = $fails; TimedOut = $r.TimedOut }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

$expect = @{
    # First entry is the leg this defect must turn red; the rest are legs that can only fail
    # *because* of it. A FAIL outside this set means the mutant rode on something else.
    badentry     = @('panel')
    wrongtarget  = @('ka', 'stop-server')
    unreachable  = @('panel')
    missingasset = @('panel')
    badminutes   = @('on-minutes', 'off')
}

function Get-Verdict($Child) {
    # Read from what the child itself concluded, not from how it stopped: an exit code of 0 has
    # already been measured here meaning "cmd never ran the thing" as well as "the probe passed".
    if ($Child.Text -notmatch 'PROBE (OK|FAILED)') { return 'none' }
    return $Matches[1]
}

function Run-SelfTest {
    $clean = Run-Child ''
    if ($clean.TimedOut) { Bad 'selftest' 'the un-defected child never finished' }
    $cv = Get-Verdict $clean
    if ($cv -ne 'OK') {
        Bad 'selftest' ("the un-defected run did not come out green (verdict={0} exit={1}) - the reds below would prove nothing" -f $cv, $clean.Exit)
        foreach ($l in $clean.Fails) { Bad 'selftest' ('        ' + $l) }
        Bad 'selftest' ('        child said: ' + (($clean.Text -replace '\s+', ' ').Trim()))
    }
    foreach ($m in @(Get-Mutants)) {
        $c = Run-Child $m
        $allowed = $expect[$m]
        if ($c.TimedOut) { Bad 'selftest' ("mutant '{0}' never finished" -f $m); continue }
        $v = Get-Verdict $c
        if ($v -eq 'none') {
            Bad 'selftest' ("mutant '{0}' printed no verdict (exit={1}) - it died before the legs ran, so nothing was asserted" -f $m, $c.Exit)
            Bad 'selftest' ('        child said: ' + (($c.Text -replace '\s+', ' ').Trim()))
        } elseif ($v -eq 'OK') {
            Bad 'selftest' ("mutant '{0}' stayed green - the legs cannot see the defect it injects" -f $m)
        }
        if ($c.Exit -ne 0 -and $v -eq 'OK') { Bad 'selftest' ("mutant '{0}' said PROBE OK and then exited {1}" -f $m, $c.Exit) }
        if ($v -eq 'FAILED' -and $c.Fails.Count -eq 0) {
            Bad 'selftest' ("mutant '{0}' went red with no [leg] finding at all - it died between the legs and the verdict" -f $m)
        }
        $primary = @($c.Fails | Where-Object { $_.StartsWith('[' + $allowed[0] + '] ') })
        if ($primary.Count -eq 0) { Bad 'selftest' ("mutant '{0}' never failed the '{1}' leg it is about" -f $m, $allowed[0]) }
        $foreign = @($c.Fails | Where-Object { $allowed -notcontains ($_ -replace '^\[(.*?)\].*', '$1') })
        if ($foreign.Count) { Bad 'selftest' ("mutant '{0}' also failed legs it did not touch: {1}" -f $m, ($foreign -join ' / ')) }
        Write-Host ("  run mutate='{0,-12}' verdict={1,-6} exit={2} fails={3}" -f $m, $v, $c.Exit, $c.Fails.Count)
        foreach ($l in $c.Fails) { Write-Host ('      ' + $l) }
    }
}

# ------------------------------------------------------------------ main
$machineBefore = @(Get-MachineKaProc)
try {
    if ($SelfTest) {
        Run-SelfTest
    } else {
        New-Tree $Mutate
        Invoke-Legs
        # Nothing this probe does may disturb what the machine is actually running: the worker
        # keeping it awake and the panel somebody is looking at belong to other data roots.
        $machineAfter = @(Get-MachineKaProc)
        $drift = @(Compare-Object @($machineBefore | Sort-Object) @($machineAfter | Sort-Object))
        if ($drift.Count) {
            Bad 'machine' ("this run changed a Keep-Awake process it does not own: {0}" -f (($drift | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join ' / '))
        }
    }
} catch {
    $script:bad += ('setup died before the legs finished: ' + $_.Exception.Message)
    Write-Host ('  FAIL ' + $_.Exception.Message)
} finally {
    Stop-Scratch
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:bad.Count) {
    # Each finding already reached stdout once, from Bad(); printing the list again would make every
    # mutant look like it failed twice.
    Write-Output ('PROBE FAILED: ' + $script:bad.Count + ' problem(s)')
    exit 1
}
$ran = 'ka/off/panel/tray executed; on.bat runs only with -Power or on a runner (anti-lock pulse on the first tick)'
if ($runPower) { $ran = 'all five entries executed, on.bat and off.bat included' }
if ($SelfTest) {
    Write-Output ('PROBE OK: ' + @(Get-Mutants).Count + ' injected defects each turn their own leg red and the intact run stays green - ' + $ran)
} else {
    Write-Output ('PROBE OK: every double-click entry that can run here ran for real, and every dashboard file the release ships answered over HTTP - ' + $ran)
}
exit 0
