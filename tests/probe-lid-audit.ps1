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
            Record 'B06-lid-no-backup' ($writes -eq 0 -and -not $r.Ok -and -not (Test-Path -LiteralPath $backupPath)) @{ writes = $writes; ok = $r.Ok; backupExists = (Test-Path -LiteralPath $backupPath) }
        } elseif ($case -eq 'backup-other-plan') {
            Record 'B07-lid-plan' ($writes -eq 0 -and -not $r.Ok) @{ writes = $writes; backupScheme = 'A'; modifiedScheme = 'B'; ok = $r.Ok }
        } else {
            Record 'B08-lid-corrupt' ($writes -eq 0 -and -not $r.Verified -and (Test-Path -LiteralPath $backupPath)) @{ valueWrites = $writes; verified = $r.Verified; backupDeleted = (-not (Test-Path -LiteralPath $backupPath)); reason = $r.Reason }
        }
    }
}


if (@($results | Where-Object { -not $_.reproduced }).Count) { exit 1 }
Write-Host "PROBE OK: lid backup guards"
