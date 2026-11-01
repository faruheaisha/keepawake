# Exercise the real orchestration lock with two independent PowerShell processes.
# Worker operations are fixtures; this probe never changes the actual power state.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root '_tmp\operation-lock-probe'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$data = Join-Path $dir ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data -Force | Out-Null
$scriptPath = Join-Path $data 'child.ps1'
$src = @'
param($Root, $Data, $Mode)
$ErrorActionPreference = 'Stop'
$env:KA_DATA = $Data
. (Join-Path $Root 'ka-core.ps1')
$live = Join-Path $Data 'fake-worker'
function Get-KaWorker { if (Test-Path -LiteralPath $live) { [PSCustomObject]@{ Pid = 123456 } } }
function Start-KaWorker {
    param($Minutes, $Override)
    [IO.File]::WriteAllText($live, 'live')
    Start-Sleep -Seconds 3
    return @{ Ok = $true; Pid = 123456; StateRecorded = $true }
}
function Stop-KaWorker {
    param($Reason)
    Remove-Item -LiteralPath $live -Force -ErrorAction SilentlyContinue
    return @{ Stopped = 1; Forced = 0; Cooperative = $true }
}
function Get-KaSessionAdoption { return $false }
if ($Mode -eq 'start') {
    $r = Start-KaProtection
    if (-not $r.Ok -or -not $r.intentWritten) { throw 'start failed' }
    [IO.File]::WriteAllText((Join-Path $Data 'start-result'), 'ok')
} else {
    $r = Reconcile-KaProtection
    [IO.File]::WriteAllText((Join-Path $Data 'guard-result'), $r.action)
}
'@
[IO.File]::WriteAllText($scriptPath, $src, (New-Object Text.UTF8Encoding($true)))
$exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Launch([string]$Mode) {
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $scriptPath),
               '-Root', ('"{0}"' -f $root), '-Data', ('"{0}"' -f $data), '-Mode', $Mode)
    Start-Process -FilePath $exe -ArgumentList $args_ -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $data "$Mode.out") -RedirectStandardError (Join-Path $data "$Mode.err")
}
$start = $null; $guard = $null
try {
    $start = Launch 'start'
    $end = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath (Join-Path $data 'fake-worker')) -and (Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath (Join-Path $data 'fake-worker'))) { throw 'start fixture did not reach the interleaving point' }
    $guard = Launch 'guard'
    if (-not $start.WaitForExit(30000) -or -not $guard.WaitForExit(30000)) { throw 'fixture timed out' }
    if (-not (Test-Path -LiteralPath (Join-Path $data 'start-result'))) { throw 'start did not report success' }
    if (-not (Test-Path -LiteralPath (Join-Path $data 'guard-result'))) { throw 'guard did not report success' }
    $intent = [IO.File]::ReadAllText((Join-Path $data 'intent.json')) | ConvertFrom-Json
    if ($intent.desired -ne 'awake' -or -not (Test-Path -LiteralPath (Join-Path $data 'fake-worker'))) {
        throw 'guard stopped the worker during start'
    }
    Write-Host 'PROBE OK: start and guard serialize across processes; awake intent and worker agree'
} finally {
    foreach ($p in @($start, $guard)) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } }
}
