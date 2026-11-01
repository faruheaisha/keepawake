$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ka-core.ps1'), [ref]$null, [ref]$null)
$node = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-KaDiagnosticExport' }, $true))
if ($node.Count -ne 1) { throw 'diagnostic export function is missing' }
. ([scriptblock]::Create($node[0].Extent.Text))
$script:KaVersion = 'test'
$secret = 'private-user-secret-4819'
function Get-KaFullState {
    param([switch]$Quiet)
    return @{ running = $true; workerCount = 1; root = $secret; dataRoot = $secret
        worker = @{ pid = 12345; displayActive = $true; antiLock = $false; error = $secret; note = $secret }
        guard = @{ installed = $true; enabled = $true; exec = $secret }
        battery = @{ known = $true; acKnown = $true; batteryKnown = $true; acOnline = $true; percent = 80 }
        leases = @{ items = @(@{ reason = $secret; tokenHash = $secret }) }
        alert = @(@{ id = 'alert.staleState'; path = $secret }, @{ id = $secret }) }
}
function Get-KaSleepEvidence {
    param($Since)
    return @{ queriesOk = $false; canSee = $false; instrument = $secret; reason = $secret; events = @($secret)
        realSleeps = 0; s3Enters = 0; bypasses = 0; s3Bypasses = 0; spanUnknown = 0; s3SpanUnknown = 0; truncated = $false }
}
$json = Get-KaDiagnosticExport | ConvertTo-Json -Depth 10
if ($json.Contains($secret) -or $json.Contains('12345')) { throw 'diagnostic export leaked fixture data' }
$out = $json | ConvertFrom-Json
if ($out.schemaVersion -ne 1 -or -not $out.protection.running -or $out.evidence.queriesOk -or
    $out.evidence.instrument -ne 'unknown' -or @($out.alertIds).Count -ne 1) { throw 'diagnostic export lost expected facts or did not report unknown evidence' }
Write-Host 'PROBE OK: diagnostic export uses a whitelist and retains unknown evidence'
