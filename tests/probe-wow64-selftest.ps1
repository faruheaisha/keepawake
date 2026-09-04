$ErrorActionPreference = 'Stop'
<#
    Self-test for tests/probe-wow64.ps1. The differential passing once does not show that it
    compares anything - a mistyped key list or an allowlist that swallows every field would look
    exactly the same. So build a copy of the probe that injects a fake 32-bit-only divergence and
    require the real judgement to go red on that one field, then require the same copy with the
    injection switched off to stay green (otherwise the mutant is red for an unrelated reason and
    the first result proves nothing either).
#>
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$src = Join-Path $here 'probe-wow64.ps1'
$mut = Join-Path $root '_tmp/probe-wow64-mutant.ps1'   # the mutant never lives beside the shipped tests
$text = [IO.File]::ReadAllText($src)
$anchor = '    foreach ($k in $out.Keys) { Write-Output ($k + ''='' + $out[$k]) }'
if (-not $text.Contains($anchor)) { throw 'anchor line not found in probe-wow64.ps1 - the mutant would not be testing what we think' }
$inject = '    if ("$env:KA_PROBE_SABOTAGE" -eq ''1'' -and [int]$out[''KA_BIT''] -eq 0) { $out[''KA_STANDBY_AC''] = ''sabotaged''; $out[''KA_CAPS_S3''] = ''sabotaged'' }' + "`n" + $anchor
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mut) | Out-Null
[IO.File]::WriteAllText($mut, $text.Replace($anchor, $inject), (New-Object Text.UTF8Encoding($true)))

function Run-Mutant {
    $f = Join-Path $env:TEMP ('ka-wow-mut-' + [guid]::NewGuid().ToString('N') + '.out')
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

if ($on.Exit -eq 0) { $bad += 'the sabotaged 32-bit leg still passed - the differential compares nothing' }
foreach ($k in 'KA_STANDBY_AC', 'KA_CAPS_S3') {
    if ($on.Text -notmatch ('  FAIL ' + $k + ' differs')) { $bad += "sabotage did not surface as a '$k differs' failure" }
}
if ($off.Exit -ne 0) {
    Write-Output $off.Text
    $bad += 'the mutant is red even without the sabotage - the first result would have proved nothing'
}
foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: the WOW64 differential names a divergence when one exists and stays silent when it does not'
