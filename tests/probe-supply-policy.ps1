$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:KA_DATA = Join-Path $root ('_tmp\supply-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $root 'ka-core.ps1')
function Assert-Supply([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message }; Write-Host ('  ok   ' + $Message) }
Set-KaSupplyPolicy -Mode 'screen-off' -LimitMinutes 30
$policy = Get-KaSupplyPolicy
$battery = @{ known = $true; acKnown = $true; acOnline = $false; hasBattery = $true }
$first = Get-KaSupplyDecision $battery $policy $null 1000
$second = Get-KaSupplyDecision $battery $policy $first 11000
Assert-Supply (-not $first.screenOff -and $second.screenOff -and $second.confirmed) 'unplug action requires two known consecutive readings'
$expired = Get-KaSupplyDecision $battery $policy $second 1801000
Assert-Supply ($expired.abort -eq 'battery-limit') 'battery time limit uses monotonic elapsed time'
$unknown = Get-KaSupplyDecision @{ known = $true; acKnown = $false; acOnline = $true } $policy $second 21000
Assert-Supply (-not $unknown.confirmed -and -not $unknown.abort -and -not $unknown.screenOff) 'unknown AC does not choose an unplug action'
$plugged = Get-KaSupplyDecision @{ known = $true; acKnown = $true; acOnline = $true } $policy $second 31000
Assert-Supply ($plugged.batterySince -eq 0 -and -not $plugged.screenOff) 'confirmed AC resets the battery timer'
$stop = Get-KaSupplyDecision $battery @{ mode = 'stop'; limitMinutes = 0 } $first 11000
Assert-Supply ($stop.abort -eq 'battery-policy') 'explicit stop policy cancels after confirmation'
$action = Get-KaBatteryAction -Status @{ known = $true; acKnown = $false; acOnline = $true; hasBattery = $true; percent = 95 } -KeepDisplayOn $true -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $true
Assert-Supply (-not $action.Restore -and -not $action.Downgrade) 'unknown AC cannot restore a downgraded display'
$action = Get-KaBatteryAction -Status @{ known = $true; acKnown = $true; acOnline = $false; hasBattery = $true; percent = 25 } -KeepDisplayOn $true -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $true
Assert-Supply (-not $action.Restore) 'low-charge recovery retains the ten-point hysteresis'
$bad = $false; try { Set-KaSupplyPolicy -Mode 'unknown' -LimitMinutes 0 } catch { $bad = $true }
Assert-Supply $bad 'unknown policies are rejected before save'
Write-Host 'PROBE OK: independent battery policy and hysteresis'
