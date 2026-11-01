<# Real command wrapper, isolated data root, no display request or synthetic input. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root ('_tmp\cli-run-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work -Force)
$env:KA_DATA = Join-Path $work 'data'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$run = Join-Path $root 'ka-run.ps1'
function Wait-For([scriptblock]$Condition, [int]$Seconds = 60) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 500 } while ([DateTime]::UtcNow -lt $end)
    return $false
}
function TaskCount {
    $path = Join-Path $env:KA_DATA 'leases.json'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    try { return @((Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).leases).Count } catch { return -1 }
}
$wrapper = $null; $childPid = 0; $monitorPid = 0
try {
    & cmd.exe /d /c ('"' + (Join-Path $root 'ka.bat') + '" run -- cmd.exe /d /c exit 7')
    if ($LASTEXITCODE -ne 7 -or (TaskCount) -ne 0) { throw 'the wrapper did not preserve the exit code or release its task' }
    Write-Host '  ok   command exit code and task release'
    $missing = Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $run),'run','--','not-a-keepawake-command-123456.exe') -PassThru -Wait -NoNewWindow
    if ($missing.ExitCode -ne 127 -or (TaskCount) -ne 0) { throw 'missing command was not refused without protection' }
    Write-Host '  ok   missing command fails without starting protection'
    $child = Join-Path $work 'child-wait.ps1'
    [IO.File]::WriteAllText($child, 'Start-Sleep -Seconds 120', (New-Object Text.UTF8Encoding($true)))
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $run),'run','--',$ps,'-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $child))
    $wrapper = Start-Process -FilePath $ps -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $ready = Wait-For {
        $found = Get-CimInstance Win32_Process -Filter ('ParentProcessId = ' + $wrapper.Id) |
            Where-Object { $_.CommandLine -like '*child-wait.ps1*' } | Select-Object -First 1
        if ($found) { $script:childPid = [int]$found.ProcessId }
        $monitor = Get-CimInstance Win32_Process -Filter ('ParentProcessId = ' + $wrapper.Id) |
            Where-Object { $_.CommandLine -like '*integrations\cli\monitor.ps1*' } | Select-Object -First 1
        if ($monitor) { $script:monitorPid = [int]$monitor.ProcessId }
        return ($script:childPid -gt 0 -and $script:monitorPid -gt 0 -and (TaskCount) -eq 1)
    }
    if (-not $ready) { throw 'the long command did not start with a task lease' }
    Stop-Process -Id $wrapper.Id -Force
    if (-not (Wait-For { (TaskCount) -eq 0 })) { throw 'the monitor did not release the task after wrapper termination' }
    if (-not (Wait-For { -not (Get-Process -Id $script:monitorPid -ErrorAction SilentlyContinue) } 30)) { throw 'the task monitor did not exit' }
    Write-Host '  ok   monitor releases task after wrapper termination'
    Write-Host 'PROBE OK: command wrapper lifecycle'
} finally {
    if ($wrapper) { try { $wrapper.Refresh(); if (-not $wrapper.HasExited) { Stop-Process -Id $wrapper.Id -Force } } catch { } }
    if ($childPid -gt 0) { try { Stop-Process -Id $childPid -Force -ErrorAction Stop } catch { } }
}
