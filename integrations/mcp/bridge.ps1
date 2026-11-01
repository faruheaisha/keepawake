# A single, bounded JSON request over stdin. The MCP adapter owns protocol framing;
# this bridge never accepts shell commands and never puts capability tokens on argv.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
try {
    . (Join-Path $root 'ka-gate.ps1')
    if (-not (Test-KaLanguageMode)) { throw 'language-mode-unavailable' }
    . (Join-Path $root 'ka-core.ps1')
    if (-not $script:KaLeaseAvailable) { throw 'lease-support-unavailable' }
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 8192) { throw 'request-too-large' }
    $q = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $q -or $q.op -isnot [string] -or $q.owner -isnot [string] -or
        $q.owner -cnotmatch '^[a-zA-Z0-9_-]{1,80}$') { throw 'invalid-request' }
    $result = & {
        switch ($q.op) {
            'status' {
                $s = Get-KaFullState -Quiet
                $mine = @($s.leases.items | Where-Object { $_.owner -ceq $q.owner } | ForEach-Object {
                    @{ id = "$($_.id)"; createdEpoch = [long]$_.createdEpoch; expiresEpoch = [long]$_.expiresEpoch
                       keepDisplayOn = [bool]$_.keepDisplayOn; antiLock = [bool]$_.antiLock }
                })
                return @{ ok = $true; version = $s.version; running = [bool]$s.running; workerCount = [int]$s.workerCount
                    stateRecorded = [bool]($null -ne $s.worker); leasesReadable = [bool]$s.leases.readable
                    paused = [bool]$s.leases.paused; pauseUntilEpoch = [long]$s.leases.pauseUntilEpoch
                    workerError = [bool]($s.worker -and $s.worker.error)
                    alertIds = @($s.alert | ForEach-Object { "$($_.id)" } | Where-Object { $_ -cmatch '^alert\.[a-zA-Z0-9]+$' })
                    taskCount = @($s.leases.items).Count; ownTasks = $mine }
            }
            'evidence' {
                if ($q.hours -isnot [ValueType] -or $q.hours -is [bool] -or
                    [double]$q.hours -ne [math]::Floor([double]$q.hours) -or [int]$q.hours -lt 1 -or [int]$q.hours -gt 24) { throw 'invalid-hours' }
                $ev = Get-KaSleepEvidence -Since (Get-Date).AddHours(-[int]$q.hours)
                return @{ ok = $true; queriesOk = [bool]$ev.queriesOk; hours = [int]$q.hours; canSee = [bool]$ev.canSee
                    instrument = "$($ev.instrument)"; realSleeps = [int]$ev.realSleeps; s3Enters = [int]$ev.s3Enters
                    bypasses = [int]$ev.bypasses; s3Bypasses = [int]$ev.s3Bypasses
                    unknown = ([int]$ev.spanUnknown + [int]$ev.s3SpanUnknown); truncated = [bool]$ev.truncated }
            }
            'acquire' {
                if ($q.minutes -isnot [ValueType] -or $q.minutes -is [bool] -or
                    [double]$q.minutes -ne [math]::Floor([double]$q.minutes) -or [int]$q.minutes -lt 1 -or [int]$q.minutes -gt 1440 -or
                    $q.keepDisplayOn -isnot [bool] -or $q.antiLock -isnot [bool] -or
                    $q.reason -isnot [string] -or $q.token -isnot [string] -or $q.requestId -isnot [string]) { throw 'invalid-acquire' }
                return (Invoke-KaLeaseAcquire -Owner $q.owner -Token $q.token -Reason $q.reason -Minutes ([int]$q.minutes) `
                    -KeepDisplayOn $q.keepDisplayOn -AntiLock $q.antiLock -RequestId $q.requestId)
            }
            { $_ -in @('renew','release') } {
                if ($q.id -isnot [string] -or $q.id -cnotmatch '^[0-9a-f]{32}$' -or $q.token -isnot [string]) { throw 'invalid-capability' }
                $minutes = 0
                if ($q.op -eq 'renew') {
                    if ($q.minutes -isnot [ValueType] -or $q.minutes -is [bool] -or
                        [double]$q.minutes -ne [math]::Floor([double]$q.minutes) -or [int]$q.minutes -lt 1 -or [int]$q.minutes -gt 1440) { throw 'invalid-duration' }
                    $minutes = [int]$q.minutes
                }
                return (Invoke-KaLeaseChange -Owner $q.owner -Token $q.token -Id $q.id -Action $q.op -Minutes $minutes)
            }
            default { throw 'unknown-operation' }
        }
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 12))
} catch {
    # Error details and arguments may contain local paths or credentials. Return a
    # stable code, not the exception text, across the AI boundary.
    [Console]::Error.WriteLine('KeepAwake bridge operation failed.')
    [Console]::Out.WriteLine('{"ok":false,"reason":"bridge-operation-failed"}')
    exit 1
}
