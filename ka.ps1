<#
.SYNOPSIS
    ka.ps1 - the command line for 防休眠 / Keep-Awake.

.DESCRIPTION
    One script, one shared library (ka-core.ps1) with the dashboard, tray and
    watchdog. Everything that can be reported is reported from a measured fact -
    a live process, a power state, or the kernel power log - never from a PID file.

.EXAMPLE
    ka.ps1 start                       protect until you stop me
    ka.ps1 start -Minutes 120          protect for 2 hours
    ka.ps1 start -ExpireAt 09:00       protect until 09:00 (rolls to tomorrow if past)
    ka.ps1 start -Method mouse -IntervalSec 90
    ka.ps1 status                      what is running right now
    ka.ps1 stop                        release the request, stay stopped
    ka.ps1 report                      what this machine is configured to do
    ka.ps1 check -Force                re-read the machine, write machine.json
    ka.ps1 config -Set antiLockIntervalSec=90
    ka.ps1 guard                       auto-recover after reboot / crash
    ka.ps1 guard -Boot                 + boot-trigger task (needs admin; honestly reports denial)
    ka.ps1 serve                       open the local dashboard
    ka.ps1 log -Tail 40
    ka.ps1 evidence                    did the machine actually stay awake?

.PARAMETER Json
    Machine-readable output for status / report / evidence / config.
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'start', 'stop', 'report', 'check', 'config', 'guard',
                 'unguard', 'log', 'evidence', 'serve', 'stop-server', 'tray', 'requests', 'lid')]
    [string]$Action = 'status',

    [double]$Minutes = 0,
    [string]$ExpireAt = '',
    [ValidateSet('', 'key', 'mouse')]
    [string]$Method = '',
    [ValidateSet('status', 'apply', 'restore')]
    [string]$LidAction = 'status',
    [int]$IntervalSec = 0,
    [switch]$NoDisplay,
    [switch]$NoAntiLock,
    [switch]$DisplayOn,
    [switch]$Away,
    [switch]$Boot,
    [switch]$Force,
    [string[]]$Set = @(),
    [int]$Tail = 20,
    [int]$Hours = 24,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')

function Get-KaDisplayWidth([string]$t) {
    # Terminals render CJK in two cells, so -12 character padding misaligns every
    # Chinese label. Count cells, not characters.
    $w = 0
    foreach ($ch in $t.ToCharArray()) {
        $c = [int]$ch
        $wide = ($c -ge 0x1100 -and ($c -le 0x115F -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
                 ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
                 ($c -ge 0xFE30 -and $c -le 0xFE6F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
                 ($c -ge 0xFFE0 -and $c -le 0xFFE6)))
        $w += $(if ($wide) { 2 } else { 1 })
    }
    return $w
}

function Write-Head($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Kv($k, $v, $color) {
    # 18: sized for the longest English label ("Plan display-off"). It was 14, which the
    # Chinese labels all fitted - an English report pushed two values flush against them.
    $pad = ' ' * [Math]::Max(1, 18 - (Get-KaDisplayWidth "$k"))
    if ($color) { Write-Host ("  $k$pad") -NoNewline; Write-Host $v -ForegroundColor $color }
    else { Write-Host "  $k$pad$v" }
}

function Show-Status {
    param($s)
    if ($Json) { return ($s | ConvertTo-Json -Depth 8) }
    Write-Head (Get-KaText 'st.head')
    if ($s.running) {
        $w = $s.worker
        $mode = @()
        if ($w.displayActive) { $mode += Get-KaText 'st.mode.display' } elseif ($w.keepDisplayOn) { $mode += Get-KaText 'st.mode.displayDown' }
        else { $mode += Get-KaText 'st.mode.systemOnly' }
        if ($w.antiLock) { $mode += (Get-KaText 'st.mode.antilock' @{ method = $w.antiLockMethod; interval = $w.antiLockInterval }) }
        Write-Kv (Get-KaText 'st.label.state') (Get-KaText 'st.running' @{
            # activeFlags carries ES_CONTINUOUS (0x80000000) - a UINT32 bitmask, so [int]
            # overflows on it and the whole status screen dies mid-render.
            pid = $w.pid; flags = [Convert]::ToString([long]$w.activeFlags, 16).PadLeft(8, '0') }) 'Green'
        Write-Kv (Get-KaText 'st.label.mode') ($mode -join ' + ')
        Write-Kv (Get-KaText 'st.label.up') (Format-KaDuration ($s.nowEpoch - [long]$w.startedEpoch))
        if ([long]$w.expiresEpoch -gt 0) {
            Write-Kv (Get-KaText 'st.label.left') (Get-KaText 'st.left.minutes' @{ n = $s.minutesLeft })
        } else { Write-Kv (Get-KaText 'st.label.left') (Get-KaText 'st.left.manual') }
        if ([long]$w.pulses -gt 0) {
            $lastPulse = $(if ([long]$w.lastPulseEpoch) { (Get-Date).AddSeconds([long]$w.lastPulseEpoch - $s.nowEpoch).ToString('HH:mm:ss') } else { '-' })
            Write-Kv (Get-KaText 'st.label.pulse') (Get-KaText 'st.pulse.sent' @{
                n = $w.pulses; last = $lastPulse; result = $w.lastPulseResult })
        } else {
            $nextIn = [Math]::Max(0, [long]$w.antiLockInterval - [long]($s.nowEpoch - [long]$w.startedEpoch))
            Write-Kv (Get-KaText 'st.label.pulse') (Get-KaText 'st.pulse.pending' @{
                next = $nextIn; interval = $w.antiLockInterval })
        }
        if ([int]$w.lockSkips -gt 0) {
            $lockLast = [long]$w.lastLockEpoch
            if ($lockLast -gt 0) {
                $lockAt = (Get-Date).AddSeconds($lockLast - $s.nowEpoch).ToString('HH:mm:ss')
                Write-Kv (Get-KaText 'st.label.lockSkip') (Get-KaText 'st.lockSkipsAt' @{
                    n = $w.lockSkips; last = $lockAt }) 'DarkYellow'
            } else {
                Write-Kv (Get-KaText 'st.label.lockSkip') (Get-KaText 'st.lockSkips' @{ n = $w.lockSkips }) 'DarkYellow'
            }
        }
        if ([int]$w.ilSkips -gt 0) { Write-Kv (Get-KaText 'st.label.ilSkip') (Get-KaText 'st.ilSkips' @{ n = $w.ilSkips }) 'DarkYellow' }
        if ($w.error) { Write-Kv (Get-KaText 'st.label.error') (Get-KaErrorText $w.error) 'Red' }
        if ($w.note) { Write-Kv (Get-KaText 'st.label.note') (Get-KaNoteText $w.note @{ pct = $w.batteryPercent; floor = $w.batteryFloor }) 'DarkYellow' }
        if ($s.evidence) {
            $ev = $s.evidence
            # A 506 also fires when the display merely blanks, so `enters` is not the answer
            # to "did it sleep" - and a real sleep is not this tool's failure unless the
            # request was held at that instant. Bypassed / unprotected / not-placeable are
            # three different answers, and printing the first for all three is how a panel
            # ends up accusing the platform of ignoring a request nobody had made.
            $slept = $(if ($ev.sessionKnown) { [int]$ev.realSleeps } else { [int]$ev.enters })
            if ([int]$ev.bypasses -gt 0) {
                # First because it is the one thing that was positively observed: on a machine
                # that is also partly blind, "we could not see everything" must not bury the
                # sleeps it did see while the request was held.
                Write-Kv (Get-KaText 'st.label.evidence') `
                    (Get-KaText 'st.evidence.bad' @{ n = [int]$ev.bypasses }) 'Red'
                $cause = @($ev.events | Where-Object {
                    [int]$_.prot -eq 1 -and $(if ($ev.sessionKnown) { [int]$_.to -eq 2 } else { $_.kind -eq 'standbyEnter' }) })
                $parts = @()
                foreach ($g in @($cause | Group-Object { if ($_.reason) { $_.reason } else { 'no-reason' } } | Sort-Object Name)) {
                    $parts += ('{0} x{1}' -f (Get-KaReasonText "$($g.Name)"), [int]$g.Count)
                }
                if ($parts.Count -gt 0) { Write-Kv (Get-KaText 'st.label.reason') ($parts -join '; ') 'Red' }
            } elseif (-not $ev.canSee) {
                Write-Kv (Get-KaText 'st.label.evidence') (Get-KaText 'st.evidence.blind') 'DarkYellow'
            } elseif ($slept -eq 0) {
                if ([int]$ev.enters -gt 0) {
                    Write-Kv (Get-KaText 'st.label.evidence') `
                        (Get-KaText 'st.evidence.screenOnly' @{ n = [int]$ev.enters }) 'Green'
                } else {
                    Write-Kv (Get-KaText 'st.label.evidence') (Get-KaText 'st.evidence.ok') 'Green'
                }
            } elseif ([int]$ev.unprotectedSleeps -eq 0) {
                Write-Kv (Get-KaText 'st.label.evidence') `
                    (Get-KaText 'st.evidence.spanUnknown' @{ n = [int]$ev.spanUnknown }) 'DarkYellow'
            } else {
                $txt = Get-KaText 'st.evidence.unprotected' @{ n = [int]$ev.unprotectedSleeps }
                if ([int]$ev.spanUnknown -gt 0) {
                    $txt += ' ' + (Get-KaText 'st.evidence.spanUnknown' @{ n = [int]$ev.spanUnknown })
                }
                Write-Kv (Get-KaText 'st.label.evidence') $txt 'DarkYellow'
            }
            if ([int]$ev.s3Enters -gt 0) {
                # Its own line, not folded into the sentences above: Kernel-Power 42 records a
                # transition into a sleep state, which is not the same testimony as a session
                # switch to sleep, and a hybrid box has to be able to show both separately.
                Write-Kv (Get-KaText 'st.label.evidence') (Get-KaText 'st.evidence.s3' @{
                    n = [int]$ev.s3Enters; bypass = [int]$ev.s3Bypasses
                    out = [int]$ev.s3Unprotected; unknown = [int]$ev.s3SpanUnknown }) `
                    $(if ([int]$ev.s3Bypasses -gt 0) { 'Red' } else { 'DarkYellow' })
            }
            Write-Kv (Get-KaText 'st.label.instrument') (Get-KaInstrumentText "$($ev.instrument)") `
                $(if ($ev.canSee) { 'Gray' } else { 'DarkYellow' })
        }
    } else {
        if (@($s.foreignWorkers).Count -gt 0) {
            Write-Kv (Get-KaText 'st.label.state') (Get-KaText 'st.foreign') 'DarkYellow'
        } elseif (@($s.orphans).Count -gt 0) {
            # state.json unreadable while our own worker holds the request: "not running, the
            # machine will sleep" would be the loudest lie on this screen.
            Write-Kv (Get-KaText 'st.label.state') `
                (Get-KaText 'st.unrecorded' @{ pid = @($s.orphans)[0].pid }) 'DarkYellow'
        } else {
            Write-Kv (Get-KaText 'st.label.state') (Get-KaText 'st.notRunning') 'Red'
        }
        if ("$($s.intent.desired)" -eq 'awake') {
            Write-Kv (Get-KaText 'st.label.intent') (Get-KaText 'st.intentAwake') 'DarkYellow'
        } elseif ($s.intent.expired) {
            Write-Kv (Get-KaText 'st.label.last') (Get-KaText 'st.expired') 'DarkGray'
        }
    }
    Write-Kv (Get-KaText 'st.label.idle') (Format-KaDuration $s.idleSec)
    $b = $s.battery
    if (-not $b.known) {
        Write-Kv (Get-KaText 'st.label.power') (Get-KaText 'st.power.unknown') 'DarkYellow'
    } elseif (-not [bool]$b.hasBattery) {
        # BatteryLifePercent is not a battery reading on a batteryless box - it reads 0 on
        # most desktops - so saying "0%" here would be inventing a charge level.
        Write-Kv (Get-KaText 'st.label.power') `
            $(if ($b.acOnline) { Get-KaText 'st.power.none' } else { Get-KaText 'st.power.noneOdd' }) `
            $(if ($b.acOnline) { $null } else { 'DarkYellow' })
    } else {
        $pct = if ([int]$b.percent -ge 0) { "$([int]$b.percent)%" } else { '?' }
        Write-Kv (Get-KaText 'st.label.power') $(if ($b.acOnline) {
            Get-KaText 'st.power.ac' @{ pct = $pct }
        } else {
            Get-KaText 'st.power.battery' @{ pct = $pct; suffix = $(if ($b.critical) {
                Get-KaText 'st.power.crit' } elseif ($b.low) { Get-KaText 'st.power.low' } else { '' }) }
        })
    }
    $sess = switch ("$($s.session.state)") {
        'Active'        { Get-KaText 'st.session.active' }
        'OtherSession'  { Get-KaText 'st.session.other' }
        'NoConsole'     { Get-KaText 'st.session.none' }
        'unreadable'    { Get-KaText 'st.session.unreadable' }
        default         { Get-KaText 'st.session.unknown' }
    }
    if ($s.session.lockScreen) { $sess += Get-KaText 'st.session.lock' }
    Write-Kv (Get-KaText 'st.label.session') $sess
    Write-Kv (Get-KaText 'st.label.guard') $(if ($s.guard.enabled) {
        Get-KaText 'st.guard.installed' @{ detail = $s.guard.detail }
    } elseif ($s.guard.installed) {
        Get-KaText 'st.guard.disabled' @{ names = (@($s.guard.disabled) -join ', ') }
    } else { Get-KaText 'st.guard.missing' }) $(if ($s.guard.enabled) { $null } elseif ($s.guard.installed) { 'DarkYellow' } else { 'Red' })
    if ($s.competitors -and @($s.competitors.suspected).Count) {
        Write-Kv (Get-KaText 'st.label.competitors') (Get-KaText 'st.competitors' @{
            list = (($s.competitors.suspected | ForEach-Object { Get-KaProse $_.label }) -join ', ') }) 'DarkYellow'
    }
    if (@($s.orphans).Count -gt 1) { Write-Kv (Get-KaText 'st.label.orphans') (Get-KaText 'st.orphans' @{ n = @($s.orphans).Count }) 'Red' }
    foreach ($a in $s.alert) { Write-Kv (Get-KaText 'st.label.alert') (Get-KaProse $a) $(if ($a.level -eq 'bad') { 'Red' } else { 'DarkYellow' }) }
    return $null
}

function Show-Report {
    <#
        Get-KaReport returns data; the words are here. It used to build these rows itself and
        hand back a `lines` array, which meant the CLI and the panel each carried a copy of the
        same facts in a different shape - and only one of them could ever switch language.
    #>
    param($r)
    if ($Json) { return ($r | ConvertTo-Json -Depth 8) }
    $p = $r.plan; $b = $r.battery; $st = $r.sleepStates; $c = $r.config
    Write-Head (Get-KaText 'report.head')

    Write-Kv (Get-KaText 'report.label.os') $r.os
    Write-Kv (Get-KaText 'report.label.ps') $r.psVersion

    $power = Get-KaText 'fmt.unknown'
    if ($b.known -and -not [bool]$b.hasBattery) {
        # No battery means BatteryLifePercent is not a reading of anything - it reports 0 on
        # most desktops - so the row says the metric does not apply instead of "0%".
        $power = Get-KaText 'report.power.none'
    } elseif ($b.known) {
        $pct = if ([int]$b.percent -ge 0) { "$([int]$b.percent)%" } else { '?' }
        $power = if ($b.acOnline) {
            Get-KaText 'report.power.ac' @{ pct = $pct }
        } else {
            Get-KaText 'report.power.battery' @{ pct = $pct; saver = $(if ($b.onBatterySaver) { Get-KaText 'report.power.saver' } else { '' }) }
        }
    }
    Write-Kv (Get-KaText 'report.label.power') $power
    $machine = Get-KaText 'report.machine.desktop'
    if (-not $b.known) { $machine = Get-KaText 'report.machine.unknown' }
    elseif ($b.hasBattery) { $machine = Get-KaText 'report.machine.laptop' }
    Write-Kv (Get-KaText 'report.label.machine') $machine
    Write-Kv (Get-KaText 'report.label.sleep') (Get-KaText 'report.sleepRow' @{ ms = $st.modernStandby; s3 = $st.s3; hib = $st.hibernate })
    Write-Kv (Get-KaText 'report.label.planSleep') (Get-KaText 'report.acdc' @{ ac = (Format-KaSeconds $p.sleepAcSec); dc = (Format-KaSeconds $p.sleepDcSec) })
    Write-Kv (Get-KaText 'report.label.planVideo') (Get-KaText 'report.acdc' @{ ac = (Format-KaSeconds $p.videoAcSec); dc = (Format-KaSeconds $p.videoDcSec) })
    Write-Kv (Get-KaText 'report.label.unattended') (Get-KaText 'report.unattended' @{ sec = (Format-KaSeconds $p.unattendedAcSec) })
    Write-Kv (Get-KaText 'report.label.lid') $(
        if ($null -eq $p.lidAc) { Get-KaText 'report.lid.hidden' }
        else { Get-KaText 'report.lid.vals' @{ ac = [int]$p.lidAc; dc = $(if ($null -eq $p.lidDc) { '?' } else { [int]$p.lidDc }) } })
    # Three answers, not one boolean: the kernel bit can confirm a lid, rule one out, or be
    # unreadable, and "unreadable" must never be printed as "no lid".
    if ($r.lid) {
        $lidHas = Get-KaText 'report.lid.nolid'
        if (-not $r.lid.lidKnown) { $lidHas = Get-KaText 'report.lid.unknown' }
        elseif ($r.lid.lidPresent) { $lidHas = Get-KaText 'report.lid.has' }
        Write-Kv (Get-KaText 'report.label.lidHas') $lidHas `
            $(if ($r.lid.lidKnown) { $null } else { 'DarkYellow' })
    }
    if ($r.lid -and $r.lid.lidKnown -and [bool]$r.lid.lidPresent) {
        $lid = $r.lid
        if (-not $lid.readable) {
            Write-Kv (Get-KaText 'report.label.lidNow') (Get-KaText 'report.lidnow.hidden')
        } else {
            $tierKey = if ($lid.acOnline) { 'report.lidnow.tier-ac' } else { 'report.lidnow.tier-dc' }
            $actIdx = if ($null -eq $(if ($lid.acOnline) { $lid.actionAc } else { $lid.actionDc })) { -1 } else { [int]$(if ($lid.acOnline) { $lid.actionAc } else { $lid.actionDc }) }
            $actName = if ($actIdx -ge 0 -and $actIdx -le 3) { Get-KaText "lid.action.$actIdx" } else { Get-KaText 'lid.unknown' @{ v = $actIdx } }
            $pct = $(if ([int]$lid.batteryPercent -ge 0) { "$([int]$lid.batteryPercent)%" } else { '?' })
            Write-Kv (Get-KaText 'report.label.lidNow') (Get-KaText 'report.lidnow.action' @{ tier = (Get-KaText $tierKey @{ pct = $pct }); action = $actName })
            $vp = @{ }
            if ($lid.lastApplyEpoch) { $vp.apply = [DateTimeOffset]::FromUnixTimeSeconds([long]$lid.lastApplyEpoch).LocalDateTime.ToString('MM-dd HH:mm') }
            if ($lid.lastClosed) { $vp.when = [DateTimeOffset]::FromUnixTimeSeconds([long]$lid.lastClosed.epoch).LocalDateTime.ToString('MM-dd HH:mm') }
            Write-Kv (Get-KaText 'report.label.lidVerify') (Get-KaText ('report.lidnow.verify-' + $lid.verified) $vp)
        }
    }
    Write-Kv (Get-KaText 'report.label.lockReq') $(
        if ($null -eq $p.consoleLockAc) { Get-KaText 'report.lock.hidden' }
        elseif ([int]$p.consoleLockAc -eq 0) { Get-KaText 'report.lock.wont' @{ v = [int]$p.consoleLockAc } }
        else { Get-KaText 'report.lock.will' @{ v = [int]$p.consoleLockAc } })
    Write-Kv (Get-KaText 'report.label.policy') $(
        if ($p.inactivityPolicySec) { Get-KaText 'report.policy.has' @{ min = [int]($p.inactivityPolicySec / 60) } }
        else { Get-KaText 'report.policy.none' })
    Write-Kv (Get-KaText 'report.label.ss') $(
        if ($p.screensaver) {
            Get-KaText 'report.ss.vals' @{ exe = $p.screensaver.exe; timeout = (Format-KaSeconds $p.screensaver.timeoutSec);
                                           secure = (Get-KaText $(if ($p.screensaver.secure) { 'report.ss.secure' } else { 'report.ss.open' })) }
        } else { Get-KaText 'report.ss.none' })
    Write-Kv (Get-KaText 'report.label.idle') (Get-KaText 'report.idle.vals' @{ dur = (Format-KaDuration $r.idleSec) })
    Write-Kv (Get-KaText 'report.label.eng1') $(
        if ($r.powerTightestSec) { Get-KaText 'report.eng1.vals' @{ dur = (Format-KaSeconds $r.powerTightestSec) } }
        else { Get-KaText 'report.eng1.never' })
    Write-Kv (Get-KaText 'report.label.reco') (Get-KaText 'report.reco.vals' @{ sec = $r.recommendedIntervalSec; why = (Get-KaProse $r.recommendedWhy) }) 'Green'
    Write-Kv (Get-KaText 'report.label.config') (Get-KaText 'report.config.vals' @{
        interval = $c.antiLockIntervalSec; display = $c.keepDisplayOn; antiLock = $c.antiLock;
        method = $c.antiLockMethod; away = $c.awayMode; floor = $c.batteryFloorPercent })

    if (-not $r.lockTightestSec) { Write-Host "    $(Get-KaText 'report.note.noLockTimer')" -ForegroundColor DarkGray }
    $risks = @($r.risk)
    if ($risks.Count) {
        Write-Host "  $(Get-KaText 'report.riskHead')"
        foreach ($x in $risks) { Write-Host "    - $(Get-KaProse $x)" -ForegroundColor DarkYellow }
    }
    return $null
}

function Show-Evidence {
    param([int]$HoursSpan)
    $since = (Get-Date).AddHours(-$HoursSpan)
    $ev = Get-KaSleepEvidence -Since $since
    if ($Json) { return ($ev | ConvertTo-Json -Depth 6) }
    Write-Head (Get-KaText 'ev.head' @{ n = $HoursSpan })
    if (-not $ev.queriesOk) { Write-Kv (Get-KaText 'ev.label.fail') "$($ev.reason)" 'Red'; return $null }
    Write-Kv (Get-KaText 'ev.label.enters') "$($ev.enters)" $(if ($ev.enters) { 'Red' } else { 'Green' })
    if ($ev.sessionKnown) {
        Write-Kv (Get-KaText 'ev.label.realSleeps') "$($ev.realSleeps)" `
            $(if ([int]$ev.bypasses) { 'Red' } elseif ([int]$ev.realSleeps) { 'DarkYellow' } else { 'Green' })
        if ([int]$ev.screenOffToSleep -gt 0) {
            $detail = ''
            if ([int]$ev.lastScreenOffToSleepSecs -gt 0) {
                $detail = Get-KaText 'ev.offToSleep.detail' @{ n = [int]$ev.lastScreenOffToSleepSecs }
            }
            Write-Kv (Get-KaText 'ev.label.offToSleep') "$($ev.screenOffToSleep)$detail" 'Red'
        }
    }
    # Outside the sessionKnown gate on purpose: without 566 these three describe `enters`
    # instead, and "the request was not held then" is the answer the user came for either way.
    if ([int]$ev.bypasses) { Write-Kv (Get-KaText 'ev.label.bypasses') "$($ev.bypasses)" 'Red' }
    if ([int]$ev.unprotectedSleeps) { Write-Kv (Get-KaText 'ev.label.unprotected') "$($ev.unprotectedSleeps)" }
    if ([int]$ev.spanUnknown) { Write-Kv (Get-KaText 'ev.label.spanUnknown') "$($ev.spanUnknown)" 'DarkYellow' }
    # The 42 instrument, kept as its own group: same three-way split, different records, and
    # on a hybrid machine the two groups count different episodes. Merging them would make
    # the identities the numbers rest on false.
    if ([int]$ev.s3Enters -or [int]$ev.s3Exits) {
        Write-Kv (Get-KaText 'ev.label.s3Enters') "$($ev.s3Enters)" `
            $(if ([int]$ev.s3Bypasses) { 'Red' } elseif ([int]$ev.s3Enters) { 'DarkYellow' } else { 'Green' })
        if ([int]$ev.s3Bypasses) { Write-Kv (Get-KaText 'ev.label.s3Bypasses') "$($ev.s3Bypasses)" 'Red' }
        if ([int]$ev.s3Unprotected) { Write-Kv (Get-KaText 'ev.label.s3Unprotected') "$($ev.s3Unprotected)" }
        if ([int]$ev.s3SpanUnknown) { Write-Kv (Get-KaText 'ev.label.s3SpanUnknown') "$($ev.s3SpanUnknown)" 'DarkYellow' }
        if ([int]$ev.s3Exits) { Write-Kv (Get-KaText 'ev.label.s3Exits') "$($ev.s3Exits)" }
    }
    if ($ev.spansKnown) {
        Write-Kv (Get-KaText 'ev.label.spans') "$(@($ev.spans).Count)"
        $coveredAt = ([DateTimeOffset]::FromUnixTimeSeconds([long]$ev.spansCoveredFrom)).LocalDateTime
        if ($since -lt $coveredAt) {
            Write-Host ('  ' + (Get-KaText 'ev.spans.partial' @{ time = (ConvertFrom-KaEpoch $ev.spansCoveredFrom) })) -ForegroundColor DarkYellow
        }
    } else {
        Write-Kv (Get-KaText 'ev.label.spans') (Get-KaText 'ev.spans.unknown') 'DarkYellow'
    }
    Write-Kv (Get-KaText 'ev.label.exits') "$($ev.exits)"
    # Which of the two instruments this machine let run at all. Without this line a zero above
    # reads as "it did not happen"; with it, a zero says "nothing this box would have written".
    Write-Kv (Get-KaText 'st.label.instrument') (Get-KaInstrumentText "$($ev.instrument)") `
        $(if ($ev.canSee) { 'Gray' } else { 'DarkYellow' })
    if (-not $ev.canSee) { Write-Host ('  ' + (Get-KaText 'st.evidence.blind')) -ForegroundColor DarkYellow }
    if ($ev.truncated) {
        Write-Host ('  ' + (Get-KaText 'ev.truncated' @{ n = [int]$ev.max })) -ForegroundColor DarkYellow
    }
    foreach ($e in $ev.events) {
        # Machine tokens, not sentences - this dump is meant to be grepped and pasted.
        $tail = @()
        if ($e.reason) { $tail += "reason=$($e.reason)" }
        if ($e.lid) { $tail += "lid=$($e.lid)" }
        if ($null -ne $e.to) { $tail += "session=$($e.from)->$($e.to)" }
        # prot only where the classifier actually used it - and -1 ("the log does not reach
        # back this far") belongs in that set as much as 0 and 1 do.
        if ($(if ($ev.sessionKnown) { [int]$e.to -eq 2 } else { $e.kind -eq 'standbyEnter' })) {
            $tail += "prot=$($e.prot)"
        }
        $join = $(if ($tail.Count) { '  ' + ($tail -join '  ') } else { '' })
        Write-Host ("    {0}  id={1,-4} {2}{3}" -f (ConvertFrom-KaEpoch $e.epoch), $e.id, $e.kind, $join)
    }
    if (-not @($ev.events).Count) { Write-Host (Get-KaText 'ev.none') }
    return $null
}

function Set-ConfigPairs {
    param([string[]]$Pairs)
    if (-not $Pairs.Count) { return $null }
    $patch = @{}
    foreach ($pair in $Pairs) {
        $kv = $pair -split '=', 2
        if ($kv.Count -ne 2) { throw (Get-KaText 'cli.pairFormat' @{ pair = $pair }) }
        $k = $kv[0].Trim(); $v = $kv[1].Trim()
        switch ($v.ToLower()) {
            'true'  { $v = $true }
            'false' { $v = $false }
            default {
                $n = 0.0
                if ([double]::TryParse($v, [ref]$n)) { $v = $n }
            }
        }
        $patch[$k] = $v
    }
    return $patch
}

switch ($Action) {

    'status' {
        $out = Show-Status (Get-KaFullState)
        if ($out) { Write-Host $out }
    }

    'start' {
        $ov = @{}
        if ($NoDisplay)   { $ov.keepDisplayOn = $false }
        if ($DisplayOn)   { $ov.keepDisplayOn = $true }
        if ($NoAntiLock)  { $ov.antiLock = $false }
        if ($Away)        { $ov.awayMode = $true }
        if ($Method)      { $ov.antiLockMethod = $Method; $ov.antiLock = $true }
        if ($IntervalSec) { $ov.antiLockIntervalSec = $IntervalSec }

        if ($Force) { [void](Stop-KaWorker -Reason 'force') }

        $mins = $Minutes
        if ($ExpireAt) {
            if ($Minutes -gt 0) {
                Write-Host (Get-KaText 'cli.bothMins') -ForegroundColor Red
                exit 2
            }
            $u = Get-KaMinutesUntil -Text $ExpireAt
            if (-not $u.Ok) {
                Write-Host (Get-KaText 'cli.expireAt' @{ text = $ExpireAt; reason = $u.Reason }) -ForegroundColor Red
                exit 2
            }
            $mins = $u.Minutes
            Write-Host (Get-KaText 'cli.willRelease' @{
                at = $u.At.ToString('yyyy-MM-dd HH:mm:ss'); mins = [math]::Ceiling($mins) }) -ForegroundColor DarkGray
        }
        $r = Start-KaProtection -Minutes $mins -Override $ov
        if (-not $r.Ok) {
            Write-Host (Get-KaText 'cli.startFail' @{ reason = $r.Reason }) -ForegroundColor Red
            Write-Host (Get-KaText 'cli.startFailHint') -ForegroundColor DarkGray
            exit 1
        }
        # $false only: an older result without the key stays the success path.
        $unrecorded = ($r.StateRecorded -eq $false)
        $s = Get-KaFullState -Quiet
        if ($Json) { Write-Host ($s | ConvertTo-Json -Depth 8) }
        else {
            if ($unrecorded) {
                # Alive, holding the mutex, and the record could not be written. Every other
                # surface reads that as "stopped", so this line is all that stands between
                # the user and a manual stop of a protection that is working.
                Write-Host (Get-KaText 'cli.startedUnrecorded' @{ pid = $r.Pid; path = (Get-KaPath).state }) -ForegroundColor Yellow
                Write-Host (Get-KaText 'cli.startedUnrecordedHint' @{ detail = $r.Detail }) -ForegroundColor DarkGray
            } elseif ($r.AlreadyRunning -and -not $r.restarted) {
                Write-Host (Get-KaText 'cli.alreadyRunning' @{ pid = $r.Pid }) -ForegroundColor Green
            } elseif ($r.restarted) {
                Write-Host (Get-KaText 'cli.restarted' @{ pid = $r.Pid }) -ForegroundColor Green
            } else {
                Write-Host (Get-KaText 'cli.started' @{ pid = $r.Pid }) -ForegroundColor Green
            }
            if ($r.intentWritten -eq $false) {
                Write-Host (Get-KaText 'cli.intentUnwritable' @{ path = (Get-KaPath).intent }) -ForegroundColor Yellow
            }
            $out = Show-Status $s
            if ($out) { Write-Host $out }
        }
        if ($unrecorded) { exit 3 }
    }

    'stop' {
        $r = Stop-KaProtection -Reason 'cli'
        if ($r.Stopped -eq 0) { Write-Host (Get-KaText 'cli.stopNone') -ForegroundColor DarkGray }
        else {
            $msg = Get-KaText 'cli.stopped' @{ n = $r.Stopped }
            if ($r.Forced) { $msg += Get-KaText 'cli.stoppedForced' @{ n = $r.Forced } }
            Write-Host $msg -ForegroundColor Green
            if ($r.Cooperative -eq $false) {
                # stop.flag could not be written, so nothing released the request politely -
                # the process was killed and its finally block never ran.
                Write-Host (Get-KaText 'cli.stopUncooperative' @{ detail = $r.Detail }) -ForegroundColor Yellow
            }
        }
        if ($r.intentWritten -eq $false) {
            Write-Host (Get-KaText 'cli.intentUnwritable' @{ path = (Get-KaPath).intent }) -ForegroundColor Yellow
        }
        Write-Host (Get-KaText 'cli.intentOff') -ForegroundColor DarkGray
    }

    'report'  { $out = Show-Report (Get-KaReport); if ($out) { Write-Host $out } }

    'check'   {
        $out = Show-Report (Get-KaReport -Refresh)
        if ($out) { Write-Host $out }
        $p = Get-KaPath
        Write-Host ''
        Write-Host (Get-KaText 'cli.machineWritten' @{ path = $p.machine }) -ForegroundColor DarkGray
        $cfg = Get-KaConfig
        $rec = (Read-KaJson $p.machine).recommendedIntervalSec
        if ($rec -and [int]$cfg.antiLockIntervalSec -gt [int]$rec) {
            Write-Host (Get-KaText 'cli.intervalHint' @{ cur = $cfg.antiLockIntervalSec; rec = $rec }) -ForegroundColor DarkYellow
        }
    }

    'config' {
        # Set-ConfigPairs and Set-KaConfig both throw for input a person can fix
        # (a pair without '=', a value outside an enum). They get one red line, not
        # an exception block with a char offset.
        $patch = $null
        try {
            $patch = Set-ConfigPairs -Pairs $Set
            if ($patch) {
                if (-not (Set-KaConfig -Patch $patch)) { throw (Get-KaText 'cli.configWriteFail') }
            }
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            exit 1
        }
        if ($patch) { Write-Host (Get-KaText 'cli.saved') -ForegroundColor Green }
        $cfg = Get-KaConfig      # after revalidation, so what is printed is what will run
        if ($Json) { Write-Host ($cfg | ConvertTo-Json -Depth 5); return }
        Write-Head (Get-KaText 'cli.configHead')
        Write-Host (Get-KaText 'cli.configPath' @{ path = (Get-KaPath).config }) -ForegroundColor DarkGray
        foreach ($k in ($cfg.Keys | Sort-Object)) { Write-Kv $k "$($cfg[$k])" }
        Write-Host ''
        Write-Host (Get-KaText 'cli.configHint') -ForegroundColor DarkGray
    }

    'guard' {
        $r = Install-KaGuard -WithBoot:$Boot
        if ($r.Ok) {
            Write-Host (Get-KaText 'cli.guardInstalled') -ForegroundColor Green
            foreach ($t in $r.Status.tasks) {
                Write-Kv $t.name (Get-KaText 'cli.guardTaskRow' @{
                    state = $t.state; last = $t.lastRun; result = $t.lastResult; next = $t.nextRun })
            }
            if ($r.Boot) {
                # The boot task degrades stepwise (s4u -> interactive -> denied) and each
                # outcome has its own honest sentence - "installed" alone would hide which.
                $k = switch ($r.Boot.mode) {
                    's4u'         { 'cli.guardBootS4u' }
                    'interactive' { 'cli.guardBootInteractive' }
                    default       { 'cli.guardBootDenied' }
                }
                $vars = @{ }
                if ($r.Boot.mode -eq 'denied') { $vars.reason = $r.Boot.reason }
                Write-Host (Get-KaText $k $vars) -ForegroundColor $(if ($r.Boot.ok) { 'Green' } else { 'DarkYellow' })
            }
        } else {
            Write-Host (Get-KaText 'cli.guardFail' @{ reason = $r.Reason }) -ForegroundColor Red
            Write-Host (Get-KaText 'cli.guardFailHint') -ForegroundColor DarkGray
            exit 1
        }
    }

    'unguard' {
        $r = Uninstall-KaGuard
        if ($r.Ok) { Write-Host (Get-KaText 'cli.unguarded' @{ list = ($r.Removed -join ', ') }) -ForegroundColor Green }
        else { Write-Host (Get-KaText 'cli.unguardFail' @{ reason = $r.Reason }) -ForegroundColor Red; exit 1 }
    }

    'log' {
        $p = Get-KaPath
        if (-not (Test-Path -LiteralPath $p.log)) { Write-Host (Get-KaText 'cli.noLogYet' @{ path = $p.log }) -ForegroundColor DarkGray; return }
        Get-Content -LiteralPath $p.log -Tail $Tail | ForEach-Object { Write-Host $_ }
    }

    'evidence' {
        $out = Show-Evidence -HoursSpan $Hours
        if ($out) { Write-Host $out }
    }

    'serve' {
        $r = Start-KaServer
        if (-not $r.Ok) { Write-Host (Get-KaText 'cli.serveFail' @{ reason = $r.Reason }) -ForegroundColor Red; exit 1 }
        Write-Host (Get-KaText 'cli.panelUrl' @{ url = $r.Url }) -ForegroundColor Green
        if ($r.Newly) { Write-Host (Get-KaText 'cli.panelOpening') -ForegroundColor DarkGray }
        try { Start-Process $r.Url } catch { Write-Host (Get-KaText 'cli.panelManual' @{ url = $r.Url }) -ForegroundColor DarkYellow }
    }

    'stop-server' {
        $r = Stop-KaServer
        $col = 'Green'
        if ([int]$r.Stopped -le 0) { $col = if (@($r.Answering).Count) { 'DarkYellow' } else { 'Gray' } }
        Write-Host (Get-KaStopServerText $r) -ForegroundColor $col
    }

    'tray' {
        $p = Get-KaPath
        if (-not (Test-Path -LiteralPath $p.tray)) { Write-Host (Get-KaText 'cli.missingTray') -ForegroundColor Red; exit 1 }
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $p.tray)) -WindowStyle Hidden
        Write-Host (Get-KaText 'cli.trayStarted') -ForegroundColor Green
    }

    'requests' {
        Write-Head (Get-KaText 'cli.requestsHead')
        try {
            $out = & powercfg /requests 2>&1
            ($out | ForEach-Object { "$_" }) | ForEach-Object { Write-Host "  $_" }
        } catch {
            Write-Host (Get-KaText 'cli.requestsFail' @{ msg = $_.Exception.Message }) -ForegroundColor Red
            Write-Host (Get-KaText 'cli.requestsHint') -ForegroundColor DarkGray
        }
        # The silent blocker: an override naming our image makes the kernel drop every
        # request above without any error, so it belongs in the same screen.
        $ovr = Get-KaRequestOverrides
        Write-Host ''
        Write-Host (Get-KaText 'cli.overridesHead')
        if (@($ovr).Count -eq 0) {
            Write-Host (Get-KaText 'cli.overridesNone')
        } else {
            foreach ($o in $ovr) { Write-Host ("  [{0}] {1}" -f $o.scope, $o.line) }
            $self = @(Get-KaSelfOverrides $ovr)
            if ($self.Count) {
                $names = (@($self | ForEach-Object { "$($_.scope): $($_.line)" }) -join ' | ')
                Write-Host (Get-KaText 'cli.overridesSelf' @{ names = $names }) -ForegroundColor Yellow
            }
        }
    }

    'lid' {
        $p = Get-KaPath
        if (-not (Test-Path -LiteralPath $p.lid)) { Write-Host (Get-KaText 'cli.missingLid') -ForegroundColor Red; exit 1 }
        & $p.lid -Action $LidAction -Force:$Force
    }
}
