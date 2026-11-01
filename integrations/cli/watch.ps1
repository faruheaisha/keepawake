<# Bind one explicitly chosen process instance to a renewable task lease. #>
function Start-KaWatchedProcess {
    param([int]$ProcessId, [bool]$KeepDisplayOn = $false, [bool]$AntiLock = $false)
    if ($ProcessId -le 0) { throw 'Invalid process ID.' }
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $ticks = $process.StartTime.ToUniversalTime().Ticks
    $reason = [string]$process.ProcessName
    if (-not $reason) { $reason = 'Process' }
    if ($reason.Length -gt 100) { $reason = $reason.Substring(0, 100) }
    $owner = 'watch_' + [guid]::NewGuid().ToString('N')
    $token = New-KaLeaseToken
    $lease = $null; $monitor = $null; $ready = $false
    try {
        $lease = Invoke-KaLeaseAcquire -Owner $owner -Token $token -Reason $reason -Minutes 15 `
            -KeepDisplayOn $KeepDisplayOn -AntiLock $AntiLock -RequestId ([guid]::NewGuid().ToString('N'))
        if (-not $lease.ok) { throw 'Could not acquire task protection.' }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'monitor.ps1') + '"'
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $identity = @{ owner = $owner; token = $token; id = $lease.id; pid = $ProcessId; startedTicks = $ticks }
        $monitor = [Ka.Native]::StartBackground($info.FileName, $info.Arguments, ($identity | ConvertTo-Json -Compress))
        $ready = $true
        return @{ ok = $true; id = $lease.id; pid = $ProcessId; process = $reason }
    } finally {
        if (-not $ready -and $lease -and $lease.id) {
            try { [void](Invoke-KaLeaseChange -Owner $owner -Token $token -Id $lease.id -Action release) } catch { }
        }
        if ($monitor) {
            if (-not $ready) { try { if (-not $monitor.HasExited) { $monitor.Kill() } } catch { } }
            $monitor.Dispose()
        }
        $process.Dispose()
    }
}
