<# Bind a real, isolated child process to protection without enabling input or display. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root ('_tmp\watch-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work -Force)
$env:KA_DATA = Join-Path $work 'data'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$bridge = Join-Path $root 'ka-desktop.ps1'
$target = $null
try {
    $target = Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 180') -WindowStyle Hidden -PassThru
    $body = @{ pid = $target.Id; keepDisplayOn = $false; antiLock = $false } | ConvertTo-Json -Compress
    $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $ps
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $bridge + '" -Action watch -Request ' + $request
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $bridgeProcess = [Diagnostics.Process]::Start($info)
    try {
        $out = $bridgeProcess.StandardOutput.ReadToEndAsync(); $err = $bridgeProcess.StandardError.ReadToEndAsync()
        if (-not $bridgeProcess.WaitForExit(60000)) { $bridgeProcess.Kill(); throw 'watch bridge did not exit' }
        if (-not $out.Wait(5000) -or -not $err.Wait(5000)) { throw 'watch bridge left inherited output handles open' }
        $output = $out.Result
        if ($bridgeProcess.ExitCode -ne 0) { throw ('watch bridge failed: ' + $output + $err.Result) }
    } finally { $bridgeProcess.Dispose() }
    $result = $output | ConvertFrom-Json
    if (-not $result.ok -or -not $result.state.running -or @($result.state.leases.items).Count -ne 1) { throw 'watched process did not acquire protection' }
    $record = $result.state.leases.items[0]
    if ($record.keepDisplayOn -or $record.antiLock) { throw 'process watch enabled unrequested display or input' }
    Stop-Process -Id $target.Id -Force
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $released = $false
    do {
        Start-Sleep -Seconds 2
        try {
            $ledger = Get-Content -Raw -Encoding UTF8 (Join-Path $env:KA_DATA 'leases.json') | ConvertFrom-Json
            $intent = Get-Content -Raw -Encoding UTF8 (Join-Path $env:KA_DATA 'intent.json') | ConvertFrom-Json
            $released = @($ledger.leases).Count -eq 0 -and $intent.desired -eq 'off'
        } catch { }
    } until ($released -or [DateTime]::UtcNow -ge $deadline)
    if (-not $released) { throw 'the process exit did not release its task' }
    Write-Host 'PROBE OK: selected process instance is protected and its exit releases the task'
} finally {
    if ($target) { try { $target.Refresh(); if (-not $target.HasExited) { Stop-Process -Id $target.Id -Force } } catch { } }
    try { & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ka.ps1') stop | Out-Null } catch { }
}
