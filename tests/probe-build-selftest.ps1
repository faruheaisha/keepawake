param([switch]$Show)
$ErrorActionPreference = 'Stop'
<#
    Self-test for packaging/build.ps1 -Smoke, and for the layout rule the release manifest enforces.

    The smoke is the only gate that claims "the thing a person downloads actually runs", and a
    gate seen only green has proved nothing. So build seven release trees inside a throwaway copy
    of the manifest - each one carrying exactly one defect the smoke would ship silently if it
    were blind to it - and require four of them to turn the smoke red on its own assertion:

      override - KA_DATA ignored, so the artifact writes into whoever built it. The portable
                 zip would still "work"; it would just work on somebody else's machine.
      crash    - status throws. The archive has the right entries and the product is dead.
      litter   - status writes into its own program directory. Harmless on a writable folder,
                 fatal on a Program Files install - and the exact thing the no-fallback
                 doctrine says must never happen.
      strayfile- a file at the repository root that no rule of the manifest claims. The previous
                 round replaced 17 typed names with discovery, but discovery was three globs, and
                 a glob is still an extension list wearing the word "discovered": a run.cmd or a
                 notes.txt at the root matched none of them and quietly joined the set of things
                 that are "not in the release" - the favicon.svg failure one layer up. The
                 manifest now walks the root and requires every name to be claimed, so this tree
                 has to die naming the file. Its control is the next leg.
      strayoutside - the same file one directory down, under tests/. The root walk does not read
                 there, so this one must stay green. Without it the red above is a claim about
                 ".txt", not about an unclaimed root.

    One more leg asks the opposite question, and it is the one this file could not ask while
    the manifest was a typed list:

      extrafile- a root .ps1 that no list names. A typed name fails only one way: the file simply
                 is not in the release, while every check that compares the zip against the
                 manifest stays green. So the requirement here is green smoke *and* that entry
                 present. Not hypothetical - switching the manifest to tree discovery surfaced
                 dashboard\favicon.svg, which index.html asks for by name and which the published
                 v1.0.0 zip was measured not to carry (23 entries, no favicon among them).

    The same tree with no injection must stay green, or the reds above came from nothing.
    -Show prints all seven runs verbatim.
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
    if ($Mode -eq 'extrafile') {
        # A program file at the repository root that no list mentions. By this repository's layout
        # convention (root = shipped, tests/ = not) it belongs in the zip, and the smoke has to be
        # green with it there: ka-extra.ps1 is never dot-sourced by anything.
        [IO.File]::WriteAllText((Join-Path $Dir 'ka-extra.ps1'),
            "# build-selftest: a root script no list names" + "`n", $enc)
        return
    }
    if ($Mode -eq 'strayfile' -or $Mode -eq 'strayoutside') {
        # The same file, one directory apart. Only the root one is an unclaimed shipment.
        $rel = if ($Mode -eq 'strayfile') { 'build-notes.txt' } else { 'tests\build-notes.txt' }
        [IO.File]::WriteAllText((Join-Path $Dir $rel),
            "build-selftest: a file no rule of the manifest claims`n", $enc)
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

function Get-ZipEntryName([string]$Tree) {
    # Read the artifact, not the log line: "N entries" would be true whether or not the one entry
    # this leg is about is among them.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zips = @(Get-ChildItem -LiteralPath (Join-Path $Tree 'dist') -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if ($zips.Count -ne 1) { return @() }
    $z = [IO.Compression.ZipFile]::OpenRead($zips[0].FullName)
    try { return @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
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
    foreach ($mode in @('override', 'crash', 'litter', 'extrafile', 'strayfile', 'strayoutside', 'clean')) {
        $tree = New-Tree $mode
        $runs[$mode] = Run-Build $tree $mode
        # Captured before the finally block deletes the tree: this is the artifact the leg is
        # about, and the assertions below run after cleanup.
        $runs[$mode].Entries = @(Get-ZipEntryName $tree)
    }
} catch {
    # A setup death has to be a red. Printing "PROBE FAILED" and falling through leaves the bottom
    # of this file free to print "PROBE OK" and exit 0; the null-run assertions below catch it
    # today, and that is a coincidence worth removing.
    $bad += ('setup died before the legs finished: ' + $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($bad.Count) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }

Require-Red $runs['override'] 'override' @("the artifact's dataRoot is", 'did not run')
Require-Red $runs['crash'] 'crash' @('status -Json exited', 'did not run')
Require-Red $runs['litter'] 'litter' @('wrote into its own program directory', 'did not run')
Require-Red $runs['strayfile'] 'strayfile' @('build-notes.txt', 'no rule claims it')
Require-Green $runs['clean'] 'the unsabotaged tree'
Require-Green $runs['extrafile'] 'the tree with a root script no list names'
Require-Green $runs['strayoutside'] "the tree whose unclaimed file sits under tests/, not at the root"

# One defect per leg, asserted on the failure's own words. The singular "is at the repository root"
# immediately after the name is what says "this leg blamed exactly one file" - a second unclaimed
# name would join with ", " and take the plural. Whitespace is flattened first because the message
# is one long sentence and the child may have wrapped it anywhere.
$flat = ($runs['strayfile'].Text -replace '\s+', ' ')
if ($flat -notlike '*build-notes.txt is at the repository root*') {
    $shown = $flat
    if ($shown.Length -gt 400) { $shown = $shown.Substring(0, 400) }
    $bad += ('strayfile did not blame exactly one unclaimed root file (waiting for "build-notes.txt is at the repository root"). It said: ' + $shown)
}

# The two legs must differ in exactly one thing, or "the zip carries it" is an accident of staging.
if (@($runs['clean'].Entries) -contains 'ka-extra.ps1') {
    $bad += 'the clean tree also carried ka-extra.ps1 - the two legs are not measuring different trees'
}
if (@($runs['extrafile'].Entries) -notcontains 'ka-extra.ps1') {
    $bad += ("ka-extra.ps1 is a program file at the repository root and the portable zip does not carry it ({0} entries) - the manifest is a typed list again" -f @($runs['extrafile'].Entries).Count)
}

# "Exactly one defect per leg" is checked, not assumed: the two zips must differ by that one
# entry and nothing else. Without this, a leg that gained ka-extra.ps1 while losing a dashboard
# file would still read green above - which is the same omission this leg exists to catch.
if (@($runs['clean'].Entries).Count -and @($runs['extrafile'].Entries).Count) {
    $diff = @(Compare-Object @($runs['clean'].Entries | Sort-Object) @($runs['extrafile'].Entries | Sort-Object))
    $gained = @($diff | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })
    $lost = @($diff | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })
    if (($gained -join ',') -ne 'ka-extra.ps1') { $bad += ("the extrafile zip differs from the clean one by more than the injected file: +" + ($gained -join ', ')) }
    if ($lost.Count) { $bad += ('the extrafile zip also lost something the clean tree carries: ' + ($lost -join ', ')) }
}

if ($bad.Count) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output ('  info portable zip entries: this tree = ' + @($runs['clean'].Entries).Count +
              ', with one root script no list names = ' + @($runs['extrafile'].Entries).Count)
Write-Output 'PROBE OK: each of the four broken artifacts turns the smoke red on its own assertion, a root script that no list names still ships, a root file no rule claims stops the build, and the intact trees stay green'
exit 0
