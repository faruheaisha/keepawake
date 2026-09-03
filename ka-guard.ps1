<#
.SYNOPSIS
    ka-guard.ps1 - the watchdog body behind the KeepAwake-Guard scheduled task.

.DESCRIPTION
    Runs every few minutes and once at logon, does one comparison and exits:

        intent.json   what the user last asked for
        a live worker what is actually running

    The previous build started protection unconditionally, so a deliberate `stop` was
    undone within ten minutes and the user had no way to win that argument. Everything
    that decides what to do now lives in Reconcile-KaProtection; this file only owns
    the plumbing around it:

      * its own mutex, so three overlapping task triggers cannot interleave starts
        and stop-then-start each other;
      * a hard guard on a missing ka-core.ps1 - after the folder is moved or copied
        the task still fires, and the failure has to be visible somewhere rather
        than swallowed by the scheduler's exit code;
      * one log line per run, which is also the evidence that the guard is alive.

    No Write-Host anywhere: under some hosts the raw UI helper throws when there is no
    interactive host, which would fail a run that otherwise succeeded.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-guard.ps1
#>
[CmdletBinding()]
param(
    [int]$StaleTickSec = 90,
    [switch]$Json,
    [string]$DataDir = ''
)

# The task passes this explicitly: reconciling is entirely about whose intent.json and
# state.json are being compared, and guessing from the account the scheduler happened to
# start us under is how a watchdog resurrects protection somebody else stopped.
if ($DataDir) { $env:KA_DATA = $DataDir }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }   # 2 is what the scheduler records as Last Task Result
$core = Join-Path $PSScriptRoot 'ka-core.ps1'

if (-not (Test-Path -LiteralPath $core)) {
    # Last resort: the plan is that nobody ever sees this file, but a silently dead
    # watchdog is the failure mode worth spending a write to avoid. Two candidate
    # locations, because the failure this reports - the task pointing at a folder that
    # is gone - is often a folder that cannot be written either, and ka-core.ps1 is
    # missing, so Get-KaPath does not exist to ask.
    $stamp = (Get-Date -Format 'o')
    $msg = "{0} ka-core.ps1 missing / 缺失，看门狗无法工作（计划任务指向的路径可能已失效）- the watchdog cannot work (the scheduled task may point at a dead path)" -f $stamp
    foreach ($cand in @((Join-Path $PSScriptRoot 'ka-guard-missing-core.txt'),
                        (Join-Path $env:TEMP 'KeepAwake-guard-missing-core.txt'))) {
        try { Set-Content -LiteralPath $cand -Value $msg -Encoding UTF8; break } catch { }
    }
    exit 2
}

. $core

$mutex = $null
$owned = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, (Get-KaMutexName 'KA-Guard'))
    try { $owned = $mutex.WaitOne(0) } catch { $owned = $true }
} catch {
    $owned = $true          # cannot even build a named object: run anyway, protecting beats idling
}

if (-not $owned) {
    exit 0                 # another guard pass is already reconciling; it will cover this one too
}

$result = @{ ok = $false; action = ''; at = 0 }
try {
    $result = Reconcile-KaProtection -StaleTickSec $StaleTickSec
    $result.ok = $true
    if ($Json) { $result | ConvertTo-Json -Compress | Write-Output }
    else {
        Write-Output (Get-KaText 'guard.line' @{
            action  = $result.action
            intent  = $(if ($result.wantOn) { 'awake' } else { 'off' })
            workers = $result.workers
            alive   = $result.alive })
    }
} catch {
    $result.action = "error: $($_.Exception.Message)"
    try { if ($Json) { $result | ConvertTo-Json -Compress | Write-Output } } catch { }
    Add-KaLog "GUARD-FAILED $($_.Exception.Message)"
    exit 1
} finally {
    Add-KaLog ('GUARD action={0} intent={1} workers={2} alive={3}' -f `
               $result.action, $(if ($result.wantOn) { 'awake' } else { 'off' }), `
               $result.workers, $(if ($result.alive) { 'yes' } else { 'no' }))
    try { if ($owned -and $mutex) { [void]$mutex.ReleaseMutex() } } catch { }
    try { if ($mutex) { $mutex.Dispose() } } catch { }
}
