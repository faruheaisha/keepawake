<# A task monitor never receives the lease capability on its command line. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
try {
    . (Join-Path $root 'ka-gate.ps1')
    if (-not (Test-KaLanguageMode)) { throw 'language mode' }
    . (Join-Path $root 'ka-core.ps1')
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 2048) { throw 'invalid request' }
    $q = $raw | ConvertFrom-Json
    if ($q.owner -cnotmatch '^(cli|watch)_[0-9a-f]{32}$' -or $q.id -cnotmatch '^[0-9a-f]{32}$' -or
        $q.token -cnotmatch '^[0-9a-f]{64}$' -or [int]$q.pid -le 0 -or [long]$q.startedTicks -le 0) { throw 'invalid identity' }
    $parent = Get-Process -Id ([int]$q.pid) -ErrorAction Stop
    if ($parent.StartTime.ToUniversalTime().Ticks -ne [long]$q.startedTicks) { throw 'parent identity mismatch' }
    [Console]::Out.WriteLine('READY'); [Console]::Out.Flush()
    $renew = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Start-Sleep -Seconds 3
        $alive = $false
        try { $p = Get-Process -Id ([int]$q.pid) -ErrorAction Stop; $alive = ($p.StartTime.ToUniversalTime().Ticks -eq [long]$q.startedTicks) } catch { }
        if (-not $alive) {
            [void](Invoke-KaLeaseChange -Owner $q.owner -Token $q.token -Id $q.id -Action release)
            break
        }
        $ledger = Get-KaLeaseLedger
        if (@($ledger.leases | Where-Object { $_.id -ceq $q.id -and $_.owner -ceq $q.owner }).Count -eq 0) { break }
        if ($renew.Elapsed.TotalMinutes -ge 5) {
            $r = Invoke-KaLeaseChange -Owner $q.owner -Token $q.token -Id $q.id -Action renew -Minutes 15
            if (-not $r.ok) { Add-KaLog 'CLI-LEASE-RENEW-FAILED'; break }
            $renew.Restart()
        }
    }
} catch {
    try { Add-KaLog 'CLI-LEASE-MONITOR-FAILED' } catch { }
    exit 1
}
