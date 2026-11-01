# Real cross-process ledger and mutex; only the power worker itself is simulated.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('_tmp\lease-race-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data -Force | Out-Null
$childPath = Join-Path $data 'child.ps1'
$source = @'
param($Root, $Data, $Owner, $Token, $Action, $LeaseId)
$ErrorActionPreference = 'Stop'; $env:KA_DATA = $Data
. (Join-Path $Root 'ka-core.ps1')
. (Join-Path $Root 'integrations\mcp\lease-model.ps1')
. (Join-Path $Root 'integrations\mcp\lease-store.ps1')
function Get-KaIntent { @{ desired = 'off'; expiresEpoch = 0 } }
function Get-KaWorkerState { $null }
function Start-KaLeaseKeeper { }
function Invoke-KaProtectionStartInternal {
    param($Minutes, $Override)
    [IO.File]::AppendAllText((Join-Path $Data 'events'), "start`n")
    Start-Sleep -Milliseconds 250
    @{ Ok = $true; intentWritten = $true }
}
function Invoke-KaProtectionStopInternal {
    param($Reason)
    [IO.File]::AppendAllText((Join-Path $Data 'events'), "stop`n")
    @{ intentWritten = $true }
}
if ($Action -eq 'acquire') {
    $r = Invoke-KaLeaseAcquire -Owner $Owner -Token $Token -Reason $Owner -Minutes 5 -RequestId 'same-request'
} else { $r = Invoke-KaLeaseChange -Owner $Owner -Token $Token -Id $LeaseId -Action release }
if (-not $r.ok) { throw 'lease operation failed' }
[IO.File]::WriteAllText((Join-Path $Data "$Owner-$Action.json"), ($r | ConvertTo-Json -Depth 8))
'@
[IO.File]::WriteAllText($childPath, $source, (New-Object Text.UTF8Encoding($true)))
$exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Launch([string]$Owner, [string]$Token, [string]$Action, [string]$Id = '') {
    $args_ = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $childPath),
        '-Root',('"{0}"' -f $root),'-Data',('"{0}"' -f $data),'-Owner',$Owner,'-Token',$Token,'-Action',$Action)
    if ($Id) { $args_ += @('-LeaseId', $Id) }
    Start-Process $exe -ArgumentList $args_ -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $data "$Owner-$Action.out") -RedirectStandardError (Join-Path $data "$Owner-$Action.err")
}
$aToken = 'a' * 64; $bToken = 'b' * 64; $running = @()
try {
    $running = @((Launch 'a' $aToken 'acquire'), (Launch 'b' $bToken 'acquire'))
    foreach ($p in $running) { if (-not $p.WaitForExit(30000)) { throw 'acquire timed out' } }
    $aFile = Join-Path $data 'a-acquire.json'; $bFile = Join-Path $data 'b-acquire.json'
    if (-not (Test-Path $aFile) -or -not (Test-Path $bFile)) { throw 'a concurrent acquisition failed' }
    $a = Get-Content $aFile -Raw | ConvertFrom-Json; $b = Get-Content $bFile -Raw | ConvertFrom-Json
    $ledger = Get-Content (Join-Path $data 'leases.json') -Raw | ConvertFrom-Json
    if (@($ledger.leases).Count -ne 2) { throw 'concurrent acquisitions lost a lease' }
    $running = @((Launch 'a' $aToken 'release' $a.id), (Launch 'b' $bToken 'release' $b.id))
    foreach ($p in $running) { if (-not $p.WaitForExit(30000)) { throw 'release timed out' } }
    if (-not (Test-Path (Join-Path $data 'a-release.json')) -or -not (Test-Path (Join-Path $data 'b-release.json'))) { throw 'a concurrent release failed' }
    $events = @(Get-Content (Join-Path $data 'events'))
    if (@($events | Where-Object { $_ -eq 'stop' }).Count -ne 1 -or $events[-1] -ne 'stop') { throw 'a release stopped a surviving lease' }
    $ledger = Get-Content (Join-Path $data 'leases.json') -Raw | ConvertFrom-Json
    if (@($ledger.leases).Count -ne 0) { throw 'leases remained after release' }
    Write-Host 'PROBE OK: concurrent acquisition and release preserve independent leases'
} finally { foreach ($p in $running) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } } }
