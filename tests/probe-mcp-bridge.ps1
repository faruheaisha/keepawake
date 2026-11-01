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
    # Framework has no ProcessStartInfo.StandardInputEncoding property. Its input
    # writer can flush its preamble as soon as the process starts, before Write.
    $consoleEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        $p = [Diagnostics.Process]::Start($psi)
    } finally { [Console]::InputEncoding = $consoleEncoding }
    try {
        # Framework Process.StandardInput inherits the console encoding. On UTF-8
        # runners its StreamWriter emits a BOM, unlike the real MCP adapter's explicit
        # UTF8Encoding(false). Write the actual transport bytes, independent of locale.
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Request | ConvertTo-Json -Compress -Depth 8))
        $inputStream = $p.StandardInput.BaseStream
        $inputStream.Write($bytes, 0, $bytes.Length); $inputStream.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(40000)) { $p.Kill(); throw 'bridge timed out' }
        $output = $outTask.GetAwaiter().GetResult(); $errors = $errTask.GetAwaiter().GetResult()
        $lines = @($output -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -ne 1) { throw 'bridge stdout was not a single JSON message' }
        return @{ code = $p.ExitCode; body = ($lines[0] | ConvertFrom-Json); out = $output; err = $errors }
    } finally { $p.Dispose() }
}
$originalInputEncoding = [Console]::InputEncoding
try {
    # Reproduce the cloud runner's UTF-8 console on every local run as well.
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
    $r = Call-Bridge @{ op = 'status'; owner = 'test-client' }
} finally { [Console]::InputEncoding = $originalInputEncoding }
$encodedPath = ($data | ConvertTo-Json -Compress).Trim('"')
if ($r.code -ne 0 -or -not $r.body.ok -or $r.body.running -or $r.out.Contains($encodedPath)) {
    # This request has no capability or user content. Report the individual verdicts;
    # a generic failure hid whether the cloud runner failed to read state or leaked it.
    Write-Host ('Idle bridge: exit={0}, ok={1}, running={2}, pathInResponse={3}' -f $r.code, $r.body.ok, $r.body.running, $r.out.Contains($encodedPath))
    Write-Host ('Idle response: ' + $r.out.Trim())
    throw 'status did not return a redacted idle response'
}
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
