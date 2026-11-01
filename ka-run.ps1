<# Run one foreground command while a finite, independently owned lease is kept alive. #>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')
if (-not $script:KaLeaseAvailable) { [Console]::Error.WriteLine('Task protection is unavailable.'); exit 2 }
$parts = @($args)
if ($parts.Count -gt 0 -and $parts[0] -eq 'run') { $parts = @($parts | Select-Object -Skip 1) }
if ($parts.Count -gt 0 -and $parts[0] -eq '--') { $parts = @($parts | Select-Object -Skip 1) }
if (-not $parts.Count) { [Console]::Error.WriteLine('Usage: ka run -- <command> [arguments]'); exit 2 }
$command = Get-Command -Name ([string]$parts[0]) -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $command) { [Console]::Error.WriteLine('Command not found.'); exit 127 }
$arguments = @($parts | Select-Object -Skip 1)
$owner = 'cli_' + [guid]::NewGuid().ToString('N')
$token = New-KaLeaseToken
$reason = [IO.Path]::GetFileName($command.Source)
if (-not $reason) { $reason = 'Command' }
if ($reason.Length -gt 110) { $reason = $reason.Substring(0, 110) }
$lease = $null; $monitor = $null; $resultCode = 1
try {
    $lease = Invoke-KaLeaseAcquire -Owner $owner -Token $token -Reason $reason -Minutes 15 -RequestId ([guid]::NewGuid().ToString('N'))
    if (-not $lease.ok) { throw 'Could not acquire task protection.' }
    $monitorPath = Join-Path $PSScriptRoot 'integrations\cli\monitor.ps1'
    if (-not (Test-Path -LiteralPath $monitorPath)) { throw 'Task monitor is missing.' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $monitorPath + '"'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $identity = @{ owner = $owner; token = $token; id = $lease.id; pid = $PID; startedTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks }
    $monitor = [Ka.Native]::StartBackground($info.FileName, $info.Arguments, ($identity | ConvertTo-Json -Compress))
    $LASTEXITCODE = 0
    & $command.Source @arguments
    $resultCode = [int]$LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $resultCode = 1
} finally {
    if ($lease -and $lease.id) {
        try {
            $released = Invoke-KaLeaseChange -Owner $owner -Token $token -Id $lease.id -Action release
            if (-not $released.ok) { [Console]::Error.WriteLine('Task protection could not be released; it will expire automatically.') }
        } catch { [Console]::Error.WriteLine('Task protection could not be released; it will expire automatically.') }
    }
    if ($monitor) { $monitor.Dispose() }
}
exit $resultCode
