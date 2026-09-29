<#
    A leg's process bookkeeping: the job object that marks the leg's tree, and the rules around it.

    Why this exists (2026-09-28/29): four false results, each one a CI cycle spent on a process that
    had nothing to do with the probe it was blamed for (and the blamed probe had printed its own PROBE
    OK) - wps.exe/wpscloudsvr.exe (the user's office suite, blamed on a leg by a stale parent entry),
    the machine's own worker pid 21688, CompatTelRunner.exe, and then a whole Windows servicing burst
    (TiWorker.exe, TrustedInstaller.exe, MoUsoCoreWorker.exe, three svchost.exe, CompatTelRunner.exe)
    plus, locally, Git's `sleep.exe`, started by the tooling that was watching the run. All of it came
    from reconstructing a leg's ancestry out of pids: a pid->ppid entry is evidence only about the
    process that held that pid when the entry was written, and a chain stitched through a recycled pid
    can land on the leg's cmd by coincidence.

    So the reconstruction is gone. Each leg runs inside a Job object, every descendant inherits the
    membership, and the members are read back with one query. The cases below pin that contract, and
    the last run injects into the single line that asks the job, so a green here cannot survive that
    line being replaced by "everything alive" - which is what the old approach amounted to.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lib = if ($env:KA_PROCWALK_LIB) { $env:KA_PROCWALK_LIB } else { Join-Path $PSScriptRoot 'ka-procwalk.ps1' }
$asChild = ("$env:KA_PROCWALK_CHILD" -eq '1')
$selfPath = $PSCommandPath
if (-not (Test-Path -LiteralPath $lib)) { Write-Output ('PROBE FAILED: no library at ' + $lib); exit 1 }
. $lib

$bad = @()
function Bad([string]$m) { $script:bad += $m; Write-Output ('  FAIL ' + $m) }
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }

$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Start-Sleeper { param([int]$Seconds = 90)
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-Command', ("Start-Sleep -Seconds $Seconds")) -WindowStyle Hidden -PassThru
}

$job = [Ka.LegJob]::Create()
if ($job -eq [IntPtr]::Zero) { Write-Output 'PROBE FAILED: CreateJobObject returned 0 - nothing below could be tested'; exit 1 }
$mine = Start-Sleeper 90
$wmi = $null
try {
    Write-Output '--- 1. a process this script starts and assigns is in the job'
    $err = [Ka.LegJob]::Assign($job, [int]$mine.Id)
    if ($err) { Bad ("Assign failed: $err") }
    $ans = Get-KaLegPids $job
    if (-not $ans.Ok) { Bad ('the job query failed with Win32 ' + $ans.Err) }
    $pids = @($ans.Pids)
    if ($pids -contains [int]$mine.Id) { Ok ("member: $($mine.Id)") }
    else { Bad ("the assigned process is not listed by the job (" + ($pids -join ',') + ")") }

    Write-Output '--- 2. a process created through WMI is not a member (the CI failure shape)'
    # Its parent is WmiPrvSE.exe, so it is born inside the leg's window and unrelated to this tree -
    # exactly what CompatTelRunner.exe and Git's sleep.exe were.
    $wmi = [int](Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = ('"' + $ps + '" -NoProfile -Command "Start-Sleep -Seconds 85"') }).ProcessId
    Start-Sleep -Milliseconds 700
    $pids2 = @((Get-KaLegPids $job).Pids)
    if (-not $wmi) { Ok 'SKIP: WMI could not create a process here, so this shape was not exercised' }
    elseif ($pids2 -contains $wmi) { Bad ("a WMI-created process is listed as a member: $wmi - this is the false positive the job removes") }
    else { Ok ("the unrelated process $wmi (parent: WmiPrvSE) is not a member") }

    Write-Output '--- 3. a member that exits is gone from the list'
    try { Stop-Process -Id $mine.Id -Force -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 600
    $pids3 = @((Get-KaLegPids $job).Pids)
    if ($pids3 -contains [int]$mine.Id) { Bad 'a process that exited is still listed as a member' }
    else { Ok 'the exited member is no longer listed' }

    Write-Output '--- 4. the age window still partitions what may be reported'
    $second = Start-Sleeper 90
    $null = [Ka.LegJob]::Assign($job, [int]$second.Id)
    $inWin = @(Get-OwnLeftovers @([int]$second.Id) (Get-Date).AddMinutes(-5) (Get-Date).AddMinutes(1))
    if ($inWin -contains [int]$second.Id) { Ok 'a member born inside the window is kept' } else { Bad 'a live member born just now was dropped by the window' }
    $outWin = @(Get-OwnLeftovers @([int]$second.Id) (Get-Date).AddMinutes(10) (Get-Date).AddMinutes(20))
    if ($outWin.Count -eq 0) { Ok 'a member born outside the window is dropped' } else { Bad 'the window let a process born later through' }

    Write-Output '--- 5. kill terminates the members (the timeout path)'
    $null = [Ka.LegJob]::Kill($job)
    Start-Sleep -Milliseconds 900
    $alive = Get-Process -Id $second.Id -ErrorAction SilentlyContinue
    if ($alive) { Bad ('TerminateJobObject left the member running: ' + $second.Id) } else { Ok 'the job kill took its members with it' }
    $pids5 = @((Get-KaLegPids $job).Pids)
    if ($pids5 -contains [int]$second.Id) { Bad 'the killed member is still listed' } else { Ok 'and it is no longer listed' }
} finally {
    try { Stop-Process -Id $mine.Id -Force -ErrorAction Stop } catch { }
    if ($wmi) { try { Stop-Process -Id $wmi -Force -ErrorAction Stop } catch { } }
    [Ka.LegJob]::Close($job)
}

if ($asChild) {
    # Running as the guard's own red check: report and stop. No second level of mutation.
    foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
    if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
    Write-Output 'PROBE OK (child): the library under test behaves'
    exit 0
}

# ---------------------------------------------------------------- the query's own red
# Replace the one line that asks the job with "everything alive" and require case 2 to go red. Anchored
# on exact text and counted first: a silent miss would make this half vacuous, which is the failure mode
# this file exists to avoid.
Write-Output '--- 6. the injection: the job query replaced by a list of everything alive'
$anchor = '    $pids = [Ka.LegJob]::Pids($Job)'
$libText = [IO.File]::ReadAllText($lib)
$hits = ([regex]::Matches($libText, [regex]::Escape($anchor))).Count
if ($hits -ne 1) { Write-Output ("PROBE FAILED: the query anchor matches $hits time(s), expected 1 - the injection would not test what we think"); exit 1 }
$mutant = Join-Path $root ('_tmp/procwalk-allpids-' + [guid]::NewGuid().ToString('N') + '.ps1')
$mutText = $libText.Replace($anchor, '    $pids = @(Get-ProcessRows | ForEach-Object { [int]$_.ProcessId })')
$enc = New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($mutant, $mutText, $enc)
$out = Join-Path $env:TEMP ('ka-procwalk-child-' + [guid]::NewGuid().ToString('N') + '.out')
try {
    $prevLib = $env:KA_PROCWALK_LIB
    $prevChild = $env:KA_PROCWALK_CHILD
    $env:KA_PROCWALK_LIB = $mutant
    $env:KA_PROCWALK_CHILD = '1'
    $p = Start-Process -FilePath $ps -NoNewWindow -PassThru -RedirectStandardOutput $out `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $selfPath + '"')
    $deadline = (Get-Date).AddSeconds(180)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $timedOut = -not $p.HasExited
    if ($timedOut) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    $text = (@(Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) -join "`n")   # Get-Content: the redirect handle is still ours
    if ($prevLib) { $env:KA_PROCWALK_LIB = $prevLib } else { Remove-Item Env:KA_PROCWALK_LIB -ErrorAction SilentlyContinue }
    if ($prevChild) { $env:KA_PROCWALK_CHILD = $prevChild } else { Remove-Item Env:KA_PROCWALK_CHILD -ErrorAction SilentlyContinue }
    if ($timedOut) {
        Bad 'the injected child did not finish in 180s'
    } elseif ($text -notlike '*false positive the job removes*') {
        Bad 'with the job query replaced by everything alive, case 2 still passed - the WMI case does not depend on it'
        foreach ($l in ($text -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
    } else {
        Ok 'the WMI case goes red the moment the answer stops coming from the job'
    }
} finally {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mutant -Force -ErrorAction SilentlyContinue
}

foreach ($m in $bad) { Write-Output ('  problem: ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output 'PROBE OK: the job lists what this leg started and assigned, does not list a WMI-created stranger, drops an exited member, takes its members with it when killed, and the WMI case goes red the moment the answer stops coming from the job'
