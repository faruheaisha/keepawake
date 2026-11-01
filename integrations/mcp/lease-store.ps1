# Lease transactions. The host dot-sources ka-core.ps1 and lease-model.ps1 first.
# The caller must run all public operations through Invoke-KaOperationLocked.

function Get-KaLeaseLedgerPath { Join-Path (Get-KaDataRoot) 'leases.json' }
function Get-KaLeaseUptimeMs { return [long][Ka.Native]::SystemUptimeMilliseconds() }

function Get-KaLeaseBootEpoch {
    # Boot time is a fixed OS fact. Calculating it from wall time minus uptime would
    # change whenever the user adjusts the clock and could falsely revoke a lease.
    if ($script:KaLeaseBootEpoch -gt 0) { return [long]$script:KaLeaseBootEpoch }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if (-not $os.LastBootUpTime) { throw 'system boot time is unavailable' }
    $boot = [DateTimeOffset]::new([datetime]$os.LastBootUpTime).ToUnixTimeSeconds()
    if ($boot -le 0) { throw 'system boot time is unavailable' }
    $script:KaLeaseBootEpoch = [long]$boot
    return [long]$boot
}

function Get-KaLeaseBootLeases {
    param($Leases, [long]$Now)
    if (@($Leases | Where-Object { $_ }).Count -eq 0) { return @() }
    $boot = Get-KaLeaseBootEpoch
    if ($boot -le 0) { throw 'system boot time is unavailable' }
    return @(Get-KaLiveLeases -Leases $Leases -Now $Now -UptimeMs (Get-KaLeaseUptimeMs) | Where-Object {
        [long]$_.bootEpoch -gt 0 -and [math]::Abs([long]$_.bootEpoch - $boot) -le 5
    })
}

function Get-KaLeaseTombstones {
    param($Ledger, $Live, [long]$Now)
    $recent = @($Ledger.tombstones | Where-Object { $_ -and [long]$_.untilEpoch -gt $Now })
    $activeIds = @{}; foreach ($l in @($Live)) { $activeIds["$($l.id)"] = $true }
    foreach ($l in @($Ledger.leases)) {
        if ($activeIds.ContainsKey("$($l.id)")) { continue }
        $recent += @{ id = "$($l.id)"; owner = "$($l.owner)"; tokenHash = "$($l.tokenHash)"; untilEpoch = $Now + 86400
                      requestId = "$($l.requestId)"; requestFingerprint = "$($l.requestFingerprint)" }
    }
    return $recent
}

function Get-KaLeaseInitialLedger {
    $intent = Get-KaIntent
    $cfg = Get-KaConfig
    $state = Get-KaWorkerState
    $options = @{}
    foreach ($k in @('keepDisplayOn','antiLock','awayMode','antiLockMethod','antiLockIntervalSec','reassertSec','batteryFloorPercent','batteryAllowDisplayOff')) {
        if ($cfg.ContainsKey($k)) { $options[$k] = $cfg[$k] }
    }
    $manual = @{ active = ("$($intent.desired)" -eq 'awake'); expiresEpoch = [long]$intent.expiresEpoch
                 keepDisplayOn = [bool]$cfg.keepDisplayOn; antiLock = [bool]$cfg.antiLock; options = $options }
    if ($state) {
        $manual.keepDisplayOn = [bool]$state.keepDisplayOn; $manual.antiLock = [bool]$state.antiLock
        foreach ($pair in @(@('keepDisplayOn','keepDisplayOn'),@('antiLock','antiLock'),@('awayMode','awayMode'),
                 @('antiLockMethod','antiLockMethod'),@('antiLockIntervalSec','antiLockInterval'),
                 @('reassertSec','reassertSec'),@('batteryFloorPercent','batteryFloor'),@('batteryAllowDisplayOff','batteryAllowDisplayOff'))) {
            if ($null -ne $state.($pair[1])) { $options[$pair[0]] = $state.($pair[1]) }
        }
    }
    return @{ version = 1; manual = $manual; leases = @(); tombstones = @(); pause = $null
              clockEpoch = (Get-KaEpoch); clockUptimeMs = (Get-KaLeaseUptimeMs) }
}

function Get-KaLeaseLedger {
    $path = Get-KaLeaseLedgerPath
    if (-not (Test-Path -LiteralPath $path)) { return (Get-KaLeaseInitialLedger) }
    $raw = Read-KaJson $path
    if (-not $raw -or [int]$raw.version -ne 1 -or $null -eq $raw.manual -or
        $null -eq $raw.leases -or $null -eq $raw.tombstones) { throw 'lease ledger is unreadable or has an unsupported version' }
    $manualExpiry = [long]0
    if ($raw.manual.active -isnot [bool] -or $raw.manual.keepDisplayOn -isnot [bool] -or
        $raw.manual.antiLock -isnot [bool] -or -not [long]::TryParse("$($raw.manual.expiresEpoch)", [ref]$manualExpiry) -or $manualExpiry -lt 0) {
        throw 'lease ledger contains an invalid manual record'
    }
    $ids = @{}
    foreach ($entry in @($raw.leases)) {
        $expiry = [long]0; $created = [long]0; $boot = [long]0; $uptimeExpiry = [long]0
        if (-not $entry -or "$($entry.id)" -cnotmatch '^[0-9a-f]{32}$' -or
            "$($entry.owner)" -cnotmatch '^[a-zA-Z0-9_-]{1,80}$' -or "$($entry.tokenHash)" -cnotmatch '^[0-9a-f]{64}$' -or
            $entry.keepDisplayOn -isnot [bool] -or $entry.antiLock -isnot [bool] -or
            -not [long]::TryParse("$($entry.createdEpoch)", [ref]$created) -or
            -not [long]::TryParse("$($entry.expiresEpoch)", [ref]$expiry) -or
            -not [long]::TryParse("$($entry.bootEpoch)", [ref]$boot) -or
            -not [long]::TryParse("$($entry.expiresUptimeMs)", [ref]$uptimeExpiry) -or
            $created -le 0 -or $expiry -le 0 -or $boot -le 0 -or $uptimeExpiry -le 0 -or $ids.ContainsKey("$($entry.id)")) {
            throw 'lease ledger contains an invalid lease record'
        }
        $ids["$($entry.id)"] = $true
    }
    foreach ($entry in @($raw.tombstones)) {
        $until = [long]0
        if (-not $entry -or "$($entry.id)" -cnotmatch '^[0-9a-f]{32}$' -or
            "$($entry.owner)" -cnotmatch '^[a-zA-Z0-9_-]{1,80}$' -or "$($entry.tokenHash)" -cnotmatch '^[0-9a-f]{64}$' -or
            -not [long]::TryParse("$($entry.untilEpoch)", [ref]$until) -or $until -le 0 -or $ids.ContainsKey("$($entry.id)")) {
            throw 'lease ledger contains an invalid tombstone'
        }
        $ids["$($entry.id)"] = $true
    }
    $clockEpoch = [long]0; $clockUptime = [long]0
    if (-not [long]::TryParse("$($raw.clockEpoch)", [ref]$clockEpoch) -or
        -not [long]::TryParse("$($raw.clockUptimeMs)", [ref]$clockUptime) -or $clockEpoch -le 0 -or $clockUptime -lt 0) {
        throw 'lease ledger contains an invalid clock reference'
    }
    $pause = $raw.pause
    if ($pause) {
        $until = [long]0; $bootTime = [long]0
        if (-not [long]::TryParse("$($pause.untilUptimeMs)", [ref]$until) -or $until -le 0 -or
            -not [long]::TryParse("$($pause.bootEpoch)", [ref]$bootTime) -or $bootTime -le 0) { throw 'lease ledger contains an invalid pause' }
    }
    return @{ version = 1; manual = $raw.manual; leases = @($raw.leases); tombstones = @($raw.tombstones); pause = $pause
              clockEpoch = $clockEpoch; clockUptimeMs = $clockUptime }
}

function Set-KaLeaseLedger {
    param($Ledger)
    $Ledger['clockEpoch'] = Get-KaEpoch
    $Ledger['clockUptimeMs'] = Get-KaLeaseUptimeMs
    if (-not (Write-KaJson (Get-KaLeaseLedgerPath) $Ledger -Depth 8)) { throw 'lease ledger could not be written' }
}

function Invoke-KaLeaseApplyAggregate {
    param($Ledger, [long]$Now, [string]$StopReason = 'lease-complete')
    $currentBoot = @(Get-KaLeaseBootLeases -Leases $Ledger.leases -Now $Now)
    $uptime = Get-KaLeaseUptimeMs
    $aggregate = Get-KaLeaseAggregate -Leases $currentBoot -Manual $Ledger.manual -Now $Now -UptimeMs $uptime
    $paused = $Ledger.pause -and [long]$Ledger.pause.untilUptimeMs -gt $uptime -and
        [math]::Abs([long]$Ledger.pause.bootEpoch - (Get-KaLeaseBootEpoch)) -le 5
    $aggregate['paused'] = [bool]$paused
    if ($paused) {
        $intentOk = Set-KaIntent -Desired 'paused'
        $r = Stop-KaWorker -Reason 'pause'
        if ([int]$r.Remaining -gt 0) { throw 'the worker could not be stopped for pause' }
        $r['Ok'] = [bool]$intentOk; $r['intentWritten'] = [bool]$intentOk
        if (-not $intentOk) { throw 'could not persist paused intent' }
    } elseif ($aggregate.active) {
        $minutes = if ($aggregate.expiresEpoch -gt 0) {
            [math]::Max(0.01, ($aggregate.expiresEpoch - $Now) / 60.0)
        } else { 0 }
        $options = @{}
        if ($aggregate.manualActive -and $Ledger.manual.options) {
            if ($Ledger.manual.options -is [Collections.IDictionary]) {
                foreach ($k in $Ledger.manual.options.Keys) { $options[$k] = $Ledger.manual.options[$k] }
            } else { foreach ($p in $Ledger.manual.options.PSObject.Properties) { $options[$p.Name] = $p.Value } }
        }
        $options.keepDisplayOn = [bool]$aggregate.keepDisplayOn; $options.antiLock = [bool]$aggregate.antiLock
        $r = Invoke-KaProtectionStartInternal -Minutes $minutes -Override $options
        if (-not $r.Ok -or -not $r.intentWritten) { throw 'could not establish the requested protection and intent' }
    } else {
        $r = Invoke-KaProtectionStopInternal -Reason $StopReason
        if (-not $r.intentWritten -or [int]$r.Remaining -gt 0) { throw 'could not release protection and persist the intent' }
    }
    $aggregate['process'] = $r
    return $aggregate
}

function Invoke-KaLeaseCommit {
    param($Before, $After, [long]$Now, [string]$StopReason = 'lease-complete')
    # Persist the new intent before changing the worker. On failure restore the old
    # ledger and attempt to reapply it; never report a failed transition as success.
    Set-KaLeaseLedger $After
    try { return (Invoke-KaLeaseApplyAggregate -Ledger $After -Now $Now -StopReason $StopReason) }
    catch {
        $original = $_
        try { Set-KaLeaseLedger $Before; [void](Invoke-KaLeaseApplyAggregate -Ledger $Before -Now $Now) }
        catch { throw 'lease transition failed and the previous state could not be restored' }
        throw $original
    }
}

function Confirm-KaLeaseKeeperAfterCommit {
    param($Before, $Aggregate, [long]$Now)
    if ([int]$Aggregate.count -le 0 -and -not $Aggregate.paused) { return }
    try { Start-KaLeaseKeeper }
    catch {
        $original = $_
        try { Set-KaLeaseLedger $Before; [void](Invoke-KaLeaseApplyAggregate -Ledger $Before -Now $Now) }
        catch { throw 'lease keeper failed and the previous state could not be restored' }
        throw $original
    }
}

function Invoke-KaLeaseAcquire {
    param([string]$Owner, [string]$Token, [string]$Reason, [int]$Minutes = 30,
          [bool]$KeepDisplayOn = $false, [bool]$AntiLock = $false, [string]$RequestId = '')
    Invoke-KaOperationLocked {
        $now = Get-KaEpoch
        $before = Get-KaLeaseLedger
        if (Test-KaCriticalBattery) { throw 'battery-critical' }
        if ($before.pause -and [long]$before.pause.untilUptimeMs -gt (Get-KaLeaseUptimeMs) -and
            [math]::Abs([long]$before.pause.bootEpoch - (Get-KaLeaseBootEpoch)) -le 5) { throw 'protection-is-paused' }
        $hash = Get-KaLeaseTokenHash $Token
        if (-not $hash) { throw 'invalid lease token' }
        $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $recent = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now)
        if ($RequestId) {
            $duplicates = @($live | Where-Object { $_.owner -ceq $Owner -and $_.requestId -ceq $RequestId })
            if ($duplicates.Count -gt 1) { throw 'duplicate lease request records' }
            if ($duplicates.Count -eq 1) {
                $d = $duplicates[0]
                if (-not (Test-KaLeaseToken "$($d.tokenHash)" $Token) -or "$($d.reason)" -cne "$Reason".Trim() -or
                    [bool]$d.keepDisplayOn -ne $KeepDisplayOn -or [bool]$d.antiLock -ne $AntiLock -or
                    [int]$d.requestMinutes -ne $Minutes) { throw 'request id conflicts with an earlier request' }
                # A previous broker could have died after committing the ledger but before
                # starting the worker/keeper. A replay repairs that incomplete transition.
                $replayLedger = @{ version = 1; manual = $before.manual; leases = $live; tombstones = $recent; pause = $before.pause }
                [void](Invoke-KaLeaseApplyAggregate -Ledger $replayLedger -Now $now)
                Start-KaLeaseKeeper
                $projectedExpiry = $now + [long][math]::Ceiling(([long]$d.expiresUptimeMs - (Get-KaLeaseUptimeMs)) / 1000.0)
                return @{ ok = $true; id = "$($d.id)"; expiresEpoch = $projectedExpiry; replayed = $true }
            }
            $old = @($recent | Where-Object { $_.owner -ceq $Owner -and $_.requestId -ceq $RequestId -and [long]$_.untilEpoch -gt $now })
            if ($old.Count -gt 1) { throw 'duplicate released request records' }
            if ($old.Count -eq 1) {
                $fingerprint = Get-KaLeaseRequestFingerprint -Reason $Reason -Minutes $Minutes -KeepDisplayOn $KeepDisplayOn -AntiLock $AntiLock
                if (-not (Test-KaLeaseToken "$($old[0].tokenHash)" $Token) -or "$($old[0].requestFingerprint)" -cne $fingerprint) {
                    throw 'request id conflicts with an earlier request'
                }
                if ($live.Count -ne @($before.leases).Count) {
                    $pruned = @{ version = 1; manual = $before.manual; leases = $live; tombstones = $recent; pause = $before.pause }
                    $effective = Invoke-KaLeaseCommit -Before $before -After $pruned -Now $now
                    Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $effective -Now $now
                }
                return @{ ok = $true; id = "$($old[0].id)"; expiresEpoch = 0; replayed = $true; alreadyReleased = $true }
            }
        }
        if ($live.Count -ge 128 -or @($live | Where-Object { $_.owner -ceq $Owner }).Count -ge 32 -or
            $recent.Count -ge 512) { throw 'lease capacity reached' }
        $record = New-KaLeaseRecord -Reason $Reason -Minutes $Minutes -KeepDisplayOn $KeepDisplayOn `
            -AntiLock $AntiLock -Owner $Owner -TokenHash $hash -Now $now -RequestId $RequestId -BootEpoch (Get-KaLeaseBootEpoch) -UptimeMs (Get-KaLeaseUptimeMs)
        $after = @{ version = 1; manual = $before.manual; leases = @($live) + @($record); tombstones = $recent; pause = $before.pause }
        $aggregate = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
        Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $aggregate -Now $now
        [void]$aggregate.Remove('process')
        return @{ ok = $true; id = $record.id; expiresEpoch = $record.expiresEpoch; replayed = $false; effective = $aggregate }
    }
}

function Start-KaLeaseKeeper {
    $root = Get-KaProgramRoot
    $scriptPath = Join-Path $root 'integrations\mcp\keeper.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'lease keeper is missing' }
    $mutex = New-Object System.Threading.Mutex($false, ('Global\' + (Get-KaIdentitySuffix 'KA-LeaseKeeper')))
    $free = $false
    try { $free = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
    if (-not $free) { $mutex.Dispose(); return }
    $mutex.ReleaseMutex()
    $args_ = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
               '-File', ('"{0}"' -f $scriptPath), '-DataDir', ('"{0}"' -f (Get-KaDataRoot)))
    # Do not let a long-lived keeper inherit a desktop/MCP bridge's redirected
    # output handles: otherwise the caller waits for EOF until the lease expires.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = $args_ -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $p = $null
    try {
        $p = [Ka.Native]::StartBackground($info.FileName, $info.Arguments, $null)
        $end = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $end) {
            $free = $false
            try { $free = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
            if (-not $free) { return }
            $mutex.ReleaseMutex()
            if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { throw 'lease keeper exited before becoming ready' }
            Start-Sleep -Milliseconds 200
        }
        throw 'lease keeper did not become ready'
    } finally { $mutex.Dispose(); if ($p) { $p.Dispose() } }
}

function Invoke-KaLeaseChange {
    param([string]$Owner, [string]$Token, [string]$Id,
          [ValidateSet('renew','release')][string]$Action, [int]$Minutes = 0)
    Invoke-KaOperationLocked {
        $now = Get-KaEpoch; $before = Get-KaLeaseLedger
        $currentBoot = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $recent = @(Get-KaLeaseTombstones -Ledger $before -Live $currentBoot -Now $now)
        $update = Update-KaLeaseRecord -Leases $currentBoot -Tombstones $recent -Id $Id `
            -Token $Token -Owner $Owner -Now $now -Action $Action -Minutes $Minutes -UptimeMs (Get-KaLeaseUptimeMs)
        if (-not $update.ok) { return @{ ok = $false; reason = $update.reason } }
        if ($update.alreadyReleased) { return @{ ok = $true; alreadyReleased = $true } }
        $after = @{ version = 1; manual = $before.manual; leases = @($update.leases); tombstones = @($update.tombstones); pause = $before.pause }
        $aggregate = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
        Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $aggregate -Now $now
        [void]$aggregate.Remove('process')
        return @{ ok = $true; alreadyReleased = $false; expiresEpoch = [long]$update.expiresEpoch; effective = $aggregate }
    }
}

function Invoke-KaLeaseSweep {
    Invoke-KaOperationLocked {
        $path = Get-KaLeaseLedgerPath
        if (-not (Test-Path -LiteralPath $path)) { return @{ ok = $true; activeLeases = 0; pendingPause = $false; changed = $false } }
        $now = Get-KaEpoch; $before = Get-KaLeaseLedger
        $intentPath = Join-Path (Get-KaDataRoot) 'intent.json'
        $intent = Read-KaJson $intentPath
        if (-not $intent -or "$($intent.desired)" -notin @('awake','off','paused')) { throw 'lease intent is unreadable' }
        if ("$($intent.desired)" -eq 'off' -and @($before.leases).Count -gt 0) {
            # An explicit global stop wins even if a previous ledger update failed.
            $cancelled = @{ version = 1; manual = @{ active = $false; expiresEpoch = 0; keepDisplayOn = $false; antiLock = $false; options = @{} }
                            leases = @(); tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live @() -Now $now); pause = $null }
            Set-KaLeaseLedger $cancelled
            return @{ ok = $true; activeLeases = 0; pendingPause = $false; changed = $true }
        }
        $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $recent = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now)
        $manual = $before.manual
        $manualExpired = ($manual -and [bool]$manual.active -and [long]$manual.expiresEpoch -gt 0 -and [long]$manual.expiresEpoch -le $now)
        if ($manualExpired) {
            $manual = @{ active = $false; expiresEpoch = 0; keepDisplayOn = [bool]$manual.keepDisplayOn; antiLock = [bool]$manual.antiLock; options = $manual.options }
        }
        $uptime = Get-KaLeaseUptimeMs
        $pause = $before.pause
        $pauseElapsed = $pause -and ([long]$pause.untilUptimeMs -le $uptime -or
            [math]::Abs([long]$pause.bootEpoch - (Get-KaLeaseBootEpoch)) -gt 5)
        if ($pauseElapsed) { $pause = $null }
        $expected = [double]$before.clockEpoch + (($uptime - [long]$before.clockUptimeMs) / 1000.0)
        $clockChanged = ($uptime -lt [long]$before.clockUptimeMs -or [math]::Abs($now - $expected) -gt 3)
        $changed = ($live.Count -ne @($before.leases).Count -or $recent.Count -ne @($before.tombstones).Count -or $manualExpired -or $clockChanged -or $pauseElapsed)
        if ($changed) {
            $after = @{ version = 1; manual = $manual; leases = $live; tombstones = $recent; pause = $pause }
            [void](Invoke-KaLeaseCommit -Before $before -After $after -Now $now)
        }
        return @{ ok = $true; activeLeases = $live.Count; pendingPause = [bool]$pause; changed = [bool]$changed }
    }
}

function Invoke-KaLeaseRecover {
    Invoke-KaOperationLocked {
        if (-not (Test-Path -LiteralPath (Get-KaLeaseLedgerPath))) { return @{ recovered = $false } }
        $previousWorker = Read-KaJson (Join-Path (Get-KaDataRoot) 'state.json')
        if ($previousWorker -and "$($previousWorker.exitReason)" -in @('battery-policy','battery-limit') -and @(Get-KaWorker).Count -eq 0) {
            $stopped = Invoke-KaLeaseStopAll -Reason $previousWorker.exitReason
            if (-not $stopped.intentWritten -or [int]$stopped.Remaining -gt 0) { throw 'battery policy stop failed' }
            return @{ recovered = $false; stoppedForBattery = $true }
        }
        if (Test-KaCriticalBattery) {
            $stopped = Invoke-KaLeaseStopAll -Reason 'battery-critical'
            if (-not $stopped.intentWritten -or [int]$stopped.Remaining -gt 0) { throw 'battery-critical protection stop failed' }
            return @{ recovered = $false; stoppedForBattery = $true }
        }
        $intent = Read-KaJson (Join-Path (Get-KaDataRoot) 'intent.json')
        if (-not $intent -or "$($intent.desired)" -ne 'awake') { return @{ recovered = $false } }
        $now = Get-KaEpoch; $ledger = Get-KaLeaseLedger
        $live = @(Get-KaLeaseBootLeases -Leases $ledger.leases -Now $now)
        if ($live.Count -eq 0 -or @(Get-KaWorker).Count -gt 0) { return @{ recovered = $false } }
        $effective = Invoke-KaLeaseApplyAggregate -Ledger $ledger -Now $now
        return @{ recovered = $true; taskCount = [int]$effective.count }
    }
}

function Invoke-KaLeaseManualStart {
    # Caller already holds the operation lock.
    param([double]$Minutes = 0, [hashtable]$Override = @{})
    $now = Get-KaEpoch; $before = Get-KaLeaseLedger; $cfg = Get-KaConfig
    foreach ($k in $Override.Keys) { if ($cfg.ContainsKey($k)) { $cfg[$k] = $Override[$k] } }
    $options = @{}
    foreach ($k in @('keepDisplayOn','antiLock','awayMode','antiLockMethod','antiLockIntervalSec','reassertSec','batteryFloorPercent','batteryAllowDisplayOff')) {
        if ($cfg.ContainsKey($k)) { $options[$k] = $cfg[$k] }
    }
    $manual = @{ active = $true; expiresEpoch = $(if ($Minutes -gt 0) { $now + [long]($Minutes * 60) } else { 0 })
        keepDisplayOn = [bool]$cfg.keepDisplayOn; antiLock = [bool]$cfg.antiLock; options = $options }
    $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
    $after = @{ version = 1; manual = $manual; leases = $live; tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now); pause = $null }
    $aggregate = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
    Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $aggregate -Now $now
    return $aggregate.process
}

function Invoke-KaLeaseStopAll {
    # Stop is an explicit global cancellation. Old capability tokens cannot renew.
    # Caller already holds the operation lock.
    param([string]$Reason = 'user')
    $now = Get-KaEpoch; $before = Get-KaLeaseLedger
    $automationCancellationFailed = $false
    if (Get-Command Block-KaAutomationOccurrences -ErrorAction SilentlyContinue) {
        try { Block-KaAutomationOccurrences -Records $before.leases } catch { $automationCancellationFailed = $true }
    }
    $after = @{ version = 1; manual = @{ active = $false; expiresEpoch = 0; keepDisplayOn = $false; antiLock = $false; options = @{} }
                leases = @(); tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live @() -Now $now); pause = $null }
    $aggregate = Invoke-KaLeaseCommit -Before $before -After $after -Now $now -StopReason $Reason
    $aggregate.process['automationCancellationFailed'] = $automationCancellationFailed
    return $aggregate.process
}

function Invoke-KaLeasePause {
    param([int]$Minutes)
    if ($Minutes -lt 1 -or $Minutes -gt 1440) { return @{ ok = $false; reason = 'invalid-duration' } }
    Invoke-KaOperationLocked {
        $now = Get-KaEpoch; $before = Get-KaLeaseLedger; $uptime = Get-KaLeaseUptimeMs
        $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $current = Get-KaLeaseAggregate -Leases $live -Manual $before.manual -Now $now -UptimeMs $uptime
        if (-not $current.active) { return @{ ok = $false; reason = 'not-active' } }
        $pause = @{ untilUptimeMs = $uptime + [long]$Minutes * 60000; bootEpoch = Get-KaLeaseBootEpoch }
        $after = @{ version = 1; manual = $before.manual; leases = $live; tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now); pause = $pause }
        $effective = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
        Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $effective -Now $now
        return @{ ok = $true; untilEpoch = $now + [long]$Minutes * 60 }
    }
}

function Invoke-KaLeaseResume {
    Invoke-KaOperationLocked {
        $now = Get-KaEpoch; $before = Get-KaLeaseLedger
        if (-not $before.pause) { return @{ ok = $true; alreadyResumed = $true } }
        $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $after = @{ version = 1; manual = $before.manual; leases = $live
                    tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now); pause = $null }
        $effective = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
        Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $effective -Now $now
        return @{ ok = $true; alreadyResumed = $false; active = [bool]$effective.active }
    }
}

function Invoke-KaLeaseUserRelease {
    param([string]$Id)
    if ($Id -cnotmatch '^[0-9a-f]{32}$') { return @{ ok = $false; reason = 'invalid-id' } }
    Invoke-KaOperationLocked {
        $now = Get-KaEpoch; $before = Get-KaLeaseLedger
        $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $matches = @($live | Where-Object { $_.id -ceq $Id })
        if ($matches.Count -ne 1) { return @{ ok = $false; reason = 'not-found' } }
        $record = $matches[0]
        if (Get-Command Block-KaAutomationOccurrences -ErrorAction SilentlyContinue) { Block-KaAutomationOccurrences -Records @($record) }
        $tombstone = @{ id = $Id; owner = "$($record.owner)"; tokenHash = "$($record.tokenHash)"; untilEpoch = $now + 86400
                        requestId = "$($record.requestId)"; requestFingerprint = "$($record.requestFingerprint)" }
        $after = @{ version = 1; manual = $before.manual; leases = @($live | Where-Object { $_.id -cne $Id })
                    tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now) + @($tombstone); pause = $before.pause }
        $aggregate = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
        Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $aggregate -Now $now
        [void]$aggregate.Remove('process')
        return @{ ok = $true; effective = $aggregate }
    }
}
