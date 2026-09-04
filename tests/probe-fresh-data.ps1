# What does a *fresh download* actually do? Nothing ships a config.json any more (the
# defaults live in Get-KaDefaultConfig), so this asserts the first-run experience by
# assembling the same file list the release zip will carry, in a scratch directory, with an
# empty data root - and then watching which files appear. Watching beats reading the code,
# because the migration runs from a path nobody looks at (Initialize-KaDataRoot), and it
# copies whatever it finds beside the scripts.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot
$work = Join-Path $root '_tmp/fresh-run'   # scratch stays in the ignored _tmp, never beside the shipped tests
$fail = New-Object System.Collections.Generic.List[string]
function Bad([string]$m) { $script:fail.Add($m); Write-Output ('  FAIL ' + $m) }
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }

# The release manifest, shared with probe-motw.ps1 and with CI packaging.
. (Join-Path $root 'tests/ka-release-files.ps1')
$files = @(Get-KaReleaseFile)

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$prog = Join-Path $work 'program'
New-Item -ItemType Directory -Force -Path $prog | Out-Null
foreach ($f in $files) {
    $src = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $src)) { Bad "the shipped list names $f but the tree does not have it"; continue }
    $dst = Join-Path $prog $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
# A zip carries no runtime state. If one of these ever appears beside the scripts, the
# release is shipping somebody's machine - so say it here rather than in a bug report.
foreach ($n in @('config.json', 'intent.json', 'state.json', 'machine.json', 'ka.log', '.migrated.json')) {
    if (Test-Path -LiteralPath (Join-Path $prog $n)) { Bad ('the zip would carry ' + $n) }
}
$topLevel = @($files | Where-Object { $_ -notlike '*\*' })
$progFiles = @(Get-ChildItem -LiteralPath $prog -File -Force | ForEach-Object { $_.Name })
if ($progFiles.Count -ne $topLevel.Count) {
    Bad ('the program directory has ' + $progFiles.Count + ' files but the shipped list names ' + $topLevel.Count)
} else {
    Ok ("assembled a clean program directory: $($progFiles.Count) top-level files")
}

$data = Join-Path $work 'data'
New-Item -ItemType Directory -Force -Path $data | Out-Null

function Invoke-Ka([string[]]$Cmd) {
    # A fresh powershell.exe per command: the library caches $script:KaDataRoot the first
    # time it resolves it, so two in-process commands would report each other's files.
    $prev = $env:KA_DATA
    $env:KA_DATA = $data
    try {
        $txt = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $prog 'ka.ps1') @Cmd 2>&1 |
               ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    }
    return @{ code = $code; text = ($txt -join "`n") }
}
function Data-Names {
    @(Get-ChildItem -LiteralPath $data -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) | Sort-Object
}

Write-Output '--- 1. the first command on a machine with nothing configured'
$r = Invoke-Ka @('config')
if ($r.code -ne 0) { Bad "config exit=$($r.code): $($r.text.Substring(0, [Math]::Min(200, $r.text.Length)))" }
else { Ok 'config exit=0 with no config.json anywhere' }
if ($r.text -notmatch '8791') { Bad 'the default port 8791 was not reported' } else { Ok 'defaults are the documented ones (port 8791)' }
if ($r.text -notmatch 'auto') { Bad 'language does not default to auto' } else { Ok 'language defaults to auto (a German downloader is not forced into Chinese)' }
$now = Data-Names
if ($now.Count -ne 0) { Bad ('a read-only command created ' + ($now -join ', ')) } else { Ok 'a first read created no files at all' }

Write-Output '--- 2. the read-only commands, one fresh process each'
foreach ($a in @('status', 'report', 'evidence', 'log', 'check')) {
    $before = Data-Names
    $r = Invoke-Ka @($a)
    $new = @(Data-Names | Where-Object { $before -notcontains $_ })
    $allowed = @()
    if ($a -eq 'check') { $allowed = @('machine.json') }
    $bad = @($new | Where-Object { $allowed -notcontains $_ })
    if ($r.code -ne 0) { Bad "$a exit=$($r.code) on a virgin install" }
    if ($bad.Count) { Bad "$a wrote $(($bad -join ', ')) - a read command must not write" }
    if (-not $bad) { Ok (('{0}: exit=0, wrote {1}' -f $a, $(if ($new.Count) { ($new -join ', ') } else { 'nothing' }))) }
}

Write-Output '--- 3. an explicit write records intent, not a copy of every default'
$before = Data-Names
$r = Invoke-Ka @('config', '-Set', 'port=8799')
$new = @(Data-Names | Where-Object { $before -notcontains $_ })
if ($r.code -ne 0) { Bad "config -Set exit=$($r.code): $($r.text.Substring(0, [Math]::Min(200, $r.text.Length)))" }
if ($new -notcontains 'config.json') { Bad ('config -Set wrote ' + $(if ($new.Count) { ($new -join ', ') } else { 'nothing' })) }
else { Ok 'config -Set creates config.json on demand' }
$cfg = [IO.File]::ReadAllText((Join-Path $data 'config.json'))
if ($cfg -notmatch '"port"\s*:\s*8799') { Bad 'the file does not carry the port that was asked for' } else { Ok 'the file carries what was asked' }
if ($cfg -match 'antiLockIntervalSec|awayMode|batteryFloorPercent') { Bad ("the file copied every default: " + $cfg.Trim()) }
else { Ok 'the file holds only the key that was chosen, so a later release can move a default' }
if ($cfg[0] -eq [char]0xFEFF) { Bad 'config.json was written with a BOM' } else { Ok 'config.json is BOM-free' }
if ((Invoke-Ka @('config')).text -notmatch '8799') { Bad 'the saved config.json is not read back' } else { Ok 'the saved config.json is read back' }

Write-Output '--- 4. a hand-mangled config.json must not brick the tool'
[IO.File]::WriteAllText((Join-Path $data 'config.json'),
    '{"port": "not-a-number", "language": "de", "keepDisplayOn": "false", "antiLock": "off"}',
    (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Ka @('config', '-Json')
if ($r.code -ne 0) { Bad "config -Json exit=$($r.code) on a mangled file" }
$o = $null
try { $o = $r.text | ConvertFrom-Json } catch { Bad "config -Json stopped returning JSON: $($r.text.Substring(0, [Math]::Min(160, $r.text.Length)))" }
if ($o) {
    if ([int]$o.port -ne 8791) { Bad "an unparsable port became $($o.port) instead of the default" } else { Ok 'an unparsable port falls back, it does not clamp to the minimum' }
    if ("$($o.language)" -ne 'auto') { Bad "an out-of-enum language became '$($o.language)' instead of auto" } else { Ok 'an out-of-enum language falls back to auto on read' }
    if ([bool]$o.keepDisplayOn) { Bad '"false" as a string still reads as True - the display would be held on' } else { Ok '"false" written as a string means off' }
    if ([bool]$o.antiLock) { Bad '"off" as a string still reads as True - the fake keystrokes would keep coming' } else { Ok '"off" written as a string means off' }
}

Write-Output '--- 5. every surface shows the one version number'
$vl = (Get-Content -LiteralPath (Join-Path $root 'ka-core.ps1')) |
      Where-Object { $_ -like '*KaVersion*' -and $_ -like "*'*" } | Select-Object -First 1
$ver = ($vl -split "'")[1]
if ($ver -notmatch '^\d+\.\d+\.\d+$') { Bad "cannot read a version out of ka-core.ps1 (line was: $vl)" } else { Ok "ka-core.ps1 declares $ver" }
$r = Invoke-Ka @('status', '-Json')
$o = $null
try { $o = $r.text | ConvertFrom-Json } catch { Bad "status -Json is not parsable: $($_.Exception.Message)" }
if ($o -and "$($o.version)" -ne $ver) { Bad "status -Json says version=$($o.version) but ka-core.ps1 says $ver" }
elseif ($o) { Ok "the /api/state surface (status -Json) says the same version: $ver" }

Write-Output '--- 6. nothing landed next to the scripts'
$after = @(Get-ChildItem -LiteralPath $prog -File -Force | ForEach-Object { $_.Name }) | Sort-Object
$leaked = @($after | Where-Object { $topLevel -notcontains $_ })
if ($leaked.Count) { Bad ('the program directory gained ' + ($leaked -join ', ')) } else { Ok 'the program directory still holds exactly the shipped files' }

Write-Output '--- cleanup'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
if ($fail.Count) {
    Write-Output ('PROBE FAILED: ' + $fail.Count + ' assertion(s)')
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output 'PROBE OK: a fresh download runs, writes only what it is told to, survives a hand-mangled config.json, and shows one version'
