param([switch]$Show, [string]$Only = '')
$ErrorActionPreference = 'Stop'
<#
    Self-test for tests/probe-server-hint.ps1.

    A probe that has only ever been seen green proves nothing about the bugs it names, so
    rebuild the pre-fix world inside a throwaway copy of the probe and require the red:

      shared      - one `.server.json` for every panel, deleted unconditionally on exit. This is
                    the original bug: the second panel overwrote the first's pid, and the first
                    panel to leave removed the handle the second one still needed.
      blind       - Stop-KaServer never asks the ports, so "I found no process of ours" is
                    reported as 面板没有在运行 even while a panel is answering.
      claim       - a panel in this program folder is ours, whoever its data root is. The heart of
                    the second bug; measured on this machine, not imagined: ka.log 2026-09-27
                    01:12:47 `SERVER EXIT pid=28208` is the user's own panel obeying a scratch
                    stop-server that had only moved KA_DATA.
      stopfilter  - the Ours test is computed but Stop-KaServer ignores it.
      startfilter - the Ours test is computed but Start-KaServer ignores it.
      portfallback- the shutdown request is aimed at "the port we would have used" instead of at a
                    port some evidence names for that process.

    Each mode must go red naming its own assertion, and the same mutant with the injection
    switched off must stay green - otherwise the red came from something else entirely.

    -Show prints every run verbatim, for the day the assertions themselves are in doubt.
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$src = Join-Path $here 'probe-server-hint.ps1'
# Per-pid, because this file writes the mutant, runs it six times and then deletes it: two sweeps on one
# machine sharing one filename had one of them delete the other's subject mid-run, and the symptom was
# three arms failing with "The argument ...\probe-server-hint-mutant.ps1 to the -File parameter does not
# exist" - a real trap from the day's list, paid for once. # the mutant never lives beside the shipped tests
$mut = Join-Path $root ('_tmp/probe-server-hint-mutant-' + $PID + '.ps1')

# The injections are line replacements, so every anchor has to match exactly one line in the real
# source. The -like patterns are kept free of [ ] on purpose - those are character classes there,
# and `[int]` is half of what the newer anchors are looking for, so those use Count-Plain.
function Count-Like([string]$Rel, [string]$Pattern) {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $root $Rel))) { if ($l -like $Pattern) { $n++ } }
    return $n
}
function Count-Plain([string]$Rel, [string]$Needle) {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $root $Rel))) { if ($l.Contains($Needle)) { $n++ } }
    return $n
}
foreach ($c in @(@{ F = 'ka-core.ps1'; P = '*data (''.server-{0}.json*' },
                 @{ F = 'ka-core.ps1'; P = '*$answering = @($candidatePorts*' },
                 @{ F = 'ka-server.ps1'; P = '*.pid -eq $PID)*' })) {
    $n = Count-Like $c.F $c.P
    if ($n -ne 1) { throw "expected exactly 1 line matching '$($c.P)' in $($c.F), found $n - the mutant would not be testing what we think" }
}
foreach ($c in @(@{ F = 'ka-core.ps1'; N = '$ours = [bool]($hint' },
                 @{ F = 'ka-core.ps1'; N = '$servers = @(Get-KaServer | Where-Object' },
                 @{ F = 'ka-core.ps1'; N = '$existing = @(Get-KaServer | Where-Object' },
                 @{ F = 'ka-core.ps1'; N = '$port = [int]$s.Port' })) {
    $n = Count-Plain $c.F $c.N
    if ($n -ne 1) { throw "expected exactly 1 line containing '$($c.N)' in $($c.F), found $n - the mutant would not be testing what we think" }
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
        if ($Mode -eq 'claim' -and $cl[$i].Contains('$ours = [bool]($hint')) {
            $cl[$i] = '            $ours = [bool]$byPath'
        }
        if ($Mode -eq 'stopfilter' -and $cl[$i].Contains('$servers = @(Get-KaServer | Where-Object')) {
            $cl[$i] = '    $servers = @(Get-KaServer)'
        }
        if ($Mode -eq 'startfilter' -and $cl[$i].Contains('$existing = @(Get-KaServer | Where-Object')) {
            $cl[$i] = '    $existing = @(Get-KaServer)'
        }
        if ($Mode -eq 'portfallback' -and $cl[$i].Contains('$port = [int]$s.Port')) {
            $cl[$i] = '        $port = [int]$cfg.port'
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
$notes = @{
    shared       = 'one shared .server.json, deleted by whoever exits first'
    blind        = 'stop-server never probes the ports'
    claim        = 'a panel is ours because it runs from this program folder'
    stopfilter   = 'stop-server takes every panel Get-KaServer lists, ours or not'
    startfilter  = 'serve takes over any panel it can see, ours or not'
    portfallback = 'the shutdown request is aimed at the configured port, not an evidenced one'
}
foreach ($m in @('shared', 'blind', 'claim', 'stopfilter', 'startfilter', 'portfallback')) {
    if ("$env:KA_PROBE_SABOTAGE" -ne $m) { continue }
    Write-Output ('  note  mutant: ' + $notes[$m])
    Sabotage-Source $progA $m
    Sabotage-Source $progB $m
}
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
# Each run is a whole probe (9 legs, ~76 s measured here), so the sweep costs arms+1 of those.
# -Only <a,b> runs a subset and still ends with its own control, which is how a human re-runs one
# arm without paying for six: CI passes no arguments and so always runs every arm.
$arms = @('shared', 'blind', 'claim', 'stopfilter', 'startfilter', 'portfallback')
$expect = @{
    shared       = @('two panels still share one handle file', 'this is the original bug')
    blind        = @('it did not report that', 'user-facing verdict still says')
    claim        = @('dataA claims a panel that answers to dataC')
    stopfilter   = @('stop-server from dataA stopped a panel of dataC')
    startfilter  = @("serve accepted the dataC panel as dataA's own")
    portfallback = @('was shut down by a stop-server that only wanted its own')
}
if ($Only) {
    $want = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($want | Where-Object { $arms -notcontains $_ })
    if ($unknown.Count) { throw ("unknown arm(s) in -Only: " + ($unknown -join ', ') + " - known: " + ($arms -join ', ')) }
    $arms = $want
}
$runs = @{}
foreach ($m in $arms) { $runs[$m] = Run-Mutant $m }
$clean = Run-Mutant ''

foreach ($m in $arms) { Require-Red $runs[$m] $m $expect[$m] }
Require-Green $clean 'the unsabotaged mutant'

Remove-Item -LiteralPath $mut -Force -ErrorAction SilentlyContinue
foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output ('PROBE OK: ' + $arms.Count + ' reverted guard(s) each turned this probe red on their own assertion (' + ($arms -join ', ') + '), and the untouched mutant stays green')
