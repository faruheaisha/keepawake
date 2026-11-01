$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('_tmp\bridge-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data -Force | Out-Null
$exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$bridge = Join-Path $root 'integrations\mcp\bridge.ps1'
function Call-Bridge($Request) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $bridge + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['KA_DATA'] = $data
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Write(($Request | ConvertTo-Json -Compress -Depth 8)); $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(40000)) { $p.Kill(); throw 'bridge timed out' }
        $output = $outTask.GetAwaiter().GetResult(); $errors = $errTask.GetAwaiter().GetResult()
        $lines = @($output -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -ne 1) { throw 'bridge stdout was not a single JSON message' }
        return @{ code = $p.ExitCode; body = ($lines[0] | ConvertFrom-Json); out = $output; err = $errors }
    } finally { $p.Dispose() }
}
$r = Call-Bridge @{ op = 'status'; owner = 'test-client' }
if ($r.code -ne 0 -or -not $r.body.ok -or $r.body.running -or $r.out.Contains($data)) { throw 'status did not return a redacted idle response' }
$secret = 'a' * 64
foreach ($bad in @(
    @{ op = 'acquire'; owner = 'test-client'; token = $secret; reason = 'x'; minutes = 'oops'; keepDisplayOn = $false; antiLock = $false; requestId = 'x' },
    @{ op = 'acquire'; owner = 'test-client'; token = $secret; reason = 'x'; minutes = 1; keepDisplayOn = 'false'; antiLock = $false; requestId = 'x' },
    @{ op = 'run-shell'; owner = 'test-client'; token = $secret }
)) {
    $r = Call-Bridge $bad
    if ($r.code -eq 0 -or $r.body.ok -or $r.out.Contains($secret) -or $r.err.Contains($secret)) { throw 'invalid bridge request was accepted or leaked a token' }
}
if (Test-Path -LiteralPath (Join-Path $data 'leases.json')) { throw 'invalid request created a lease' }
Write-Host 'PROBE OK: redacted bridge status and rejected malformed requests without side effects'
