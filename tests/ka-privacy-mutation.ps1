# Mutation harness for tests/ka-privacy.ps1: proves each rule actually fires.
#
# Stages a copy of the shipped surface into _tmp/privacy-red, runs the gate once on the clean copy
# (it must pass), then once per defect with only that defect present. Per-defect rather than all at
# once because a shared run cannot tell whose finding is whose - one injection riding on another's
# message reads as coverage while testing nothing. Each leg therefore asserts three things: the
# gate refused, it said the named thing, and every finding it produced points at the file this leg
# broke. Run it after touching either the gate or the product's network surface.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$red  = Join-Path $root '_tmp/privacy-red'
$gate = Join-Path $root 'tests/ka-privacy.ps1'

function Stage-Copy {
    if (Test-Path -LiteralPath $red) { Remove-Item -LiteralPath $red -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $red | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $red 'dashboard') | Out-Null
    # -Path, not -LiteralPath: -LiteralPath does not expand the wildcard and would silently
    # stage nothing.
    Copy-Item -Path (Join-Path $root '*.ps1') -Destination $red
    Copy-Item -Path (Join-Path $root '*.bat') -Destination $red
    Copy-Item -Path (Join-Path $root 'dashboard\*') -Destination (Join-Path $red 'dashboard')
    if (-not (Test-Path -LiteralPath (Join-Path $red 'ka-core.ps1'))) {
        throw "staging failed: nothing was copied into $red"
    }
}

function Add-Defect([string]$File, [string]$Needle, [string]$Injection) {
    if (-not (Test-Path -LiteralPath $File)) { throw "no such file to mutate: $File" }
    $text = [IO.File]::ReadAllText($File)
    if ($text -notmatch [regex]::Escape($Needle)) { throw "mutation anchor missing in $File : $Needle" }
    $text = $text.Replace($Needle, $Injection + "`r`n" + $Needle)
    [IO.File]::WriteAllText($File, $text, (New-Object System.Text.UTF8Encoding($true)))
}

function Run-Gate {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $gate -Root $red 2>&1
    $code = $LASTEXITCODE
    return @{ code = $code; text = (($out | Out-String) -replace "`r", '') }
}

# One line of shipped code per leg, chosen so that each one trips exactly the rule named in Want.
# The two composed-host legs are the ones the gate used to miss entirely (measured 2026-09-26):
# no scheme:// literal for rule 1 to see, and no API name on the old exact-name list to match.
$core = 'ka-core.ps1'; $worker = 'ka-worker.ps1'; $srv = 'ka-server.ps1'; $css = 'dashboard\styles.css'
$defects = @(
    @{ Name = 'telemetry endpoint as a literal'; File = $core; Anchor = '$script:KaVersion ='
       Line = '$KaTelemetry = "https://telemetry.example.com/v1/event"'
       Want = @('telemetry.example.com') }
    @{ Name = 'a second HTTP client, new file'; File = $worker; Anchor = 'while ($true) {'
       Line = '    Invoke-RestMethod -Uri "http://www.w3.org/2000/svg/update" | Out-Null'
       Want = @('non-loopback URL literal: http://www.w3.org/2000/svg/update',
                "rule 2: network API 'Invoke-RestMethod' appears in ka-worker.ps1") }
    @{ Name = 'raw TCP socket, host built in pieces'; File = $worker; Anchor = 'while ($true) {'
       Line = "    `$KaPeer = 'telemetry' + '.example' + '.com'; `$KaSock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp); `$KaSock.Connect(`$KaPeer, 80)"
       Want = @("rule 2: network API 'Sockets' appears in ka-worker.ps1",
                "rule 2: network API 'System.Net' used by ka-worker.ps1") }
    @{ Name = 'DNS lookup of a composed host'; File = $worker; Anchor = 'while ($true) {'
       Line = "    `$KaLookup = [System.Net.Dns]::GetHostAddresses('collector' + '.example.net')"
       Want = @("rule 2: network API 'Net.Dns' appears in ka-worker.ps1") }
    @{ Name = 'the listener opened to every interface'; File = $srv; Anchor = '$listener.Prefixes.Add("http://localhost:$Port/")'
       Line = '$listener.Prefixes.Add("http://+:$Port/")'
       Want = @('binds a non-loopback prefix') }
    @{ Name = 'the CSRF boundary traded away'; File = $srv; Anchor = '$res.StatusCode = $Status'
       Line = '$res.Headers.Add("Access-Control-Allow-Origin", "*")'
       Want = @('sets a CORS response header') }
    # The two legs below are what rule 4 used to miss (measured 2026-09-26, same shape as the two
    # composed-host legs above): a header name assembled out of pieces, and a header name that was
    # never imagined because the rule only ever looked for one string.
    @{ Name = 'a CORS header built out of pieces'; File = $srv; Anchor = "`$Ctx.Response.Headers.Add('Cache-Control', 'no-store')"
       Line = "`$KaCors = 'Access-' + 'Control-Allow-Origin'; `$Ctx.Response.Headers.Add(`$KaCors, '*')"
       Want = @('sets a response header whose name this gate cannot read') }
    @{ Name = 'an unknown header carrying the machine name'; File = $srv; Anchor = "`$Ctx.Response.Headers.Add('Cache-Control', 'no-store')"
       Line = "`$Ctx.Response.Headers.Add('X-Ka-Machine', `$env:COMPUTERNAME)"
       Want = @("sets response header 'X-Ka-Machine'") }
)

$fail = @()

Stage-Copy
$clean = Run-Gate
if ($clean.code -ne 0) { $fail += "the un-mutated copy failed the gate (exit $($clean.code)) - a rule is over-broad, not under-broad" }
# The xmlns exemption must stay narrow, and its count is measured, not asserted from the docs:
# favicon.svg plus one CSS data: URI.
if ($clean.text -notmatch '2 xmlns namespace') { $fail += 'xmlns exemption count drifted from the measured 2' }
Write-Output ("clean copy: exit={0} {1}" -f $clean.code, $(if ($clean.code -eq 0) { 'passed, as it must' } else { 'FAILED' }))

foreach ($d in $defects) {
    Stage-Copy
    Add-Defect (Join-Path $red $d.File) $d.Anchor $d.Line
    $r = Run-Gate
    $problems = @()
    if ($r.code -eq 0) { $problems += 'the mutated copy PASSED - the gate cannot detect this defect' }
    foreach ($want in $d.Want) {
        if ($r.text -notmatch [regex]::Escape($want)) { $problems += "missing finding: $want" }
    }
    # Cross-talk: every finding must name the file this leg broke. A finding elsewhere means the
    # leg is not measuring what its name says.
    $named = @((($r.text -split "`n") | Where-Object { $_ -match '^\s+-\s' } | ForEach-Object { $_.Trim() }))
    $stray = @($named | Where-Object { $_ -notlike ('*'+ (Split-Path -Leaf $d.File) + '*') })
    if ($stray.Count) { $problems += ($stray.Count.ToString() + ' finding(s) naming another file: ' + (($stray | Select-Object -First 2) -join ' ~ ')) }
    Write-Output ('  {0} {1,-38} exit={2} findings={3}' -f $(if ($problems.Count) { 'FAIL' } else { 'ok  ' }), $d.Name, $r.code, $named.Count)
    foreach ($p in $problems) { $fail += ($d.Name + ': ' + $p) }
    if ($problems.Count) { Write-Output ('       ' + ($problems -join '; ')) }
}

Remove-Item -LiteralPath $red -Recurse -Force
if ($fail.Count) {
    Write-Output ('MUTATION CHECK FAILED: ' + $fail.Count)
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output ('MUTATION CHECK OK: all {0} defects each red on their own rule, and the clean copy green' -f $defects.Count)
exit 0
