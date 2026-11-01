$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:KA_DATA = Join-Path $root ('_tmp\expiry-probe-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $root 'ka-core.ps1')
$eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$beforeSpring = [datetime]::new(2026, 3, 7, 12, 0, 0)
$across = Get-KaMinutesUntil -Text '2026-03-08 12:00' -Now $beforeSpring -TimeZone $eastern
if (-not $across.Ok -or $across.Minutes -ne 1380) { throw 'elapsed duration across spring DST is not 23 hours' }
$missing = Get-KaMinutesUntil -Text '2026-03-08 02:30' -Now $beforeSpring -TimeZone $eastern
if ($missing.Ok) { throw 'nonexistent DST time was accepted' }
$repeated = Get-KaMinutesUntil -Text '2026-11-01 01:30' -Now ([datetime]::new(2026,10,31,12,0,0)) -TimeZone $eastern
if ($repeated.Ok) { throw 'ambiguous DST time was accepted' }
$near = Get-KaMinutesUntil -Text '2026-05-01 10:00:01' -Now ([datetime]::new(2026,5,1,10,0,0)) -TimeZone $eastern
if (-not $near.Ok -or $near.Minutes -le 0) { throw 'near-future expiry became unlimited' }
Write-Host 'PROBE OK: absolute expiry, DST gap/fold, elapsed duration and near-future boundary'
