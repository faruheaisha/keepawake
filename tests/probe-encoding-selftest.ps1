<#
    Self-test for tests/ka-encoding.ps1.

    The byte gate now claims three things it did not claim a day ago: that every shipped .bat and
    the installer script are CRLF-only, carry no BOM and no non-ASCII byte, and that a shipped file
    whose extension belongs to no family stops the build instead of shipping unchecked. A claim
    like that is worth nothing seen only green - the previous rule set was green the whole time
    .gitattributes' own ".bat 只有 CRLF 才能可靠执行" was false on disk for packaging/KeepAwake.iss
    (154 bare LF). Writing the rule and running it is what found that.

    So build one throwaway copy of the shipped surface and break it six ways, one defect per run,
    requiring each to turn the gate red naming exactly the file this leg broke:

      ps1nobom  - a product script without its BOM. Invisible on this machine (ACP 65001),
                  mojibake on a default zh-CN install (ACP 936).
      ps1crlf   - a product script whose LF got CRLF'd. Not what the suite ran, and it churns the
                  whole diff.
      batlf     - on.bat with bare LF. The double-click entry point, on cmd's known bad shape.
      batbom    - ka.bat carrying a UTF-8 BOM. cmd prints the BOM as text on the first line.
      nonascii  - a Chinese character inside panel.bat. The console codepage decodes it, not us.
      nofamily  - dashboard\evil.py. The manifest ships anything under dashboard/ by discovery, so
                  a file in no family has to stop the build rather than ride along unexamined.

    The un-broken copy has to stay green or the six reds prove nothing. -Show prints every run.
#>
param([switch]$Show)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$work = Join-Path $root '_tmp/encoding-selftest'
$gate = Join-Path $root 'tests/ka-encoding.ps1'

. (Join-Path $root 'tests/ka-release-files.ps1')
$manifest = @(Get-KaReleaseFile)

# What a finding line looks like, in one place. The gate also prints `info` lines holding
# "CRLF=0" and "BOM=False" for the reported families - substring-matching the words 'CRLF' or
# 'BOM' without this filter would read every one of those as a second culprit.
$phrases = @('no BOM', 'CRLF', 'bare LF', 'carries a BOM', 'non-ASCII', 'no family', 'not in the tree')
function Get-Findings([string]$Text) {
    $out = @()
    foreach ($l in ($Text -split "`n")) {
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t -like 'info *' -or $t -like 'every shipped *') { continue }
        foreach ($ph in $phrases) { if ($t -like ('*' + $ph + '*')) { $out += $t; break } }
    }
    return $out
}

function New-Copy([string]$Name) {
    # A whole tree, because the gate resolves its own root from where it sits and reads the shipped
    # surface from the manifest - which derives from that tree. Copy one file and the leg is about
    # an empty directory, not about bytes.
    $dst = Join-Path $work $Name
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $dst
    $extra = @('tests/ka-release-files.ps1', 'tests/ka-encoding.ps1')
    foreach ($n in @($manifest) + $extra) {
        $src = Join-Path $root ($n -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { throw "the copy cannot be built: $n is missing" }
        $d = Join-Path $dst ($n -replace '/', '\')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $d)
        Copy-Item -LiteralPath $src -Destination $d -Force
    }
    # The installer script is asserted by the gate without being in the zip, so it has to be here
    # or the legs about it would be assertions about a missing file.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $dst 'packaging')
    Copy-Item -LiteralPath (Join-Path $root 'packaging\KeepAwake.iss') -Destination (Join-Path $dst 'packaging\KeepAwake.iss') -Force
    return $dst
}

function Get-Body([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3)
    }
    return [Text.Encoding]::UTF8.GetString($b)
}

function Set-Breakage([string]$Dir, [string]$Mode) {
    $plain = New-Object System.Text.UTF8Encoding($false)
    switch ($Mode) {
        'clean' { }
        'ps1nobom' {
            $f = Join-Path $Dir 'ka-worker.ps1'
            [IO.File]::WriteAllBytes($f, $plain.GetBytes((Get-Body $f)))
        }
        'ps1crlf' {
            $f = Join-Path $Dir 'ka-core.ps1'
            $b = [IO.File]::ReadAllBytes($f)
            $text = [Text.Encoding]::UTF8.GetString($b)
            [IO.File]::WriteAllBytes($f, $plain.GetBytes((($text -replace "`r`n", "`n") -replace "`n", "`r`n")))
        }
        'batlf' {
            $f = Join-Path $Dir 'on.bat'
            [IO.File]::WriteAllBytes($f, $plain.GetBytes(((Get-Body $f) -replace "`r`n", "`n")))
        }
        'batbom' {
            $f = Join-Path $Dir 'ka.bat'
            [IO.File]::WriteAllText($f, (Get-Body $f), (New-Object System.Text.UTF8Encoding($true)))
        }
        'nonascii' {
            $f = Join-Path $Dir 'panel.bat'
            # The extra parentheses are load-bearing: inside a method call a bare comma is an
            # argument separator, so GetBytes(x -replace a, b) arrives as GetBytes(x-a, b) -
            # "Cannot find an overload for GetBytes and the argument count: 2", which is what the
            # first version of this leg did.
            [IO.File]::WriteAllBytes($f, $plain.GetBytes(((Get-Body $f) -replace '@echo off', ('rem 防休眠 in a batch file' + "`r`n" + '@echo off'))))
        }
        'nofamily' {
            [IO.File]::WriteAllBytes((Join-Path $Dir 'dashboard\evil.py'), $plain.GetBytes("print('a family nobody asserted')`n"))
        }
        default { throw "unknown mode $Mode" }
    }
    # An injection that did not land makes the leg an assertion about nothing.
    if ($Mode -ne 'clean') {
        $target = @{ ps1nobom = 'ka-worker.ps1'; ps1crlf = 'ka-core.ps1'; batlf = 'on.bat';
                     batbom = 'ka.bat'; nonascii = 'panel.bat'; nofamily = 'dashboard\evil.py' }[$Mode]
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $target))) { throw "$Mode did not produce $target" }
    }
}

function Run-Gate([string]$Dir, [string]$Mode) {
    # A fresh filename per leg: two legs sharing one output file interleave, and the verdict you
    # read is then not the one this run produced.
    $out = Join-Path $env:TEMP ('ka-enc-selftest-' + $Mode + '-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $p = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError ($out + '.err') `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'tests\ka-encoding.ps1') + '"')
        $r = [IO.File]::ReadAllText($out) + [IO.File]::ReadAllText($out + '.err')
        if ($Show) { Write-Host ('===== mode=' + $Mode + '  exit=' + $p.ExitCode + ' ====='); Write-Host $r }
        @{ Exit = [int]$p.ExitCode; Text = $r }
    } finally { Remove-Item -LiteralPath $out, ($out + '.err') -Force -ErrorAction SilentlyContinue }
}

function Require-Red([hashtable]$Run, [string]$Mode, [string]$Leaf, [string]$MustName) {
    if ($null -eq $Run) { $script:bad += "$Mode never ran"; return }
    if ($Run.Exit -eq 0) { $script:bad += "$Mode stayed green - the gate cannot see the defect it claims to catch" }
    $hits = Get-Findings $Run.Text
    $named = @($hits | Where-Object { $_ -like ('{0} *' -f $Leaf) })
    if ($named.Count -eq 0) { $script:bad += ("{0} never named {1}; findings: [{2}]" -f $Mode, $Leaf, ($hits -join ' / ')) }
    foreach ($l in $named) { if ($l -notlike ('*' + $MustName + '*')) { $script:bad += "$Mode named $Leaf but never said '$MustName': $l" } }
    if ($Run.Text -notlike ('*' + $MustName + '*')) { $script:bad += "$Mode never failed with '$MustName'" }
    # One defect per run: a second file in the findings means this leg rode on another break.
    $others = @($hits | Where-Object { $_ -notlike ('{0} *' -f $Leaf) })
    if ($others.Count) { $script:bad += ("{0} also blamed something it did not touch: {1}" -f $Mode, ($others -join ' / ')) }
}

$bad = @()
try {
    if (-not (Test-Path -LiteralPath $gate)) { throw 'tests/ka-encoding.ps1 is gone - there is nothing to self-test' }
    foreach ($mode in @('clean', 'ps1nobom', 'ps1crlf', 'batlf', 'batbom', 'nonascii', 'nofamily')) {
        $dir = New-Copy $mode
        Set-Breakage $dir $mode
        $run = Run-Gate $dir $mode
        switch ($mode) {
            'clean' {
                if ($run.Exit -ne 0) {
                    $bad += 'the un-broken copy was red - the six reds would prove nothing'
                    foreach ($l in (Get-Findings $run.Text)) { $bad += ('        ' + $l) }
                }
            }
            'ps1nobom' { Require-Red $run $mode 'ka-worker.ps1' 'no BOM' }
            'ps1crlf'  { Require-Red $run $mode 'ka-core.ps1' 'CRLF' }
            'batlf'    { Require-Red $run $mode 'on.bat' 'bare LF' }
            'batbom'   { Require-Red $run $mode 'ka.bat' 'carries a BOM' }
            'nonascii' { Require-Red $run $mode 'panel.bat' 'non-ASCII' }
            'nofamily' { Require-Red $run $mode 'evil.py' 'no family here asserts its byte shape' }
        }
    }
} catch {
    # A setup death is a red, not a note. Printing "PROBE FAILED" and falling through to the
    # bottom of the file emits "PROBE OK" and exit 0 - which is exactly what the first version of
    # this probe did, right after its own injection threw.
    $bad += ('setup died before the legs finished: ' + $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($bad.Count) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: six broken byte shapes each turn the encoding gate red on the file this leg broke, and the intact copy stays green'
exit 0
