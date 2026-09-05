param([switch]$Show)
$ErrorActionPreference = 'Stop'
<#
    Self-test for packaging/build.ps1 -Smoke.

    The smoke is the only gate that claims "the thing a person downloads actually runs", and a
    gate seen only green has proved nothing. So build three broken release trees inside a
    throwaway copy of the manifest - each one a defect that would ship silently if the smoke
    were blind to it - and require each to turn the smoke red on its own assertion:

      override - KA_DATA ignored, so the artifact writes into whoever built it. The portable
                 zip would still "work"; it would just work on somebody else's machine.
      crash    - status throws. The archive has the right entries and the product is dead.
      litter   - status writes into its own program directory. Harmless on a writable folder,
                 fatal on a Program Files install - and the exact thing the no-fallback
                 doctrine says must never happen.

    The same tree with no injection must stay green, or the reds above came from nothing.
    -Show prints all four runs verbatim.
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$work = Join-Path $root '_tmp/build-selftest'
$build = Join-Path $root 'packaging/build.ps1'

# Every injection is a line replacement, so each anchor has to match exactly one line of the
# real source. -like patterns stay free of [ ] on purpose: those are character classes there.
function Count-Like([string]$Rel, [string]$Pattern) {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $root $Rel))) { if ($l -like $Pattern) { $n++ } }
    return $n
}
foreach ($c in @(@{ F = 'ka-core.ps1'; P = '*if ($env:KA_DATA) {*' },
                 @{ F = 'ka.ps1'; P = '*= Show-Status (Get-KaFullState)*' })) {
    $n = Count-Like $c.F $c.P
    if ($n -ne 1) { throw "expected exactly 1 line matching '$($c.P)' in $($c.F), found $n - the mutant would not be testing what we think" }
}

. (Join-Path $root 'tests/ka-release-files.ps1')
$manifest = @(Get-KaReleaseFile)

function Sabotage([string]$Dir, [string]$Mode) {
    # Rewrites the staged copy only; the shipped tree is never touched. LF + BOM are kept because
    # every one of these files is read back by the packaging build and by the child it starts.
    if ($Mode -eq 'clean') { return }
    $enc = New-Object Text.UTF8Encoding($true)
    if ($Mode -eq 'override') {
        $f = Join-Path $Dir 'ka-core.ps1'
        $l = [IO.File]::ReadAllLines($f)
        for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -like '*if ($env:KA_DATA) {*') { $l[$i] = '    if ($false) {' } }
        [IO.File]::WriteAllText($f, (($l -join "`n") + "`n"), $enc)
        return
    }
    $f = Join-Path $Dir 'ka.ps1'
    $l = [IO.File]::ReadAllLines($f)
    for ($i = 0; $i -lt $l.Count; $i++) {
        if ($l[$i] -like '*= Show-Status (Get-KaFullState)*') {
            if ($Mode -eq 'crash') {
                $l[$i] = "        throw 'build-selftest: this artifact cannot render status'"
            } elseif ($Mode -eq 'litter') {
                $l[$i] = "        [IO.File]::WriteAllText((Join-Path (Get-KaPath).program 'build-selftest-litter.txt'), 'x')`n" + $l[$i]
            }
        }
    }
    [IO.File]::WriteAllText($f, (($l -join "`n") + "`n"), $enc)
}

function New-Tree([string]$Mode) {
    # A release tree is exactly what the manifest names, plus the files build.ps1 loads but does
    # not ship: the manifest itself and the Inno compiler finder. Nothing outside this list may be
    # needed to package - which is also the point. Add a helper to build.ps1 and forget it here
    # and all four legs below go red for one unrelated reason, which is exactly what happened
    # when ka-iscc.ps1 was extracted: the clean tree "failed" and the three reds proved nothing.
    $dst = Join-Path $work $Mode
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $dst
    $extra = @('tests/ka-release-files.ps1', 'packaging/build.ps1', 'packaging/ka-iscc.ps1')
    foreach ($n in @($manifest) + $extra) {
        $src = Join-Path $root ($n -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { throw "the manifest cannot build a tree: $n is missing" }
        $d = Join-Path $dst ($n -replace '/', '\')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $d)
        Copy-Item -LiteralPath $src -Destination $d -Force
    }
    Sabotage $dst $Mode
    return $dst
}

function Run-Build([string]$Tree, [string]$Mode) {
    $out = Join-Path $env:TEMP ('ka-build-mut-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $p = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError ($out + '.err') `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Tree 'packaging\build.ps1') + '" -OutDir "' + (Join-Path $Tree 'dist') + '" -Smoke')
        $r = [IO.File]::ReadAllText($out) + [IO.File]::ReadAllText($out + '.err')
        if ($Show) {
            # Write-Host, not Write-Output: whatever this function emits becomes its return value.
            Write-Host ('===== mode=' + $Mode + '  exit=' + $p.ExitCode + ' =====')
            Write-Host $r
        }
        @{ Exit = [int]$p.ExitCode; Text = $r }
    } finally { Remove-Item -LiteralPath $out, ($out + '.err') -Force -ErrorAction SilentlyContinue }
}

$bad = @()
function Require-Red([hashtable]$Run, [string]$Mode, [string[]]$MustName) {
    if ($null -eq $Run) { $script:bad += "$Mode tree never built"; return }
    if ($Run.Exit -eq 0) { $script:bad += "$Mode tree passed the smoke - the gate cannot see the defect it is supposed to catch" }
    foreach ($m in $MustName) {
        if ($Run.Text -notlike ('*' + $m + '*')) { $script:bad += "$Mode tree never failed with '$m'" }
    }
}
function Require-Green([hashtable]$Run, [string]$What) {
    if ($null -eq $Run) { $script:bad += "$What never built"; return }
    if ($Run.Exit -ne 0) {
        $script:bad += "$What was red with nothing injected - the reds above would prove nothing"
        foreach ($l in ($Run.Text -split "`n")) { if ($l -like '*FAIL*' -or $l -like '*Exception*') { $script:bad += ('        ' + $l.Trim()) } }
    }
}

$bad += @(if (-not (Test-Path -LiteralPath $build)) { 'packaging/build.ps1 is gone - there is nothing to self-test' })

$runs = @{}
try {
    if ($bad.Count) { throw ($bad -join '; ') }
    foreach ($mode in @('override', 'crash', 'litter', 'clean')) {
        $runs[$mode] = Run-Build (New-Tree $mode) $mode
    }
} catch {
    Write-Output ('  note ' + $_.Exception.Message)
    Write-Output 'PROBE FAILED: setup'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($bad.Count) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }

Require-Red $runs['override'] 'override' @("the artifact's dataRoot is", 'did not run')
Require-Red $runs['crash'] 'crash' @('status -Json exited', 'did not run')
Require-Red $runs['litter'] 'litter' @('wrote into its own program directory', 'did not run')
Require-Green $runs['clean'] 'the unsabotaged tree'

if ($bad.Count) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: each of the three broken artifacts turns the smoke red on its own assertion, and the intact one stays green'
exit 0
