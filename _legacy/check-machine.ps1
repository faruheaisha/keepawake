<#
.SYNOPSIS
    Detect this machine's power / lock-screen posture and write config.json
    so the keep-awake tool adapts to THIS computer out of the box.

.DESCRIPTION
    Checks (all read-only, no admin needed):
      - OS version, PowerShell version
      - desktop vs laptop (battery present?)
      - power plan sleep / display-off / unattended-sleep timeouts,
        for BOTH plugged-in (AC) and battery (DC) - laptops often differ!
      - idle auto-lock policy (InactivityTimeoutSecs, common on corporate machines)
      - screen saver state and timeout

    It then recommends an anti-lock heartbeat interval that is safely shorter
    than the tightest idle timeout found, and writes config.json (unless it
    already exists - pass -Force to overwrite).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File check-machine.ps1
#>
param([switch]$Force)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $dir 'config.json'

$lines = @()

# --- system -----------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
$formFactor = if ($battery) { 'laptop (battery detected)' } else { 'desktop' }
$lines += "OS          : $($os.Caption)  ($($os.Version))"
$lines += "PowerShell  : $($PSVersionTable.PSVersion)"
$lines += "Machine     : $formFactor"

# --- power plan timeouts (AC = plugged in, DC = on battery) -------------------
function Get-PowerTimeout {
    param([string]$Subgroup, [string]$Setting)
    try {
        $out = powercfg /q SCHEME_CURRENT $Subgroup $Setting 2>$null
        if (-not $out) { return $null }
        # Output order is stable: first hex index = AC value, second = DC value.
        # 0xFFFFFFFF is powercfg's sentinel for "never / not set" -> normalize to 0.
        $hex = [regex]::Matches(($out -join "`n"), '0x([0-9A-Fa-f]{8})')
        if ($hex.Count -ge 1) {
            $acVal = [Convert]::ToInt64($hex[0].Groups[1].Value, 16)
            if ($acVal -ge 4294967295) { $acVal = 0 }
            $dcVal = $null
            if ($hex.Count -ge 2) {
                $dcVal = [Convert]::ToInt64($hex[1].Groups[1].Value, 16)
                if ($dcVal -ge 4294967295) { $dcVal = 0 }
            }
            return @{ AcSec = $acVal; DcSec = $dcVal }
        }
    } catch {}
    return $null
}

function Format-Timeout($t) {
    if (-not $t) { return 'unknown' }
    function Fmt($sec) {
        if ($null -eq $sec) { '?' }
        elseif ($sec -eq 0) { 'never' }
        else { "$([int]($sec / 60))m" }
    }
    return "AC $(Fmt $t.AcSec) / DC $(Fmt $t.DcSec)"
}

$sleep    = Get-PowerTimeout -Subgroup 'SUB_SLEEP' -Setting 'STANDBYIDLE'
$video    = Get-PowerTimeout -Subgroup 'SUB_VIDEO' -Setting 'VIDEOIDLE'
$unatt    = Get-PowerTimeout -Subgroup 'SUB_SLEEP' -Setting 'UNATTENDSLEEP'

$lines += "Sleep after : $(Format-Timeout $sleep)"
$lines += "Display off : $(Format-Timeout $video)"
if ($unatt) { $lines += "Unattended* : $(Format-Timeout $unatt)   (*after a wake with no user present)" }

# --- lock policy ---------------------------------------------------------------
$inactivity = $null
try {
    $inactivity = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name InactivityTimeoutSecs -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty InactivityTimeoutSecs
} catch {}
$lockText = if ($inactivity) { "after $([int]($inactivity / 60)) min (machine-inactivity policy)" } else { 'no idle-lock policy found' }
$lines += "Auto-lock   : $lockText"

# --- screen saver ---------------------------------------------------------------
$ssActive = $null; $ssTimeOut = $null; $ssExe = $null
try {
    $desk = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
    if ($desk) {
        if ($desk.ScreenSaveActive)   { $ssActive  = "$($desk.ScreenSaveActive)" }
        if ($desk.ScreenSaveTimeOut)  { $ssTimeOut = [int]$desk.ScreenSaveTimeOut }
        if ($desk.'SCRNSAVE.EXE')     { $ssExe     = "$($desk.'SCRNSAVE.EXE')" }
    }
} catch {}
# ScreenSaveActive=1 without a .scr program still means "no screen saver runs".
$ssText = if ($ssActive -eq '1' -and $ssExe) {
    "enabled ($([IO.Path]::GetFileName($ssExe))), timeout $(if ($ssTimeOut) { "$([int]($ssTimeOut / 60)) min" } else { 'unknown' })"
} else {
    'none'
}
$lines += "Screen saver: $ssText"

# --- recommendation ----------------------------------------------------------------
$candidates = @()
foreach ($sec in @(
        $sleep.AcSec, $sleep.DcSec,
        $video.AcSec, $video.DcSec,
        $unatt.AcSec, $unatt.DcSec,
        $ssTimeOut, $inactivity)) {
    if ($sec -and $sec -gt 0) { $candidates += [int]$sec }
}
$tightest = if ($candidates.Count) { ($candidates | Measure-Object -Minimum).Minimum } else { 0 }

$recommendedPulse = 240
if ($tightest -gt 0) {
    $recommendedPulse = [Math]::Max(30, [int][Math]::Floor($tightest / 2))
    if ($recommendedPulse -gt 240) { $recommendedPulse = 240 }
}
$lines += "Recommend   : anti-lock heartbeat every $recommendedPulse s (tightest idle timeout: $(if ($tightest) { "$tightest s" } else { 'none found -> default 240 s' }))"

$lines | ForEach-Object { Write-Host $_ }

# --- write machine-adapted config -----------------------------------------------------
$config = [ordered]@{
    keepDisplayOn       = $true
    antiLock            = $true
    antiLockMethod      = 'key'
    antiLockIntervalSec = $recommendedPulse
    generatedFrom       = 'check-machine.ps1'
    machine             = @{
        os               = "$($os.Caption) $($os.Version)"
        laptop           = $battery
        sleepAfterAcSec  = if ($sleep) { $sleep.AcSec } else { $null }
        sleepAfterDcSec  = if ($sleep -and $sleep.DcSec) { $sleep.DcSec } else { 0 }
        displayOffAcSec  = if ($video) { $video.AcSec } else { $null }
        displayOffDcSec  = if ($video -and $video.DcSec) { $video.DcSec } else { 0 }
        unattendedSec    = if ($unatt) { $unatt.AcSec } else { 0 }
        lockAfterSec     = if ($inactivity) { [int]$inactivity } else { 0 }
    }
}

if ((Test-Path $cfgPath) -and -not $Force) {
    Write-Host ''
    Write-Host "[config] $cfgPath already exists - keeping it. Use -Force to regenerate."
}
else {
    $json = $config | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ''
    Write-Host "[config] written: $cfgPath"
}
