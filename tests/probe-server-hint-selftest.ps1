param([switch]$Show)
$ErrorActionPreference = 'Stop'
<#
    Self-test for tests/probe-server-hint.ps1.

    A probe that has only ever been seen green proves nothing about the two bugs it names, so
    rebuild the pre-fix world inside a throwaway copy of the probe and require the red:

      shared  - one `.server.json` for every panel, deleted unconditionally on exit. This is
                the original bug: the second panel overwrote the first's pid, and the first
                panel to leave removed the handle the second one still needed.
      blind   - Stop-KaServer never asks the ports, so "I found no process of ours" is
                reported as 面板没有在运行 even while a panel is answering.

    Each mode must go red naming its own assertion, and the same mutant with the injection
    switched off must stay green - otherwise the red came from something else entirely.

    -Show prints all three runs verbatim, for the day the assertions themselves are in doubt.
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$src = Join-Path $here 'probe-server-hint.ps1'
$mut = Join-Path $root '_tmp/probe-server-hint-mutant.ps1'   # the mutant never lives beside the shipped tests

# The injections are line replacements, so every anchor has to match exactly one line in the real
# source. The -like patterns are kept free of [ ] on purpose - those are character classes there.
function Count-Like([string]$Rel, [string]$Pattern) {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $root $Rel))) { if ($l -like $Pattern) { $n++ } }
    return $n
}
foreach ($c in @(@{ F = 'ka-core.ps1'; P = '*data (''.server-{0}.json*' },
                 @{ F = 'ka-core.ps1'; P = '*$answering = @($candidatePorts*' },
                 @{ F = 'ka-server.ps1'; P = '*.pid -eq $PID)*' })) {
    $n = Count-Like $c.F $c.P
    if ($n -ne 1) { throw "expected exactly 1 line matching '$($c.P)' in $($c.F), found $n - the mutant would not be testing what we think" }
}

$text = [IO.File]::ReadAllText($src)
$anchor = 'Install-Child $progB'
if (-not $text.Contains($anchor)) { throw 'anchor line not found in probe-server-hint.ps1 - the mutant would not be testing what we think' }

# Single-quoted: this is source code for the mutant, nothing here may expand in *this* file.
$inject = @'
function Sabotage-Source([string]$Dir, [string]$Mode) {
    # Rewrites the *staged* copies into the pre-fix shape. The shipped tree is never touched.
    # LF + BOM are preserved: ka-core.ps1 is loaded by every child process started below.
    $enc = New-Object Text.UTF8Encoding($true)
    $cf = Join-Path $Dir 'ka-core.ps1'
    $cl = [IO.File]::ReadAllLines($cf)
    for ($i = 0; $i -lt $cl.Count; $i++) {
        if ($Mode -eq 'shared' -and $cl[$i] -like '*data (''.server-{0}.json*') {
            $cl[$i] = '    Join-Path (Get-KaPath).data (''.server.json'')'
        }
        if ($Mode -eq 'blind' -and $cl[$i] -like '*$answering = @($candidatePorts*') {
            $cl[$i] = '    $answering = @()'
        }
    }
    [IO.File]::WriteAllText($cf, (($cl -join "`n") + "`n"), $enc)
    if ($Mode -eq 'shared') {
        $sf = Join-Path $Dir 'ka-server.ps1'
        $sl = [IO.File]::ReadAllLines($sf)
        for ($i = 0; $i -lt $sl.Count; $i++) {
            if ($sl[$i] -like '*.pid -eq $PID)*') { $sl[$i] = '        if ($true) {' }
        }
        [IO.File]::WriteAllText($sf, (($sl -join "`n") + "`n"), $enc)
    }
}
if ("$env:KA_PROBE_SABOTAGE" -eq 'shared') { Write-Output '  note  mutant: one shared .server.json, deleted by whoever exits first'; Sabotage-Source $progA 'shared'; Sabotage-Source $progB 'shared' }
if ("$env:KA_PROBE_SABOTAGE" -eq 'blind')  { Write-Output '  note  mutant: stop-server never probes the ports'; Sabotage-Source $progA 'blind'; Sabotage-Source $progB 'blind' }
'@

$text = $text.Replace($anchor, $anchor + "`n" + $inject)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mut) | Out-Null
[IO.File]::WriteAllText($mut, $text, (New-Object Text.UTF8Encoding($true)))

function Run-Mutant([string]$Mode) {
    if ($Mode) { $env:KA_PROBE_SABOTAGE = $Mode } else { Remove-Item Env:KA_PROBE_SABOTAGE -ErrorAction SilentlyContinue }
    $f = Join-Path $env:TEMP ('ka-hint-mut-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $p = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput $f `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $mut + '"')
        $r = [IO.File]::ReadAllText($f)
        if ($Show) {
            # Write-Host, not Write-Output: anything this function emits becomes its return value.
            Write-Host ('===== mode=' + $(if ($Mode) { $Mode } else { 'control' }) + '  exit=' + $p.ExitCode + ' =====')
            Write-Host $r
        }
        @{ Exit = $p.ExitCode; Text = $r }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

$bad = @()
function Require-Red($Run, [string]$Mode, [string[]]$MustName) {
    if ($null -eq $Run) { $script:bad += "$Mode mutant did not run"; return }
    if ($Run.Exit -eq 0) { $script:bad += "$Mode mutant still passed - the probe cannot see the pre-fix behaviour it names" }
    foreach ($m in $MustName) {
        if ($Run.Text -notlike ('*' + $m + '*')) { $script:bad += "$Mode mutant never failed with '$m'" }
    }
}
function Require-Green($Run, [string]$What) {
    if ($null -eq $Run) { $script:bad += "$What did not run"; return }
    if ($Run.Exit -ne 0) {
        $script:bad += "$What was red without any sabotage - the reds above would prove nothing"
        foreach ($l in ($Run.Text -split "`n")) { if ($l -like '*FAIL*' -or $l -like '*PROBE FAILED*') { $script:bad += ('        ' + $l.Trim()) } }
    }
}

# Order matters: the control run last, so a broken mutant cannot be blamed on a stolen port.
$shared = Run-Mutant 'shared'
$blind = Run-Mutant 'blind'
$clean = Run-Mutant ''

Require-Red $shared 'shared' @('two panels still share one handle file', 'this is the original bug')
Require-Red $blind 'blind' @('it did not report that', 'user-facing verdict still says')
Require-Green $clean 'the unsabotaged mutant'

Remove-Item -LiteralPath $mut -Force -ErrorAction SilentlyContinue
foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: reverting either half of the fix turns this probe red on its own assertion, and the untouched mutant stays green'
