<# Build, move and open the standalone native executable; exercise the real bridge in an isolated data root. #>
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root ('_tmp\desktop-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $work
$previousData = $env:KA_DATA
$previousLanguage = $env:KA_LANG
$env:KA_DATA = Join-Path $work 'data'
$env:KA_LANG = 'zh'
$bridge = Join-Path $root 'ka-desktop.ps1'
function Assert-Desktop([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "  ok   $Message"
}
function Invoke-Desktop([string]$Action, [hashtable]$Body = @{}, [int]$Exit = 0) {
    $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $bridge + '" -Action ' + $Action + ' -Request ' + $request
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $proc = [Diagnostics.Process]::Start($info)
    try {
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(60000)) { $proc.Kill(); throw 'Bridge timed out' }
        if (-not $out.Wait(5000) -or -not $err.Wait(5000)) { throw 'Bridge output did not close after process exit' }
        if ($proc.ExitCode -ne $Exit) { throw "Bridge $Action exited $($proc.ExitCode): $($err.Result) $($out.Result)" }
        return ($out.Result | ConvertFrom-Json)
    } finally { $proc.Dispose() }
}
try {
    if (-not $Exe) {
        $Exe = Join-Path $work 'built\KeepAwake.exe'
        & (Join-Path $root 'desktop\build.ps1') -OutputPath $Exe
    }
    $single = Join-Path $work '单文件 app'
    $null = New-Item -ItemType Directory -Force -Path $single
    $portable = Join-Path $single 'KeepAwake.exe'
    Copy-Item -LiteralPath $Exe -Destination $portable
    $image = Join-Path $work 'preview.png'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $portable
    $info.Arguments = '--self-test "' + $image + '"'
    $info.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($info)
    try {
        # The full UI run performs three bounded engine calls plus dialog and rendering checks.
        if (-not $proc.WaitForExit(210000)) { $proc.Kill(); throw ('Native desktop timed out; inspect ' + $image + '.trace.txt') }
        Assert-Desktop ($proc.ExitCode -eq 0) 'standalone EXE opens, reads the engine, renders all pages and applies UI presets'
    } finally { $proc.Dispose() }
    Assert-Desktop ((Get-Item -LiteralPath $image).Length -gt 10000) 'the desktop screenshot contains a full window'
    Assert-Desktop (@(Get-ChildItem -LiteralPath $single -File).Count -eq 1) 'standalone execution writes nothing next to the EXE'
    $engine = @(Get-ChildItem -LiteralPath (Join-Path $env:KA_DATA 'app') -Filter 'ka-desktop.ps1' -Recurse -File)
    Assert-Desktop ($engine.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $engine[0].DirectoryName 'integrations\mcp\lease-store.ps1'))) 'standalone EXE includes its task protection engine'
    Assert-Desktop ((Test-Path -LiteralPath (Join-Path $engine[0].DirectoryName 'LICENSE')) -and (Test-Path -LiteralPath (Join-Path $engine[0].DirectoryName 'NOTICE'))) 'standalone EXE includes the license and copyright notice'
    $bridge = $engine[0].FullName
    $info.Arguments = ''
    $desktop = [Diagnostics.Process]::Start($info)
    try {
        if (-not $desktop.WaitForInputIdle(30000)) { throw 'The desktop message loop did not become ready' }
        $duplicate = [Diagnostics.Process]::Start($info)
        try {
            Assert-Desktop ($duplicate.WaitForExit(10000) -and $duplicate.ExitCode -eq 0 -and -not $desktop.HasExited) 'a second launch activates the existing desktop and exits'
        } finally { if (-not $duplicate.HasExited) { $duplicate.Kill() }; $duplicate.Dispose() }
        Copy-Item -LiteralPath (Join-Path $root 'panel.bat') -Destination $single
        $launcher = New-Object Diagnostics.ProcessStartInfo
        $launcher.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $launcher.Arguments = '/d /c ""' + (Join-Path $single 'panel.bat') + '""'
        $launcher.UseShellExecute = $false; $launcher.CreateNoWindow = $true
        $entry = [Diagnostics.Process]::Start($launcher)
        try {
            Assert-Desktop ($entry.WaitForExit(10000) -and $entry.ExitCode -eq 0 -and -not $desktop.HasExited) 'panel.bat opens the native desktop entry'
        } finally { $entry.Dispose() }
        $info.Arguments = '--shutdown'
        $closing = [Diagnostics.Process]::Start($info)
        try {
            Assert-Desktop ($closing.WaitForExit(30000) -and $closing.ExitCode -eq 0 -and $desktop.WaitForExit(5000)) 'installer shutdown closes the matching desktop without terminating unrelated processes'
        } finally { if (-not $closing.HasExited) { $closing.Kill() }; $closing.Dispose() }
    } finally { if (-not $desktop.HasExited) { $desktop.Kill() }; $desktop.Dispose() }
    $s = Invoke-Desktop 'state'
    Assert-Desktop ($s.ok -and -not $s.state.running -and $s.state.dataRoot -eq $env:KA_DATA) 'fresh state uses the isolated data root'
    $s = Invoke-Desktop 'save' @{ keepDisplayOn = $false; antiLock = $false; antiLockMethod = 'mouse'; antiLockIntervalSec = 90; language = 'zh'; closeToTray = $false }
    Assert-Desktop ($s.state.config.antiLockMethod -eq 'mouse' -and -not $s.desktop.closeToTray) 'engine and desktop preferences persist'
    $s = Invoke-Desktop 'start' @{ minutes = -1 } 1
    Assert-Desktop (-not $s.ok) 'invalid duration is rejected before starting a worker'
    $startClock = [Diagnostics.Stopwatch]::StartNew()
    $s = Invoke-Desktop 'start' @{ minutes = 2; keepDisplayOn = $false; antiLock = $false; antiLockMethod = 'key' }
    $startClock.Stop()
    Assert-Desktop ($s.state.running -and $s.state.worker.expiresEpoch -gt $s.state.nowEpoch) 'a real worker starts with a finite deadline'
    Assert-Desktop ($startClock.Elapsed.TotalSeconds -lt 60 -and $null -ne (Get-Process -Id ([int]$s.state.worker.pid) -ErrorAction SilentlyContinue)) 'the bridge returns while the worker is still alive'
    Assert-Desktop (-not $s.state.worker.keepDisplayOn -and -not $s.state.worker.antiLock -and $s.state.worker.antiLockMethod -eq 'key') 'session settings are applied without generating synthetic input'
    Assert-Desktop ($s.state.config.antiLockMethod -eq 'mouse') 'session overrides do not overwrite saved defaults'
    $s = Invoke-Desktop 'pause'
    Assert-Desktop ($s.state.leases.paused -and -not $s.state.running) 'pause releases the request and records a resumable session'
    $s = Invoke-Desktop 'resume'
    Assert-Desktop (-not $s.state.leases.paused -and $s.state.running) 'resume restores protection'
    $diagnostic = Invoke-Desktop 'diagnostic'
    $diagnosticJson = $diagnostic.result | ConvertTo-Json -Depth 12 -Compress
    Assert-Desktop ($diagnostic.ok -and $diagnostic.result.schemaVersion -eq 1 -and -not $diagnosticJson.Contains($env:KA_DATA)) 'desktop diagnostic export excludes the data path'
    $s = Invoke-Desktop 'stop'
    Assert-Desktop (-not $s.state.running -and $s.state.workerCount -eq 0 -and $s.state.intent.desired -eq 'off') 'stop releases the worker and records the stopped intent'
    $s = Invoke-Desktop 'log'
    Assert-Desktop ([string]$s.result -match 'STOP') 'activity reads actual engine logs'
    Write-Host "PROBE OK: native desktop and bridge; screenshot at $image"
} finally {
    try { $null = Invoke-Desktop 'stop' } catch { Write-Warning $_.Exception.Message }
    if ($null -eq $previousData) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $previousData }
    if ($null -eq $previousLanguage) { Remove-Item Env:KA_LANG -ErrorAction SilentlyContinue } else { $env:KA_LANG = $previousLanguage }
}
