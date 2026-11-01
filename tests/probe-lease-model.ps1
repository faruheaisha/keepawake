$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'integrations\mcp\lease-model.ps1')
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
$now = [long]1700000000
$tokenA = New-KaLeaseToken; $tokenB = New-KaLeaseToken
Assert ($tokenA -cne $tokenB) 'random lease tokens collided'
$a = New-KaLeaseRecord -Reason 'build' -Minutes 10 -KeepDisplayOn $false -AntiLock $false `
    -Owner 'client-a' -TokenHash (Get-KaLeaseTokenHash $tokenA) -Now $now -RequestId 'r1'
$b = New-KaLeaseRecord -Reason 'render' -Minutes 20 -KeepDisplayOn $true -AntiLock $true `
    -Owner 'client-b' -TokenHash (Get-KaLeaseTokenHash $tokenB) -Now $now
$leases = @($a, $b)
$aggregate = Get-KaLeaseAggregate -Leases $leases -Now $now
Assert ($aggregate.active -and $aggregate.count -eq 2 -and $aggregate.keepDisplayOn -and $aggregate.antiLock) 'aggregate did not combine both leases'
Assert ($aggregate.expiresEpoch -eq ($now + 1200)) 'aggregate did not use the last expiry'
$unauthorized = Update-KaLeaseRecord -Leases $leases -Id $a.id -Token $tokenB -Owner 'client-a' -Now $now -Action release
Assert (-not $unauthorized.ok -and $unauthorized.leases.Count -eq 2) 'wrong token released a lease'
$wrongOwner = Update-KaLeaseRecord -Leases $leases -Id $a.id -Token $tokenA -Owner 'client-b' -Now $now -Action release
Assert (-not $wrongOwner.ok) 'wrong owner released a lease'
$renewed = Update-KaLeaseRecord -Leases $leases -Id $a.id -Token $tokenA -Owner 'client-a' -Now ($now + 1) -Action renew -Minutes 30
Assert ($renewed.ok -and $renewed.expiresEpoch -eq ($now + 1801)) 'renewal did not extend the requested lease'
Assert ($a.expiresEpoch -eq ($now + 600)) 'renewal mutated the input record'
$released = Update-KaLeaseRecord -Leases $leases -Id $a.id -Token $tokenA -Owner 'client-a' -Now $now -Action release
$left = Get-KaLeaseAggregate -Leases $released.leases -Now $now
Assert ($released.ok -and $left.active -and $left.count -eq 1) 'releasing A affected B'
$again = Update-KaLeaseRecord -Leases $released.leases -Tombstones $released.tombstones -Id $a.id -Token $tokenA -Owner 'client-a' -Now ($now + 1) -Action release
Assert ($again.ok -and $again.alreadyReleased -and $again.leases.Count -eq 1) 'repeated release was not idempotent'
$forged = Update-KaLeaseRecord -Leases $released.leases -Tombstones $released.tombstones -Id $a.id -Token $tokenB -Owner 'client-a' -Now ($now + 1) -Action release
Assert (-not $forged.ok) 'tombstone accepted a forged token'
$public = @(Get-KaLeasePublicSnapshot -Leases $leases -Now $now)
Assert ($public.Count -eq 2 -and -not $public[0].PSObject.Properties['tokenHash']) 'public snapshot leaked a token hash'
$expired = Get-KaLeaseAggregate -Leases $leases -Now ($now + 1200)
Assert (-not $expired.active -and $expired.count -eq 0) 'leases did not expire at their boundary'
$manual = @{ active = $true; expiresEpoch = 0; keepDisplayOn = $false; antiLock = $false }
$combined = Get-KaLeaseAggregate -Leases $leases -Manual $manual -Now $now
Assert ($combined.active -and $combined.manualActive -and $combined.expiresEpoch -eq 0) 'unlimited manual protection was shortened'
$jsonCopy = $a | ConvertTo-Json | ConvertFrom-Json
$jsonRenewal = Update-KaLeaseRecord -Leases @($jsonCopy) -Id $a.id -Token $tokenA -Owner 'client-a' -Now $now -Action renew -Minutes 5
Assert ($jsonRenewal.ok -and $jsonRenewal.expiresEpoch -eq ($now + 300)) 'deserialized lease could not be renewed'
foreach ($bad in @(0, -1, 1441)) {
    $threw = $false
    try { [void](New-KaLeaseRecord -Reason 'x' -Minutes $bad -Owner 'client-a' -TokenHash (Get-KaLeaseTokenHash $tokenA) -Now $now) } catch { $threw = $true }
    Assert $threw "invalid duration was accepted: $bad"
}
Write-Host 'PROBE OK: independent leases, token authorization, renewal, expiry, manual protection and JSON roundtrip'
