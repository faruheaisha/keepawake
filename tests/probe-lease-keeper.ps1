# Exercise keeper startup and clean shutdown with a future-dated fixture lease.
# The fixture never expires during the test, so no actual power request is made.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('_tmp\keeper-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data -Force | Out-Null
$env:KA_DATA = $data
. (Join-Path $root 'ka-core.ps1')
$now = Get-KaEpoch
$token = New-KaLeaseToken
$record = New-KaLeaseRecord -Reason 'keeper fixture' -Minutes 5 -Owner 'fixture' `
    -TokenHash (Get-KaLeaseTokenHash $token) -Now $now -BootEpoch (Get-KaLeaseBootEpoch) -UptimeMs (Get-KaLeaseUptimeMs)
$ledger = @{ version = 1; manual = @{ active = $false; expiresEpoch = 0; keepDisplayOn = $false; antiLock = $false; options = @{} }
    leases = @($record); tombstones = @() }
if (-not (Write-KaJson (Join-Path $data 'intent.json') @{ desired = 'awake'; expiresEpoch = 0; minutes = 0; updatedAt = $now })) { throw 'fixture intent write failed' }
Set-KaLeaseLedger $ledger
$ownedPids = @()
$fakeDir = Join-Path $data 'fake-program'
New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
$fakeScript = Join-Path $fakeDir 'ka-worker.ps1'
$sentinel = Join-Path $data 'fake-running'
[IO.File]::WriteAllText($sentinel, 'running')
[IO.File]::WriteAllText($fakeScript, 'param([string]$DataDir) while (Test-Path -LiteralPath (Join-Path $DataDir ''fake-running'')) { Start-Sleep -Milliseconds 200 }', (New-Object Text.UTF8Encoding($true)))
$fake = Start-Process powershell.exe -ArgumentList @('-NoProfile','-File',('"{0}"' -f $fakeScript),'-DataDir',('"{0}"' -f $data)) -WindowStyle Hidden -PassThru
try {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and @((Get-KaWorker) | Where-Object { $_.Pid -eq $fake.Id }).Count -eq 0) { Start-Sleep -Milliseconds 200 }
    if (@((Get-KaWorker) | Where-Object { $_.Pid -eq $fake.Id }).Count -ne 1) { throw 'fake worker was not discoverable' }
    Start-KaLeaseKeeper
    $found = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        "$($_.CommandLine)" -like '*integrations\mcp\keeper.ps1*' -and "$($_.CommandLine)" -like "*$data*"
    })
    if ($found.Count -ne 1) { throw "expected one keeper, got $($found.Count)" }
    $ownedPids = @($found | ForEach-Object { [int]$_.ProcessId })
    $ledger.leases = @()
    if (-not (Write-KaJson (Get-KaLeaseLedgerPath) $ledger)) { throw 'fixture update failed' }
    $end = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $end -and (Get-Process -Id $ownedPids[0] -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 200 }
    if (Get-Process -Id $ownedPids[0] -ErrorAction SilentlyContinue) { throw 'keeper did not exit after the final lease disappeared' }
    Write-Host 'PROBE OK: keeper starts for its data root and exits after the last lease'
} finally {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
    if ($fake -and -not $fake.HasExited -and -not $fake.WaitForExit(5000)) { try { $fake.Kill() } catch {} }
    foreach ($id in $ownedPids) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if ($p -and "$($p.CommandLine)" -like '*integrations\mcp\keeper.ps1*' -and "$($p.CommandLine)" -like "*$data*") {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
    }
}
