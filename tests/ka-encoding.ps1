<#
    Byte shape of every shipped .ps1: UTF-8 **with BOM**, and **LF only**.

    Windows PowerShell 5.1 decodes a BOM-less .ps1 using the system ANSI codepage.
    This machine runs ACP 65001 (UTF-8), which hides the problem locally, but a
    default zh-CN install is ACP 936 and would turn every Chinese message in these
    files into mojibake - and the clone-and-run promise dies with it.

    CRLF is the other half of the same "is this the file we tested?" question:
    .gitattributes pins *.ps1 to eol=lf, so a working copy that got CRLF'd is not
    byte-for-byte what the suite ran against, and it churns the entire diff.

    The dashboard assets and README are reported, not asserted: no BOM is required
    for them, and a CRLF in a .md is nobody's problem.

    -Apply rewrites the files in place.
#>
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$targets = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
# packaging/build.ps1 runs on the same Windows PowerShell 5.1 as the product, so the same byte
# shape is required of it. _legacy/ keeps the shape its own files had, and _tmp/ is scratch that
# does not even exist in a fresh clone - neither is a shipped surface and neither is scanned.
foreach ($d in @('tests', 'packaging')) {
    $targets += @(Get-ChildItem -LiteralPath (Join-Path $root $d) -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

$missing = @()
foreach ($f in ($targets | Sort-Object -Unique)) {
    $bytes = [IO.File]::ReadAllBytes($f)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $cr = ([regex]::Matches($text, "`r(?!`n)")).Count
    $why = @()
    if (-not $hasBom) { $why += 'no BOM' }
    if ($crlf) { $why += "$crlf CRLF" }
    if ($cr) { $why += "$cr bare CR" }
    if (-not $why.Count) { continue }
    $missing += $f
    Write-Host ('  {0,-14} {1}' -f (Split-Path -Leaf $f), ($why -join ', '))
    if ($Apply -and -not $hasBom) {
        [IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "  BOM added : $(Split-Path -Leaf $f)"
    }
}
foreach ($f in @('dashboard/index.html', 'dashboard/app.js', 'dashboard/styles.css', 'dashboard/i18n.js', 'README.md')) {
    $p = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $b = [IO.File]::ReadAllBytes($p)
    $t = [Text.Encoding]::UTF8.GetString($b)
    Write-Host ('  info {0,-22} BOM={1} CRLF={2} cjk={3}' -f $f, ($b[0] -eq 0xEF), ([regex]::Matches($t, "`r`n")).Count, ([regex]::Matches($t, '\p{IsCJKUnifiedIdeographs}')).Count)
}
if (-not $missing.Count) { Write-Host 'all scripts carry a UTF-8 BOM and are LF-only' }
if (-not $Apply -and $missing.Count) { exit 1 }
exit 0
