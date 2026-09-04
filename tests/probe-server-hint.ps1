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
    running". Everything runs against staged copies of the shipped files with their own
    KA_DATA, so a panel the user left running from the real install is never touched.
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
param([switch]$Hints, [switch]$Servers, [switch]$Stop, [switch]$Port)
. (Join-Path $PSScriptRoot 'ka-core.ps1')
if ($Port) { Write-Output ("PORT=" + [int](Get-KaConfig).port); exit 0 }
if ($Hints) {
    foreach ($h in @(Get-KaServerHints)) { Write-Output ("HINT pid=" + $h.Pid + " port=" + $h.Port + " name=" + (Split-Path -Leaf $h.Path)) }
    exit 0
}
if ($Servers) { foreach ($s in @(Get-KaServer)) { Write-Output ("SERVER pid=" + $s.Pid + " port=" + $s.Port) } exit 0 }
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
        $p = Start-Process -FilePath $ps64 -Wait -NoNewWindow -PassThru -RedirectStandardOutput $out `
             -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'hint-child.ps1') + '" ' + $ChildArgs)
        @{ Exit = $p.ExitCode; Lines = @((Get-Content -LiteralPath $out -ErrorAction SilentlyContinue) | Where-Object { $_.Trim() }) }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    }
}
function Start-Panel([string]$Dir, [string]$Data, [int]$Port) {
    return Start-Process -FilePath $ps64 -PassThru -WindowStyle Hidden `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'ka-server.ps1') +
                       '" -DataDir "' + $Data + '" -Port ' + $Port)
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
foreach ($d in @($dataA, $dataB)) { $null = New-Item -ItemType Directory -Force -Path $d }
Install-Child $progA
Install-Child $progB
$P1 = Get-FreePort
$P2 = Get-FreePort
if ($P1 -eq $P2) { Bad "the two free ports came back identical ($P1) - the whole probe would be vacuous" }
# The scratch config has to point at $P1, otherwise Stop-KaServer probes the built-in default
# and a panel the user left running on it answers for us.
@{ port = $P1 } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataA 'config.json') -Encoding UTF8
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
} finally {
    foreach ($procId in $pids) { try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Milliseconds 400
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: two panels hold two handles, stopping one leaves the other findable, and a port that answers is never called "not running"'
