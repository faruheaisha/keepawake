$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-core.ps1')
$start = Get-Date -Year 2026 -Month 8 -Day 29 -Hour 22 -Minute 40 -Second 0
$end   = Get-Date -Year 2026 -Month 8 -Day 29 -Hour 23 -Minute 20 -Second 0
$ev = @(Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$start; EndTime=$end } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
"count=$($ev.Count)"
foreach ($e in $ev) {
    $t = $e.TimeCreated.ToString('HH:mm:ss')
    "[$t] $($e.ProviderName) id=$($e.Id) lvl=$($e.Level)"
    if ($e.Id -in @(506,507,566,42,1,131,86,87,572,573)) {
        $map = Get-KaEventDataMap $e
        foreach ($k in @($map.Keys | Sort-Object)) { "      $k = $($map[$k])" }
    }
}
