<#
.SYNOPSIS
    Make "close lid" do nothing instead of sleeping (for unattended / remote use).

.DESCRIPTION
    This machine is a Modern Standby (S0) laptop that HIDES the classic
    "Lid close action" setting. Closing the lid therefore always puts the
    machine into standby - which kills every remote session and all running
    tasks, no matter what the "never sleep" plan says.

    apply    1. unhides the LIDACTION power setting
             2. backs up the current AC/DC values to lid-backup.json
             3. sets lid close = "Do nothing" for both AC and DC
             4. re-applies the active scheme and verifies

    restore  puts the original values back and re-hides nothing.

    Changing the lid action requires elevation. If you run this without admin
    rights it relaunches itself with a UAC prompt.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File fix-lid.ps1 -Action status
    powershell -NoProfile -ExecutionPolicy Bypass -File fix-lid.ps1 -Action apply
    powershell -NoProfile -ExecutionPolicy Bypass -File fix-lid.ps1 -Action restore
#>
param(
    [ValidateSet('status', 'apply', 'restore')]
    [string]$Action = 'status',
    [switch]$Pause
)

$SubGuid   = '4f971e89-eebd-4455-a8de-9e59040e7347'   # SUB_BUTTONS
$LidGuid   = '5ca83367-6e45-459f-a27b-476b1d01c936'   # LIDACTION
$backupFile = Join-Path $PSScriptRoot 'lid-backup.json'

$names = @{ 0 = 'Do nothing'; 1 = 'Sleep'; 2 = 'Hibernate'; 3 = 'Shut down' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LidRaw {
    $out = powercfg /q SCHEME_CURRENT $SubGuid $LidGuid 2>$null
    $hex = [regex]::Matches(($out -join "`n"), '0x([0-9A-Fa-f]{8})')
    if ($hex.Count -eq 0) { return $null }
    @{
        Ac = [Convert]::ToInt64($hex[0].Groups[1].Value, 16)
        Dc = if ($hex.Count -ge 2) { [Convert]::ToInt64($hex[1].Groups[1].Value, 16) } else { $null }
    }
}

function Show-Status {
    $lid = Get-LidRaw
    if ($null -eq $lid) {
        Write-Host 'LIDACTION: hidden / not present in this scheme (typical for Modern Standby OEM images).'
    } else {
        $acName = if ($names.ContainsKey([int]$lid.Ac)) { $names[[int]$lid.Ac] } else { "unknown($($lid.Ac))" }
        $dcName = if ($null -ne $lid.Dc -and $names.ContainsKey([int]$lid.Dc)) { $names[[int]$lid.Dc] } else { '?' }
        Write-Host "LIDACTION: AC=$($lid.Ac) ($acName), DC=$($lid.Dc) ($dcName)"
    }
    Write-Host ("Backup file : " + $(if (Test-Path $backupFile) { 'present (' + $backupFile + ')' } else { 'none' }))
}

switch ($Action) {

    'status' {
        Write-Host '=== Lid close action status ==='
        Show-Status
    }

    'apply' {
        if (-not (Test-Admin)) {
            Write-Host 'Elevation required - relaunching with UAC prompt...'
            Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Action', 'apply', '-Pause')
            exit 0
        }

        # 1. Unhide the setting so it is visible/queryable from now on.
        powercfg /attributes $SubGuid $LidGuid -ATTRIB_HIDE 2>$null

        # 2. Back up whatever is there before touching it (only ever the first time).
        if (-not (Test-Path $backupFile)) {
            $lid = Get-LidRaw
            $backup = [ordered]@{
                ac = if ($lid) { $lid.Ac } else { $null }
                dc = if ($lid -and $null -ne $lid.Dc) { $lid.Dc } else { $null }
                capturedAt = (Get-Date).ToString('s')
            }
            [IO.File]::WriteAllText($backupFile, ($backup | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "Backup written: $backupFile"
        }

        # 3. Lid close = Do nothing (0) for plugged-in and battery.
        powercfg /setacvalueindex SCHEME_CURRENT $SubGuid $LidGuid 0
        powercfg /setdcvalueindex SCHEME_CURRENT $SubGuid $LidGuid 0
        powercfg /setactive SCHEME_CURRENT

        # 4. Verify.
        $now = Get-LidRaw
        Write-Host '=== After apply ==='
        Show-Status
        if ($null -eq $now -or ($now.Ac -ne 0)) {
            Write-Warning 'LIDACTION could not be set to 0 - this platform may not honour the setting.'
            Write-Warning 'Fallback: keep the lid open; the keep-awake engine already prevents idle standby.'
        } else {
            Write-Host 'OK: closing the lid will no longer sleep the machine.'
        }
    }

    'restore' {
        if (-not (Test-Admin)) {
            Write-Host 'Elevation required - relaunching with UAC prompt...'
            Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Action', 'restore', '-Pause')
            exit 0
        }
        if (-not (Test-Path $backupFile)) {
            Write-Warning "No backup file found ($backupFile) - nothing to restore."
            if ($Pause) { [void](Read-Host 'Press Enter to close'); }
            exit 1
        }
        $b = Get-Content $backupFile -Raw | ConvertFrom-Json
        if ($null -ne $b.ac) { powercfg /setacvalueindex SCHEME_CURRENT $SubGuid $LidGuid $b.ac }
        if ($null -ne $b.dc) { powercfg /setdcvalueindex SCHEME_CURRENT $SubGuid $LidGuid $b.dc }
        powercfg /setactive SCHEME_CURRENT
        Remove-Item $backupFile -ErrorAction SilentlyContinue
        Write-Host 'Original lid action restored.'
        Show-Status
    }
}

if ($Pause) { [void](Read-Host 'Press Enter to close') }
