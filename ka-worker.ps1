<#
.SYNOPSIS
    Keep-Awake engine worker. One process, one thread, holds the power request.

.DESCRIPTION
    Two independent engines, each on its own deadline, evaluated from a 1s scheduler
    slice, so neither the heartbeat interval nor the expiry gets rounded up to the
    loop period (the previous build could only ever pulse on multiples of its 60s tick).

      engine 1  SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED
                                       [| ES_DISPLAY_REQUIRED] [| ES_AWAYMODE_REQUIRED])
                Re-asserted on a timer and again after a detected suspend/resume.
      engine 2  A SendInput heartbeat - F15 with its real E0 scan code, or a drift-free
                absolute mouse nudge - which resets the console idle timer that
                screensavers and inactivity-lock policies watch. It reports the actual
                SendInput return value instead of assuming the keypress landed, and
                counts a skip when the secure desktop owns the session.

    Design notes that are load-bearing:
      * A named mutex, not a PID file, makes single-instance atomic. The old PID file
        lost races and left workers holding a power request that no command could stop.
      * No log or state write can abort the run.
      * Stop is cooperative via stop.flag so this thread releases its own request and
        records why; Stop-KaWorker force-kills only stragglers.
      * The battery floor exists because "never turn the display off" on a laptop that
        leaves its desk means a hard power cut and lost work.

.PARAMETER KeepDisplayOn
    1 = also request ES_DISPLAY_REQUIRED (screen stays lit); 0 = system only.

.PARAMETER Minutes
    0 = until stopped.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-worker.ps1 -Minutes 120
#>
[CmdletBinding()]
param(
    [int]$KeepDisplayOn = 1,
    [int]$AntiLock = 1,
    [int]$AwayMode = 0,
    [int]$BatteryAllowDisplayOff = 1,
    [ValidateSet('key', 'mouse')]
    [string]$AntiLockMethod = 'key',
    [int]$AntiLockIntervalSec = 240,
    [int]$ReassertSec = 60,
    [int]$BatteryFloorPercent = 20,
    [double]$Minutes = 0,
    [string]$StatePath = '',
    [string]$DataDir = '',
    [int]$SliceMs = 1000
)

# Set before ka-core is dot-sourced: everything downstream - paths, the mutex name, the
# log - derives from the data root, so a worker started by a scheduled task or by another
# copy of the tool cannot end up watching somebody else's state.json.
if ($DataDir) { $env:KA_DATA = $DataDir }
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')

$ErrorActionPreference = 'Stop'
$paths = Get-KaPath
if (-not $StatePath) { $StatePath = $paths.state }

# ---------------------------------------------------------------- single instance
# The mutex name is a hash of the data root plus this user's SID, because a mutex name may
# not contain '\'. Keyed on the data root (whose state this process owns) rather than the
# install folder: two copies of the tool for one user must not both hold a power request.
$mutex = New-Object System.Threading.Mutex($false, (Get-KaMutexName 'KA-Worker'))
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
} catch {
    $owned = $true          # if named-object creation is blocked here, do not refuse to protect
}
if (-not $owned) {
    Add-KaLog "SKIP pid=$PID another ka-worker already holds the mutex for $(Get-KaDataRoot)"
    try { $mutex.Dispose() } catch { }
    exit 0
}

# ---------------------------------------------------------------- build the request
# Precomputed instead of masked with a bitwise NOT at runtime: keeps every value a
# plain Int64 so nothing can overflow on the way into JSON or a format string.
$reqSystem  = [long][Ka.Native]::ES_SYSTEM_REQUIRED
$reqDisplay = [long][Ka.Native]::ES_DISPLAY_REQUIRED
$reqAway    = [long][Ka.Native]::ES_AWAYMODE_REQUIRED

$flagsFull = $reqSystem
if ($KeepDisplayOn -eq 1) { $flagsFull = $flagsFull -bor $reqDisplay }
if ($AwayMode -eq 1)      { $flagsFull = $flagsFull -bor $reqAway }
$flagsSystemOnly = $reqSystem + $(if ($AwayMode -eq 1) { $reqAway } else { 0 })

$activeFlags = 0
$lastError = ''
$note = ''
$pulseResult = ''
$pulses = 0
$lockSkips = 0
$lastLockEpoch = 0
$ilSkips = 0
$displayDowngraded = $false
$battPct = -1
$battAc = $true

function Apply-Flags {
    param([long]$Flags, [string]$Why)
    try {
        $r = [Ka.Native]::ApplyPowerRequest([uint32]$Flags)
        if ($r -eq 0) {
            # `code:context`, not a sentence: state.json is read by the panel, the CLI and
            # the tray, and each of them renders it in its own language.
            $script:lastError = "settes-zero:$Why"
            Add-KaLog "FAIL pid=$PID $($script:lastError)"
            return $false
        }
        $script:activeFlags = [long]$Flags -bor [long][Ka.Native]::ES_CONTINUOUS
        $script:lastError = ''
        return $true
    } catch {
        # The exception text stays in the log - a stack string is not something to put in a
        # pill, and it is already on the one screen built to show it.
        $script:lastError = "settes-throw:$Why"
        Add-KaLog "FAIL pid=$PID $($script:lastError) $($_.Exception.Message)"
        return $false
    }
}

$startedEpoch = Get-KaEpoch
$expiresEpoch = if ($Minutes -gt 0) { $startedEpoch + [long]($Minutes * 60) } else { 0 }
$lastPulseEpoch = 0

if (-not (Apply-Flags -Flags $flagsFull -Why 'initial')) {
    Add-KaLog "EXIT pid=$PID reason=power-request-refused"
    try { [void]$mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
    throw "SetThreadExecutionState refused the power request (error=$lastError)"
}

# The effective mask, not the requested one: this line is the forensic record of what the
# kernel took, and it has to agree with state.json's activeFlags.
$msg = 'STARTED pid={0} flags=0x{1:X8} display={2} away={3} antiLock={4}@{5}s reassert={6}s batteryFloor={7}% duration={8}' -f `
       $PID, [long]$script:activeFlags, $(if ($KeepDisplayOn) { 'on' } else { 'off' }), $(if ($AwayMode) { 'on' } else { 'off' }), `
       $(if ($AntiLock) { $AntiLockMethod } else { 'off' }), $AntiLockIntervalSec, $ReassertSec, $BatteryFloorPercent, `
       $(if ($expiresEpoch -gt 0) { "$Minutes min" } else { 'until stopped' })
Add-KaLog $msg

# ---------------------------------------------------------------- scheduler state
$now = $startedEpoch
$nextReassert = $now + $ReassertSec
$nextPulse    = $now            # engine 2 fires on the first tick, not one period later
$nextState    = 0
$nextBattery  = 0
$nextStopChk  = 0
$nextBeatLog  = $now + 1800
$lastTick     = $now
$exitReason   = 'unknown'

function Write-State {
    $s = @{
        pid              = $PID
        startedEpoch     = [long]$startedEpoch
        expiresEpoch     = [long]$expiresEpoch
        lastTickEpoch    = [long](Get-KaEpoch)
        baseFlags        = [long]($flagsFull -bor [long][Ka.Native]::ES_CONTINUOUS)
        activeFlags      = [long]$activeFlags
        keepDisplayOn    = [bool]($KeepDisplayOn -eq 1)
        displayActive    = [bool](($activeFlags -band $reqDisplay) -ne 0)
        awayMode         = [bool]($AwayMode -eq 1)
        antiLock         = [bool]($AntiLock -eq 1)
        antiLockMethod   = [string]$AntiLockMethod
        antiLockInterval = [int]$AntiLockIntervalSec
        reassertSec      = [int]$ReassertSec
        pulses           = [int]$pulses
        lastPulseEpoch   = [long]$lastPulseEpoch
        lockSkips        = [int]$lockSkips
        lastLockEpoch    = [long]$lastLockEpoch
        ilSkips          = [int]$ilSkips
        lastPulseResult  = [string]$pulseResult
        batteryFloor     = [int]$BatteryFloorPercent
        batteryPercent   = [int]$battPct
        acOnline         = [bool]$battAc
        displayDowngrade = [bool]$displayDowngraded
        error            = [string]$lastError
        note             = [string]$note
    }
    [void](Write-KaJson $StatePath $s -Depth 4)
}
Write-State

# ---------------------------------------------------------------- main loop
try {
    while ($true) {
        Start-Sleep -Milliseconds $SliceMs
        $now = Get-KaEpoch

        if (($now - $lastTick) -gt 120) {
            # Wall clock jumped: the machine slept despite us, or was suspended/resumed.
            Add-KaLog "RESUMED pid=$PID gap=$($now - $lastTick)s reapply=after-resume"
            [void](Apply-Flags -Flags $activeFlags -Why 'after-resume')
            $nextReassert = $now + $ReassertSec
        }

        if ($expiresEpoch -gt 0 -and $now -ge $expiresEpoch) { $exitReason = 'expired'; break }

        # --- battery policy -----------------------------------------------------
        if ($now -ge $nextBattery) {
            $nextBattery = $now + 10
            try {
                $b = [Ka.Native]::PowerStatus()
                if ($b.known) {
                    # Policy lives in ka-core as a pure function so it can be tested
                    # without waiting for a laptop to discharge.
                    $act = Get-KaBatteryAction -Status $b `
                        -KeepDisplayOn ($KeepDisplayOn -eq 1) `
                        -BatteryAllowDisplayOff ($BatteryAllowDisplayOff -eq 1) `
                        -FloorPercent $BatteryFloorPercent -Downgraded $displayDowngraded
                    $battPct = [int]$act.Percent
                    $battAc  = [bool]$act.Ac
                    if ($act.Abort) {
                        # Only reached when the AC line is really gone: some firmware
                        # asserts the critical bit at 99% while plugged in.
                        $exitReason = $act.Abort
                        Add-KaLog "EXIT pid=$PID reason=$exitReason pct=$battPct ac=$battAc"
                        break
                    }
                    $onBattery = $act.OnBattery
                    $shouldDowngrade = $act.Downgrade
                    if ($shouldDowngrade -and -not $displayDowngraded) {
                        $displayDowngraded = $true
                        [void](Apply-Flags -Flags $flagsSystemOnly -Why 'battery-floor')
                        # A token, not a sentence: batteryPercent and batteryFloor are already
                        # their own state fields, and every surface renders this in its own
                        # language.
                        $note = 'battery-floor'
                        Add-KaLog "DOWNGRADE pid=$PID battery=$battPct% -> system-only"
                    } elseif ($act.Restore) {
                        $displayDowngraded = $false
                        [void](Apply-Flags -Flags $flagsFull -Why 'battery-recovered')
                        $note = ''
                        Add-KaLog "RESTORE pid=$PID display request back (battery=$battPct% ac=$battAc)"
                    }
                }
            } catch { }
        }

        # --- cooperative stop ---------------------------------------------------
        if ($now -ge $nextStopChk) {
            $nextStopChk = $now + 1
            if (Test-Path -LiteralPath $paths.stopFlag) {
                $asked = Read-KaJson $paths.stopFlag
                $exitReason = 'stopped'
                $why = if ($asked -and $asked.reason) { "$($asked.reason)" } else { 'flag' }
                Add-KaLog "STOP-REQUEST pid=$PID reason=$why"
                break
            }
        }

        # --- engine 1 -----------------------------------------------------------
        if ($now -ge $nextReassert) {
            [void](Apply-Flags -Flags $activeFlags -Why 'reassert')
            $nextReassert = $now + $ReassertSec
        }

        # --- engine 2 -----------------------------------------------------------
        if ($AntiLock -eq 1 -and $now -ge $nextPulse) {
            $nextPulse = $now + $AntiLockIntervalSec
            $sess = Get-KaSession
            if ($sess.lockScreen) {
                # Input cannot reach a session owned by the secure desktop. Claiming a
                # pulse here would be a false assurance, so count it as a skip instead.
                $lockSkips++
                $lastLockEpoch = $now
                $pulseResult = 'skipped:lock-screen'
                # A machine token, not a sentence: the dashboard renders this verbatim, so
                # prose here could never be translated.
                $note = 'lock-screen'
                if ($lockSkips -eq 1 -or ($lockSkips % 20) -eq 0) {
                    Add-KaLog ('PULSE-SKIP pid={0} reason=lock-screen secureDesktop=true pulses={1}' -f `
                               $PID, $pulses)
                }
            } else {
                # The note only means "this cycle could not reach the session", so a cycle
                # that does reach the input API starts with it cleared.
                $note = ''
                # UIPI: a focused elevated app silently swallows synthetic input from this
                # (usually medium-integrity) process. Measured, not assumed - an unknown
                # foreground never suppresses a pulse.
                $il = Get-KaForegroundIntegrity
                if ($il.blocked) {
                    $ilSkips++
                    $pulseResult = 'skipped:il-mismatch'
                    $note = 'il-mismatch'
                    if ($ilSkips -eq 1 -or ($ilSkips % 20) -eq 0) {
                        Add-KaLog ('PULSE-SKIP pid={0} reason=il-mismatch selfIl=0x{1:X4} fgIl=0x{2:X4} fgPid={3}' -f `
                                   $PID, $il.selfIl, $il.fgIl, $il.fgPid)
                    }
                } else {
                    try {
                        if ($AntiLockMethod -eq 'mouse') {
                            $ok = [Ka.Native]::NudgeMouse()
                            $pulseResult = $(if ($ok) { 'mouse-ok' } else { 'mouse-not-restored' })
                        } else {
                            $ok = [Ka.Native]::PulseF15()
                            $pulseResult = $(if ($ok) { 'f15-ok' } else { 'f15-rejected' })
                        }
                        if ($ok) {
                            $pulses++
                            $lastPulseEpoch = $now
                            if ($pulses -eq 1 -or ($pulses % 20) -eq 0) { Add-KaLog "PULSE pid=$PID #$pulses $pulseResult" }
                        } else {
                            Add-KaLog "WARN pid=$PID pulse-ignored result=$pulseResult"
                        }
                    } catch {
                        $pulseResult = 'error'
                        Add-KaLog "WARN pid=$PID pulse-error msg=$($_.Exception.Message)"
                    }
                }
            }
        }

        # --- reporting ----------------------------------------------------------
        if ($now -ge $nextState) { Write-State; $nextState = $now + 5 }
        if ($now -ge $nextBeatLog) {
            $nextBeatLog = $now + 1800
            $left = ''
            if ($expiresEpoch -gt 0) { $left = ' remaining=' + [int][math]::Ceiling(($expiresEpoch - $now) / 60) + 'm' }
            Add-KaLog (('HEARTBEAT pid={0} pulses={1} lockSkips={2} ilSkips={3} flags=0x{4:X8} battery={5}%{6}' -f `
                       $PID, $pulses, $lockSkips, $ilSkips, $activeFlags, $battPct, $left))
        }
        $lastTick = $now
    }
}
finally {
    # Runs on expiry, on a cooperative stop and on Ctrl+C. It does NOT run for
    # Stop-Process -Force, which is exactly why stopping prefers the cooperative path.
    try {
        # The clear call returns the mask that was in effect until now, so the log
        # records what was actually released instead of just that a stop happened.
        $released = [uint32]0
        try { $released = [Ka.Native]::ClearPowerRequest() } catch { }
        Add-KaLog ('STOPPED pid={0} reason={1} pulses={2} lockSkips={3} ilSkips={4} released=0x{5:X8}' -f `
                   $PID, $exitReason, $pulses, $lockSkips, $ilSkips, $released)
    } catch { }
    try { Write-State } catch { }
    try { Remove-Item -LiteralPath $paths.stopFlag -Force -ErrorAction SilentlyContinue } catch { }
    try { if ($owned) { [void]$mutex.ReleaseMutex() } } catch { }
    try { $mutex.Dispose() } catch { }
}
