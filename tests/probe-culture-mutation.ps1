$ErrorActionPreference = 'Stop'
<#
    Mutation test for the culture fixes, because a probe that has only ever been seen green proves
    nothing. Reverts the three product expressions that tests/probe-culture.ps1 pins, runs that
    probe, and requires it to go red - statically on all three pins and dynamically on the Thai
    log stamp, where the writer really does disagree with Get-KaEvidence's invariant reader.
    Then restores, verifies the sources are byte-for-byte the originals, and re-runs clean.

    Two hazards this file used to get wrong, recorded so nobody re-introduces them:
      * Pristine text and mutated text must be separate variables. Mutating the only copy in place
        makes the finally block "restore" the mutation, which is worse than never testing.
      * `& powershell.exe ... 2>&1` inside a Stop-preferred script throws on the child's first
        stderr line, and an `exit` from the finally then swallows the diagnostic. The child writes
        its transcript to files instead.
#>
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'ka-core.ps1'
$lid  = Join-Path $root 'ka-lid.ps1'
$files = @($core, $lid)

$fixes = @(
    @{ File = $lid;  New = "capturedAt = (Get-Date -Format 'o')";
                     Old = "capturedAt = (Get-Date -Format 's')" },
    @{ File = $core; New = '::Parse("$($bp.capturedAt)", [Globalization.CultureInfo]::InvariantCulture)';
                     Old = '::Parse("$($bp.capturedAt)")' },
    @{ File = $core; New = "(Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)";
                     Old = "(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
)

$pristine = @{}   # byte arrays, the only thing the restore is allowed to write back
$working  = @{}   # strings, mutated in memory
foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f)
    $pristine[$f] = $bytes
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $working[$f] = $text
}
foreach ($x in $fixes) {
    if (-not $working[$x.File].Contains($x.New)) { throw "expected fixed text not found: $($x.New)" }
}
Write-Output 'all three fixed expressions present - the mutation is a real revert'

$probe = Join-Path $PSScriptRoot 'probe-culture.ps1'
function Invoke-CultureProbe {
    $tag = [guid]::NewGuid().ToString('N')
    $out = Join-Path $env:TEMP "ka-culture-$tag.out"
    $err = Join-Path $env:TEMP "ka-culture-$tag.err"
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Wait -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $probe + '"')
        $text = ''
        foreach ($r in @($out, $err)) {
            if (Test-Path -LiteralPath $r) { $text += [IO.File]::ReadAllText($r) }
        }
        @{ Exit = $p.ExitCode; Text = $text }
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

$mut = $null
try {
    foreach ($x in $fixes) { $working[$x.File] = $working[$x.File].Replace($x.New, $x.Old) }
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    foreach ($f in $files) {
        $body = [Text.Encoding]::UTF8.GetBytes($working[$f])
        [IO.File]::WriteAllBytes($f, $bom + $body)
    }
    Write-Output '--- mutated sources (fixes reverted), running probe-culture.ps1'
    $mut = Invoke-CultureProbe
} finally {
    foreach ($f in $files) { [IO.File]::WriteAllBytes($f, $pristine[$f]) }
    $same = $true
    foreach ($f in $files) {
        $now = [IO.File]::ReadAllBytes($f)
        if ($now.Length -ne $pristine[$f].Length) { $same = $false; continue }
        for ($i = 0; $i -lt $now.Length; $i++) {
            if ($now[$i] -ne $pristine[$f][$i]) { $same = $false; break }
        }
    }
    Write-Output ('restored byte-for-byte: ' + $same)
    if (-not $same) { Write-Output 'PRODUCT FILES ARE STILL MUTATED - fix them by hand'; exit 9 }
}

if (-not $mut) { Write-Output 'PROBE FAILED: the mutated run never happened, so nothing was measured'; exit 1 }
Write-Output ('mutated run exit=' + $mut.Exit)
$mt = $mut.Text
if ($mt -notmatch 'PROBE (OK|FAILED)') {
    Write-Output 'PROBE FAILED: the child never produced a verdict - the mutated run measured nothing'
    $mt | Write-Output
    exit 1
}

$want = @('no longer writes an offset-bearing capturedAt',
          'parses capturedAt with the ambient culture again',
          'stamps with the ambient culture again')
$wantRx = @('th-TH\s+LOG_STAMP_DELTA=\d+ seconds off')
$missing = @()
foreach ($w in $want) { if ($mt -notlike ('*' + $w + '*')) { $missing += $w } }
foreach ($w in $wantRx) { if ($mt -notmatch $w) { $missing += "regex /$w/" } }
if ($mut.Exit -eq 0) { Write-Output 'PROBE FAILED: the mutation did not make probe-culture.ps1 red'; exit 1 }
if ($missing.Count) {
    ($mt -split "`n" | Where-Object { $_ -match 'FAIL|PROBE' }) -join "`n" | Write-Output
    Write-Output ('PROBE FAILED: mutation went red but not where expected, missing: ' + ($missing -join ' / '))
    exit 1
}
Write-Output ('  red where expected: ' + (($want + $wantRx) -join ' / '))

Write-Output '--- restored sources, running probe-culture.ps1 again'
$clean = Invoke-CultureProbe
($clean.Text -split "`n" | Where-Object { $_ -match 'PROBE|FAIL' }) -join "`n" | Write-Output
if ($clean.Text -notmatch 'PROBE OK') {
    Write-Output 'PROBE FAILED: the restored sources did not produce a green verdict'
    exit 1
}
if ($clean.Exit -ne 0) { Write-Output 'PROBE FAILED: sources do not pass after the restore'; exit 1 }
Write-Output ('PROBE OK: all ' + ($want.Count + $wantRx.Count) + ' assertions are red on the reverted code and green on the shipped one')
