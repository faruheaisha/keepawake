<#
    Run the installer for real: install the built setup.exe, measure what it actually did, uninstall
    it, measure the undo. Every other check in the repo can only read KeepAwake.iss; this is the one
    that can say "the wizard a downloader double-clicks works". Build-time only - packaging/ is out
    of the release manifest on purpose.

    The assertions are README's installer claims, put in front of the thing they describe, so a doc
    line cannot drift from the installer quietly: per-user install with no elevation, exactly the
    manifest files plus Inno's own two, no Mark-of-the-Web on installed scripts, the five Start Menu
    entries, the desktop shortcut really being checked by default, the Add/Remove Programs entry, no
    scheduled task and no panel created by installing, the uninstall hook running stop-server / stop /
    unguard BEFORE files go, and the machine ending where it started.

    That last clause is the dangerous one on a dev machine: unguard deletes KeepAwake-Guard and
    KeepAwake-Logon by a fixed name, and they may belong to whoever runs this. So every KeepAwake
    task is exported to XML first (to a printed path) and the finally block re-registers what the
    uninstall took, then checks the definition came back byte-identical. KA_DATA is pointed at a
    scratch data root, which the hook inherits, so the real %LOCALAPPDATA%\KeepAwake is only ever
    read - and the run ends by proving its fingerprint never moved. A GitHub runner has nothing to
    lose; this machine does.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File packaging\ka-test-install.ps1
        ... -Setup <path>     a specific setup.exe (default: newest in dist\)
        ... -WorkDir <path>    install here (default: a fresh subdirectory of %TEMP%)
        ... -WithWorker       start protection from the installed copy first, so the uninstall hook
                              has a live worker to release. Off by default: locally that leaves a
                              process running for a few seconds if the hook fails.
        ... -Mutate <name>     break exactly one known thing (precreate | expectfiles)
        ... -SelfTest          both mutants must go red on their own assertion, the clean run green

    Exit: 0 every assertion passed, 1 at least one red, 2 it could not even start.
#>
[CmdletBinding()]
param(
    [string]$Setup = '',
    [string]$WorkDir = '',
    [string]$Mutate = '',
    [switch]$WithWorker,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests/ka-release-files.ps1')

function Get-ListeningPorts {
    try { @(Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object { $_.LocalPort }) } catch { @() }
}

function Start-UntilExit {
    <#
        Launch, poll, hand back the exit code - never with Start-Process -Wait.

        Measured 2026-09-05 on this box with a three-level repro (parent -> child that exits at once ->
        hidden grandchild that sleeps 40s): -Wait took 42.3s, i.e. it waited for the grandchild, not for
        the process it was told to wait for; the same launch with -PassThru and a HasExited poll took
        2.6s and still reported ExitCode 0. 'ka.ps1 start' is exactly that shape - a detached keep-awake
        worker is what it leaves behind - and that is what wedged the first -WithWorker run for seven
        minutes, waiting on a process whose whole job is to stay alive.

        A bound that expires is reported, not swallowed: $null out, a sentence in $script:TimedOut, and
        the child killed. A red that says "still running after Ns, killed" is actionable; a step that
        hangs until a CI job timeout kills it is not.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgLine = '',
        [string]$WorkingDirectory = '',
        [int]$TimeoutSec = 600,
        [string]$What = 'child process'
    )
    $p = if ($WorkingDirectory) {
        Start-Process -FilePath $FilePath -ArgumentList $ArgLine -WorkingDirectory $WorkingDirectory -PassThru
    } else {
        Start-Process -FilePath $FilePath -ArgumentList $ArgLine -PassThru
    }
    $t0 = Get-Date
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) { Start-Sleep -Milliseconds 250 }
    if (-not $p.HasExited) {
        $script:TimedOut = ('{0} (pid {1}) was still running after {2}s and was killed' -f $What, $p.Id, $TimeoutSec)
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $script:TimedOut = ''
    return $p.ExitCode
}

# ---------------------------------------------------------------- the self-test drives children
if ($SelfTest) {
    $expect = [ordered]@{ precreate = 'install directory'; expectfiles = 'manifest files' }
    $runs = @{}
    foreach ($m in @('', 'precreate', 'expectfiles')) {
        $log = Join-Path $env:TEMP ("ka-test-install-" + $(if ($m) { $m } else { 'clean' }) + ".txt")
        # The child redirects itself and then re-exits with the script's own code; the parent polls
        # instead of using -Wait. All three halves were measured, not assumed:
        #   - -Wait waits for a detached grandchild, not for the process it was pointed at: the
        #     redirect is not what hung the first -WithWorker run, the seven-minute wait on a live
        #     keep-awake worker was (42.3s vs 2.6s in the repro, same ExitCode).
        #   - "& script *> log" alone loses the exit code: a child script calling exit 7 reported
        #     exit 1 to the parent. The mutation checks compare that number to 0 and 1, so without
        #     'exit $LASTEXITCODE' the clean run would look red and the shape of the failure would
        #     look like the product's, not the harness's.
        # One -f format string, so all four quotes sit where you can see them: the concatenation this
        # replaces left the script path's single quote unterminated, every child died on a
        # command-line parse error, and two mutants still looked correctly red on their exit code.
        $extra = $(if ($m) { ' -Mutate ' + $m } else { '' }) + $(if ($WithWorker) { ' -WithWorker' } else { '' })
        $argline = ('-NoProfile -ExecutionPolicy Bypass -Command "& ''{0}''{1} *> ''{2}''; exit $LASTEXITCODE"' -f $PSCommandPath, $extra, $log)
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
        $exit = Start-UntilExit -FilePath (Join-Path $PSHome 'powershell.exe') -ArgLine $argline -TimeoutSec 1500 -What ("run mutate='{0}'" -f $m)
        $timedOut = $script:TimedOut
        $hasLog = Test-Path -LiteralPath $log
        $fails = @((Get-Content -LiteralPath $log -ErrorAction SilentlyContinue) | Where-Object { $_ -match '^\s+FAIL\s' })
        $runs[$m] = @{ Exit = $exit; Fails = $fails; Log = $log; HasLog = $hasLog; TimedOut = $timedOut }
        Write-Output ("  run mutate='{0,-10}' exit={1} fails={2} log={3}" -f $m, $(if ($null -eq $exit) { 'TIMEOUT' } else { $exit }), $fails.Count, $(if ($hasLog) { 'yes' } else { 'MISSING' }))
        foreach ($f in $fails) { Write-Output ('      ' + $f.Trim()) }
    }
    $bad = New-Object System.Collections.ArrayList
    foreach ($m in @('', 'precreate', 'expectfiles')) {
        $r = $runs[$m]
        # A run that never finished has no exit code, and $null -ne 0 is false: without this branch a
        # clean run that timed out would satisfy "exit -eq 0" and read as a pass.
        if ($r.TimedOut) { [void]$bad.Add($r.TimedOut); continue }
        # A run that wrote nothing says nothing, and "0 FAIL lines" is otherwise indistinguishable
        # from "no problems found".
        if (-not $r.HasLog) { [void]$bad.Add(("run mutate='{0}' left no log at {1} (exit {2}) - it never ran, so its 0 FAIL lines mean nothing" -f $m, $r.Log, $r.Exit)) }
    }
    if (-not $runs[''].TimedOut -and $runs[''].Exit -ne 0) { [void]$bad.Add(("the clean run went red ({0} FAIL lines) - nothing here is trustworthy" -f $runs[''].Fails.Count)) }
    foreach ($m in @('precreate', 'expectfiles')) {
        $r = $runs[$m]
        if ($r.TimedOut) { continue }
        if ($r.Exit -ne 1) { [void]$bad.Add(("mutation '{0}' exited {1}, expected 1 - the check is decoration" -f $m, $r.Exit)) }
        $named = @($r.Fails | Where-Object { $_ -like ('*' + $expect[$m] + '*') })
        if ($named.Count -eq 0) { [void]$bad.Add(("mutation '{0}' did not name '{1}' in any FAIL line" -f $m, $expect[$m])) }
        if ($r.Fails.Count -gt 3) { [void]$bad.Add(("mutation '{0}' turned {1} things red, expected 1-3: the mutant is not surgical" -f $m, $r.Fails.Count)) }
    }
    Write-Output '-----------------------------------------------------------------------'
    if ($bad.Count) { foreach ($b in $bad) { Write-Output ('  FAIL ' + $b) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
    Write-Output 'PROBE OK: each mutation goes red on its own assertion and the intact run stays green'
    exit 0
}

# ---------------------------------------------------------------- what is under test
if (-not $Setup) {
    $cand = @(Get-ChildItem -LiteralPath (Join-Path $root 'dist') -Filter 'KeepAwake-*-setup.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if (-not $cand.Count) { Write-Output 'FAIL no setup.exe in dist\ - run packaging\build.ps1 -Installer first'; exit 2 }
    $Setup = $cand[0].FullName
}
if (-not (Test-Path -LiteralPath $Setup)) { Write-Output ("FAIL setup.exe not found: {0}" -f $Setup); exit 2 }
if ($Setup -notmatch 'KeepAwake-(\d+\.\d+\.\d+)-setup\.exe$') {
    Write-Output ("FAIL cannot read a version out of the file name: {0}" -f (Split-Path $Setup -Leaf)); exit 2
}
$version = $matches[1]
$app = if ($WorkDir) { $WorkDir } else { Join-Path $env:TEMP ('ka-test-install-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
$work = Join-Path $env:TEMP ('ka-test-install-' + $version)
$setupLog = Join-Path $work 'setup.log'
$uninstLog = Join-Path $work 'uninstall.log'
$hookData = Join-Path $work 'scratch-data'
$taskBackup = Join-Path $work 'tasks'
foreach ($d in @($work, $taskBackup)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$manifest = @(Get-KaReleaseFile | ForEach-Object { $_.Replace('\', '/') }) | Sort-Object
$bad = New-Object System.Collections.ArrayList
function Ok([string]$m) { Write-Output ('  ok   ' + $m) }
function Red([string]$m) { [void]$bad.Add($m); Write-Output ('  FAIL ' + $m) }
function Get-DataFingerprint([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 'ABSENT' }
    $rows = @(Get-ChildItem -LiteralPath $dir -Recurse -Force -File | ForEach-Object {
        ($_.FullName.Substring($dir.Length + 1)) + '|' + $_.Length + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    ($rows | Sort-Object) -join "`n"
}
function Wait-For([scriptblock]$test, [int]$ms) {
    # Inno finishes its own cleanup after the process we waited on has returned: the first run of
    # this script declared the install directory a survivor 0ms after the uninstaller exited 0, and
    # the directory was gone by the time anyone looked. So the question is "did it go away", not
    # "had it gone away in the same microsecond" - poll, then judge.
    $t0 = Get-Date
    while (-not (& $test)) {
        if (((Get-Date) - $t0).TotalMilliseconds -gt $ms) { return $false }
        Start-Sleep -Milliseconds 500
    }
    return $true
}
function Invoke-Quiet([string]$exe, [string]$cmd, [string]$what) {
    # Inno writes its own log, so nothing is redirected here - and the repo path can hold a space, so
    # every value keeps its own quotes (unquoted, Inno sees "/DIR=E:\claude" plus a stray token and
    # exits 4 before it opens a log).
    Start-UntilExit -FilePath $exe -ArgLine $cmd -TimeoutSec 900 -What $what
}
function Invoke-Ka([string]$appDir, [string]$kaCmd, [string]$outFile, [string]$what) {
    # Through a real process, not "& ka.ps1": the report is Write-Host, which never reaches the
    # pipeline, so "*> file" (stream 6 included) is how the parent gets to read what it said.
    # $script:KaText holds that text, or is empty when $outFile is empty.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -Command "& ''' + (Join-Path $appDir 'ka.ps1') + ''' ' + $kaCmd
    if ($outFile) { $argLine += (' *> ''' + $outFile + '''') }
    $argLine += '"'
    $exit = Start-UntilExit -FilePath (Join-Path $PSHome 'powershell.exe') -ArgLine $argLine `
        -WorkingDirectory $appDir -TimeoutSec 180 -What $what
    $script:KaText = if ($outFile -and (Test-Path -LiteralPath $outFile)) { Get-Content -LiteralPath $outFile -Raw } else { '' }
    return $exit
}

function Clear-StaleRuns {
    # An interrupted run of this script can leave a keep-awake worker alive under a %TEMP% install
    # directory, holding a power request that nobody is going to release - that is exactly how the
    # first -WithWorker run stranded one for half an hour. Next time this script starts, before it
    # installs anything, it cleans up after its own kind. The pattern needs the 8 hex characters of
    # a generated install directory: this script's own name is ka-test-install.ps1, and the
    # version-named work directory holds the setup logs and the task XML backups, so neither may be
    # swept. The process match has no age bound, which means two runs of this script at the same time
    # on one account are not supported: the second sweep stops the first run's worker.
    $stale = 'ka-test-install-[0-9a-f]{8}'
    $stranded = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $stale })
    foreach ($s in $stranded) {
        Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Output ("  sweep stopped stranded pid {0} from an earlier run" -f $s.ProcessId)
    }
    $cut = (Get-Date).AddMinutes(-60)
    foreach ($d in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'ka-test-install-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ('^' + $stale + '$') -and $_.LastWriteTime -lt $cut })) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output ("  sweep removed {0}" -f $d.Name)
    }
    if ($stranded.Count) { Start-Sleep -Milliseconds 500 }
}
Clear-StaleRuns

Write-Output ("setup.exe  : {0}" -f $Setup)
Write-Output ("install    : {0}" -f $app)
Write-Output ("task xml   : {0}" -f $taskBackup)
Write-Output ("mutate     : '{0}'  withWorker={1}" -f $Mutate, [bool]$WithWorker)

$dataRoot = Join-Path $env:LOCALAPPDATA 'KeepAwake'
$dataBefore = Get-DataFingerprint $dataRoot
$svc = New-Object -ComObject Schedule.Service
$svc.Connect()
$taskFolder = $svc.GetFolder('\')
$tasksBefore = @($taskFolder.GetTasks(0) | Where-Object { $_.Name -like 'KeepAwake*' } | ForEach-Object { $_.Name })
foreach ($n in $tasksBefore) {
    [IO.File]::WriteAllText((Join-Path $taskBackup ($n + '.xml')), $taskFolder.GetTask($n).Xml, [Text.Encoding]::Unicode)
}
$rootCountBefore = @(Get-ScheduledTask -TaskPath '\').Count
$portsBefore = Get-ListeningPorts
$workerPid = 0

try {
    # ---------------------------------------------------------------- install
    Write-Output '--- install ---'
    if ($Mutate -eq 'precreate') {
        # Inno removes a directory it created and leaves one it did not. Creating it first is the
        # one-defect mutant for the "install directory removed" assertion - and the reason the real
        # run installs into a path that does not exist yet, which is what a user gets.
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Write-Output '  mutation: the install directory exists before the installer runs'
    }
    $rc = Invoke-Quiet $Setup ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /DIR="' + $app + '" /LOG="' + $setupLog + '"') 'setup.exe'
    # $null first, and not by habit: $null -eq 0 is true in PowerShell, so an installer that had to be
    # killed after its bound would have been reported as "exit 0, no elevation prompt".
    if ($null -eq $rc) { Red ("setup.exe: {0} - see {1}" -f $script:TimedOut, $setupLog) }
    elseif ($rc -eq 0) { Ok 'installer exit 0, no elevation prompt in a silent per-user run' }
    else { Red ("installer exit {0} - see {1}" -f $rc, $setupLog) }

    # %TEMP% can be an 8.3 short path (a GitHub runner's is C:\Users\RUNNER~1\...). Inno records
    # {app} verbatim and Test-Path agrees either way, but Get-ChildItem spells every FullName in
    # long form (C:\Users\runneradmin\...), so Substring against the short string cut 3 characters
    # too few and prefixed each entry with the tail of the directory name: "48/CHANGELOG.md", where
    # 48 was the last two hex digits of that run's generated suffix. Cut against the root as the
    # enumerator spells it, not as we passed it to the installer.
    $appSeen = if (Test-Path -LiteralPath $app) { (Get-Item -LiteralPath $app -Force).FullName } else { $app }
    $landed = @(Get-ChildItem -LiteralPath $appSeen -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($appSeen.Length + 1).Replace('\', '/') }) | Sort-Object
    $missing = @($manifest | Where-Object { $landed -notcontains $_ })
    $extra = @($landed | Where-Object { $manifest -notcontains $_ })
    $want = $manifest.Count
    if ($Mutate -eq 'expectfiles') { $want = $manifest.Count + 1 }
    if ($missing.Count -eq 0 -and $extra.Count -eq 2 -and $landed.Count -eq ($want + 2)) {
        Ok ("all {0} manifest files landed, and nothing besides them but unins000.dat/unins000.exe" -f $manifest.Count)
    } else {
        Red ("install directory: expected the {0} manifest files + Inno's own 2, got {1} files, missing [{2}], unexpected [{3}]" -f `
            $want, $landed.Count, ($missing -join ', '), ($extra -join ', '))
    }

    $motw = @(Get-ChildItem -LiteralPath $app -Filter '*.ps1' -File | ForEach-Object {
        if (@(Get-Item -LiteralPath $_.FullName -Stream * -ErrorAction SilentlyContinue | ForEach-Object { $_.Stream }) -contains 'Zone.Identifier') { $_.Name } })
    if ($motw.Count -eq 0) { Ok 'no installed script carries Mark-of-the-Web - the zip path is the one that needs Unblock-File' }
    else { Red ("installed scripts still blocked: {0}" -f ($motw -join ', ')) }

    $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\KeepAwake'
    $wantLnk = @('KeepAwake - Dashboard.lnk', 'KeepAwake - Tray.lnk', 'KeepAwake - Protect.lnk', 'KeepAwake - Release.lnk', 'Uninstall KeepAwake.lnk') | Sort-Object
    $gotLnk = @(Get-ChildItem -LiteralPath $sm -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) | Sort-Object
    if (($gotLnk -join ',') -eq ($wantLnk -join ',')) { Ok 'Start Menu holds exactly the five shortcuts' }
    else { Red ("Start Menu: got [{0}]" -f ($gotLnk -join ', ')) }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (Test-Path -LiteralPath (Join-Path $desktop 'KeepAwake.lnk')) { Ok "the desktopicon task is checked by default - shortcut in $desktop" }
    else { Red 'no desktop shortcut although the desktopicon task was not unchecked, so README is wrong about the default' }

    $key = @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '{8B7C1F4E*' })
    if ($key.Count -eq 1) {
        $v = Get-ItemProperty -LiteralPath $key[0].PSPath
        if ($v.DisplayName -eq 'KeepAwake' -and [string]$v.DisplayVersion -eq $version -and $v.UninstallString -like ('*"' + $app + '\unins000.exe"')) {
            Ok ("Add/Remove Programs: {0} {1} under {2}" -f $v.DisplayName, $v.DisplayVersion, $key[0].PSChildName)
        } else {
            Red ("Add/Remove Programs entry says DisplayName={0} DisplayVersion={1} UninstallString={2}" -f $v.DisplayName, $v.DisplayVersion, $v.UninstallString)
        }
    } else { Red ("expected exactly 1 uninstall key, found {0}" -f $key.Count) }

    $tasksNow = @($taskFolder.GetTasks(0) | Where-Object { $_.Name -like 'KeepAwake*' } | ForEach-Object { $_.Name })
    if (($tasksNow | Sort-Object) -join ',' -eq ($tasksBefore | Sort-Object) -join ',') { Ok 'installing registered no scheduled task and removed none' }
    else { Red ("install changed the scheduled tasks: [{0}] -> [{1}]" -f ($tasksBefore -join ', '), ($tasksNow -join ', ')) }
    $newPorts = @(Compare-Object $portsBefore (Get-ListeningPorts) | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })
    if ($newPorts.Count -eq 0) { Ok 'a silent install opened no panel (skipifsilent holds)' }
    else { Red ("silent install started listening on: {0}" -f ($newPorts -join ', ')) }

    $env:KA_DATA = $hookData
    $st = Invoke-Ka $app 'status' (Join-Path $work 'status.txt') 'the installed ka.ps1 status'
    $out = $script:KaText
    $firstLine = (($out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($null -eq $st) { Red ("installed ka.ps1 status: {0}" -f $script:TimedOut) }
    elseif ($st -eq 0 -and $out -match 'Keep-Awake') { Ok "the installed copy answers status (exit 0, $(@(($out -split "`r?`n") | Where-Object { $_.Trim() }).Count) lines, first: $firstLine)" }
    else { Red ("installed ka.ps1 status: exit=$st first line=[$firstLine]") }

    if ($WithWorker) {
        Write-Output '--- protection up, so the hook has something to release ---'
        $st = Invoke-Ka $app 'start' '' 'the installed ka.ps1 start'
        $stateFile = Join-Path $hookData 'state.json'
        if (Test-Path -LiteralPath $stateFile) { $workerPid = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).pid }
        if ($null -eq $st) { Red ("ka.ps1 start: {0}" -f $script:TimedOut) }
        elseif ($st -eq 0 -and $workerPid -and @(Get-Process -Id $workerPid -ErrorAction SilentlyContinue).Count) {
            Ok "worker pid $workerPid is holding a power request from the installed copy"
        } else { Red ("ka.ps1 start from the installed copy: exit=$st worker pid=[$workerPid]") }
    }

    # ---------------------------------------------------------------- uninstall
    Write-Output '--- uninstall ---'
    $rc = Invoke-Quiet (Join-Path $app 'unins000.exe') ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + $uninstLog + '"') 'unins000.exe'
    if ($null -eq $rc) { Red ("unins000.exe: {0} - see {1}" -f $script:TimedOut, $uninstLog) }
    elseif ($rc -eq 0) { Ok 'uninstaller exit 0' } else { Red ("uninstaller exit {0} - see {1}" -f $rc, $uninstLog) }

    $ulog = @(Get-Content -LiteralPath $uninstLog -ErrorAction SilentlyContinue)
    $hookAt = @()
    $delAt = -1
    for ($i = 0; $i -lt $ulog.Count; $i++) {
        if ($ulog[$i] -match 'KeepAwake: ran "ka\.ps1 (\S+)"') { $hookAt += , @($i, $matches[1]) }
        elseif ($ulog[$i] -match 'KeepAwake: could not run') { $hookAt += , @($i, 'FAILED') }
        elseif ($delAt -lt 0 -and $ulog[$i] -match 'Deleting file:') { $delAt = $i }
    }
    $names = @($hookAt | ForEach-Object { $_[1] })
    $late = @($hookAt | Where-Object { $delAt -ge 0 -and $_[0] -gt $delAt }).Count
    if (($names -join ',') -eq 'stop-server,stop,unguard' -and $late -eq 0) {
        Ok 'the hook ran stop-server, stop, unguard in that order, all of it before the first deletion'
    } else {
        Red ("hook order/timing: ran [{0}], first deletion on line {1}, {2} hook line(s) after it" -f ($names -join ', '), $delAt, $late)
    }
    if ($hookAt.Count -ge 2) {
        try {
            $t0 = [datetime]::ParseExact((($ulog[$hookAt[0][0]]) -split '   ')[0], 'yyyy-MM-dd HH:mm:ss.fff', $null)
            $t1 = [datetime]::ParseExact((($ulog[$hookAt[-1][0]]) -split '   ')[0], 'yyyy-MM-dd HH:mm:ss.fff', $null)
            Write-Output ("  info the hook cost {0:N1}s of the uninstall before anything was deleted" -f ($t1 - $t0).TotalSeconds)
        } catch { Write-Output '  info could not read the hook timing out of the log' }
    }

    if ($WithWorker -and $workerPid) {
        $alive = @(Get-Process -Id $workerPid -ErrorAction SilentlyContinue)
        if ($alive.Count -eq 0) { Ok "the hook took the worker down with it (pid $workerPid is gone, its power request with it)" }
        else { Red ("worker pid $workerPid outlived the uninstall - it holds a power request with no script behind it") }
    }

    foreach ($what in @(@('install directory', $app), @('Start Menu folder', $sm), @('desktop shortcut', (Join-Path $desktop 'KeepAwake.lnk')))) {
        if (Wait-For { -not (Test-Path -LiteralPath $what[1]) } 20000) { Ok ("{0} removed" -f $what[0]) }
        else { Red ("{0} survived the uninstall: {1}" -f $what[0], $what[1]) }
    }
    $keyGone = Wait-For { @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '{8B7C1F4E*' }).Count -eq 0 } 20000
    if ($keyGone) { Ok 'Add/Remove Programs entry removed' } else { Red 'the uninstall key is still there' }
    $dataAfter = Get-DataFingerprint $dataRoot
    if ($dataAfter -eq $dataBefore) { Ok 'the real data directory was never touched - config, log and history survive an uninstall' }
    else {
        Red 'the real data directory changed, which PRIVACY.md says an uninstall must not do'
        Write-Output ('  before: ' + ($dataBefore -replace "`n", ' ; '))
        Write-Output ('  after : ' + ($dataAfter -replace "`n", ' ; '))
    }
}
finally {
    # ---------------------------------------------------------------- put the machine back
    Write-Output '--- restore what unguard is allowed to take ---'
    Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue
    if ($WithWorker -and $workerPid -and @(Get-Process -Id $workerPid -ErrorAction SilentlyContinue).Count) {
        Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
        Write-Output ("  cleanup killed the leftover worker pid {0}" -f $workerPid)
    }
    $back = 0
    foreach ($x in @(Get-ChildItem -LiteralPath $taskBackup -Filter '*.xml' -File)) {
        $n = [IO.Path]::GetFileNameWithoutExtension($x.Name)
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { continue }
        $xml = [IO.File]::ReadAllText($x.FullName)
        $null = Register-ScheduledTask -TaskName $n -Xml $xml -ErrorAction SilentlyContinue
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if (-not $t) { Red ("task {0} is gone and the backup would not re-register it - recover by hand from {1}" -f $n, $x.FullName); continue }
        if ($taskFolder.GetTask($n).Xml -eq $xml) { Ok ("re-registered {0} (state={1}), byte-identical to the export" -f $n, $t.State) }
        else { Red ("re-registered {0} but its definition differs from the export - compare with {1}" -f $n, $x.FullName) }
        $back++
    }
    Write-Output ("  info {0} task(s) had to be put back; root task count {1} -> {2}" -f $back, $rootCountBefore, @(Get-ScheduledTask -TaskPath '\').Count)
    Remove-Item -LiteralPath $hookData -Recurse -Force -ErrorAction SilentlyContinue
    # The precreate mutant leaves its install directory behind by design (Inno only removes a
    # directory it created), so the sweep here is what keeps %TEMP% clean. A -WorkDir the caller
    # named is not ours to delete.
    if ($app -like (Join-Path $env:TEMP 'ka-test-install-*')) {
        Remove-Item -LiteralPath $app -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output '-----------------------------------------------------------------------'
if ($bad.Count -eq 0) {
    Write-Output 'PROBE OK: the installer installs, the hook uninstalls, and the machine ends where it started'
    exit 0
}
Write-Output ("PROBE FAILED: {0} problem(s)" -f $bad.Count)
exit 1
