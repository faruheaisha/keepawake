<#
.SYNOPSIS
    Keep this Windows machine awake (no sleep, no display-off, no idle lock)
    while AI / vibe-coding sessions run.

.DESCRIPTION
    Dual-engine design:

    Engine 1 - Power request (borrowed from Microsoft PowerToys "Awake"):
        A background thread repeatedly calls Win32 SetThreadExecutionState
        (ES_CONTINUOUS | ES_SYSTEM_REQUIRED [| ES_DISPLAY_REQUIRED]). This defeats
        system sleep and display power-off without touching the power plan.

    Engine 2 - Anti-lock heartbeat (technique made popular by Zhorn's Caffeine):
        Every AntiLockIntervalSec seconds it emits a harmless synthetic input -
        a single F15 keypress (a key most keyboards/apps ignore) or a 1px
        mouse micro-move that is immediately reverted. This resets the user-idle
        timer, which is what idle-based screen savers and auto-lock policies key
        off of.

    When the process exits or is killed, Windows drops all requests automatically
    and your normal power/lock behaviour resumes. Nothing persistent is modified.
    Manual locking (Win+L) can never be blocked - by design and for good reason.

.PARAMETER Minutes
    Minutes to stay awake. 0 (default) = until stopped.

.PARAMETER AllowDisplayOff
    Let the screen turn off while the system stays awake (default: keep display on).

.PARAMETER NoAntiLock
    Disable the anti-lock input heartbeat (power-request engine only).

.PARAMETER AntiLockIntervalSec
    Heartbeat interval in seconds. Must be shorter than the machine's idle-lock /
    screensaver timeout to be effective. Default 240s.

.PARAMETER AntiLockMethod
    'key' (F15 pulse, default) or 'mouse' (1px jiggle out-and-back).

.PARAMETER IntervalSeconds
    How often the power request is re-asserted. Default 60s.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File keep-awake.ps1
#>
param(
    [double]$Minutes = 0,
    [switch]$AllowDisplayOff,
    [switch]$NoAntiLock,
    [int]$AntiLockIntervalSec = 240,
    [ValidateSet('key', 'mouse')]
    [string]$AntiLockMethod = 'key',
    [int]$IntervalSeconds = 60,
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($LogPath)) {
    $LogPath = Join-Path -Path $PSScriptRoot -ChildPath 'keep-awake.log'
}

Add-Type -Namespace Native -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

Add-Type -Namespace Native -Name Input -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, System.UIntPtr dwExtraInfo);
'@

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" |
        Out-File -FilePath $LogPath -Append -Encoding utf8
}

# ------------------------------------------------------------------ engine 1
[uint32]$esContinuous      = [uint32]'0x80000000'
[uint32]$esSystemRequired  = [uint32]'0x00000001'
[uint32]$esDisplayRequired = [uint32]'0x00000002'

[uint32]$flags = [uint32]($esContinuous -bor $esSystemRequired)
$modeParts = @('system awake')
if (-not $AllowDisplayOff) {
    $flags = [uint32]($flags -bor $esDisplayRequired)
    $modeParts += 'display on'
}

$applied = [Native.Power]::SetThreadExecutionState($flags)
if ($applied -eq [uint32]0) {
    throw 'SetThreadExecutionState returned 0 - Windows refused the keep-awake request.'
}
$modeParts += 'power request OK'

# ------------------------------------------------------------------ engine 2
function Send-AntiLockPulse {
    param([string]$Method)
    if ($Method -eq 'mouse') {
        # MOUSEEVENTF_MOVE = 0x0001: nudge +1,+1 then back -1,-1 (net zero drift).
        [Native.Input]::mouse_event(0x0001, 1, 1, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 30
        [Native.Input]::mouse_event(0x0001, -1, -1, 0, [UIntPtr]::Zero)
        return 'mouse-jiggle'
    }
    else {
        # VK_F15 = 0x7E, KEYEVENTF_KEYUP = 0x02: press-and-release F15 (harmless).
        [Native.Input]::keybd_event(0x7E, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 30
        [Native.Input]::keybd_event(0x7E, 0, 2, [UIntPtr]::Zero)
        return 'F15'
    }
}

$antiLockText = 'off'
if (-not $NoAntiLock) {
    if ($AntiLockIntervalSec -lt 5) { $AntiLockIntervalSec = 5 }
    $antiLockText = "$AntiLockMethod@$($AntiLockIntervalSec)s"
}
$modeParts += "anti-lock=$antiLockText"
$mode = ($modeParts -join '; ')

$durText = 'until stopped'
if ($Minutes -gt 0) { $durText = "$Minutes minute(s)" }

Write-Log "STARTED pid=$PID mode=$mode duration=$durText"
Write-Host "[keep-awake] active: $mode | duration: $durText"

# ------------------------------------------------------------------ main loop
$deadline = $null
if ($Minutes -gt 0) { $deadline = (Get-Date).AddMinutes($Minutes) }

$pulseCount = 0
$lastPulse = (Get-Date).AddSeconds(-9999)   # fire the first heartbeat immediately

try {
    $elapsed = 0
    while ($true) {
        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
        if ($null -ne $deadline -and (Get-Date) -ge $deadline) { break }

        # Engine 1: re-assert the power request (idempotent).
        $null = [Native.Power]::SetThreadExecutionState($flags)

        # Engine 2: reset the idle timer on schedule.
        if (-not $NoAntiLock -and ((Get-Date) - $lastPulse).TotalSeconds -ge $AntiLockIntervalSec) {
            $methodUsed = Send-AntiLockPulse -Method $AntiLockMethod
            $lastPulse = Get-Date
            $pulseCount++
            if ($pulseCount -eq 1 -or ($pulseCount % 15) -eq 0) {
                Write-Log "anti-lock pulse #$pulseCount ($methodUsed) pid=$PID"
            }
        }

        if ($elapsed % 1800 -eq 0) {
            $left = ''
            if ($null -ne $deadline) {
                $minsLeft = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalMinutes)
                $left = " remaining=${minsLeft}m"
            }
            Write-Log "heartbeat pid=$PID$left pulses=$pulseCount"
        }
    }
}
finally {
    # ES_CONTINUOUS alone clears our power request (also runs on Ctrl+C).
    [void][Native.Power]::SetThreadExecutionState($esContinuous)
    Write-Log "STOPPED after $pulseCount anti-lock pulse(s) - normal behaviour restored"
    Write-Host '[keep-awake] stopped.'
}
