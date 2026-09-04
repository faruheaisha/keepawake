param(
    [switch]$Child,
    [string]$Tmp = ''
)
$ErrorActionPreference = 'Stop'
<#
    WOW64 differential: what actually happens when somebody runs this tool from the 32-bit
    PowerShell that ships with Windows (C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe,
    what "powershell.exe" resolves to for any 32-bit parent, and what some third-party launchers
    still use). Nothing about this tool can be reasoned about safely on that question: file-system
    redirection rewrites System32 lookups to SysWOW64, the C# compiler that Add-Type uses is a
    different binary, sizeof(INPUT) changes, and a task action string written by a 32-bit process
    is later resolved by a 64-bit scheduler service.

    So the probe runs the same measurement twice, once per bitness, and requires the two answers
    to agree on everything that must not depend on bitness. A plain "it did not crash under WOW64"
    would be a vacuous pass: it would also print nothing if the child died at the first line.

    Child legs only read the machine plus one per-thread SetThreadExecutionState round trip, which
    dies with the probe process. Nothing is registered, nothing is written outside -Tmp.
#>
$root = Split-Path -Parent $PSScriptRoot
$wow = Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
$nat = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

function KaValue([scriptblock]$Body) {
    try { $v = & $Body
          if ($null -eq $v) { return '<null>' }
          return "$v" }
    catch { return '<err>' }
}

if ($Child) {
    $env:KA_DATA = $Tmp
    $env:KA_LANG = ''
    $out = [ordered]@{}
    $out['KA_BIT']       = KaValue { [int][Environment]::Is64BitProcess }
    $out['KA_PTR']       = KaValue { [IntPtr]::Size }
    $out['KA_PSVER']     = KaValue { "$($PSVersionTable.PSVersion)" }
    $out['KA_PSHOME']    = KaValue { $PSHome }
    $out['KA_NATIVE']    = KaValue { if ('Ka.Native' -as [type]) { 'loaded' } else { 'missing' } }

    . (Join-Path $root 'ka-core.ps1')

    $out['KA_NATIVE']    = KaValue { if ('Ka.Native' -as [type]) { 'loaded' } else { 'missing' } }
    $out['KA_LANG']      = KaValue { Resolve-KaLanguage }
    $out['KA_OS_LANGS']  = KaValue { (Get-KaOsUiLanguages) -join ',' }

    # powercfg is called by bare name everywhere in ka-core, so WOW64 file-system redirection
    # is exactly what decides whether it resolves at all. Where it comes from may legitimately
    # differ; that it resolves to a real binary and parses the same values may not.
    $out['KA_POWERCFG']      = KaValue { $src = (Get-Command powercfg -ErrorAction Stop).Source
                                         if (Test-Path -LiteralPath $src) { 'resolves-to-existing-exe' } else { 'MISSING-EXE' } }
    $pp = try { Get-PowerSetting -Subgroup 'SUB_SLEEP' -Setting 'STANDBYIDLE' } catch { @{} }
    $out['KA_STANDBY_AC']    = KaValue { $pp.Ac }
    $out['KA_STANDBY_DC']    = KaValue { $pp.Dc }
    $out['KA_STANDBY_FOUND'] = KaValue { $pp.Found }
    $out['KA_STANDBY_SOURCE']= KaValue { $pp.Source }
    $caps = try { Get-KaPowerCaps } catch { @{} }
    $out['KA_CAPS_SOURCE']   = KaValue { $caps.source }
    foreach ($k in 's3', 's4', 'aoAc', 'lidPresent', 'batteriesPresent') {
        $out["KA_CAPS_$k"] = KaValue { $caps.$k }
    }
    $ss = try { Get-KaSleepStates } catch { @{} }
    $out['KA_SS_KNOWN']     = KaValue { $ss.known }
    $out['KA_SS_S0']        = KaValue { $ss.s0 }
    $out['KA_SS_S3']        = KaValue { $ss.s3 }
    $out['KA_SS_MODERN']    = KaValue { $ss.modernStandby }
    $plan = try { Get-KaPlan } catch { @{} }
    $out['KA_PLAN_GUID']    = KaValue { $plan.guid }
    $out['KA_PLAN_NAME']    = KaValue { $plan.name }
    $bat = try { Get-KaBattery } catch { @{} }
    $out['KA_BAT_KNOWN']    = KaValue { $bat.known }
    $out['KA_IL']           = KaValue { [Ka.Native]::SelfIntegrityRid() }
    $out['KA_IDLE_GE0']     = KaValue { if ([double](Get-KaIdleSeconds) -ge 0) { 'yes' } else { 'no' } }
    # Per-thread, released two lines later and gone at process exit whatever happens.
    $prev = KaValue { [Ka.Native]::ApplyPowerRequest(1) }
    $out['KA_ES_APPLY']     = if ($prev -eq '<err>') { '<err>' } else { 'call-ok' }
    $out['KA_ES_CLEAR']     = KaValue { [void][Ka.Native]::ClearPowerRequest(); 'call-ok' }
    $out['KA_ES_CONT']    = KaValue { '0x' + ('{0:X8}' -f [uint32][Ka.Native]::ES_CONTINUOUS) }

    # The three read-only CLI surfaces a downloader actually types, run the way the tool runs
    # them: as a separate -File process under the same bitness as the caller.
    foreach ($cmd in 'status', 'check') {
        $p = Start-Process -FilePath (Join-Path $PSHome 'powershell.exe') -Wait -NoNewWindow -PassThru `
             -RedirectStandardOutput "$Tmp.$cmd.out" -RedirectStandardError "$Tmp.$cmd.err" `
             -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'ka.ps1') + '" ' + $cmd)
        $out["KA_EXIT_$cmd"] = KaValue { $p.ExitCode }
        $out["KA_ERRLEN_$cmd"] = KaValue { if (Test-Path -LiteralPath "$Tmp.$cmd.err") { ([IO.File]::ReadAllText("$Tmp.$cmd.err")).Trim().Length } else { 0 } }
        Remove-Item -LiteralPath "$Tmp.$cmd.out", "$Tmp.$cmd.err" -Force -ErrorAction SilentlyContinue
    }
    $rp = Start-Process -FilePath (Join-Path $PSHome 'powershell.exe') -Wait -NoNewWindow -PassThru `
         -RedirectStandardOutput "$Tmp.report.out" -RedirectStandardError "$Tmp.report.err" `
         -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'ka.ps1') + '" report -Json')
    $out['KA_EXIT_report'] = KaValue { $rp.ExitCode }
    $out['KA_REPORT_KEYS'] = KaValue {
        $t = [IO.File]::ReadAllText("$Tmp.report.out")
        $j = $t | ConvertFrom-Json
        (@($j.PSObject.Properties.Name) | Sort-Object) -join ','
    }
    $out['KA_REPORT_BITY'] = KaValue {
        $j = ([IO.File]::ReadAllText("$Tmp.report.out")) | ConvertFrom-Json
        "$($j.machine.s0ModernStandby)/$($j.machine.s3Available)/$($j.os)"
    }
    Remove-Item -LiteralPath "$Tmp.report.out", "$Tmp.report.err" -Force -ErrorAction SilentlyContinue

    foreach ($k in $out.Keys) { Write-Output ($k + '=' + $out[$k]) }
    exit 0
}

# ------------------------------------------------------------------ parent
if (-not (Test-Path -LiteralPath $wow)) {
    Write-Output 'PROBE SKIPPED: no WOW64 PowerShell on this machine - nothing was measured'
    exit 0
}
$tmp = Join-Path $env:TEMP ('ka-wow64-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force

function Run-Leg([string]$exe, [string]$tag) {
    $o = Join-Path $env:TEMP "ka-wow-$tag.out"
    $e = Join-Path $env:TEMP "ka-wow-$tag.err"
    try {
        $p = Start-Process -FilePath $exe -Wait -NoNewWindow -PassThru `
            -RedirectStandardOutput $o -RedirectStandardError $e `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Child -Tmp "' + $tmp + '"')
        $text = [IO.File]::ReadAllText($o)
        $errText = [IO.File]::ReadAllText($e)
        $map = @{}
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^KA_[A-Za-z0-9_]+=') {
                $map[$line.Substring(0, $line.IndexOf('='))] = $line.Substring($line.IndexOf('=') + 1)
            }
        }
        @{ Map = $map; Exit = $p.ExitCode; Err = $errText; Raw = $text }
    } finally { Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue }
}

$a = Run-Leg $nat '64'
$b = Run-Leg $wow '32'
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

$bad = @()
if ($a.Map.Count -lt 20) { $bad += "64-bit leg produced $($a.Map.Count) measurements - it died early: $($a.Err)" }
if ($b.Map.Count -lt 20) { $bad += "32-bit leg produced $($b.Map.Count) measurements - it died early: $($b.Err)" }
if ($a.Map['KA_BIT'] -ne '1') { $bad += "the baseline leg is not 64-bit (KA_BIT=$($a.Map['KA_BIT']))" }
if ($b.Map['KA_BIT'] -ne '0') { $bad += "the WOW64 leg is not 32-bit (KA_BIT=$($b.Map['KA_BIT'])) - the differential measured nothing" }
if ($b.Map['KA_PTR'] -ne '4') { $bad += "the WOW64 leg reports IntPtr.Size=$($b.Map['KA_PTR'])" }
Write-Output ('  legs: 64-bit ptr=' + $a.Map['KA_PTR'] + ' ps=' + $a.Map['KA_PSVER'] + ' | 32-bit ptr=' + $b.Map['KA_PTR'] + ' ps=' + $b.Map['KA_PSVER'])

# Keys whose value is allowed to differ because it *is* the bitness or the path it implies.
$diffOk = @('KA_BIT', 'KA_PTR', 'KA_PSHOME')
foreach ($k in $a.Map.Keys) {
    if ($diffOk -contains $k) { continue }
    if (-not $b.Map.ContainsKey($k)) { $bad += "32-bit leg never reported $k" ; continue }
    if ($a.Map[$k] -ne $b.Map[$k]) { $bad += "$k differs: 64-bit=[$($a.Map[$k])] 32-bit=[$($b.Map[$k])]" }
}
foreach ($k in 'KA_NATIVE', 'KA_CAPS_SOURCE', 'KA_POWERCFG', 'KA_STANDBY_FOUND', 'KA_PLAN_GUID', 'KA_IL') {
    if ($a.Map[$k] -eq '<err>') { $bad += "$k threw even in the 64-bit baseline leg - the probe cannot judge WOW64 from that" }
}
if ($a.Map['KA_NATIVE'] -ne 'loaded') { $bad += "Add-Type did not compile Ka.Native in the baseline leg ($($a.Map['KA_NATIVE']))" }
if ($a.Map['KA_POWERCFG'] -ne 'resolves-to-existing-exe') { $bad += "powercfg did not resolve in the baseline leg" }
if ($a.Map['KA_ES_APPLY'] -ne 'call-ok' -or $a.Map['KA_ES_CLEAR'] -ne 'call-ok') { $bad += 'SetThreadExecutionState round trip failed in the baseline leg' }
foreach ($c in 'status', 'check', 'report') {
    if ($a.Map["KA_EXIT_$c"] -ne $b.Map["KA_EXIT_$c"]) { $bad += "ka.ps1 $c exit code differs by bitness" }
}
if ($a.Map['KA_ERRLEN_status'] -ne '0' -or $a.Map['KA_ERRLEN_check'] -ne '0') { $bad += 'a CLI leg wrote to stderr in the baseline (an error record leaked to the console)' }

# The guard's task action is a literal System32 path string, and the 64-bit scheduler service is
# what resolves it later - so a task registered from a 32-bit run still launches 64-bit PowerShell.
$core = [IO.File]::ReadAllText((Join-Path $root 'ka-core.ps1'))
if ($core -notmatch "Join-Path \`$env:windir 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'") {
    $bad += 'Install-KaGuard no longer builds its task action from a literal System32 path - re-check what a WOW64 registration would store'
}
if (-not (Test-Path -LiteralPath $nat)) { $bad += "System32 powershell.exe is missing - the guard task would point at nothing" }

foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output ('PROBE OK: 32-bit and 64-bit PowerShell give ' + $a.Map.Count + ' identical answers; the guard action still names a real System32 binary')
