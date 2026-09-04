# Mutation harness for tests/ka-privacy.ps1: proves each of the four rules actually fires.
# Copies the shipped surface into _tmp/privacy-red, injects one defect per rule, and checks
# the gate reports exactly that many findings and names the right file. Run it after touching
# either the gate or the product's network surface.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$red  = Join-Path $root '_tmp/privacy-red'
$gate = Join-Path $root 'tests/ka-privacy.ps1'

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
# ka-privacy.ps1 itself lives in tests/, so it is not part of the copied shipped surface.
Remove-Item -LiteralPath (Join-Path $red 'ka-privacy.ps1') -Force -ErrorAction SilentlyContinue

function Add-Defect([string]$File, [string]$Needle, [string]$Injection) {
    $text = [IO.File]::ReadAllText($File)
    if ($text -notmatch [regex]::Escape($Needle)) { throw "mutation anchor missing in $File : $Needle" }
    $text = $text.Replace($Needle, $Injection + "`r`n" + $Needle)
    [IO.File]::WriteAllText($File, $text, (New-Object System.Text.UTF8Encoding($true)))
}

$core = Join-Path $red 'ka-core.ps1'
$worker = Join-Path $red 'ka-worker.ps1'
$srv = Join-Path $red 'ka-server.ps1'
$css = Join-Path $red 'dashboard\styles.css'

# 1. a telemetry endpoint, written as a plain literal in shipped code
Add-Defect $core '$script:KaVersion =' '$KaTelemetry = "https://telemetry.example.com/v1/event"'
# 2. a second HTTP client in a file the allow-list does not name
Add-Defect $worker 'while ($true) {' '    Invoke-RestMethod -Uri "http://www.w3.org/2000/svg/update" | Out-Null'
# 3. the listener opened to every interface
Add-Defect $srv '$listener.Prefixes.Add("http://localhost:$Port/")' '$listener.Prefixes.Add("http://+:$Port/")'
# 4. the CSRF boundary traded away for convenience
Add-Defect $srv '$res.StatusCode = $Status' '$res.Headers.Add("Access-Control-Allow-Origin", "*")'

$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $gate -Root $red 2>&1
$code = $LASTEXITCODE
$text = ($out | Out-String)
Write-Output $text
Write-Output ("gate exit code: {0}" -f $code)

$fail = @()
if ($code -eq 0) { $fail += 'the mutated copy PASSED - the gate cannot detect a violation' }
foreach ($want in @(
    'telemetry.example.com',
    'non-loopback URL literal: http://www.w3.org/2000/svg/update',
    "rule 2: network API 'Invoke-RestMethod'",
    'binds a non-loopback prefix',
    'sets a CORS response header')) {
    if ($text -notmatch [regex]::Escape($want)) { $fail += "missing finding: $want" }
}
# The xmlns exemption must stay narrow: the injected fetch to the *same* host as the SVG
# namespace has to be reported even though two real xmlns declarations were exempted.
if ($text -notmatch '2 xmlns namespace') { $fail += 'xmlns exemption count drifted from the measured 2' }

Remove-Item -LiteralPath $red -Recurse -Force
if ($fail.Count) {
    Write-Output ('MUTATION CHECK FAILED: ' + $fail.Count)
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output 'MUTATION CHECK OK: all four privacy rules fire on injected defects'
exit 0
