$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ka-core.ps1'), [ref]$null, [ref]$null)
$node = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-KaWorker' }, $true))
if ($node.Count -ne 1) { throw 'Stop-KaWorker is missing' }
. ([scriptblock]::Create($node[0].Extent.Text))
$dir = Join-Path $root ('_tmp\stop-honesty-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$flag = Join-Path $dir 'stop.flag'
$script:cooperates = $false
function Get-KaPath { @{ stopFlag = $flag; data = $dir } }
function Get-KaWorker {
    if ($script:cooperates -and (Test-Path -LiteralPath $flag)) { return }
    [PSCustomObject]@{ Pid = 123456 }
}
function Get-KaEpoch { 1700000000 }
function Write-KaJson { param($Path, $Object, $Depth) [IO.File]::WriteAllText($Path, '{}'); return $true }
function Stop-Process { throw 'injected permission failure' }
function Add-KaLog { }
$r = Stop-KaWorker -GraceSec 0
if ($r.Stopped -ne 0 -or $r.Remaining -ne 1 -or -not (Test-Path -LiteralPath $flag)) { throw 'failed stop was reported as success or its request was discarded' }
Remove-Item -LiteralPath $flag -Force
$script:cooperates = $true
$r = Stop-KaWorker -GraceSec 3
if ($r.Stopped -ne 1 -or $r.Remaining -ne 0 -or (Test-Path -LiteralPath $flag)) { throw 'cooperative stop did not complete cleanly' }
Write-Host 'PROBE OK: failed stops remain visible and cooperative stops report actual results'
