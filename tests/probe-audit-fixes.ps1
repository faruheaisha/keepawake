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
    Write-Host ('{0} {1} {2}' -f $(if ($Reproduced) { 'PASS' } else { 'FAIL' }), $Id, ($Detail | ConvertTo-Json -Compress -Depth 5))
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
Record 'B01-battery-bits' ($low.low -and $critical.critical -and -not $charging.critical -and $saver.onBatterySaver) @{
    lowFlag2 = $low.low; criticalFlag4 = $critical.critical; chargingFlag8Critical = $charging.critical; saverFlag1 = $saver.onBatterySaver
}
[AuditKa.Native]::MockFlag = 255
[AuditKa.Native]::MockAc = 255
$unknown = [AuditKa.Native]::PowerStatus()
Record 'B01-unknown-power' (-not $unknown.acKnown -and -not $unknown.batteryKnown -and -not $unknown.critical) @{
    acKnown = $unknown.acKnown; batteryKnown = $unknown.batteryKnown; critical = $unknown.critical
}
& {
    . (Get-AuditFunction 'Get-KaBatteryAction')
    . (Get-AuditFunction 'Test-KaCriticalBattery')
    $action = Get-KaBatteryAction -Status @{ known = $true; acOnline = $false; acKnown = $false; hasBattery = $true; critical = $true; percent = 1 } `
        -KeepDisplayOn $true -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false
    $criticalUnknown = Test-KaCriticalBattery -Status @{ known = $true; acKnown = $false; acOnline = $false; critical = $true }
    $criticalPlugged = Test-KaCriticalBattery -Status @{ known = $true; acKnown = $true; acOnline = $true; critical = $true }
    $criticalUnplugged = Test-KaCriticalBattery -Status @{ known = $true; acKnown = $true; acOnline = $false; critical = $true }
    Record 'B01-critical-restart-gate' (-not $criticalUnknown -and -not $criticalPlugged -and $criticalUnplugged) @{
        unknown = $criticalUnknown; plugged = $criticalPlugged; unplugged = $criticalUnplugged }
    Record 'B01-unknown-ac-action' (-not $action.Abort -and -not $action.Downgrade) @{ abort = $action.Abort; downgrade = $action.Downgrade }
}
$mouseOk = [AuditKa.Native]::NudgeMouse()
Record 'B02-mouse' (-not $mouseOk -and (([AuditKa.Native]::LastMouseFlags -band 0x4000) -ne 0)) @{
    sendInputReturned = 0; reportedSuccess = $mouseOk; flags = ('0x{0:X}' -f [AuditKa.Native]::LastMouseFlags); virtualDesktop = '3840x1080'
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
    Record 'B10-json-race' ($failures -eq 0) @{ writes = 600; failed = $failures; writers = 4 }
} finally { foreach ($job in $jobs) { $job.ps.Dispose() } }


if (@($results | Where-Object { -not $_.reproduced }).Count) { exit 1 }
Write-Host "PROBE OK: native flag decoding, rejected input, virtual desktop and concurrent JSON writes"
