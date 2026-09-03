<#
.SYNOPSIS
    ka-lid.ps1 - make "close the lid" stop sleeping the machine.

.DESCRIPTION
    On an S0 Modern-Standby laptop the lid is the one control that beats every
    keep-awake tool: closing it is a policy action, not an idle timeout, so
    SetThreadExecutionState has no say in it. Many OEM images also hide the setting,
    which is why it is missing from the GUI rather than merely set wrong.

    apply    unhide LIDACTION, record what was there, set 0 (do nothing) for AC and DC,
             re-activate the scheme, then verify by reading it back.
    restore  write the recorded values back.
    status   report the current values and whether this tool has touched them.

    What is deliberately honest here:
      * Verification is a re-read, never an assumption that powercfg exited 0. Some
        platforms accept the write and ignore it.
      * The scheme name is recorded with the backup. `apply` changes SCHEME_CURRENT;
        if the active plan is switched before `restore`, writing the old values back
        would land in a different plan and leave the original one modified forever -
        so that case is reported instead of papered over.
      * Changing this needs elevation. Without it the script says so and does nothing
        rather than half-applying.
      * A machine whose kernel capability bit proves it has no lid switch gets no write at
        all: setting LIDACTION there would modify a power plan for a control that cannot be
        triggered. -Force is the escape hatch for the rare box that reports no lid but has
        one (some docks and tablets do exactly that).

.PARAMETER Action
    status | apply | restore

.PARAMETER Force
    Write even when the kernel says there is no lid switch.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-lid.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-lid.ps1 -Action apply
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'apply', 'restore')]
    [string]$Action = 'status',
    [switch]$Json,
    [switch]$NoElevate,
    [switch]$Force,
    [switch]$Pause,
    [string]$DataDir = ''
)

if ($DataDir) { $env:KA_DATA = $DataDir }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')

$KaLidSub    = '4f971e89-eebd-4455-a8de-9e59040e7347'   # SUB_BUTTONS
$KaLidAction = '5ca83367-6e45-459f-a27b-476b1d01c936'   # LIDACTION
$paths = Get-KaPath
# The machine root, deliberately: `apply` runs elevated and the elevation prompt may be
# satisfied by a different account, while `restore` has to find the same record. What it
# guards is the computer's power plan, so it belongs to the computer, not to whoever
# happened to click.
$backupPath = $paths.lidBackup

function Test-KaAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-KaLidActionText {
    # Unknown raw values fall back to the number itself rather than a dictionary key,
    # so a firmware with a nonstandard LIDACTION stays honest on screen.
    param($V)
    if ($null -eq $V) { return Get-KaText 'lid.hidden' }
    if ($script:KaUi.zh.ContainsKey("lid.action.$([int]$V)")) { return Get-KaText "lid.action.$([int]$V)" }
    return (Get-KaText 'lid.unknown' @{ v = $V })
}

function Get-KaLid {
    $v = Get-PowerSetting $KaLidSub $KaLidAction
    @{
        found  = [bool]$v.Found
        ac     = $v.Ac
        dc     = $v.Dc
        acText = $(if (-not $v.Found -or $null -eq $v.Ac) { Get-KaText 'lid.hidden' } else { Get-KaLidActionText $v.Ac })
        dcText = $(if (-not $v.Found -or $null -eq $v.Dc) { '?' } else { Get-KaLidActionText $v.Dc })
    }
}

function Get-KaActiveScheme {
    <#
        One line, shaped "电源方案 GUID: 381b...  (平衡)" / "Power Scheme GUID: 381b...
        (Balanced)" in every locale. Only the GUID is ever compared; the name is for
        humans, so a parse miss there must not become a functional failure.
    #>
    $out = @{ guid = ''; name = '' }
    try {
        $line = ((& powercfg /getactivescheme 2>$null | ForEach-Object { "$_" }) -join "`n")
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $out.guid = $Matches[1].ToLower()
        }
        if ($line -match '\(([^()]+)\)\s*$') { $out.name = $Matches[1].Trim() }
    } catch { }
    return $out
}

function Test-KaLidPresent {
    <#
        $true / $false straight from GetPwrCapabilities, or $null when the API could not be
        read. The powercfg fallback parses no lid bit, so it must not answer "no lid" here -
        that is why this returns three states instead of a boolean.
    #>
    $caps = Get-KaPowerCaps
    if ("$($caps.source)" -ne 'api') { return $null }
    return [bool]$caps.lidPresent
}

# Read once: `apply` needs the answer before elevation (a UAC prompt for a control that
# cannot be triggered is friction for nothing) and the display needs it to pick its caveats.
$script:KaLidPresent = Test-KaLidPresent
# Deliberately the *proven* negative. An unreadable bit leaves $false here so a laptop whose
# capabilities could not be queried keeps getting the advice it needs.
$script:KaNoLid = ($null -ne $script:KaLidPresent) -and -not [bool]$script:KaLidPresent

function Invoke-KaLidElevation {
    param([string]$ForAction)
    if ($NoElevate -or -not [Environment]::UserInteractive) {
        return @{ Ok = $false; Reason = (Get-KaText 'lid.elev.no' @{ action = $ForAction }) }
    }
    try {
        $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                 '-Action', $ForAction, '-DataDir', ('"{0}"' -f (Get-KaDataRoot)))
        if ($Pause) { $arg += '-Pause' }
        if ($Force) { $arg += '-Force' }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arg
        return @{ Ok = $true; Relaunched = $true }
    } catch {
        # The usual cause is an account that cannot elevate at all, not a declined prompt.
        return @{ Ok = $false; Reason = (Get-KaText 'lid.elev.fail' @{
            msg = $_.Exception.Message; sub = $KaLidSub; set = $KaLidAction }) }
    }
}

function Show-KaLidResult {
    param($R)
    if ($Json) { $R | ConvertTo-Json -Depth 5 | Write-Output; return }
    $lid = Get-KaLid
    Write-Output (Get-KaText 'lid.out.scheme' @{
        scheme = (Get-KaActiveScheme).name; ac = $lid.acText; dc = $lid.dcText })
    Write-Output (Get-KaText 'lid.out.backup' @{
        path = $(if (Test-Path -LiteralPath $backupPath) { $backupPath } else { Get-KaText 'lid.out.none' }) })
    if ($R.Reason)  { Write-Output (Get-KaText 'lid.out.result' @{ reason = $R.Reason }) }
    if ($R.Verified) { Write-Output (Get-KaText 'lid.out.verified') }
    if ($lid.found -and [int]$lid.ac -eq 0 -and [int]$lid.dc -eq 0 -and -not $script:KaNoLid) {
        # Whether we wrote it or the OEM did, the two caveats are the same facts.
        Write-Output (Get-KaText 'lid.apply.verify')
        Write-Output (Get-KaText 'lid.apply.heat')
    }
    if ($script:KaNoLid) { Write-Output (Get-KaText 'lid.status.nolid') }
}

$r = @{ Action = $Action; Ok = $false; Verified = $false; Reason = ''; Before = $null; After = $null }
$r.Before = Get-KaLid
$r.LidPresent = $script:KaLidPresent

switch ($Action) {

    'status' {
        $r.Ok = $true
        $r.Verified = [bool]($r.Before.found -and [int]$r.Before.ac -eq 0 -and [int]$r.Before.dc -eq 0)
        if (-not $r.Before.found) {
            $r.Reason = Get-KaText 'lid.status.hidden'
        } elseif (-not $r.Verified) {
            $r.Reason = Get-KaText 'lid.status.notzero'
        } else {
            $r.Reason = Get-KaText 'lid.status.ok'
        }
    }

    'apply' {
        if ($script:KaNoLid -and -not $Force) {
            # Not a failure, so exit stays 0: there is nothing on this machine to fix.
            # restore is never gated - a backup taken while a lid was present has to stay
            # reachable even if the capabilities read later comes back "no lid".
            $r.Ok = $true
            $r.Reason = Get-KaText 'lid.apply.nolid'
            Add-KaLog "LID apply pid=$PID refused=no-lid"
            break
        }
        if (-not (Test-KaAdmin)) {
            $e = Invoke-KaLidElevation -ForAction 'apply'
            $r.Reason = $e.Reason
            $r.Ok = [bool]$e.Relaunched
            if ($e.Relaunched) { $r.Reason = Get-KaText 'lid.relaunch' }
            break
        }
        $scheme = Get-KaActiveScheme
        # Unhide first: without it the value cannot be read back, so verification would
        # be impossible on exactly the machines that need this the most.
        try { & powercfg /attributes $KaLidSub $KaLidAction -ATTRIB_HIDE 2>$null | Out-Null } catch { }

        if (-not (Test-Path -LiteralPath $backupPath)) {
            $lid = Get-KaLid
            [void](Write-KaJson $backupPath @{
                ac = $lid.ac; dc = $lid.dc; found = [bool]$lid.found
                schemeGuid = $scheme.guid; schemeName = $scheme.name
                capturedAt = (Get-Date -Format 'o')   # 's' has no UTC offset; the reader would guess
            } -Depth 3)
        }

        try {
            & powercfg /setacvalueindex SCHEME_CURRENT $KaLidSub $KaLidAction 0 2>$null | Out-Null
            & powercfg /setdcvalueindex SCHEME_CURRENT $KaLidSub $KaLidAction 0 2>$null | Out-Null
            & powercfg /setactive SCHEME_CURRENT 2>$null | Out-Null
        } catch {
            $r.Reason = Get-KaText 'lid.apply.writefail' @{ msg = $_.Exception.Message }
            break
        }

        $r.After = Get-KaLid
        $r.Ok = $true
        $r.Verified = [bool]($r.After.found -and [int]$r.After.ac -eq 0 -and [int]$r.After.dc -eq 0)
        $r.Reason = if ($r.Verified) {
            Get-KaText 'lid.apply.ok'
        } elseif (-not $r.After.found) {
            Get-KaText 'lid.apply.unreadable'
        } else {
            Get-KaText 'lid.apply.ignored' @{ ac = $r.After.acText; dc = $r.After.dcText }
        }
        Add-KaLog "LID apply pid=$PID verified=$($r.Verified) ac=$($r.After.ac) dc=$($r.After.dc)"
    }

    'restore' {
        if (-not (Test-KaAdmin)) {
            $e = Invoke-KaLidElevation -ForAction 'restore'
            $r.Reason = $e.Reason
            $r.Ok = [bool]$e.Relaunched
            if ($e.Relaunched) { $r.Reason = Get-KaText 'lid.relaunch' }
            break
        }
        if (-not (Test-Path -LiteralPath $backupPath)) {
            $r.Reason = Get-KaText 'lid.restore.nobackup' @{ path = $backupPath }
            break
        }
        $b = Read-KaJson $backupPath
        $scheme = Get-KaActiveScheme
        if ($b.schemeGuid -and $scheme.guid -and ($b.schemeGuid -ne $scheme.guid)) {
            # Writing now would change a plan that was never modified and leave the
            # original one silently broken. Say so and stop.
            $r.Reason = Get-KaText 'lid.restore.scheme' @{
                old = $b.schemeName; oldguid = $b.schemeGuid
                new = $scheme.name;  newguid = $scheme.guid }
            break
        }
        try {
            if ($null -ne $b.ac) { & powercfg /setacvalueindex SCHEME_CURRENT $KaLidSub $KaLidAction $b.ac 2>$null | Out-Null }
            if ($null -ne $b.dc) { & powercfg /setdcvalueindex SCHEME_CURRENT $KaLidSub $KaLidAction $b.dc 2>$null | Out-Null }
            & powercfg /setactive SCHEME_CURRENT 2>$null | Out-Null
        } catch {
            $r.Reason = Get-KaText 'lid.apply.writefail' @{ msg = $_.Exception.Message }
            break
        }
        $r.After = Get-KaLid
        $r.Ok = $true
        $same = (($null -eq $b.ac) -or ([int]$r.After.ac -eq [int]$b.ac)) -and `
                (($null -eq $b.dc) -or ($null -eq $r.After.dc) -or ([int]$r.After.dc -eq [int]$b.dc))
        $r.Verified = [bool]$same
        $r.Reason = $(if ($same) {
            try { Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop; Get-KaText 'lid.restore.ok' }
            catch { Get-KaText 'lid.restore.okkeep' @{ msg = $_.Exception.Message } }
        } else {
            Get-KaText 'lid.restore.mismatch' @{
                expac = $b.ac; expdc = $b.dc; ac = $r.After.ac; dc = $r.After.dc }
        })
        Add-KaLog "LID restore pid=$PID verified=$($r.Verified)"
    }
}

Show-KaLidResult -R $r
if ($Pause) { try { [void](Read-Host (Get-KaText 'lid.pause')) } catch { } }
if (-not $r.Ok) { exit 1 }
