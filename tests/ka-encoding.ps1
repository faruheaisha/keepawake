<#
    Byte shape of every shipped text file, family by family.

    WHY THIS IS NOT JUST THE .ps1 RULE ANY MORE (measured 2026-09-26): this gate used to scan
    `*.ps1` in three directories and nothing else, while `.gitattributes` makes two further claims
    about files that ship - ".bat 只有 CRLF 才能可靠执行, LF 版本的 cmd 会在某些行上抽风" and
    "给 .iss 一定吃得下的 CRLF". Nobody checked either one. `grep '\.bat' tests/ka-encoding.ps1` was
    empty, and `git ls-files --eol` answered the claim on the spot:

        i/lf  w/crlf attr/text eol=crlf   ka.bat            <- worktree agrees
        i/lf  w/lf   attr/text eol=crlf   packaging/KeepAwake.iss  <- 154 bare LF, no CRLF

    `eol=crlf` only rewrites a file when git *checks it out*. A file written later by an editor or
    a script keeps whatever the writer chose, and `git status` still reads clean because the clean
    filter normalises before comparing - so the drift is invisible to the one tool everybody trusts.
    The same mechanism is why a shipped `.bat` could quietly turn into LF.

    WHY NO BOM AND NO NON-ASCII IN THE CRLF FAMILY: `cmd.exe` and ISCC decode these with the system
    ANSI codepage. This machine runs ACP 65001 and hides it; a default zh-CN install is ACP 936,
    where a BOM prints `ÿþ` on the first command line and one Chinese character in a `.bat` arrives
    as mojibake. All five `.bat` and the `.iss` are pure ASCII today (`nonAscii=0`, counted here),
    which is the only reason they are safe - so the property gets asserted instead of assumed.

    The shipped surface is read from tests/ka-release-files.ps1, the same list the zip and the
    installer stage from, so what a downloader unpacks is what this gate looked at. Anything whose
    extension falls into no family stops the build rather than shipping unchecked.

    The dashboard assets and README are reported, not asserted: no BOM is required for them, and a
    CRLF in a .md is nobody's problem.

    -Apply rewrites the files in place.
#>
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'ka-release-files.ps1')

# Windows PowerShell 5.1 decodes a BOM-less .ps1 with the ANSI codepage, so the product's own
# scripts need the BOM; .gitattributes pins them to LF so a checkout is the bytes the suite ran.
$famBomLf  = @('.ps1')
# Interpreted by cmd.exe / ISCC, which want CRLF, choke on a BOM, and decode bytes < 0x80 only.
$famCrlf   = @('.bat', '.cmd', '.iss')
# Read by a browser or a human. Shape reported, never asserted.
$famReport = @('.md', '.html', '.js', '.css', '.svg', '.txt')

function Get-KaByteFamily([string]$Name) {
    $ext = [IO.Path]::GetExtension($Name)
    if (-not $ext) { return 'report' }              # LICENSE, NOTICE: nothing parses them for code
    if ($famBomLf -contains $ext)  { return 'bom-lf' }
    if ($famCrlf -contains $ext)   { return 'crlf' }
    if ($famReport -contains $ext) { return 'report' }
    return 'unknown'
}

# packaging/build.ps1 runs on the same Windows PowerShell 5.1 as the product, so the same byte
# shape is required of it. _legacy/ keeps the shape its own files had, and _tmp/ is scratch that
# does not even exist in a fresh clone - neither is a shipped surface and neither is scanned.
$targets = @()
foreach ($d in @('', 'tests', 'packaging')) {
    $targets += @(Get-ChildItem -LiteralPath (Join-Path $root $d) -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
$targets += @(Get-KaReleaseFile | ForEach-Object { Join-Path $root ($_ -replace '/', '\') })
# The installer script is not in the zip, but ISCC compiles this exact file and .gitattributes
# makes a claim about its line endings, so it is asserted like a shipped file.
$targets += @(Get-ChildItem -LiteralPath (Join-Path $root 'packaging') -Filter '*.iss' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$missing = @()
foreach ($f in ($targets | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $f)) { $missing += $f; Write-Host ('  {0,-14} named but not in the tree' -f (Split-Path -Leaf $f)); continue }
    $bytes = [IO.File]::ReadAllBytes($f)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $cr = ([regex]::Matches($text, "`r(?!`n)")).Count
    $lf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    $nonAscii = ([regex]::Matches($text, '[^\x00-\x7F]')).Count
    $family = Get-KaByteFamily $f
    $why = @()
    switch ($family) {
        'bom-lf' {
            if (-not $hasBom) { $why += 'no BOM' }
            if ($crlf) { $why += "$crlf CRLF" }
            if ($cr) { $why += "$cr bare CR" }
        }
        'crlf' {
            if ($hasBom) { $why += 'carries a BOM' }
            if ($lf) { $why += "$lf bare LF (cmd/ISCC want CRLF every line)" }
            if ($cr) { $why += "$cr bare CR" }
            if ($nonAscii) { $why += "$nonAscii non-ASCII byte(s) - the codepage decodes them, not you" }
        }
        'unknown' { $why += ("extension '{0}' ships and no family here asserts its byte shape - add a rule or stop shipping it" -f [IO.Path]::GetExtension($f)) }
    }
    if (-not $why.Count) { continue }
    $missing += $f
    Write-Host ('  {0,-14} {1}' -f (Split-Path -Leaf $f), ($why -join ', '))
    if ($Apply -and $family -eq 'bom-lf' -and -not $hasBom) {
        [IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "  BOM added : $(Split-Path -Leaf $f)"
    }
    if ($Apply -and $family -eq 'crlf' -and ($lf -or $cr -or $hasBom)) {
        $nl = (($text -replace "`r`n", "`n") -replace "`r", "`n") -replace "`n", "`r`n"
        [IO.File]::WriteAllText($f, $nl, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  CRLF, no BOM : $(Split-Path -Leaf $f)"
    }
}
foreach ($f in @('dashboard/index.html', 'dashboard/app.js', 'dashboard/styles.css', 'dashboard/i18n.js', 'dashboard/favicon.svg', 'README.md')) {
    $p = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $b = [IO.File]::ReadAllBytes($p)
    $t = [Text.Encoding]::UTF8.GetString($b)
    Write-Host ('  info {0,-22} BOM={1} CRLF={2} cjk={3}' -f $f, ($b[0] -eq 0xEF), ([regex]::Matches($t, "`r`n")).Count, ([regex]::Matches($t, '\p{IsCJKUnifiedIdeographs}')).Count)
}
if (-not $missing.Count) { Write-Host 'every shipped text file carries the byte shape its family requires' }
if (-not $Apply -and $missing.Count) { exit 1 }
exit 0
