# Exercise omitted runtime options and recycled PID evidence without system mutations.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:KA_DATA = Join-Path $root ('_tmp\runtime-identity-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $root 'ka-core.ps1')
function Assert-Runtime([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message }; Write-Host ('  ok   ' + $Message) }
& {
    $script:stops = 0
    $baseline = Get-KaDefaultConfig
    $sample = @{ keepDisplayOn = $baseline.keepDisplayOn; antiLock = $baseline.antiLock; awayMode = $baseline.awayMode;
        antiLockMethod = $baseline.antiLockMethod; antiLockInterval = $baseline.antiLockIntervalSec;
        reassertSec = $baseline.reassertSec; batteryFloor = $baseline.batteryFloorPercent; batteryAllowDisplayOff = $baseline.batteryAllowDisplayOff; expiresEpoch = 0 }
    function Test-KaCriticalBattery { $false }
    function Get-KaWorker { [pscustomobject]@{ Pid = 1234 } }
    function Read-KaJson { $sample }
    function Stop-KaWorker { $script:stops++; @{ Remaining = 0 } }
    function Start-KaWorker { param($Minutes, $Override) @{ Ok = $true } }
    function Set-KaIntent { $true }
    $same = Invoke-KaProtectionStartInternal
    Assert-Runtime (-not $same.restarted -and $script:stops -eq 0) 'an identical unlimited request preserves the worker'
    foreach ($entry in @(@{ reassertSec = 90 }, @{ batteryAllowDisplayOff = $false })) {
        $script:stops = 0
        $result = Invoke-KaProtectionStartInternal -Override $entry
        $key = @($entry.Keys)[0]
        Assert-Runtime ($result.restarted -and $script:stops -eq 1 -and $result.applied[$key] -eq $entry[$key]) ('changing ' + $key + ' restarts with a truthful response')
    }
}
& {
    $now = Get-KaEpoch; $started = $now - 120
    $script:fakeWorkers = @()
    $sample = [pscustomobject]@{ pid = $PID; startedEpoch = $started; processStartedEpoch = ($started - 1) }
    function Read-KaJson { $sample }
    function Get-KaWorker { $script:fakeWorkers }
    $unknown = Get-KaProtectedSpan
    Assert-Runtime (-not $unknown.known -and $unknown.spans.Count -eq 0) 'an unrelated real PID cannot establish protection evidence'
    $script:fakeWorkers = @([pscustomobject]@{ Pid = $PID; StartEpoch = ($started - 2) })
    $reused = Get-KaProtectedSpan
    Assert-Runtime (-not $reused.known -and $reused.spans.Count -eq 0) 'even a one-second creation mismatch rejects a recycled PID'
    $script:fakeWorkers = @([pscustomobject]@{ Pid = $PID; StartEpoch = ($started - 1) })
    $live = Get-KaProtectedSpan
    Assert-Runtime ($live.known -and $live.spans.Count -eq 1 -and $live.spans[0].from -eq $started) 'an exact owned worker identity establishes a live span'
}
Write-Host 'PROBE OK: runtime options and exact process creation identity'
