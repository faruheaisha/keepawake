# Reading a hand-edited config.json through a [bool] cast is a trap: in PowerShell every
# non-empty string is True, so "keepDisplayOn": "false" - the edit a person is most likely
# to make after reading a forum post - turns the screen *on*. This probe pins the
# vocabulary: real booleans and numbers pass through, a documented set of words means what
# it says in English and Chinese, and anything else falls back to the key's default instead
# of silently choosing a behaviour.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot
$work = Join-Path $root '_tmp/bool-data'   # scratch stays in the ignored _tmp, never beside the shipped tests
$fail = New-Object System.Collections.Generic.List[string]
function Bad([string]$m) { $script:fail.Add($m); Write-Output ('  FAIL ' + $m) }
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }

# key, value-as-written-in-json, expected effective value, why
$cases = @(
    @{ k = 'keepDisplayOn';          v = 'false'; want = $false; note = 'control: a real JSON false must read as off' }
    @{ k = 'keepDisplayOn';          v = '"false"'; want = $false; note = 'the quoted edit from a forum post' }
    @{ k = 'keepDisplayOn';          v = '"FALSE"'; want = $false; note = 'case must not matter' }
    @{ k = 'keepDisplayOn';          v = ' "off" '; want = $false; note = 'off means off, and spaces are not part of the value' }
    @{ k = 'keepDisplayOn';          v = '"no"';    want = $false; note = 'no means off' }
    @{ k = 'keepDisplayOn';          v = '"0"';     want = $false; note = 'a string zero is still zero' }
    @{ k = 'antiLock';               v = '"false"'; want = $false; note = 'asking for no fake keystrokes must stop them' }
    @{ k = 'batteryAllowDisplayOff'; v = '"false"'; want = $false; note = 'the battery floor must be honourable from the file' }
    @{ k = 'awayMode';               v = '"true"';  want = $true;  note = 'a quoted true still means on' }
    @{ k = 'awayMode';               v = '"on"';    want = $true;  note = 'on means on' }
    @{ k = 'awayMode';               v = '"是"';    want = $true;  note = 'a Chinese config.json is written by Chinese users' }
    @{ k = 'keepDisplayOn';          v = '1';       want = $true;  note = 'number one is on' }
    @{ k = 'keepDisplayOn';          v = '0';       want = $false; note = 'number zero is off' }
    @{ k = 'awayMode';               v = '"随便"';  want = $false; note = 'gibberish falls back to this key default (off)' }
    @{ k = 'keepDisplayOn';          v = 'null';    want = $true;  note = 'null falls back to this key default (on)' }
)
$defaults = @{ keepDisplayOn = $true; antiLock = $true; awayMode = $false; batteryAllowDisplayOff = $true }

function Read-Cfg([string]$Json) {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    [IO.File]::WriteAllText((Join-Path $work 'config.json'), $Json, (New-Object System.Text.UTF8Encoding($false)))
    $prev = $env:KA_DATA
    $env:KA_DATA = $work
    try {
        $txt = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ka.ps1') config -Json 2>&1 |
               ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    }
    $o = $null
    try { $o = ($txt -join "`n") | ConvertFrom-Json } catch { }
    return @{ code = $code; obj = $o; text = ($txt -join "`n") }
}

Write-Output '--- each value goes through a fresh process and a fresh data directory'
foreach ($c in $cases) {
    $json = '{ "' + $c.k + '": ' + $c.v + ' }'
    $r = Read-Cfg $json
    if ($r.code -ne 0) { Bad "$json exited $($r.code): $($r.text.Substring(0, [Math]::Min(120, $r.text.Length)))"; continue }
    if (-not $r.obj) { Bad "$json did not produce parsable config output"; continue }
    $got = [bool]$r.obj.($c.k)
    if ($got -ne $c.want) {
        Bad ("{0,-38} -> {1,-6} want {2}  ({3})" -f $json, $got, $c.want, $c.note)
    } else {
        Ok  ("{0,-38} -> {1,-6} {2}" -f $json, $got, $c.note)
    }
}

Write-Output '--- and the key must not leak into another key'
$r = Read-Cfg '{ "keepDisplayOn": "false" }'
if ($r.obj.antiLock -ne $defaults.antiLock) { Bad "keepDisplayOn leaked into antiLock ($($r.obj.antiLock))" }
else { Ok 'one bad value changed one key' }
if ($r.obj.port -ne 8791) { Bad "the untouched keys are not the defaults (port=$($r.obj.port))" } else { Ok 'untouched keys stay at their defaults' }

Write-Output '--- the write path: accepted words become booleans, everything else is refused'
function Invoke-Set([string[]]$Pairs) {
    $prev = $env:KA_DATA
    $env:KA_DATA = $work
    try {
        $txt = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'ka.ps1') config @Pairs 2>&1 |
               ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    }
    return @{ code = $code; text = ($txt -join "`n") }
}
foreach ($pair in @(@('keepDisplayOn=off', $false), @('awayMode=是', $true), @('antiLock=no', $false))) {
    $null = Read-Cfg '{}'                       # a fresh, empty data root to write into
    $r = Invoke-Set @('-Set', $pair[0])
    if ($r.code -ne 0) { Bad "$($pair[0]) exited $($r.code): $($r.text.Substring(0, [Math]::Min(140, $r.text.Length)))" }
    else {
        $onDisk = [IO.File]::ReadAllText((Join-Path $work 'config.json'))
        $key = ($pair[0] -split '=')[0]
        if ($onDisk -notmatch ('"' + $key + '"\s*:\s*' + $(if ($pair[1]) { 'true' } else { 'false' }))) {
            Bad "$($pair[0]) was stored as text rather than a boolean: $($onDisk.Trim())"
        } else { Ok "$($pair[0]) stored as a real boolean" }
    }
}
$null = Read-Cfg '{ "port": 8791 }'
$hash = (Get-FileHash -LiteralPath (Join-Path $work 'config.json')).Hash
$r = Invoke-Set @('-Set', 'keepDisplayOn=随便')
if ($r.code -eq 0) { Bad 'a value outside the vocabulary was accepted by the write path' }
else { Ok 'a value outside the vocabulary is refused' }
if ($r.text -notmatch 'keepDisplayOn') { Bad 'the refusal does not name the key' } else { Ok 'the refusal names the key' }
if ($r.text -notmatch 'true \| false') { Bad ('the refusal does not list what is accepted: ' + $r.text.Substring(0, [Math]::Min(160, $r.text.Length))) }
else { Ok 'the refusal lists what it accepts' }
if ((Get-FileHash -LiteralPath (Join-Path $work 'config.json')).Hash -ne $hash) { Bad 'the refused write still changed config.json' }
else { Ok 'the refused write left config.json alone' }

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
if ($fail.Count) {
    Write-Output ('PROBE FAILED: ' + $fail.Count + ' assertion(s)')
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output 'PROBE OK: a hand-edited config.json means what the person who edited it wrote'
