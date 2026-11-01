<# Background lease expiry. This file is invoked with an explicit data root. #>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$DataDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$env:KA_DATA = $DataDir
. (Join-Path $root 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $root 'ka-core.ps1')
. (Join-Path $PSScriptRoot 'lease-model.ps1')
. (Join-Path $PSScriptRoot 'lease-store.ps1')
$mutex = New-Object System.Threading.Mutex($false, ('Global\' + (Get-KaIdentitySuffix 'KA-LeaseKeeper')))
$owned = $false
try {
    # A second keeper waits briefly so that an acquisition racing an exiting keeper
    # still gets a successor; otherwise an existing keeper remains the only runner.
    try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(15)) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
    $nextHealth = [long]0
    while ($true) {
        $result = Invoke-KaOperationLocked {
            $sweep = Invoke-KaLeaseSweep
            if ([int]$sweep.activeLeases -eq 0 -and -not $sweep.pendingPause) {
                # Release singleton ownership before releasing the operation lock.
                # A concurrent acquire can then start a successor without a gap.
                $mutex.ReleaseMutex()
                $sweep['keeperReleased'] = $true
            }
            return $sweep
        }
        if ($result.keeperReleased) { $owned = $false; break }
        $uptime = Get-KaLeaseUptimeMs
        if ($uptime -ge $nextHealth) {
            [void](Invoke-KaLeaseRecover)
            $nextHealth = $uptime + 5000
        }
        Start-Sleep -Seconds 1
    }
} catch {
    Add-KaLog ('LEASE-KEEPER-FAILED err=' + (Get-KaErrorToken $_))
    exit 1
} finally {
    if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
