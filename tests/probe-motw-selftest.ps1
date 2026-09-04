$ErrorActionPreference = 'Stop'
<#
    Self-test for tests/probe-motw.ps1. Its C leg - "the native layer compiles out of marked
    sources" - is the one that would catch a real download problem, and it has only ever been seen
    green, which is the state a probe reaches by checking nothing too.

    Rather than pretend to break Mark-of-the-Web, this injects a block by the mechanism already
    measured to block Add-Type -TypeDefinition: ConstrainedLanguage. A copy of the probe downgrades
    the child's language mode on the marked leg only, and the real judgement has to go red naming
    that leg. Then the same copy runs with the injection off and has to stay green, otherwise the
    red above came from the copy being broken rather than from the injection.
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$src = Join-Path $here 'probe-motw.ps1'
$mut = Join-Path $root '_tmp/probe-motw-mutant.ps1'   # the mutant never lives beside the shipped tests
$text = [IO.File]::ReadAllText($src)

$anchorA = ". (Join-Path `$PSScriptRoot 'ka-core.ps1')"
$anchorB = 'function Native-Leg([string]$Dir, [switch]$Mark) {'
foreach ($a in @($anchorA, $anchorB)) {
    if (-not $text.Contains($a)) { throw "anchor not found in probe-motw.ps1 - the mutant would test nothing" }
}
$injectA = 'if ("$env:KA_PROBE_CLM" -eq ''1'') { $ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage'' }' + "`n" + $anchorA
$injectB = $anchorB + "`n" + '    $env:KA_PROBE_CLM = if ($Mark.IsPresent -and "$env:KA_PROBE_SABOTAGE" -eq ''1'') { ''1'' } else { ''0'' }'
$body = $text.Replace($anchorA, $injectA).Replace($anchorB, $injectB)
if ($body -eq $text) { throw 'no injection was applied' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mut) | Out-Null
[IO.File]::WriteAllText($mut, $body, (New-Object Text.UTF8Encoding($true)))

function Run-Mutant {
    $f = Join-Path $env:TEMP ('ka-motw-mut-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $p = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput $f `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $mut + '"')
        @{ Exit = $p.ExitCode; Text = [IO.File]::ReadAllText($f) }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

$bad = @()
$env:KA_PROBE_SABOTAGE = '1'
$on = Run-Mutant
$env:KA_PROBE_SABOTAGE = '0'
$off = Run-Mutant
Remove-Item -LiteralPath $mut -Force -ErrorAction SilentlyContinue

if ($on.Text -notmatch 'PROBE (OK|FAILED)') {
    Write-Output 'PROBE FAILED: the sabotaged mutant never reached a verdict - it is broken, not discriminating'
    ($on.Text -split "`n" | Select-Object -Last 12) | ForEach-Object { Write-Output ('  | ' + $_) }
    exit 1
}
if ($on.Exit -eq 0) { $bad += 'a marked leg whose Add-Type was blocked still passed - leg C checks nothing' }
if ($on.Text -notmatch 'did not build from MARKED sources') { $bad += 'the block was not reported on the marked leg specifically' }
if ($on.Text -notmatch 'not supported in this language mode') { $bad += 'the marked leg never showed the language-mode block - the injection did not reach ka-core compile step' }
if ($off.Exit -ne 0) {
    Write-Output $off.Text
    $bad += 'the mutant is red even with the injection switched off, so the red above proves nothing'
}
foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: probe-motw.ps1 catches a blocked native build on the marked leg and stays green when nothing is blocked'
