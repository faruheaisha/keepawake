<#
    The PowerShell inside .github/workflows/*.yml is source code that has never been executed
    anywhere except a runner. So parse it here.

    This catches: a syntax error in a run: block (which costs a whole CI round trip to find out
    about), and a tab used for YAML indentation - YAML forbids tabs there, and Actions rejects
    the *entire* workflow file for one, which looks like "my CI never ran" rather than a step
    failure.

    It cannot catch what needs the Actions evaluator itself: the `on:` shape, needs: graphs, the
    job names inside reusable-workflow calls, secrets. Those stay the runner's business, and the
    workflow that exercises them is release.yml's own first step.
#>
param([string[]]$Files = @())

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Files.Count) {
    $dir = Join-Path $root '.github/workflows'
    if (-not (Test-Path -LiteralPath $dir)) { Write-Host 'no .github/workflows - there is no CI to check' -ForegroundColor Red; exit 1 }
    $Files = @(Get-ChildItem -LiteralPath $dir -Filter '*.yml' -File | ForEach-Object { $_.FullName } | Sort-Object)
}

function Get-Indent([string]$s) { $s.Length - $s.TrimStart().Length }

$fail = 0
foreach ($f in $Files) {
    $lines = [IO.File]::ReadAllLines($f)
    $name = Split-Path -Leaf $f
    $problems = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        # YAML forbids tabs as *indentation*; a tab inside a run block's script text is legal
        # PowerShell. Only the leading one is worth going red over.
        if ($lines[$i] -match '^ *\t') { $problems += ('line {0}: a tab used to indent - Actions rejects the whole file' -f ($i + 1)) }
    }

    $blocks = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $head = $lines[$i].TrimStart()
        if ($head -notmatch '^(-\s+)?run:') { continue }
        $col = Get-Indent $lines[$i]
        $start = $i + 1
        $inline = $lines[$i].Substring($lines[$i].IndexOf('run:') + 4).Trim()
        $body = @()
        if ($inline -and ($inline[0] -notin @('|', '>', '&'))) {
            # Flow style: one physical line. Only single-quoted YAML is unwrapped, because that
            # is the form these files use and '' is its escape; anything else is parsed with its
            # quotes left in, which the PowerShell parser reads as written.
            $t = $inline
            if ($t.Length -ge 2 -and $t[0] -eq "'" -and $t[$t.Length - 1] -eq "'") {
                $t = $t.Substring(1, $t.Length - 2).Replace("''", "'")
            }
            $body = @($t)
        } else {
            $j = $i + 1
            while ($j -lt $lines.Count) {
                if ($lines[$j].Trim() -eq '') { $body += ''; $j++; continue }
                if ((Get-Indent $lines[$j]) -le $col) { break }
                $body += $lines[$j]; $j++
            }
            $i = $j - 1        # the outer $i++ then lands on the first line after the block
        }
        # `defaults:` holds `run:` too, with `shell:` as its value: a nested mapping, not a
        # script. A line that is only a key and a value is not something a PowerShell step
        # starts with, so the mapping shape is recognisable without a YAML parser.
        $bodyLines = @($body | Where-Object { $_.Trim() -ne '' })
        if ($bodyLines.Count -and $bodyLines[0].Trim() -match '^[A-Za-z_][\w-]*:\s') { continue }
        $blocks++
        $text = $bodyLines -join "`n"
        if (-not $text.Trim()) { $problems += ("run block starting at line {0} is empty" -f $start); continue }
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
        foreach ($e in @($errs)) {
            $problems += ('run block at line {0}: {1}' -f $start, $e.Message)
        }
    }

    if ($problems.Count) {
        $fail++
        Write-Host "FAIL $name" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "     $p" }
    } else {
        Write-Host ("OK   {0}  ({1} line(s), {2} run block(s))" -f $name, $lines.Count, $blocks)
    }
}
Write-Host ''
if ($fail) { Write-Host "$fail workflow file(s) have problems"; exit 1 }
Write-Host 'every run: block parses as PowerShell 5.1 and no YAML indentation tabs were found'
exit 0
