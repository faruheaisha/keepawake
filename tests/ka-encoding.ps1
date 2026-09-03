<#
    Ensures every script ships with a UTF-8 BOM.

    Windows PowerShell 5.1 decodes a BOM-less .ps1 using the system ANSI codepage.
    This machine runs ACP 65001 (UTF-8), which hides the problem locally, but a
    default zh-CN install is ACP 936 and would turn every Chinese message in these
    files into mojibake - and the clone-and-run promise dies with it.

    -Apply rewrites the files in place.
#>
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$targets = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
$targets += @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$missing = @()
foreach ($f in ($targets | Sort-Object -Unique)) {
    $bytes = [IO.File]::ReadAllBytes($f)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $missing += $f
        if ($Apply) {
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            [IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "BOM added : $(Split-Path -Leaf $f)"
        } else {
            Write-Host "BOM missing: $f"
        }
    }
}
if (-not $missing.Count) { Write-Host 'all scripts carry a UTF-8 BOM' }
if (-not $Apply -and $missing.Count) { exit 1 }
exit 0
