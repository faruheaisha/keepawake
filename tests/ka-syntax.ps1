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
    # Walk source recursively but do not inspect generated SDKs, staging trees or
    # copied test fixtures. They are not source and can be arbitrarily large.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($root)
    $found = New-Object 'System.Collections.Generic.List[string]'
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File)) { $found.Add($file.FullName) }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory)) {
            if ($dir -eq $root -and $child.Name -in @('_tmp','dist','.git')) { continue }
            if ($dir -eq (Join-Path $root 'mcp-server') -and $child.Name -in @('bin','obj')) { continue }
            $pending.Push($child.FullName)
        }
    }
    $Files = @($found | Sort-Object -Unique)
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
