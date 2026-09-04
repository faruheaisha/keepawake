<#
.SYNOPSIS
    ka-tray.ps1 - a system-tray presence for the keep-awake worker.

.DESCRIPTION
    Nothing here is load-bearing: the protection lives in ka-worker.ps1, which outlives
    this process by design. Closing the tray must never stop protection, and protection
    keeps working when this window-less process is killed.

    Decisions worth their comment:
      * The icon is drawn at runtime with System.Drawing rather than shipping a .ico, so
        the folder stays text-only and clone-and-run, and the colour can track the real
        state instead of a static picture.
      * Polling is coarse (5s by default). Worker discovery costs about a second per
        probe; a tray that burned a core every second would be the worst possible reason
        to notice this tool exists.
      * Every menu toggle applies to the live worker, not just to config.json. Writing
        the setting and waiting for the next start would be a control that looks alive
        and does nothing - the exact failure this build set out to remove.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-tray.ps1
#>
[CmdletBinding()]
param(
    [int]$PollSec = 5,
    [switch]$NoServerItem,
    [switch]$SelfTest,
    [string]$DataDir = ''
)

if ($DataDir) { $env:KA_DATA = $DataDir }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- single instance
# Keyed on the data root, not the folder: the tray edits config.json and toggles the
# worker that owns that directory's state, so two installs sharing one data root are the
# same tray, and two users of one install are not.
$mutex = $null
$owned = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, (Get-KaMutexName 'KA-Tray'))
    $owned = $mutex.WaitOne(0)
} catch { $owned = $true }
if (-not $owned) {
    try { if ($mutex) { $mutex.Dispose() } } catch { }
    exit 0
}

# ---------------------------------------------------------------- icon drawing
function New-KaTrayIcon {
    <#
        A disc plus a ring. At the 16x16 the tray actually renders, anything finer than
        that turns to mud - and GetHicon leaves the bitmap free to dispose immediately.
    #>
    param([string]$Hex)
    $c = [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($Hex.Substring(0, 2), 16),
        [Convert]::ToInt32($Hex.Substring(2, 2), 16),
        [Convert]::ToInt32($Hex.Substring(4, 2), 16))
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $c
        try { $g.FillEllipse($brush, 7, 7, 18, 18) } finally { $brush.Dispose() }
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 232, 240, 248), 2.5)
        try { $g.DrawEllipse($pen, 3, 3, 26, 26) } finally { $pen.Dispose() }
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } finally {
        $g.Dispose(); $bmp.Dispose()
    }
}
$icons = @{
    go   = New-KaTrayIcon '35d0a5'
    off  = New-KaTrayIcon '5c6b80'
    warn = New-KaTrayIcon 'ffb454'
}

# ---------------------------------------------------------------- menu
function New-MenuItem { param([string]$Text) New-Object System.Windows.Forms.ToolStripMenuItem $Text }
function New-Sep { New-Object System.Windows.Forms.ToolStripSeparator }

$MiHeader     = New-MenuItem (Get-KaText 'tray.mi.headerLoading')
$MiHeader.Enabled = $false
$MiStart      = New-MenuItem (Get-KaText 'tray.mi.start')
$MiStop       = New-MenuItem (Get-KaText 'tray.mi.stop')
$MiDuration   = New-MenuItem (Get-KaText 'tray.mi.duration')
$MiDisplay    = New-MenuItem (Get-KaText 'tray.mi.display')
$MiAntiLock   = New-MenuItem (Get-KaText 'tray.mi.antilock')
$MiMethod     = New-MenuItem (Get-KaText 'tray.mi.method')
$MiMethodKey  = New-MenuItem (Get-KaText 'tray.mi.key')
$MiMethodMouse = New-MenuItem (Get-KaText 'tray.mi.mouse')
$MiInterval   = New-MenuItem (Get-KaText 'tray.mi.interval')
$MiOpen       = New-MenuItem (Get-KaText 'tray.mi.open')
$MiGuard      = New-MenuItem (Get-KaText 'tray.mi.guard')
$MiStopServer = New-MenuItem (Get-KaText 'tray.mi.stopServer')
$MiQuit       = New-MenuItem (Get-KaText 'tray.mi.quit')

$menu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($i in @($MiHeader, (New-Sep), $MiStart, $MiDuration, $MiStop, (New-Sep),
                 $MiDisplay, $MiAntiLock, $MiMethod, $MiInterval, (New-Sep),
                 $MiOpen, $MiGuard, $MiStopServer, (New-Sep), $MiQuit)) {
    $menu.Items.Add($i) | Out-Null
}
$MiMethod.DropDownItems.Add($MiMethodKey) | Out-Null
$MiMethod.DropDownItems.Add($MiMethodMouse) | Out-Null

# The preset labels reuse the localized duration/second formatters, so the menu speaks
# the same language as every other surface without carrying its own number words.
$durations = [ordered]@{
    (Format-KaDuration 1800)  = 30
    (Format-KaDuration 3600)  = 60
    (Format-KaDuration 7200)  = 120
    (Format-KaDuration 28800) = 480
    (Get-KaText 'tray.dur.unlimited') = 0
}
foreach ($k in $durations.Keys) {
    $item = New-MenuItem $k
    $item.Tag = [double]$durations[$k]
    $item.Add_Click({ Start-Protect -Minutes ([double]$this.Tag) })
    $MiDuration.DropDownItems.Add($item) | Out-Null
}
$intervals = [ordered]@{
    (Format-KaSeconds 60)  = 60
    (Format-KaSeconds 120) = 120
    (Format-KaSeconds 240) = 240
    (Format-KaSeconds 480) = 480
}
foreach ($k in $intervals.Keys) {
    $item = New-MenuItem $k
    $item.Tag = [int]$intervals[$k]
    $item.Add_Click({ Apply-Change -Patch @{ antiLockIntervalSec = [int]$this.Tag } })
    $MiInterval.DropDownItems.Add($item) | Out-Null
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icons.off
$tray.Visible = (-not $SelfTest)      # a self test must not flash an icon at the user
$tray.ContextMenuStrip = $menu
$tray.Text = 'Keep Awake'

# ---------------------------------------------------------------- actions
function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'info')
    try {
        $ic = [System.Windows.Forms.ToolTipIcon]::None
        if ($Kind -eq 'error') { $ic = [System.Windows.Forms.ToolTipIcon]::Error }
        elseif ($Kind -eq 'ok') { $ic = [System.Windows.Forms.ToolTipIcon]::Info }
        $tray.BalloonTipTitle = $Title
        $tray.BalloonTipText = $Text
        $tray.ShowBalloonTip(4000, $Title, $Text, $ic)
    } catch { }
}

function Set-TrayText {
    param([string]$Value)
    # The shell caps NOTIFYICONDATA szTip at 63 characters and the setter throws past it.
    # Rather than amputate mid-word, drop whole trailing fields until it fits.
    if ($Value.Length -le 63) { $tray.Text = $Value; return }
    $out = ''
    foreach ($part in @($Value -split ' \| ')) {
        $cand = if ($out) { "$out | $part" } else { $part }
        if ($cand.Length -gt 60) { break }
        $out = $cand
    }
    if (-not $out) { $out = $Value.Substring(0, 57) }
    $tray.Text = $out + '…'
}

function Format-Remaining {
    param([long]$ExpiresEpoch)
    if ($ExpiresEpoch -le 0) { return (Get-KaText 'tray.dur.unlimited') }
    $left = $ExpiresEpoch - (Get-KaEpoch)
    if ($left -le 0) { return (Get-KaText 'tray.rem.expiring') }
    $h = [int][math]::Floor($left / 3600)
    $m = [int][math]::Floor(($left % 3600) / 60)
    if ($h -gt 0) { return (Get-KaText 'tray.rem.h' @{ h = $h; m = $m }) }
    return (Get-KaText 'tray.rem.m' @{ m = $m })
}

function Start-Protect {
    param([double]$Minutes = 0)
    try {
        $r = Start-KaProtection -Minutes $Minutes
        if ($r.Ok) {
            Show-Balloon (Get-KaText 'tray.bal.started') ("pid {0} · {1}" -f $r.Pid, `
                $(if ($Minutes -gt 0) { Get-KaText 'tray.bal.endsIn' @{ n = [math]::Ceiling($Minutes) } } else { Get-KaText 'tray.dur.unlimited' })) 'ok'
        } else {
            Show-Balloon (Get-KaText 'tray.bal.startFail') "$($r.Reason)" 'error'
        }
    } catch { Show-Balloon (Get-KaText 'tray.bal.startFail') $_.Exception.Message 'error' }
    Refresh-State
}

function Stop-Protect {
    try {
        $r = Stop-KaProtection -Reason 'tray'
        $extra = if ([int]$r.Forced -gt 0) { Get-KaText 'tray.bal.forcedExtra' @{ n = $r.Forced } } else { '' }
        Show-Balloon (Get-KaText 'tray.bal.stopped') (Get-KaText 'tray.bal.stoppedBody' @{ n = $r.Stopped; extra = $extra }) 'ok'
    } catch { Show-Balloon (Get-KaText 'tray.bal.stopFail') $_.Exception.Message 'error' }
    Refresh-State
}

function Apply-Change {
    <#
        Persist, then make it true right now. A live worker cannot be re-parameterised
        from outside, so Start-KaProtection restarts it when the request differs - which
        is why the remaining minutes have to be carried over rather than reset.
    #>
    param([hashtable]$Patch)
    try {
        [void](Set-KaConfig -Patch $Patch)
        $st = Get-KaWorkerState
        if ($st) {
            $minutes = 0
            if ([long]$st.expiresEpoch -gt 0) {
                $minutes = [math]::Max(1, [math]::Ceiling((( [long]$st.expiresEpoch - (Get-KaEpoch)) / 60.0)))
            }
            $r = Start-KaProtection -Minutes $minutes -Override $Patch
            if (-not $r.Ok) { Show-Balloon (Get-KaText 'tray.bal.savedNotApplied') "$($r.Reason)" 'error' }
        }
    } catch { Show-Balloon (Get-KaText 'tray.bal.applyFail') $_.Exception.Message 'error' }
    Refresh-State
}

function Open-Dashboard {
    try {
        $r = Start-KaServer
        if (-not $r.Ok) { Show-Balloon (Get-KaText 'tray.bal.openFail') "$($r.Reason)" 'error'; return }
        Start-Process $r.Url
    } catch { Show-Balloon (Get-KaText 'tray.bal.openFail') $_.Exception.Message 'error' }
}

function Toggle-Guard {
    try {
        $g = Get-KaGuardStatus
        # -Force re-registration also re-enables a Disabled task, so the disabled state needs
        # the install branch - the uninstall branch would only dig the hole deeper.
        if ($g.installed -and $g.enabled) {
            $r = Uninstall-KaGuard
            Show-Balloon $(if ($r.Ok) { Get-KaText 'tray.bal.guardOff' } else { Get-KaText 'tray.bal.uninstallFail' }) `
                          $(if ($r.Ok) { Get-KaText 'tray.bal.guardOffBody' } else { "$($r.Reason)" }) `
                          $(if ($r.Ok) { 'ok' } else { 'error' })
        } else {
            $r = Install-KaGuard
            Show-Balloon $(if ($r.Ok) { Get-KaText 'tray.bal.guardOn' } else { Get-KaText 'tray.bal.installFail' }) `
                          $(if ($r.Ok) { Get-KaText 'tray.bal.guardOnBody' } else { "$($r.Reason)" }) `
                          $(if ($r.Ok) { 'ok' } else { 'error' })
        }
    } catch { Show-Balloon (Get-KaText 'tray.bal.guardFail') $_.Exception.Message 'error' }
    Refresh-State
}

# ---------------------------------------------------------------- state refresh
function Refresh-State {
    try {
        $st  = Get-KaWorkerState
        $cfg = Get-KaConfig
        $intent = Get-KaIntent
        $running = [bool]$st
        # state.json is exactly what is missing when the data directory cannot be written, so
        # "no record" must never be read as "not protecting". The mutex answers that question
        # without the file; an unanswerable $null stays unknown, never off.
        $unrecorded = (-not $running) -and ((Test-KaWorkerMutex) -eq $true)

        # Show what the worker really does when one is running; config only governs the
        # next start, and a checkmark that disagrees with reality is a bug report away.
        $eff = if ($running) {
            @{ keepDisplayOn = [bool]$st.keepDisplayOn; antiLock = [bool]$st.antiLock
               antiLockMethod = "$($st.antiLockMethod)"; antiLockIntervalSec = [int]$st.antiLockInterval }
        } else {
            @{ keepDisplayOn = [bool]$cfg.keepDisplayOn; antiLock = [bool]$cfg.antiLock
               antiLockMethod = "$($cfg.antiLockMethod)"; antiLockIntervalSec = [int]$cfg.antiLockIntervalSec }
        }
        $MiDisplay.Checked  = $eff.keepDisplayOn
        $MiAntiLock.Checked = $eff.antiLock
        $MiMethodKey.Checked  = ($eff.antiLockMethod -eq 'key')
        $MiMethodMouse.Checked = ($eff.antiLockMethod -eq 'mouse')
        $MiInterval.Text = Get-KaText 'tray.mi.intervalNow' @{ n = $eff.antiLockIntervalSec }
        $MiMethod.Text = Get-KaText 'tray.mi.methodNow' @{ method = $eff.antiLockMethod }
        $MiStart.Enabled = -not ($running -or $unrecorded)
        $MiStop.Enabled  = [bool]$running -or $unrecorded
        foreach ($i in $MiDuration.DropDownItems) { $i.Enabled = -not ($running -or $unrecorded) }
        # A checkmark on a Disabled task promises a recovery that will never happen.
        $MiGuard.Checked = [bool](Get-KaGuardStatus).enabled

        if ($running) {
            $degraded = [bool]("$($st.error)" -or "$($st.note)" -or $st.stale)
            $tray.Icon = $(if ($degraded) { $icons.warn } else { $icons.go })
            $title = if ($st.stale) { Get-KaText 'tray.state.stale' }
                     elseif ($st.displayActive) { Get-KaText 'tray.state.display' }
                     elseif ($eff.keepDisplayOn) { Get-KaText 'tray.state.degraded' }
                     else { Get-KaText 'tray.state.systemOnly' }
            $MiHeader.Text = $title
            $tip = (@(('Keep Awake ' + $script:KaVersion), $title,
                      ("pid {0} · {1}" -f $st.pid, (Format-Remaining ([long]$st.expiresEpoch))),
                      (Get-KaText 'tray.state.pulse' @{
                          method = $eff.antiLockMethod; interval = $eff.antiLockIntervalSec; n = [int]$st.pulses }),
                      (Get-KaNoteText "$($st.note)" @{ pct = $st.batteryPercent; floor = $st.batteryFloor }),
                      (Get-KaErrorText "$($st.error)")) | Where-Object { $_ }) -join ' | '
            Set-TrayText $tip
        } elseif ($unrecorded) {
            # Alive and holding the request, invisible to every file-based surface. Saying
            # "not running" here would be the loudest lie this menu can tell.
            $tray.Icon = $icons.warn
            $title = Get-KaText 'tray.state.unrecorded' @{ path = (Get-KaPath).state }
            $MiHeader.Text = $title
            Set-TrayText ((@(('Keep Awake ' + $script:KaVersion),
                             (Get-KaText 'tray.state.unrecordedShort'))) -join ' | ')
        } else {
            $tray.Icon = $icons.off
            $wantOn = ("$($intent.desired)" -eq 'awake')
            $title = if ($wantOn) { Get-KaText 'tray.state.wantOn' }
                     elseif ($intent.expired) { Get-KaText 'tray.state.expired' }
                     else { Get-KaText 'tray.state.off' }
            $MiHeader.Text = $title
            Set-TrayText ((@(('Keep Awake ' + $script:KaVersion), $title, (Get-KaText 'tray.state.hint')) | Where-Object { $_ }) -join ' | ')
        }
    } catch {
        $tray.Icon = $icons.warn
        $MiHeader.Text = Get-KaText 'tray.state.readFail' @{ msg = $_.Exception.Message }
        Set-TrayText ('Keep Awake - ' + (Get-KaText 'tray.state.readFailShort'))
    }
}

$MiStart.Add_Click({ Start-Protect })
$MiStop.Add_Click({ Stop-Protect })
$MiDisplay.Add_Click({ Apply-Change -Patch @{ keepDisplayOn = -not $MiDisplay.Checked } })
$MiAntiLock.Add_Click({ Apply-Change -Patch @{ antiLock = -not $MiAntiLock.Checked } })
$MiMethodKey.Add_Click({ Apply-Change -Patch @{ antiLockMethod = 'key' } })
$MiMethodMouse.Add_Click({ Apply-Change -Patch @{ antiLockMethod = 'mouse' } })
$MiOpen.Add_Click({ Open-Dashboard })
$MiGuard.Add_Click({ Toggle-Guard })
$MiQuit.Add_Click({ [System.Windows.Forms.Application]::Exit() })
if ($NoServerItem) { $MiStopServer.Visible = $false } else {
    $MiStopServer.Add_Click({
        try {
            $r = Stop-KaServer
            $text = Get-KaStopServerText $r
            # A panel still answering after we were asked to stop it is not "nothing to do" -
            # the request failed, so the balloon has to look like that.
            $kind = if ([int]$r.Stopped -gt 0) { 'ok' } elseif (@($r.Answering).Count) { 'error' } else { 'info' }
            Show-Balloon (Get-KaText 'tray.bal.panel') $text $kind
        } catch { Show-Balloon (Get-KaText 'tray.bal.panel') $_.Exception.Message 'error' }
    })
}
$tray.Add_MouseDoubleClick({ Open-Dashboard })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int](Get-KaBounded $PollSec 2 600 5) * 1000

if ($SelfTest) {
    try {
        Refresh-State
        $iconName = ($icons.Keys | Where-Object { $icons.$_ -eq $tray.Icon }) -join ','
        Write-Output ('SELFTEST items={0} durations={1} intervals={2}' -f `
                     $menu.Items.Count, $MiDuration.DropDownItems.Count, $MiInterval.DropDownItems.Count)
        Write-Output ('SELFTEST header=' + $MiHeader.Text)
        Write-Output ('SELFTEST tip=' + $tray.Text + ' (len=' + $tray.Text.Length + ')')
        Write-Output ('SELFTEST icon=' + $iconName + ' display=' + $MiDisplay.Checked +
                      ' antiLock=' + $MiAntiLock.Checked + ' method=' + $MiMethod.Text +
                      ' guard=' + $MiGuard.Checked + ' start=' + $MiStart.Enabled + ' stop=' + $MiStop.Enabled)
        if ($menu.Items.Count -lt 10 -or -not $iconName) { throw (Get-KaText 'tray.selftest.fail') }
        Write-Output 'SELFTEST OK'
    } catch {
        Write-Output ('SELFTEST FAILED: ' + $_.Exception.Message)
        $script:SelfTestFailed = $true
    }
} else {
    $timer.Add_Tick({ Refresh-State })
    $timer.Start()
    Refresh-State
    [System.Windows.Forms.Application]::Run()
}

try { $timer.Stop(); $timer.Dispose() } catch { }
try { $tray.Visible = $false; $tray.Dispose() } catch { }
foreach ($k in @($icons.Keys)) { try { $icons.$k.Dispose() } catch { } }
try { if ($owned -and $mutex) { [void]$mutex.ReleaseMutex() } } catch { }
try { if ($mutex) { $mutex.Dispose() } } catch { }
if ($SelfTestFailed) { exit 1 }
