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
# A job is a separate process. Observe contention while it is holding the name, *then* collect
# what the holder reported - reading the job before it finishes yields nothing, which is a
# broken harness, not a negative result.
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
Start-Sleep -Seconds 2
$contended = $false
$why = ''
try {
    $mm = [System.Threading.Mutex]::OpenExisting($a.name)
    $mine = $mm.WaitOne(0)
    if ($mine) { $mm.ReleaseMutex() }
    $mm.Close()
    $contended = -not $mine
} catch { $why = $_.Exception.GetType().Name }
$null = Wait-Job -Job $hold -Timeout 15
$gotLine = (Receive-Job -Job $hold *>&1 | Out-String).Trim()
Remove-Job -Job $hold -Force
Write-Output "  holder job said: $gotLine ; OpenExisting error: $(if ($why) { $why } else { 'none' })"
if ($gotLine -notmatch 'got=True') { Bad "control failed: the holder never got the mutex, so contention proves nothing ($gotLine)" }
elseif ($contended) { Ok 'OpenExisting from a second process sees the name as taken - the collision is real, not theoretical' }
else { Bad 'the name read as free while another process held it - the observation is broken' }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($fail.Count) {
    Write-Output ('PROBE FAILED: ' + $fail.Count + ' assertion(s)')
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output 'PROBE OK: the mutex keys on data root + SID, not on the install folder'
exit 0
