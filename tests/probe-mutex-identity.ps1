<#
    Which identity does the single-instance mutex actually key on?

    README says two things that are in tension with the code: 架构/单实例 claims the name is
    sha256(项目根路径), and the 适配矩阵 row "复制两份目录" claims two copies "各自跑自己的
    worker". Get-KaIdentitySuffix keys the name on the *data root* plus the user SID instead.
    If the README is the stale one, then for one user with one default data root a second copy
    cannot protect on its own - which a remote-unattended user will hit.

    No protection is started here. The name is a pure function of (data root, SID), and whether
    a name is contended is observable with Mutex.OpenExisting from a second process (a job).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path $root '_tmp/mutex-run'
$fail = @()
function Ok([string]$m) { Write-Output ("  ok   {0}" -f $m) }
function Bad([string]$m) { Write-Output ("  FAIL {0}" -f $m); $script:fail += $m }

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
# A second "install folder": the shipped scripts copied elsewhere, exactly what a second clone is.
$progB = Join-Path $work 'programB'
New-Item -ItemType Directory -Force -Path $progB | Out-Null
foreach ($f in @('ka-core.ps1', 'ka-gate.ps1')) { Copy-Item -Path (Join-Path $root $f) -Destination $progB }

# Prints name= / data= / program= for whatever ka-core resolves from this directory. Staged as a
# real .ps1 because `powershell -Command <text>` does not bind named parameters at all.
$idFile = Join-Path $work 'identity.ps1'
[IO.File]::WriteAllText($idFile, @'
param([string]$Dir, [string]$Data)
$ErrorActionPreference = 'Stop'
if ($Data) { $env:KA_DATA = $Data }
. (Join-Path $Dir 'ka-core.ps1')
$p = Get-KaPath
"name=$(Get-KaMutexName 'KA-Worker')"
"data=$($p.data)"
"program=$($p.program)"
'@, (New-Object System.Text.UTF8Encoding($true)))

function Get-Identity([string]$Dir, [string]$Data) {
    # An empty -Data must not be passed at all: the native command line drops the empty
    # argument and the child then fails with "missing an argument for parameter Data".
    $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $idFile, '-Dir', $Dir)
    if ($Data) { $argl += @('-Data', $Data) }
    $lines = & powershell @argl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "identity probe failed for $Dir/$Data : $lines" }
    $o = @{}
    foreach ($l in $lines) { if ("$l" -match '^([a-z]+)=(.*)$') { $o[$matches[1]] = $matches[2].Trim() } }
    if (-not $o.name) { throw "identity probe returned no name for $Dir/$Data : $lines" }
    return $o
}

Write-Output '--- A. two install folders, one user, one default data root'
$a = Get-Identity -Dir $root -Data ''
$b = Get-Identity -Dir $progB -Data ''
Write-Output ("  A: program={0} data={1} name={2}" -f $a.program, $a.data, $a.name)
Write-Output ("  B: program={0} data={1} name={2}" -f $b.program, $b.data, $b.name)
if ($a.program -eq $b.program) { Bad 'the two probes reported the same program dir - staging failed' }
elseif ($a.name -eq $b.name) {
    Ok 'different install folders, SAME mutex name: a second copy cannot protect independently'
} else {
    Bad "mutex differs while the data root is shared ($($a.name) vs $($b.name)) - it is keyed on the folder, as README claims"
}

Write-Output '--- B. same folder, its own data root via KA_DATA'
$c = Get-Identity -Dir $root -Data (Join-Path $work 'dataC')
Write-Output ("  C: data={0} name={1}" -f $c.data, $c.name)
if ($c.name -and $c.name -ne $a.name) { Ok 'a separate data root gets its own mutex, so copies can be decoupled on purpose' }
else { Bad "KA_DATA did not change the identity (C=$($c.name) A=$($a.name))" }

Write-Output '--- C. is the shared name actually contended across processes?'
# Before staging a holder, ask who already holds the name. Measured 2026-09-25 (and reproduced from
# a pristine `git archive HEAD`): on a box where protection is live, the running worker owns
# Local\KA-Worker-<default suffix>, so the holder job below can never be first taker - it prints
# got=False, and the leg went red as if the product were broken. It is the machine. The fix is not
# to skip the question: a live foreign holder is a *better* answer than a job, because it is the
# product's own worker contending for the name from another process. So the route is chosen by
# measurement, and the PROBE OK line says which one ran.
#
# OpenExisting proves the name exists; WaitOne(0) is what proves someone else owns it right now.
# If this process does get it, it releases at once - ka-worker.ps1:70 takes the mutex once at
# startup and never re-requests it, so a momentary second applicant cannot disturb the live
# protection this box depends on.
$heldBy = $null
try {
    $pre = [System.Threading.Mutex]::OpenExisting($a.name)
    try { $mine = $pre.WaitOne(0) } finally { $pre.Close() }
    if (-not $mine) { $heldBy = 'foreign' }
} catch [System.Threading.WaitHandleCannotBeOpenedException] { $heldBy = $null }
  catch { $heldBy = $null }
if ($heldBy) {
    $workers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { "$($_.CommandLine)" -like '*ka-worker.ps1*' -and "$($_.CommandLine)" -notlike '*_tmp*' })
    $who = if ($workers.Count) { (($workers | ForEach-Object { [string]$_.ProcessId }) -join ',') } else { 'unknown pid' }
    Write-Output ("  a live process outside _tmp already owns {0} (pid {1}) - contending against the product's own worker" -f $a.name, $who)
    $contended = $false
    try {
        $mm = [System.Threading.Mutex]::OpenExisting($a.name)
        $mine2 = $mm.WaitOne(0)
        if ($mine2) { [void]$mm.ReleaseMutex() }
        $mm.Close()
        $contended = -not $mine2
    } catch { Write-Output ("  OpenExisting error: {0}" -f $_.Exception.GetType().Name) }
    if ($contended) {
        Ok "the name reads as taken to this process while pid $who holds it - contention proven against a real worker, not a job"
        $route = 'live worker pid ' + $who
    } else {
        Bad 'a foreign pid owns the name and OpenExisting + WaitOne(0) still handed it to us - the observation is broken'
        $route = 'live worker, observation broken'
    }
    Write-Output '  SKIP the holder-job control - it cannot be first taker while somebody else owns the name'
} else {
# A job is a separate process. Observe contention while it is holding the name, *then* collect
# what the holder reported - reading the job before it finishes yields nothing, which is a
# broken harness, not a negative result.
$route = 'holder job'
$hold = Start-Job -ArgumentList $a.name -ScriptBlock {
    param($n)
    try {
        $m = New-Object System.Threading.Mutex($false, $n)
        $got = $m.WaitOne(3000)
        Start-Sleep -Seconds 4
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
        "got=$got"
    } catch { "ERR=$($_.Exception.GetType().Name)" }
}
Start-Sleep -Milliseconds 500
# Observe inside the holder's *actual* holding window, not after a fixed guess. The first version
# waited a flat 2 s and then looked once: on a cold CI runner Start-Job had not created the name yet,
# OpenExisting threw, the catch reported only the wrapper type (PowerShell surfaces .NET exceptions as
# MethodInvocationException, so the reason read as a generic "observation is broken"), and the leg went
# red as if the product were broken (run 36545465699). It is a harness timing bug: poll until the name
# answers, and name the real cause when it does not.
$contended = $false
$why = ''
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and -not $contended) {
    $mine = $false
    try {
        $mm = [System.Threading.Mutex]::OpenExisting($a.name)
        try {
            $mine = $mm.WaitOne(0)
            if ($mine) { $mm.ReleaseMutex() }      # free, or abandoned: we got it, hand it straight back
        } finally { $mm.Close() }
        if ($mine) { $why = 'read-as-free' } else { $contended = $true }
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $why = 'not-created-yet'                   # the holder job has not got there; keep polling
    } catch {
        $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException.GetType().Name } else { 'none' }
        $why = $_.Exception.GetType().Name + '/' + $inner
        break
    }
    if (-not $contended) { Start-Sleep -Milliseconds 250 }
}
$null = Wait-Job -Job $hold -Timeout 15
$gotLine = (Receive-Job -Job $hold *>&1 | Out-String).Trim()
Remove-Job -Job $hold -Force
Write-Output "  holder job said: $gotLine ; last observation: $(if ($why) { $why } else { 'none' })"
# This control takes the *default* root's name, so it needs to be the first taker. On a machine
# where protection is live right now it cannot be: the running worker already owns
# Local\KA-Worker-<default suffix>, and the job prints got=False. Measured 2026-09-25 on a box
# with a panel worker alive - and the same red reproduced from a pristine `git archive HEAD`, so
# it is the machine, not the code under test. CI runs this where nothing is protecting.
if ($gotLine -notmatch 'got=True') { Bad "control failed: the holder never got the mutex, so contention proves nothing ($gotLine) - 若这台机器正在防休眠，先停掉再跑本探针" }
elseif ($contended) { Ok 'OpenExisting from a second process sees the name as taken - the collision is real, not theoretical' }
else { Bad ("the name read as free while another process held it - the observation is broken (last observation: $why)") }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($fail.Count) {
    Write-Output ('PROBE FAILED: ' + $fail.Count + ' assertion(s)')
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output ('PROBE OK: the mutex keys on data root + SID, not on the install folder (contention observed against ' + $route + ')')
exit 0
