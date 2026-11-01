# Exercise schedule boundaries, stopped-occurrence priority, and exact program identity.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:KA_DATA = Join-Path $root ('_tmp\automation-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $root 'ka-core.ps1')
function Assert-Auto([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message }; Write-Host ('  ok   ' + $Message) }
$zone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
$rule = @{ id = [guid]::NewGuid().ToString('N'); name = 'Schedule'; enabled = $true; type = 'schedule'; start = '01:00'; end = '02:30'; days = @(0); keepDisplayOn = $false; antiLock = $false }
$first = Get-KaScheduleOccurrence $rule ([DateTimeOffset]::Parse('2026-11-01T01:15:00-04:00')) $zone
$second = Get-KaScheduleOccurrence $rule ([DateTimeOffset]::Parse('2026-11-01T01:15:00-05:00')) $zone
Assert-Auto ($first.key -eq $second.key -and $first.expiresEpoch -eq $second.expiresEpoch) 'the repeated DST hour has one occurrence and one endpoint'
$foldRule = $rule.Clone(); $foldRule.end = '01:30'
$between = Get-KaScheduleOccurrence $foldRule ([DateTimeOffset]::Parse('2026-11-01T01:45:00-04:00')) $zone
Assert-Auto ($null -ne $between -and $between.expiresEpoch -eq [DateTimeOffset]::Parse('2026-11-01T01:30:00-05:00').ToUnixTimeSeconds()) 'a repeated endpoint stays active continuously until its later occurrence'
Assert-Auto ($null -eq (Get-KaScheduleOccurrence $rule ([DateTimeOffset]::Parse('2026-11-01T02:30:00-05:00')) $zone)) 'schedule end is exclusive'
$gap = Get-KaScheduleOccurrence $rule ([DateTimeOffset]::Parse('2026-03-08T01:30:00-05:00')) $zone
Assert-Auto ($gap.expiresEpoch -eq [DateTimeOffset]::Parse('2026-03-08T03:00:00-04:00').ToUnixTimeSeconds()) 'spring DST gap advances to the first valid endpoint'
Assert-Auto ($null -eq (Get-KaScheduleOccurrence $rule ([DateTimeOffset]::Parse('2026-11-02T01:15:00-05:00')) $zone)) 'unselected weekdays never start protection'

# The transaction is real; only power requests and the background keeper are replaced.
function Invoke-KaLeaseApplyAggregate { param($Ledger, [long]$Now, [string]$StopReason) $a = Get-KaLeaseAggregate $Ledger.leases $Ledger.manual $Now (Get-KaLeaseUptimeMs); $a.process = @{ Ok = $true; Remaining = 0; intentWritten = $true }; return $a }
function Start-KaLeaseKeeper { }
function Test-KaCriticalBattery { return $false }
$nowLocal = [DateTime]::Now
$rule.start = '00:00'; $rule.end = '23:59'; $rule.days = @(0,1,2,3,4,5,6)
Set-KaAutomationConfig @($rule)
$first = Invoke-KaAutomationTick
$ledger = Get-KaLeaseLedger
Assert-Auto (@($ledger.leases).Count -eq 1) 'a current opted-in schedule creates one independent task'
[void](Invoke-KaAutomationTick)
Assert-Auto (@((Get-KaLeaseLedger).leases).Count -eq 1) 'repeated polls do not duplicate a task'
$id = $ledger.leases[0].id
[void](Invoke-KaLeaseUserRelease $id)
[void](Invoke-KaAutomationTick)
Assert-Auto (@((Get-KaLeaseLedger).leases).Count -eq 0) 'manual release suppresses the current occurrence'
$rule.id = [guid]::NewGuid().ToString('N')
Set-KaAutomationConfig @($rule); [void](Invoke-KaAutomationTick)
Assert-Auto (@((Get-KaLeaseLedger).leases).Count -eq 1) 'a newly authorized rule can start'
[void](Invoke-KaLeaseStopAll -Reason 'user'); [void](Invoke-KaAutomationTick)
Assert-Auto (@((Get-KaLeaseLedger).leases).Count -eq 0) 'global stop also wins over automatic rules'
Set-KaAutomationConfig @(); [void](Invoke-KaAutomationTick)
Assert-Auto (@(Get-KaAutomationSuppressed).Count -eq 0) 'ended or removed occurrences clear their suppression'

$self = Get-Process -Id $PID
$program = @{ id = [guid]::NewGuid().ToString('N'); name = 'Selected program'; enabled = $true; type = 'program'; path = $self.Path; keepDisplayOn = $false; antiLock = $false }
$matches = @(Get-KaAutomationDesired @($program))
$key = '{0}-{1}' -f $PID, $self.StartTime.ToUniversalTime().Ticks
Assert-Auto (@($matches | Where-Object { $_.requestId -ceq $key }).Count -eq 1) 'program matching includes PID and creation time'
$program.path = Join-Path $env:KA_DATA ([IO.Path]::GetFileName($self.Path))
Assert-Auto (@(Get-KaAutomationDesired @($program)).Count -eq 0) 'an equal process name at a different path does not match'
$invalid = $false
try { $rule.end = '00:00'; Set-KaAutomationConfig @($rule) } catch { $invalid = $true }
Assert-Auto $invalid 'invalid schedules are rejected before persistence'
Write-Host 'PROBE OK: desktop schedule and program rules preserve user stop priority'
