# The first-run migration copies the files that used to live beside the scripts into the
# data root. It ran with Copy-Item -Force, which means a brand-new clone could overwrite a
# config.json the user had already edited in %LOCALAPPDATA%\KeepAwake. This probe is the
# measurement that decides whether that is real: four scenarios, and the whole tool is
# copied to a scratch program directory first so the install on this machine is never touched.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot
$work = Join-Path $root '_tmp/migrate-run'   # scratch stays in the ignored _tmp, never beside the shipped tests
$fail = New-Object System.Collections.Generic.List[string]
function Bad([string]$m) { $script:fail.Add($m); Write-Output ('  FAIL ' + $m) }
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }

$files = @('ka.ps1', 'ka-core.ps1', 'ka-gate.ps1', 'ka-worker.ps1', 'ka-server.ps1',
           'ka-guard.ps1', 'ka-lid.ps1', 'ka-tray.ps1',
           'dashboard\index.html', 'dashboard\app.js', 'dashboard\styles.css', 'dashboard\i18n.js')

function Write-Json([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-Program([string]$Config) {
    $dir = Join-Path $work 'program'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $files) {
        $src = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $src)) { throw "source tree is missing $f - the list above is stale" }
        $dst = Join-Path $dir $f
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    if ($Config) { Write-Json (Join-Path $dir 'config.json') $Config }
    return $dir
}

function New-Data([string]$Name, [string]$Config) {
    $dir = Join-Path $work ('data-' + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($Config) { Write-Json (Join-Path $dir 'config.json') $Config }
    return $dir
}

function Read-Port([string]$Program, [string]$Data) {
    $prev = $env:KA_DATA
    $env:KA_DATA = $Data
    try {
        $txt = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Program 'ka.ps1') config -Json 2>&1 |
               ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    }
    if ($code -ne 0) { throw "ka.ps1 config exited $code : $(($txt | Select-Object -First 3) -join ' / ')" }
    $o = ($txt -join "`n") | ConvertFrom-Json
    return [int]$o.port
}

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

Write-Output '--- A. the clobber case: an edited config.json in the data root, a stale one beside the scripts'
$prog = New-Program '{"port": 8791, "language": "zh"}'
$data = New-Data 'a' '{"port": 9999, "language": "en"}'
$port = Read-Port $prog $data
$after = [IO.File]::ReadAllText((Join-Path $data 'config.json'))
if ($port -ne 9999) { Bad "the user's own config.json now reports port=$port - first run replaced it with the one beside the scripts" }
else { Ok 'the data-root config.json survived the first run' }
if ($after -notmatch '9999') { Bad ('data-root config.json on disk was overwritten: ' + $after.Trim()) }
else { Ok 'the bytes on disk are still what the user wrote' }
if (-not (Test-Path -LiteralPath (Join-Path $prog 'config.json'))) { Bad 'migration moved (not copied) the program-dir file' }
else { Ok 'the old copy beside the scripts is still there' }

Write-Output '--- B. the case migration exists for: an old beside-the-scripts install, empty data root'
$prog2 = New-Program '{"port": 8791, "language": "zh"}'
$data2 = New-Data 'b' $null
$port2 = Read-Port $prog2 $data2
if ($port2 -ne 8791) { Bad "nothing was migrated: the fresh data root reports port=$port2 instead of the old file's 8791" }
else { Ok 'an old install still migrates into an empty data root' }
if (-not (Test-Path -LiteralPath (Join-Path $data2 '.migrated.json'))) { Bad 'no marker written' } else { Ok 'marker written' }
$mk = Get-Content -LiteralPath (Join-Path $data2 '.migrated.json') -Raw | ConvertFrom-Json
if ($mk.copied -notcontains 'config.json') { Bad ('marker does not name config.json: ' + ($mk.copied -join ',')) }
else { Ok ('marker records copied=' + ($mk.copied -join ',')) }

Write-Output '--- C. idempotence: the marker must stop a second run from touching anything'
Write-Json (Join-Path $prog2 'config.json') '{"port": 7777, "language": "zh"}'
$port3 = Read-Port $prog2 $data2
if ($port3 -ne 8791) { Bad "a second run re-migrated and the answer changed to $port3" }
else { Ok 'second run leaves the migrated config alone' }

Write-Output '--- D. a partially-populated data root: keep what is there, take what is missing'
$prog4 = New-Program '{"port": 8791}'
$data4 = New-Data 'd' '{"port": 9999}'
Write-Json (Join-Path $prog4 'intent.json') '{"desired": "awake", "minutes": 45}'
$null = Read-Port $prog4 $data4
if ((Read-Port $prog4 $data4) -ne 9999) { Bad 'the existing config.json lost to the program-dir one' }
else { Ok 'the existing config.json wins, as it must' }
$intent = Join-Path $data4 'intent.json'
if (-not (Test-Path -LiteralPath $intent)) { Bad 'the missing intent.json was not migrated - the watchdog cannot reconcile an intent it never got' }
else { Ok 'the missing intent.json was migrated' }
$mk4 = Get-Content -LiteralPath (Join-Path $data4 '.migrated.json') -Raw | ConvertFrom-Json
if ($mk4.skipped -notcontains 'config.json') { Bad ('the marker hides the skip: copied=' + ($mk4.copied -join ',') + ' skipped=' + ($mk4.skipped -join ',')) }
else { Ok ('marker says skipped=' + ($mk4.skipped -join ',') + ' copied=' + ($mk4.copied -join ',')) }

Write-Output '--- cleanup'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
if ($fail.Count) {
    Write-Output ('PROBE FAILED: ' + $fail.Count + ' assertion(s)')
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output 'PROBE OK: migration brings an old install forward without ever replacing a file the data root already has'
