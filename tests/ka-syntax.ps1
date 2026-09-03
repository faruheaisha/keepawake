<#
    Parser-only check: catches the PowerShell 5.1 constructs that look fine in an
    editor but fail at load time (try/catch inside a hash literal, `-f` in command
    position, `${...}` interpolation, ...). Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests/ka-syntax.ps1 [file ...]
#>
param([string[]]$Files = @())

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Files.Count) {
    # Recursive on purpose: tests/*.ps1 is where the parser traps keep showing up, and
    # a checker that cannot see itself is not a checker.
    $Files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File |
               ForEach-Object { $_.FullName } | Sort-Object -Unique)
}

$fail = 0
foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "MISS $f"; $fail++; continue }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    $errs = @($errs)
    if ($errs.Count -gt 0) {
        $fail++
        Write-Host "FAIL $(Split-Path -Leaf $f)"
        foreach ($e in $errs | Select-Object -First 8) {
            Write-Host ("     line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        $funcs = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count
        Write-Host ("OK   {0}  ({1} lines, {2} functions)" -f (Split-Path -Leaf $f), (Get-Content -LiteralPath $f).Count, $funcs)
    }
}
Write-Host ''
if ($fail) { Write-Host "$fail file(s) failed to parse"; exit 1 }
Write-Host 'all files parse clean'
exit 0
