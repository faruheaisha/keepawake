$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ka-tray.ps1'), [ref]$null, [ref]$null)
$node = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-KaTrayNotice' }, $true))
if ($node.Count -ne 1) { throw 'notice classifier is missing' }
. ([scriptblock]::Create($node[0].Extent.Text))
$state = @{ stale = $false; error = ''; note = ''; displayDowngrade = $false }
if ((Get-KaTrayNotice $state @{desired='awake'} $false $false) -ne 'healthy') { throw 'healthy worker is not healthy' }
if ((Get-KaTrayNotice $null @{desired='awake'} $false $false) -ne 'worker-missing') { throw 'missing worker was not reported' }
if ((Get-KaTrayNotice $null @{desired='off'} $false $false) -ne 'off') { throw 'explicit stop was treated as failure' }
if ((Get-KaTrayNotice $null @{desired='awake'} $false $true) -ne 'paused') { throw 'pause was treated as failure' }
$state.displayDowngrade = $true
if ((Get-KaTrayNotice $state @{desired='awake'} $false $false) -ne 'battery-floor') { throw 'battery downgrade was missed' }
$state.note = 'il-mismatch'
if ((Get-KaTrayNotice $state @{desired='awake'} $false $false) -ne 'input-blocked') { throw 'input failure was missed' }
$state.stale = $true
if ((Get-KaTrayNotice $state @{desired='awake'} $false $false) -ne 'stale') { throw 'stale state was masked' }
Write-Host 'PROBE OK: tray notices distinguish failures, explicit stops, pause and recovery'
