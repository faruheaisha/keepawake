# Pure lease model. Callers serialize mutations with the core operation mutex and
# persist the returned ledger before reporting success. No process or file I/O here.

function New-KaLeaseToken {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
}

function Get-KaLeaseTokenHash {
    param([string]$Token)
    if ($Token -notmatch '^[0-9a-f]{64}$') { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Token))).Replace('-', '').ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function Test-KaLeaseToken {
    param([string]$ExpectedHash, [string]$Token)
    $actual = Get-KaLeaseTokenHash $Token
    if ($ExpectedHash -notmatch '^[0-9a-f]{64}$' -or $actual.Length -ne 64) { return $false }
    $diff = 0
    for ($i = 0; $i -lt 64; $i++) { $diff = $diff -bor ([int][char]$ExpectedHash[$i] -bxor [int][char]$actual[$i]) }
    return ($diff -eq 0)
}

function Get-KaLeaseRequestFingerprint {
    param([string]$Reason, [int]$Minutes, [bool]$KeepDisplayOn, [bool]$AntiLock)
    $text = "$Reason".Trim()
    $payload = '{0}:{1}|{2}|{3}|{4}' -f $text.Length, $text, $Minutes, ([int]$KeepDisplayOn), ([int]$AntiLock)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-', '').ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

function New-KaLeaseRecord {
    param([string]$Reason, [int]$Minutes, [bool]$KeepDisplayOn, [bool]$AntiLock,
          [string]$Owner, [string]$TokenHash, [long]$Now, [string]$RequestId = '', [long]$BootEpoch = 0,
          [long]$UptimeMs = -1)
    $reasonText = "$Reason".Trim()
    if (-not $reasonText -or $reasonText.Length -gt 120 -or $reasonText -match '[\x00-\x1f\x7f]') { throw 'invalid lease reason' }
    if ($Minutes -lt 1 -or $Minutes -gt 1440) { throw 'invalid lease duration' }
    if ($Owner -notmatch '^[a-zA-Z0-9_-]{1,80}$') { throw 'invalid lease owner' }
    if ($TokenHash -notmatch '^[0-9a-f]{64}$') { throw 'invalid lease token hash' }
    if ($RequestId -and $RequestId -notmatch '^[a-zA-Z0-9_.-]{1,100}$') { throw 'invalid request id' }
    if ($Now -le 0) { throw 'invalid clock' }
    return @{
        id = [guid]::NewGuid().ToString('N'); owner = $Owner; tokenHash = $TokenHash
        reason = $reasonText; createdEpoch = $Now; expiresEpoch = $Now + [long]$Minutes * 60
        keepDisplayOn = $KeepDisplayOn; antiLock = $AntiLock; requestId = $RequestId; requestMinutes = $Minutes; bootEpoch = $BootEpoch
        requestFingerprint = (Get-KaLeaseRequestFingerprint -Reason $reasonText -Minutes $Minutes -KeepDisplayOn $KeepDisplayOn -AntiLock $AntiLock)
        expiresUptimeMs = $(if ($UptimeMs -ge 0) { $UptimeMs + [long]$Minutes * 60000 } else { 0 })
    }
}

function Get-KaLiveLeases {
    param($Leases, [long]$Now, [long]$UptimeMs = -1)
    # Invalid or missing expiry is never interpreted as an unlimited lease.
    return @($Leases | Where-Object { $_ -and $_.id -and $_.owner -and
        $(if ($UptimeMs -ge 0 -and [long]$_.expiresUptimeMs -gt 0) { [long]$_.expiresUptimeMs -gt $UptimeMs }
          else { $_.expiresEpoch -and [long]$_.expiresEpoch -gt $Now }) })
}

function Get-KaLeaseAggregate {
    param($Leases, $Manual, [long]$Now, [long]$UptimeMs = -1)
    $live = @(Get-KaLiveLeases -Leases $Leases -Now $Now -UptimeMs $UptimeMs)
    $manualLive = $false
    if ($Manual -and [bool]$Manual.active) {
        $manualLive = ([long]$Manual.expiresEpoch -eq 0 -or [long]$Manual.expiresEpoch -gt $Now)
    }
    $display = $false; $antiLock = $false; $expires = [long]0
    foreach ($lease in $live) {
        $display = $display -or [bool]$lease.keepDisplayOn
        $antiLock = $antiLock -or [bool]$lease.antiLock
        $deadline = if ($UptimeMs -ge 0 -and [long]$lease.expiresUptimeMs -gt 0) {
            $Now + [long][math]::Ceiling(([long]$lease.expiresUptimeMs - $UptimeMs) / 1000.0)
        } else { [long]$lease.expiresEpoch }
        if ($deadline -gt $expires) { $expires = $deadline }
    }
    if ($manualLive) {
        $display = $display -or [bool]$Manual.keepDisplayOn
        $antiLock = $antiLock -or [bool]$Manual.antiLock
        if ([long]$Manual.expiresEpoch -eq 0) { $expires = 0 }
        elseif ([long]$Manual.expiresEpoch -gt $expires) { $expires = [long]$Manual.expiresEpoch }
    }
    return @{ active = ($manualLive -or $live.Count -gt 0); manualActive = $manualLive
              keepDisplayOn = $display; antiLock = $antiLock; expiresEpoch = $expires; count = $live.Count }
}

function Update-KaLeaseRecord {
    param($Leases, [string]$Id, [string]$Token, [string]$Owner, [long]$Now,
          [ValidateSet('renew', 'release')][string]$Action, [int]$Minutes = 0, $Tombstones = @(), [long]$UptimeMs = -1)
    $live = @(Get-KaLiveLeases -Leases $Leases -Now $Now -UptimeMs $UptimeMs)
    $recent = @($Tombstones | Where-Object { $_ -and $_.untilEpoch -and [long]$_.untilEpoch -gt $Now })
    $matches = @($live | Where-Object { $_.id -ceq $Id -and $_.owner -ceq $Owner })
    if ($matches.Count -ne 1 -or -not (Test-KaLeaseToken -ExpectedHash "$($matches[0].tokenHash)" -Token $Token)) {
        # Idempotent release needs evidence of ownership even after the record is removed.
        $prior = @($recent | Where-Object { $_.id -ceq $Id -and $_.owner -ceq $Owner })
        if ($Action -eq 'release' -and $prior.Count -eq 1 -and
            (Test-KaLeaseToken -ExpectedHash "$($prior[0].tokenHash)" -Token $Token)) {
            return @{ ok = $true; alreadyReleased = $true; leases = $live; tombstones = $recent }
        }
        return @{ ok = $false; reason = 'not-found-or-unauthorized'; leases = $live; tombstones = $recent }
    }
    if ($Action -eq 'renew') {
        if ($Minutes -lt 1 -or $Minutes -gt 1440) { return @{ ok = $false; reason = 'invalid-duration'; leases = $live; tombstones = $recent } }
        # Work on a copy: failed persistence must not mutate the caller's old state.
        $updated = @{}
        if ($matches[0] -is [Collections.IDictionary]) {
            foreach ($key in $matches[0].Keys) { $updated[$key] = $matches[0][$key] }
        } else {
            foreach ($property in $matches[0].PSObject.Properties) { $updated[$property.Name] = $property.Value }
        }
        $updated.expiresEpoch = $Now + [long]$Minutes * 60
        if ($UptimeMs -ge 0) { $updated.expiresUptimeMs = $UptimeMs + [long]$Minutes * 60000 }
        $next = @($live | Where-Object { $_.id -cne $Id }) + @($updated)
        return @{ ok = $true; leases = $next; expiresEpoch = $updated.expiresEpoch; tombstones = $recent }
    }
    $recent += @{ id = $Id; owner = $Owner; tokenHash = "$($matches[0].tokenHash)"; untilEpoch = $Now + 86400
                  requestId = "$($matches[0].requestId)"; requestFingerprint = "$($matches[0].requestFingerprint)" }
    return @{ ok = $true; alreadyReleased = $false; leases = @($live | Where-Object { $_.id -cne $Id }); tombstones = $recent }
}

function Get-KaLeasePublicSnapshot {
    param($Leases, [long]$Now, [long]$UptimeMs = -1)
    return @(Get-KaLiveLeases -Leases $Leases -Now $Now -UptimeMs $UptimeMs | ForEach-Object {
        $expiry = if ($UptimeMs -ge 0 -and [long]$_.expiresUptimeMs -gt 0) {
            $Now + [long][math]::Ceiling(([long]$_.expiresUptimeMs - $UptimeMs) / 1000.0)
        } else { [long]$_.expiresEpoch }
        [PSCustomObject]@{ id = "$($_.id)"; owner = "$($_.owner)"; reason = "$($_.reason)"
            createdEpoch = [long]$_.createdEpoch; expiresEpoch = $expiry
            keepDisplayOn = [bool]$_.keepDisplayOn; antiLock = [bool]$_.antiLock }
    })
}
