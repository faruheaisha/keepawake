# Isolated audit reproductions. Does not launch workers, send input, change power plans,
# register tasks, or touch the real user data directory. Product functions are extracted
# from their AST; system effects are replaced by explicit fixtures.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root '_tmp\audit-20261031'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$coreAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ka-core.ps1'), [ref]$null, [ref]$null)
$lidAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ka-lid.ps1'), [ref]$null, [ref]$null)
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ka-server.ps1'), [ref]$null, [ref]$null)
function Get-AuditFunction([string]$Name, $Tree = $coreAst) {
    $nodes = @($Tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object Name -eq $Name)
    if ($nodes.Count -ne 1) { throw "Expected one function: $Name" }
    [scriptblock]::Create($nodes[0].Extent.Text)
}
$results = New-Object System.Collections.Generic.List[object]
function Record([string]$Id, [bool]$Reproduced, $Detail) {
    $results.Add([PSCustomObject]@{ id = $Id; reproduced = $Reproduced; detail = $Detail })
    Write-Host ('{0} {1} {2}' -f $(if ($Reproduced) { 'REPRODUCED' } else { 'NOT REPRODUCED' }), $Id, ($Detail | ConvertTo-Json -Compress -Depth 5))
}

# Compile the real native implementation, replacing only external power and mouse calls.
$native = @($coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'namespace Ka \{' }, $true))[0].Value
$native = $native.Replace('namespace Ka {', 'namespace AuditKa {')
$native = $native.Replace('static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS sps);', @'
static bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS sps) {
    sps = new SYSTEM_POWER_STATUS(); sps.ACLineStatus = MockAc;
    sps.BatteryFlag = MockFlag; sps.BatteryLifePercent = 5; sps.SystemStatus = MockSaver;
    return true;
}
public static byte MockAc = 0, MockFlag = 0, MockSaver = 0;
'@).Replace('[DllImport("kernel32.dll")]' + "`n" + '    static bool GetSystemPowerStatus', 'static bool GetSystemPowerStatus')
$native = $native.Replace('static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);', @'
static uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize) {
    LastMouseFlags = pInputs[0].u.mi.dwFlags; return 0;
}
public static uint LastMouseFlags = 0;
'@).Replace('[DllImport("user32.dll", SetLastError = true)]' + "`n" + '    static uint SendInput', 'static uint SendInput')
$native = $native.Replace('static extern bool GetCursorPos(out POINT lpPoint);', 'static bool GetCursorPos(out POINT lpPoint) { lpPoint = new POINT(); lpPoint.X = 100; lpPoint.Y = 100; return true; }')
$native = $native.Replace('[DllImport("user32.dll")]' + "`n" + '    static bool GetCursorPos', 'static bool GetCursorPos')
$native = $native.Replace('static extern int GetSystemMetrics(int nIndex);', 'static int GetSystemMetrics(int nIndex) { return nIndex == 78 ? 3840 : (nIndex == 79 ? 1080 : 0); }')
$native = $native.Replace('[DllImport("user32.dll")]' + "`n" + '    static int GetSystemMetrics', 'static int GetSystemMetrics')
if ($native -match '\[DllImport[^\r\n]*\]\s*(static (bool GetSystemPowerStatus|bool GetCursorPos|int GetSystemMetrics|uint SendInput))') { throw 'Fixture patch failed to remove a DllImport' }
Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition $native
[AuditKa.Native]::MockFlag = 2
$low = [AuditKa.Native]::PowerStatus()
[AuditKa.Native]::MockFlag = 4
$critical = [AuditKa.Native]::PowerStatus()
[AuditKa.Native]::MockFlag = 8
$charging = [AuditKa.Native]::PowerStatus()
[AuditKa.Native]::MockSaver = 1
$saver = [AuditKa.Native]::PowerStatus()
Record 'B01-battery-bits' (-not $low.low -and -not $critical.critical -and $charging.critical -and -not $saver.onBatterySaver) @{
    lowFlag2 = $low.low; criticalFlag4 = $critical.critical; chargingFlag8Critical = $charging.critical; saverFlag1 = $saver.onBatterySaver
}
$mouseOk = [AuditKa.Native]::NudgeMouse()
Record 'B02-mouse' ($mouseOk -and (([AuditKa.Native]::LastMouseFlags -band 0x4000) -eq 0)) @{
    sendInputReturned = 0; reportedSuccess = $mouseOk; flags = ('0x{0:X}' -f [AuditKa.Native]::LastMouseFlags); virtualDesktop = '3840x1080'
}

& {
    . (Get-AuditFunction 'Start-KaProtection')
    . (Get-AuditFunction 'Get-KaDefaultConfig')
    $cfg = Get-KaDefaultConfig
    $st = [PSCustomObject]@{ keepDisplayOn = $cfg.keepDisplayOn; antiLock = $cfg.antiLock; awayMode = $cfg.awayMode; antiLockMethod = $cfg.antiLockMethod; antiLockInterval = $cfg.antiLockIntervalSec; batteryFloor = $cfg.batteryFloorPercent; expiresEpoch = 0; reassertSec = 60 }
    $script:stops = 0
    function Get-KaConfig { $cfg.Clone() }
    function Get-KaPath { @{ state = 'fixture' } }
    function Get-KaWorker { [PSCustomObject]@{ Pid = 12345 } }
    function Read-KaJson { $st }
    function Stop-KaWorker { $script:stops++; @{} }
    function Start-KaWorker { @{ Ok = $true; AlreadyRunning = $true; Pid = 12345 } }
    function Set-KaIntent { $true }
    $r = Start-KaProtection -Override @{ reassertSec = 90; batteryAllowDisplayOff = $false }
    Record 'B03-live-options' ($script:stops -eq 0 -and -not $r.restarted -and -not $r.applied.batteryAllowDisplayOff) @{
        stopCalls = $script:stops; restarted = $r.restarted; claimedBatteryAllowDisplayOff = $r.applied.batteryAllowDisplayOff; workerReassertSec = $st.reassertSec
    }
}

& {
    . (Get-AuditFunction 'Start-KaProtection')
    . (Get-AuditFunction 'Set-KaIntent')
    . (Get-AuditFunction 'Get-KaIntent')
    . (Get-AuditFunction 'Reconcile-KaProtection')
    . (Get-AuditFunction 'Get-KaDefaultConfig')
    . (Get-AuditFunction 'Write-KaJson')
    . (Get-AuditFunction 'Read-KaJson')
    . (Get-AuditFunction 'Get-KaEpoch')
    $intentFile = Join-Path $outDir 'fixture-intent.json'
    function Get-KaPath { @{ state = (Join-Path $outDir 'missing-state.json'); intent = $intentFile } }
    function Get-KaConfig { Get-KaDefaultConfig }
    function Get-KaWorker { @() }
    function Start-KaWorker { param($Minutes, $Override = @{}) $script:capturedOverride = $Override; @{ Ok = $true } }
    $first = Start-KaProtection -Minutes 30 -Override @{ keepDisplayOn = $false; antiLock = $false }
    $initialOverride = $script:capturedOverride.Clone()
    $intent = Read-KaJson $intentFile
    $second = Reconcile-KaProtection
    # README.md explicitly specifies recovery from config.json, not temporary overrides.
    # This observation is a documented design tradeoff, NOT an additional bug.
    Record 'D01-documented-recovery-defaults' ($initialOverride.Count -eq 2 -and $script:capturedOverride.Count -eq 0 -and -not $intent.override) @{
        initialOverride = $initialOverride; recoveredOverride = $script:capturedOverride; intentFields = @($intent.PSObject.Properties.Name); action = $second.action
    }
}

& {
    . (Get-AuditFunction 'Start-KaProtection')
    . (Get-AuditFunction 'Reconcile-KaProtection')
    . (Get-AuditFunction 'Get-KaDefaultConfig')
    . (Get-AuditFunction 'Get-KaEpoch')
    $script:awake = $false; $script:desired = 'off'; $script:guardAction = ''
    function Get-KaConfig { Get-KaDefaultConfig }
    function Get-KaPath { @{ state = 'fixture' } }
    function Get-KaWorker { if ($script:awake) { [PSCustomObject]@{ Pid = 12345 } } }
    function Read-KaJson { $null }
    function Get-KaIntent { @{ desired = $script:desired; expiresEpoch = 0; expired = $false } }
    function Set-KaIntent { param($Desired, $Minutes) $script:desired = $Desired; $true }
    function Stop-KaWorker { $script:awake = $false; @{} }
    function Start-KaWorker {
        $script:awake = $true
        # Interleave a scheduled reconciliation before Start-KaProtection commits intent.
        $script:guardAction = (Reconcile-KaProtection).action
        @{ Ok = $true; Pid = 12345 }
    }
    $r = Start-KaProtection
    Record 'B05-start-guard-race' ($r.Ok -and -not $script:awake -and $script:desired -eq 'awake') @{
        startReturnedOk = $r.Ok; workerAlive = $script:awake; intent = $script:desired; guardAction = $script:guardAction
    }
}

$lidSwitch = @($lidAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $false) | Where-Object { $_.Condition.Extent.Text -eq '$Action' })
if ($lidSwitch.Count -ne 1) { throw 'Expected one lid action switch' }
$lidBlock = [scriptblock]::Create($lidSwitch[0].Extent.Text)
foreach ($case in @('backup-fails', 'backup-other-plan', 'restore-corrupt')) {
    & {
        . (Get-AuditFunction 'Read-KaJson')
        $backupPath = Join-Path $outDir ('lid-' + $case + '.json')
        $Action = 'apply'; $Force = $false; $script:KaNoLid = $false
        $KaLidSub = 'fixture'; $KaLidAction = 'fixture'; $script:powerCalls = @()
        $r = @{ Ok = $false; Verified = $false; Reason = '' }
        if ($case -eq 'backup-other-plan') { [IO.File]::WriteAllText($backupPath, '{"ac":1,"dc":1,"found":true,"schemeGuid":"A"}') }
        if ($case -eq 'restore-corrupt') { [IO.File]::WriteAllText($backupPath, '{broken'); $Action = 'restore' }
        function Test-KaAdmin { $true }
        function Get-KaActiveScheme { @{ guid = 'B'; name = 'Fixture plan B' } }
        function Get-KaLid { @{ found = $true; ac = 0; dc = 0 } }
        function Get-KaText { param($Key, $Vars) $Key }
        function Write-KaJson { $false }
        function Add-KaLog { }
        function powercfg { $script:powerCalls += ($args -join ' ') }
        . $lidBlock
        $writes = @($script:powerCalls | Where-Object { $_ -match '^/set(ac|dc)valueindex' }).Count
        if ($case -eq 'backup-fails') {
            Record 'B06-lid-no-backup' ($writes -eq 2 -and $r.Ok -and -not (Test-Path -LiteralPath $backupPath)) @{ writes = $writes; ok = $r.Ok; backupExists = (Test-Path -LiteralPath $backupPath) }
        } elseif ($case -eq 'backup-other-plan') {
            Record 'B07-lid-plan' ($writes -eq 2 -and $r.Ok) @{ writes = $writes; backupScheme = 'A'; modifiedScheme = 'B'; ok = $r.Ok }
        } else {
            Record 'B08-lid-corrupt' ($writes -eq 0 -and $r.Verified -and -not (Test-Path -LiteralPath $backupPath)) @{ valueWrites = $writes; verified = $r.Verified; backupDeleted = (-not (Test-Path -LiteralPath $backupPath)); reason = $r.Reason }
        }
    }
}

& {
    . (Get-AuditFunction 'Invoke-KaApi' $serverAst)
    function Start-KaProtection { param($Minutes, $Override) @{ Ok = $true; receivedMinutes = $Minutes; receivedOverride = $Override } }
    function Get-KaBounded { param($Value, $Min, $Max, $Fallback) if ($Value -lt $Min) { $Min } elseif ($Value -gt $Max) { $Max } else { $Value } }
    function Invalidate-KaStateCache { }
    function Add-KaLog { }
    function ConvertTo-KaJsonSafe { param($Object) $Object | ConvertTo-Json -Compress -Depth 6 }
    $r = Invoke-KaApi -Method POST -Path '/api/start' -Body ([PSCustomObject]@{ minutes = 'oops'; antiLock = 'false' }) -Query ''
    $b = $r.body | ConvertFrom-Json
    Record 'B09-api-validation' ($r.status -eq 200 -and $b.receivedMinutes -eq 0 -and $b.receivedOverride.antiLock) @{ status = $r.status; receivedMinutes = $b.receivedMinutes; receivedAntiLock = $b.receivedOverride.antiLock }
}

& {
    . (Get-AuditFunction 'Get-KaProtectedSpan')
    $fixtureNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    function Get-KaPath { @{ state = 'fixture'; log = (Join-Path $outDir 'missing-history.log') } }
    function Read-KaJson { [PSCustomObject]@{ pid = $PID; startedEpoch = ($fixtureNow - 7200) } }
    # The real current PowerShell process exists, but it is this auditor, not a worker.
    $r = Get-KaProtectedSpan
    Record 'B11-evidence-pid' ($r.spans.Count -eq 1 -and $r.spans[0].from -eq ($fixtureNow - 7200)) @{
        realProcessRole = 'audit-script'; claimedProtectedSeconds = ($r.spans[0].to - $r.spans[0].from); known = $r.known
    }
}

# Actual concurrent writes of the unmodified Write-KaJson function, isolated to a fixture.
$writerSource = (Get-AuditFunction 'Write-KaJson').ToString()
$target = Join-Path $outDir 'concurrent.json'
$jobs = @()
try {
    for ($j = 0; $j -lt 4; $j++) {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({ param($source, $file, $writer)
            $ErrorActionPreference = 'Stop'
            . ([scriptblock]::Create($source))
            $failures = 0
            for ($i = 0; $i -lt 150; $i++) {
                if (-not (Write-KaJson $file @{ writer = $writer; sequence = $i; payload = ('x' * 2048) })) { $failures++ }
            }
            @{ writer = $writer; failures = $failures }
        }).AddArgument($writerSource).AddArgument($target).AddArgument($j)
        $jobs += @{ ps = $ps; handle = $ps.BeginInvoke() }
    }
    $rows = @($jobs | ForEach-Object { $_.ps.EndInvoke($_.handle) })
    foreach ($job in $jobs) { if ($job.ps.HadErrors) { throw ('Writer fixture error: ' + ($job.ps.Streams.Error -join ' | ')) } }
    $failures = ($rows | ForEach-Object { $_.failures } | Measure-Object -Sum).Sum
    Record 'B10-json-race' ($failures -gt 0) @{ writes = 600; failed = $failures; writers = 4 }
} finally { foreach ($job in $jobs) { $job.ps.Dispose() } }

$results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'reproductions.json') -Encoding UTF8
if (@($results | Where-Object { -not $_.reproduced }).Count) { exit 1 }
Write-Host ('Audit complete: {0}/{0} scenarios reproduced (10 bug scenarios + 1 documented design); all system side effects were fixtures.' -f $results.Count)
