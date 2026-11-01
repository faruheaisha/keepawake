$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'integrations\mcp\lease-model.ps1')
. (Join-Path $root 'integrations\mcp\lease-store.ps1')
$data = Join-Path $root ('_tmp\lease-store-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data -Force | Out-Null
$script:fakeNow = [long]1700000000
$script:fakeBoot = [long]1699990000
$script:fakeUptime = [long]500000
$script:fakeActive = $false; $script:fakeOverride = @{}; $script:fakeMinutes = 0; $script:failApply = $false
function Get-KaDataRoot { $data }
function Get-KaEpoch { $script:fakeNow }
function Get-KaLeaseBootEpoch { $script:fakeBoot }
function Get-KaLeaseUptimeMs { $script:fakeUptime }
function Get-KaIntent { @{ desired = 'off'; expiresEpoch = 0 } }
function Get-KaConfig { @{ keepDisplayOn = $true; antiLock = $true } }
function Get-KaWorkerState { $null }
function Get-KaWorker { if ($script:fakeActive) { [PSCustomObject]@{ Pid = 123456 } } }
function Invoke-KaOperationLocked { param([scriptblock]$Operation) & $Operation }
function Start-KaLeaseKeeper { }
function Read-KaJson { param($Path) try { [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { $null } }
function Write-KaJson { param($Path, $Object, $Depth) [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth $Depth)); $true }
function Invoke-KaProtectionStartInternal {
    param($Minutes, $Override)
    if ($script:failApply) { $script:failApply = $false; return @{ Ok = $false; intentWritten = $false } }
    $script:fakeActive = $true; $script:fakeOverride = $Override; $script:fakeMinutes = $Minutes
    [IO.File]::WriteAllText((Join-Path $data 'intent.json'), '{"desired":"awake"}')
    return @{ Ok = $true; intentWritten = $true }
}
function Invoke-KaProtectionStopInternal { param($Reason) $script:fakeActive = $false; [IO.File]::WriteAllText((Join-Path $data 'intent.json'), '{"desired":"off"}'); return @{ intentWritten = $true } }
function Set-KaIntent { param($Desired) [IO.File]::WriteAllText((Join-Path $data 'intent.json'), ('{"desired":"' + $Desired + '"}')); return $true }
function Stop-KaWorker { param($Reason) $script:fakeActive = $false; return @{ Stopped = 1; Forced = 0; Cooperative = $true } }
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Test-KaCriticalBattery { return [bool]$script:criticalBattery }
$tokenA = New-KaLeaseToken; $tokenB = New-KaLeaseToken
$a = Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'build' -Minutes 10 -RequestId 'req-a'
Assert ($a.ok -and $script:fakeActive) 'first acquisition did not establish protection'
$replay = Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'build' -Minutes 10 -RequestId 'req-a'
Assert ($replay.replayed -and $replay.id -eq $a.id) 'replayed acquisition created a second lease'
$renewed = Invoke-KaLeaseChange -Owner 'client-a' -Token $tokenA -Id $a.id -Action renew -Minutes 15
$replayAfterRenew = Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'build' -Minutes 10 -RequestId 'req-a'
Assert ($renewed.ok -and $replayAfterRenew.replayed -and $replayAfterRenew.id -eq $a.id) 'renewal broke acquisition replay'
$conflict = $false
try { [void](Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'changed' -Minutes 10 -RequestId 'req-a') } catch { $conflict = $true }
Assert $conflict 'conflicting request id was accepted'
$b = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'render' -Minutes 20 -KeepDisplayOn $true
Assert ($b.ok -and $script:fakeOverride.keepDisplayOn) 'second acquisition did not update aggregate'
$deny = Invoke-KaLeaseChange -Owner 'client-a' -Token $tokenB -Id $a.id -Action release
Assert (-not $deny.ok -and $script:fakeActive) 'wrong token released protection'
$r = Invoke-KaLeaseChange -Owner 'client-a' -Token $tokenA -Id $a.id -Action release
Assert ($r.ok -and $script:fakeActive) 'releasing A stopped B'
$afterReleaseReplay = Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'build' -Minutes 10 -RequestId 'req-a'
Assert ($afterReleaseReplay.ok -and $afterReleaseReplay.alreadyReleased -and $afterReleaseReplay.id -eq $a.id) 'replayed acquisition recreated a released task'
$again = Invoke-KaLeaseChange -Owner 'client-a' -Token $tokenA -Id $a.id -Action release
Assert ($again.ok -and $again.alreadyReleased) 'repeated release failed'
$r = Invoke-KaLeaseChange -Owner 'client-b' -Token $tokenB -Id $b.id -Action release
Assert ($r.ok -and -not $script:fakeActive) 'last release did not stop protection'
$script:failApply = $true; $failed = $false
try { [void](Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'fail' -Minutes 10) } catch { $failed = $true }
$ledger = Get-KaLeaseLedger
Assert ($failed -and @($ledger.leases).Count -eq 0 -and -not $script:fakeActive) 'failed acquisition did not restore the previous ledger'
$serialized = [IO.File]::ReadAllText((Get-KaLeaseLedgerPath))
Assert (-not $serialized.Contains($tokenA) -and -not $serialized.Contains($tokenB)) 'ledger contains a raw token'
$a = Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'short' -Minutes 1 -KeepDisplayOn $true
$b = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'long' -Minutes 2
$script:fakeNow += 60
$script:fakeUptime += 60000
$sweep = Invoke-KaLeaseSweep
Assert ($sweep.changed -and $sweep.activeLeases -eq 1 -and $script:fakeActive -and -not $script:fakeOverride.keepDisplayOn) 'expiry did not update the surviving aggregate'
$script:fakeNow += 60
$script:fakeUptime += 60000
$sweep = Invoke-KaLeaseSweep
Assert ($sweep.changed -and $sweep.activeLeases -eq 0 -and -not $script:fakeActive) 'last expired lease did not release protection'
$task = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'manual-test' -Minutes 5
$manualStart = Invoke-KaLeaseManualStart -Minutes 0 -Override @{ antiLock = $false; keepDisplayOn = $false }
Assert ($manualStart.Ok -and $script:fakeActive) 'manual protection did not start alongside task'
$releaseTask = Invoke-KaLeaseChange -Owner 'client-b' -Token $tokenB -Id $task.id -Action release
Assert ($releaseTask.ok -and $script:fakeActive) 'task release stopped manual protection'
$task2 = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'cancel-test' -Minutes 5 -RequestId 'stop-retry'
$stopAll = Invoke-KaLeaseStopAll
$renewRevoked = Invoke-KaLeaseChange -Owner 'client-b' -Token $tokenB -Id $task2.id -Action renew -Minutes 5
Assert ($stopAll.intentWritten -and -not $script:fakeActive -and -not $renewRevoked.ok) 'manual stop did not revoke task protection'
$stopReplay = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'cancel-test' -Minutes 5 -RequestId 'stop-retry'
Assert ($stopReplay.alreadyReleased -and $stopReplay.id -eq $task2.id -and -not $script:fakeActive) 'retry after global stop recreated protection'
$expiryTask = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'expiry-retry' -Minutes 1 -RequestId 'expiry-retry'
$script:fakeUptime += 60000; $script:fakeNow += 60
$expiryReplay = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'expiry-retry' -Minutes 1 -RequestId 'expiry-retry'
Assert ($expiryReplay.alreadyReleased -and $expiryReplay.id -eq $expiryTask.id -and -not $script:fakeActive) 'retry after expiry recreated protection'
$task = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'user-release' -Minutes 5
$userRelease = Invoke-KaLeaseUserRelease -Id $task.id
$clientRetry = Invoke-KaLeaseChange -Owner 'client-b' -Token $tokenB -Id $task.id -Action release
Assert ($userRelease.ok -and -not $script:fakeActive -and $clientRetry.ok -and $clientRetry.alreadyReleased) 'user release did not preserve idempotent client cleanup'
$bootTask = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'reboot-test' -Minutes 5
$script:fakeBoot += 300
$script:fakeUptime = 1000
$sweep = Invoke-KaLeaseSweep
Assert ($sweep.changed -and $sweep.activeLeases -eq 0 -and -not $script:fakeActive) 'a previous-boot task survived reboot reconciliation'
$clockTask = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'clock-test' -Minutes 1
$script:fakeActive = $false
$recovered = Invoke-KaLeaseRecover
Assert ($recovered.recovered -and $script:fakeActive) 'keeper did not recover a missing task worker'
$script:fakeUptime += 10000; $script:fakeNow -= 3600
$sweep = Invoke-KaLeaseSweep
Assert ($sweep.changed -and $script:fakeActive -and $script:fakeMinutes -gt 0.8 -and $script:fakeMinutes -lt 0.9) 'backward clock adjustment changed a relative lease duration'
$script:fakeUptime += 10000; $script:fakeNow += 7200
$sweep = Invoke-KaLeaseSweep
Assert ($sweep.changed -and $script:fakeActive -and $script:fakeMinutes -gt 0.6 -and $script:fakeMinutes -lt 0.7) 'forward clock adjustment ended a live lease'
$script:fakeUptime += 40000; $script:fakeNow += 40
$sweep = Invoke-KaLeaseSweep
Assert ($sweep.changed -and -not $script:fakeActive) 'monotonic lease deadline did not expire'
$pauseTask = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'pause-test' -Minutes 5
$pause = Invoke-KaLeasePause -Minutes 1
Assert ($pause.ok -and -not $script:fakeActive) 'pause did not release power request'
$blocked = $false
try { [void](Invoke-KaLeaseAcquire -Owner 'client-a' -Token $tokenA -Reason 'blocked' -Minutes 1) } catch { $blocked = $true }
Assert $blocked 'a new task bypassed the user pause'
$renewPaused = Invoke-KaLeaseChange -Owner 'client-b' -Token $tokenB -Id $pauseTask.id -Action renew -Minutes 5
Assert ($renewPaused.ok -and $renewPaused.effective.paused -and -not $script:fakeActive) 'renewal bypassed the user pause'
$script:fakeUptime += 60000; $script:fakeNow += 60
$resumed = Invoke-KaLeaseSweep
Assert ($resumed.changed -and $script:fakeActive) 'pause did not resume surviving protection'
$pause = Invoke-KaLeasePause -Minutes 1
$stopAll = Invoke-KaLeaseStopAll
$script:fakeUptime += 60000; $script:fakeNow += 60
$sweep = Invoke-KaLeaseSweep
Assert (-not $script:fakeActive -and $sweep.activeLeases -eq 0 -and -not $sweep.pendingPause) 'global stop did not cancel automatic resume'
$batteryTask = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'battery-test' -Minutes 5 -RequestId 'battery-test'
$script:criticalBattery = $true
$batteryRecover = Invoke-KaLeaseRecover
Assert ($batteryRecover.stoppedForBattery -and -not $script:fakeActive -and @((Get-KaLeaseLedger).leases).Count -eq 0) 'critical battery did not revoke tasks and stop protection'
$batteryDenied = $false
try { [void](Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'battery-test' -Minutes 5 -RequestId 'battery-test') } catch { $batteryDenied = $true }
Assert $batteryDenied 'critical battery allowed a new task to restart protection'
$script:criticalBattery = $false
$batteryReplay = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'battery-test' -Minutes 5 -RequestId 'battery-test'
Assert ($batteryReplay.alreadyReleased -and -not $script:fakeActive) 'retry after critical battery restored a revoked task'
$policyTask = Invoke-KaLeaseAcquire -Owner 'client-b' -Token $tokenB -Reason 'supply-test' -Minutes 5
$script:fakeActive = $false
[IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"exitReason":"battery-limit"}')
$policyRecover = Invoke-KaLeaseRecover
Assert ($policyRecover.stoppedForBattery -and -not $script:fakeActive -and @((Get-KaLeaseLedger).leases).Count -eq 0) 'keeper restarted protection after a battery time limit'
Remove-Item -LiteralPath (Join-Path $data 'state.json')
$badFile = Get-KaLeaseLedgerPath
$bad = '{"version":1,"manual":{"active":false,"expiresEpoch":0,"keepDisplayOn":false,"antiLock":false},"leases":[{"id":"bad"}],"tombstones":[]}'
[IO.File]::WriteAllText($badFile, $bad)
$threw = $false
try { [void](Get-KaLeaseLedger) } catch { $threw = $true }
Assert ($threw -and [IO.File]::ReadAllText($badFile) -ceq $bad) 'malformed ledger was silently consumed or overwritten'
Write-Host 'PROBE OK: lease transactions, replay, authorization, independent release and rollback'
