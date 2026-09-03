<#
.SYNOPSIS
    Install / remove unattended protection for the keep-awake tool via Windows
    Task Scheduler (current user only, no admin rights needed).

.DESCRIPTION
    Creates two scheduled tasks so the protection survives reboots and crashes -
    essential when you control this machine remotely and cannot click anything:

      KeepAwakeLogon - starts the protection every time you log on.
      KeepAwakeGuard - runs "manage.ps1 -Action start" every 10 minutes.
                       That command is a no-op when already running, so it acts
                       as a self-healing watchdog if the worker ever dies.

    Both tasks run with battery-friendly settings (start even on battery, never
    stop when switching to battery, no execution time limit).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install-guard.ps1 -Action install
    powershell ... -File install-guard.ps1 -Action status
    powershell ... -File install-guard.ps1 -Action uninstall
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskLogon  = 'KeepAwakeLogon'
$taskGuard  = 'KeepAwakeGuard'
$psExe      = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$managePath = Join-Path $dir 'manage.ps1'
$taskArg    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$managePath`" -Action start"

function Test-Installed {
    $t1 = Get-ScheduledTask -TaskName $taskLogon -ErrorAction SilentlyContinue
    $t2 = Get-ScheduledTask -TaskName $taskGuard -ErrorAction SilentlyContinue
    return ($null -ne $t1 -and $null -ne $t2)
}

function Show-Details {
    foreach ($name in @($taskLogon, $taskGuard)) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        $i = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
        $next = if ($i.NextRunTime) { $i.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        $last = if ($i.LastRunTime) { $i.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        Write-Host ("  {0}: state={1} lastRun={2} nextRun={3}" -f $name, $t.State, $last, $next)
    }
}

switch ($Action) {

    'install' {
        if (Test-Installed) {
            Write-Host 'INSTALLED (already)'
            Show-Details
            exit 0
        }

        $actionDef = New-ScheduledTaskAction -Execute $psExe -Argument $taskArg -WorkingDirectory $dir

        # Battery-friendly: run even on battery, keep running when switching to
        # battery, no time limit. Critical for laptops used unattended.
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew

        $triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

        # Repeat forever (3650 days is the PS 5.1-safe way to say "indefinitely").
        $triggerGuard = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 10) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

        Register-ScheduledTask -TaskName $taskLogon `
            -Action $actionDef -Trigger $triggerLogon -Settings $settings -Force | Out-Null
        Register-ScheduledTask -TaskName $taskGuard `
            -Action $actionDef -Trigger $triggerGuard -Settings $settings -Force | Out-Null

        Write-Host 'INSTALLED'
        Show-Details
    }

    'uninstall' {
        foreach ($name in @($taskLogon, $taskGuard)) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Host 'UNINSTALLED'
    }

    'status' {
        if (Test-Installed) {
            Write-Host 'INSTALLED'
            Show-Details
        } else {
            Write-Host 'NOT_INSTALLED'
        }
    }
}
