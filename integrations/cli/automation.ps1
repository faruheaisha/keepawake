# Explicit desktop rules. Nothing runs merely by reading this file.
function Get-KaAutomationConfig {
    $path = Join-Path (Get-KaDataRoot) 'automation.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ version = 1; rules = @() } }
    $raw = Read-KaJson $path
    if (-not $raw -or $raw.version -ne 1 -or @($raw.rules).Count -gt 32) { throw 'Invalid automation settings.' }
    return $raw
}

function Set-KaAutomationConfig {
    param($Rules)
    Invoke-KaOperationLocked {
        $items = @($Rules); $ids = @{}
        if ($items.Count -gt 32) { throw 'At most 32 rules are supported.' }
        $validated = @()
        foreach ($rule in $items) {
            if ("$($rule.id)" -cnotmatch '^[0-9a-f]{32}$' -or $ids.ContainsKey("$($rule.id)")) { throw 'Invalid rule identity.' }
            $ids["$($rule.id)"] = $true
            if ($rule.enabled -isnot [bool] -or $rule.keepDisplayOn -isnot [bool] -or $rule.antiLock -isnot [bool]) { throw 'Invalid rule options.' }
            $name = "$($rule.name)".Trim()
            if (-not $name -or $name.Length -gt 100 -or $name -match '[\x00-\x1f\x7f]') { throw 'Invalid rule name.' }
            $copy = @{ id = "$($rule.id)"; name = $name; enabled = $rule.enabled; type = "$($rule.type)"; keepDisplayOn = $rule.keepDisplayOn; antiLock = $rule.antiLock }
            if ($rule.type -eq 'schedule') {
                if ("$($rule.start)" -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' -or "$($rule.end)" -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' -or [string]::CompareOrdinal($rule.start, $rule.end) -ge 0) { throw 'Choose a start and a later end on the same day.' }
                $days = @($rule.days)
                if ($days.Count -lt 1 -or $days.Count -gt 7) { throw 'Choose at least one weekday.' }
                foreach ($day in $days) { if ($day -is [bool] -or "$day" -notmatch '^[0-6]$') { throw 'Invalid weekday.' } }
                $copy.start = "$($rule.start)"; $copy.end = "$($rule.end)"; $copy.days = @($days | ForEach-Object { [int]$_ } | Sort-Object -Unique)
            } elseif ($rule.type -eq 'program') {
                $path = [IO.Path]::GetFullPath("$($rule.path)")
                if (-not [IO.Path]::IsPathRooted($rule.path) -or [IO.Path]::GetExtension($path) -ine '.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Choose an existing executable.' }
                $copy.path = $path
            } else { throw 'Unknown rule type.' }
            $validated += $copy
        }
        if (-not (Write-KaJson (Join-Path (Get-KaDataRoot) 'automation.json') @{ version = 1; rules = $validated } -Depth 7)) { throw 'Could not save automation settings.' }
    }
}

function Get-KaAutomationSuppressed {
    $path = Join-Path (Get-KaDataRoot) 'automation-state.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $raw = Read-KaJson $path
    if (-not $raw -or $raw.version -ne 1) { throw 'Could not read stopped rule occurrences.' }
    return @($raw.suppressed)
}

function Block-KaAutomationOccurrences {
    param($Records)
    $blocked = @(Get-KaAutomationSuppressed)
    foreach ($record in @($Records)) {
        if ("$($record.owner)" -cmatch '^auto_[0-9a-f]{32}$') { $blocked += "$($record.owner)|$($record.requestId)" }
    }
    if (-not (Write-KaJson (Join-Path (Get-KaDataRoot) 'automation-state.json') @{ version = 1; suppressed = @($blocked | Sort-Object -Unique) })) { throw 'Could not preserve stopped rule occurrences.' }
}

function Get-KaScheduleOccurrence {
    param($Rule, [DateTimeOffset]$Now = [DateTimeOffset]::Now, [TimeZoneInfo]$Zone = [TimeZoneInfo]::Local)
    $local = [TimeZoneInfo]::ConvertTime($Now, $Zone).DateTime
    if (@($Rule.days) -notcontains [int]$local.DayOfWeek) { return $null }
    $start = [TimeSpan]::ParseExact($Rule.start, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $end = [TimeSpan]::ParseExact($Rule.end, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $startLocal = [DateTime]::SpecifyKind($local.Date.Add($start), [DateTimeKind]::Unspecified)
    $endLocal = [DateTime]::SpecifyKind($local.Date.Add($end), [DateTimeKind]::Unspecified)
    # Spring gap: move the end forward to the first valid minute. Autumn overlap:
    # use the later UTC endpoint, and one occurrence ID for both copies of the hour.
    while ($Zone.IsInvalidTime($startLocal)) { $startLocal = $startLocal.AddMinutes(1) }
    while ($Zone.IsInvalidTime($endLocal)) { $endLocal = $endLocal.AddMinutes(1) }
    $startUtc = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $Zone)
    if ($Zone.IsAmbiguousTime($startLocal)) {
        $earlyOffset = @($Zone.GetAmbiguousTimeOffsets($startLocal) | Sort-Object TotalMinutes -Descending)[0]
        $startUtc = [DateTimeOffset]::new($startLocal, $earlyOffset).UtcDateTime
    }
    $endUtc = [TimeZoneInfo]::ConvertTimeToUtc($endLocal, $Zone)
    if ($Now.UtcDateTime -lt $startUtc -or $Now.UtcDateTime -ge $endUtc) { return $null }
    return @{ key = $local.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture); expiresEpoch = [DateTimeOffset]::new($endUtc).ToUnixTimeSeconds() }
}

function Get-KaAutomationDesired {
    param($Rules, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    $desired = @()
    foreach ($rule in @($Rules)) {
        if (-not $rule.enabled) { continue }
        $owner = 'auto_' + $rule.id
        if ($rule.type -eq 'schedule') {
            $occurrence = Get-KaScheduleOccurrence -Rule $rule -Now $Now
            if ($occurrence) { $desired += @{ owner = $owner; requestId = $occurrence.key; expiresEpoch = $occurrence.expiresEpoch; rule = $rule } }
        } elseif ($rule.type -eq 'program') {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($rule.path)
            foreach ($process in @(Get-Process -Name $baseName -ErrorAction SilentlyContinue)) {
                try {
                    if (-not [string]::Equals($process.Path, $rule.path, [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $key = '{0}-{1}' -f $process.Id, $process.StartTime.ToUniversalTime().Ticks
                    $desired += @{ owner = $owner; requestId = $key; expiresEpoch = $Now.ToUnixTimeSeconds() + 900; rule = $rule }
                } catch { } finally { $process.Dispose() }
            }
        }
    }
    if ($desired.Count -gt 64) { throw 'Too many matching process instances.' }
    return $desired
}

function Invoke-KaAutomationTick {
    # Called explicitly by the opted-in desktop controller while the tray is running.
    Invoke-KaOperationLocked {
        $config = Get-KaAutomationConfig
        $desired = @(Get-KaAutomationDesired -Rules $config.rules)
        $now = Get-KaEpoch; $uptime = Get-KaLeaseUptimeMs
        $before = Get-KaLeaseLedger
        $live = @(Get-KaLeaseBootLeases -Leases $before.leases -Now $now)
        $blocked = @(Get-KaAutomationSuppressed)
        $keys = @($desired | ForEach-Object { "$($_.owner)|$($_.requestId)" })
        $blocked = @($blocked | Where-Object { $keys -ccontains $_ })
        $recent = @(Get-KaLeaseTombstones -Ledger $before -Live $live -Now $now)
        foreach ($t in $recent) {
            $key = "$($t.owner)|$($t.requestId)"
            if ($keys -ccontains $key) { $blocked += $key }
        }
        if (-not (Write-KaJson (Join-Path (Get-KaDataRoot) 'automation-state.json') @{ version = 1; suppressed = @($blocked | Sort-Object -Unique) })) { throw 'Could not save rule state.' }
        $next = @($live | Where-Object { "$($_.owner)" -cnotmatch '^auto_[0-9a-f]{32}$' })
        $changed = $false
        foreach ($item in $desired) {
            $key = "$($item.owner)|$($item.requestId)"
            if ($blocked -ccontains $key) { continue }
            $found = @($live | Where-Object { $_.owner -ceq $item.owner -and $_.requestId -ceq $item.requestId })
            if ($found.Count -eq 1) {
                $record = @{}
                if ($found[0] -is [Collections.IDictionary]) { foreach ($k in $found[0].Keys) { $record[$k] = $found[0][$k] } }
                else { foreach ($p in $found[0].PSObject.Properties) { $record[$p.Name] = $p.Value } }
                if ($item.rule.type -eq 'program' -and [long]$record.expiresUptimeMs - $uptime -lt 300000) {
                    $record.expiresEpoch = $now + 900; $record.expiresUptimeMs = $uptime + 900000; $changed = $true
                }
                $next += $record
            } else {
                if (Test-KaCriticalBattery) { continue }
                $minutes = [int][math]::Max(1, [math]::Min(1440, [math]::Ceiling(($item.expiresEpoch - $now) / 60.0)))
                $record = New-KaLeaseRecord -Reason $item.rule.name -Minutes $minutes -Owner $item.owner -RequestId $item.requestId `
                    -TokenHash (Get-KaLeaseTokenHash (New-KaLeaseToken)) -Now $now -BootEpoch (Get-KaLeaseBootEpoch) -UptimeMs $uptime `
                    -KeepDisplayOn $item.rule.keepDisplayOn -AntiLock $item.rule.antiLock
                if ($item.rule.type -eq 'schedule') { $record.expiresEpoch = $item.expiresEpoch; $record.expiresUptimeMs = $uptime + [math]::Max(1, ($item.expiresEpoch - $now)) * 1000 }
                $next += $record; $changed = $true
            }
        }
        if ($next.Count -ne $live.Count) { $changed = $true }
        if ($changed) {
            $after = @{ version = 1; manual = $before.manual; leases = $next; tombstones = @(Get-KaLeaseTombstones -Ledger $before -Live $next -Now $now); pause = $before.pause }
            $aggregate = Invoke-KaLeaseCommit -Before $before -After $after -Now $now
            Confirm-KaLeaseKeeperAfterCommit -Before $before -Aggregate $aggregate -Now $now
        }
        return @{ ok = $true; matched = $desired.Count; suppressed = $blocked.Count }
    }
}
