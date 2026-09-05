<#
    The one runner behind every CI step, and the reason the workflow files stay short.

    Each gate, probe and suite script is started as its own powershell.exe, because that is how
    they were written and how they were measured by hand: they set $env:KA_DATA, capture
    $PSScriptRoot and leave scheduled tasks behind, so sharing one session between two of them
    would test a situation nobody has ever run. A child also gives an unambiguous exit code.

    Failures are collected, not fatal on the first one: a red CI that names every red script is
    one round trip instead of one per run.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-ci.ps1 -Gates
        ... -Probes | -Suite | -Only <regex on file name>
        ... (no switch) = -Gates -Probes

    -Suite is the full tests/ka-tests.ps1. It is deliberately opt-in: it is the slow one, and it
    is the only step that touches the machine it runs on (power settings, scheduled tasks), so
    running it locally is a decision, not a reflex.
#>
[CmdletBinding()]
param(
    [switch]$Gates,
    [switch]$Probes,
    [switch]$Suite,
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

$selected = @()
if (-not ($Gates -or $Probes -or $Suite)) { $Gates = $true; $Probes = $true }
if ($Gates) {
    # ka-release-files.ps1 is a manifest (it prints a list), ka-tests.ps1 is the suite and
    # ka-ci.ps1 is this script - none of them is a gate, and globbing them would be a loop.
    $selected += @(Get-ChildItem -LiteralPath $here -Filter 'ka-*.ps1' -File |
        Where-Object { $_.Name -notmatch '^(ka-release-files|ka-tests|ka-ci)\.ps1$' } |
        Sort-Object Name)
}
if ($Probes) { $selected += @(Get-ChildItem -LiteralPath $here -Filter 'probe-*.ps1' -File | Sort-Object Name) }
if ($Suite) { $selected += @(Get-Item -LiteralPath (Join-Path $here 'ka-tests.ps1')) }
if ($Only) { $selected = @($selected | Where-Object { $_.Name -match $Only }) }
if (-not $selected.Count) { Write-Host 'nothing selected - check the -Only pattern'; exit 1 }

$bad = @()
foreach ($f in $selected) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $ps -NoNewWindow -Wait -PassThru `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $f.FullName + '"')
    $sw.Stop()
    $tag = '{0,-26} {1,5:0}s' -f $f.Name, $sw.Elapsed.TotalSeconds
    if ([int]$p.ExitCode -ne 0) {
        $bad += ('{0} exit={1}' -f $f.Name, [int]$p.ExitCode)
        Write-Host ('FAIL ' + $tag + ' exit=' + [int]$p.ExitCode) -ForegroundColor Red
    } else {
        Write-Host ('ok   ' + $tag)
    }
}
Write-Host ('----- {0} run, {1} red' -f $selected.Count, $bad.Count)
foreach ($b in $bad) { Write-Host ('  RED ' + $b) -ForegroundColor Red }
if ($bad.Count) { exit 1 }
exit 0
