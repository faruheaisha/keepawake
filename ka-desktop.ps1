<# Native desktop bridge. All protection and configuration still go through ka-core. #>
[CmdletBinding()]
param(
    [ValidateSet('launch', 'state', 'start', 'stop', 'pause', 'resume', 'release', 'watch', 'automation-save', 'automation-tick', 'supply-save', 'diagnostic', 'save', 'report', 'log')]
    [string]$Action = 'launch',
    [string]$Request = '',
    [string]$DataDir = ''
)
if ($DataDir) { $env:KA_DATA = $DataDir }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
try {
    if ($Action -eq 'launch') {
        $exe = Join-Path $PSScriptRoot 'KeepAwake.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'desktop') -File -Recurse)
            $integration = Join-Path $PSScriptRoot 'integrations\mcp'
            if (Test-Path -LiteralPath $integration) { $sources += @(Get-ChildItem -LiteralPath $integration -File -Recurse) }
            $cliIntegration = Join-Path $PSScriptRoot 'integrations\cli'
            if (Test-Path -LiteralPath $cliIntegration) { $sources += @(Get-ChildItem -LiteralPath $cliIntegration -File -Recurse) }
            $fingerprint = (@($sources | Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '')
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint))).Replace('-', '').Substring(0, 16) }
            finally { $sha.Dispose() }
            $exe = Join-Path (Get-KaDataRoot) ('desktop\' + $hash + '\KeepAwake.exe')
            $buildLock = New-Object Threading.Mutex($false, (Get-KaMutexName 'KA-DesktopBuild'))
            try {
                try { if (-not $buildLock.WaitOne(60000)) { throw 'Desktop compilation is taking too long.' } } catch [Threading.AbandonedMutexException] { }
                try { if (-not (Test-Path -LiteralPath $exe)) { & (Join-Path $PSScriptRoot 'desktop\build.ps1') -OutputPath $exe } }
                finally { $buildLock.ReleaseMutex() }
            } finally { $buildLock.Dispose() }
        }
        Start-Process -FilePath $exe
        return
    }
    $inputObject = @{}
    if ($Request) {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Request)) | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) { $inputObject[$prop.Name] = $prop.Value }
    }
    $result = $null
    switch ($Action) {
        'supply-save' {
            if ($inputObject.limitMinutes -is [bool] -or "$($inputObject.limitMinutes)" -notmatch '^\d{1,4}$') { throw 'Invalid battery duration.' }
            Set-KaSupplyPolicy -Mode ([string]$inputObject.mode) -LimitMinutes ([int]$inputObject.limitMinutes)
            $result = Get-KaSupplyPolicy
        }
        'automation-save' { Set-KaAutomationConfig -Rules @($inputObject.rules); $result = Invoke-KaAutomationTick }
        'automation-tick' { $result = Invoke-KaAutomationTick }
        'start' {
            $minutes = [double]$inputObject.minutes
            if ([double]::IsNaN($minutes) -or [double]::IsInfinity($minutes) -or $minutes -lt 0 -or $minutes -gt 10080) { throw 'Duration must be between 0 and 10080 minutes.' }
            if ($inputObject.until) {
                $until = Get-KaMinutesUntil -Text ([string]$inputObject.until)
                if (-not $until.Ok) { throw $until.Reason }
                $minutes = $until.Minutes
                if ($minutes -gt 10080) { throw 'End time must be within seven days.' }
            }
            $override = @{}
            foreach ($key in @('keepDisplayOn', 'antiLock', 'antiLockMethod', 'antiLockIntervalSec', 'batteryFloorPercent')) {
                if ($inputObject.ContainsKey($key)) { $override[$key] = $inputObject[$key] }
            }
            $result = Start-KaProtection -Minutes $minutes -Override $override
            if (-not $result.Ok) { throw $result.Reason }
        }
        'stop' {
            $result = Stop-KaProtection -Reason 'desktop'
            if ([int]$result.Remaining -gt 0 -or $result.intentWritten -eq $false -or $result.leaseCancellationFailed) { throw 'Could not fully stop protection. Please retry.' }
        }
        'pause' {
            if (-not $script:KaLeaseAvailable) { throw 'Task protection is unavailable.' }
            $result = Invoke-KaLeasePause -Minutes 15
            if (-not $result.ok) { throw "Could not pause protection: $($result.reason)" }
        }
        'resume' {
            if (-not $script:KaLeaseAvailable) { throw 'Task protection is unavailable.' }
            $result = Invoke-KaLeaseResume
            if (-not $result.ok) { throw 'Could not resume protection.' }
        }
        'release' {
            if (-not $script:KaLeaseAvailable) { throw 'Task protection is unavailable.' }
            $result = Invoke-KaLeaseUserRelease -Id ([string]$inputObject.id)
            if (-not $result.ok) { throw "Could not release the task: $($result.reason)" }
        }
        'watch' {
            if (-not $script:KaLeaseAvailable) { throw 'Task protection is unavailable.' }
            $watchScript = Join-Path $PSScriptRoot 'integrations\cli\watch.ps1'
            if (-not (Test-Path -LiteralPath $watchScript)) { throw 'Process monitoring is unavailable.' }
            if ($inputObject.pid -isnot [ValueType] -or $inputObject.pid -is [bool] -or
                [double]$inputObject.pid -ne [math]::Floor([double]$inputObject.pid) -or [long]$inputObject.pid -lt 1 -or [long]$inputObject.pid -gt [int]::MaxValue) { throw 'Invalid process ID.' }
            foreach ($key in @('keepDisplayOn','antiLock')) {
                if ($inputObject.ContainsKey($key) -and $inputObject[$key] -isnot [bool]) { throw 'Invalid process options.' }
            }
            . $watchScript
            $result = Start-KaWatchedProcess -ProcessId ([int]$inputObject.pid) `
                -KeepDisplayOn ([bool]$inputObject.keepDisplayOn) -AntiLock ([bool]$inputObject.antiLock)
        }
        'diagnostic' { $result = Get-KaDiagnosticExport }
        'save' {
            $patch = @{}
            foreach ($key in @('keepDisplayOn', 'antiLock', 'antiLockMethod', 'antiLockIntervalSec', 'batteryFloorPercent', 'language')) {
                if ($inputObject.ContainsKey($key)) { $patch[$key] = $inputObject[$key] }
            }
            if (-not (Set-KaConfig -Patch $patch)) { throw 'Could not save configuration.' }
            if ($inputObject.ContainsKey('closeToTray') -or $inputObject.ContainsKey('hotkeyEnabled')) {
                $oldDesktop = Read-KaJson (Join-Path (Get-KaDataRoot) 'desktop.json')
                $desktopSettings = @{
                    closeToTray = if ($inputObject.ContainsKey('closeToTray')) { [bool]$inputObject.closeToTray } elseif ($null -ne $oldDesktop.closeToTray) { [bool]$oldDesktop.closeToTray } else { $true }
                    hotkeyEnabled = if ($inputObject.ContainsKey('hotkeyEnabled')) { [bool]$inputObject.hotkeyEnabled } else { [bool]$oldDesktop.hotkeyEnabled }
                }
                if (-not (Write-KaJson (Join-Path (Get-KaDataRoot) 'desktop.json') $desktopSettings)) {
                    throw 'Could not save desktop preferences.'
                }
            }
        }
        'report' { $result = Get-KaReport -Refresh }
        'log' {
            $path = (Get-KaPath).log
            $result = if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path -Tail 100) -join "`n" } else { '' }
        }
    }
    $state = Get-KaFullState -Quiet
    if ($Action -eq 'stop' -and $state.workerCount -gt 0) { throw 'The worker is still running. Please retry stopping protection.' }
    [ordered]@{ ok = $true; state = $state; result = $result; language = Get-KaUiLanguage;
        desktop = Read-KaJson (Join-Path (Get-KaDataRoot) 'desktop.json'); automation = Get-KaAutomationConfig; supplyPolicy = Get-KaSupplyPolicy } | ConvertTo-Json -Depth 12 -Compress
} catch {
    [ordered]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}
