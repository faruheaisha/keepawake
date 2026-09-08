param([string]$Culture, [switch]$Child)
<#
    Does this tool leak a localized number or date into anything a machine has to read back?

    Parent mode loops cultures; child mode sets the thread culture, dot-sources ka-core.ps1 and
    prints every string the tool can produce. The same child text runs for all cultures, so a
    difference is the culture's doing.

    Cultures chosen for the specific hazards, not for coverage:
      de-DE / fr-FR  decimal comma, '.' is the group separator (so "1755.0" stops parsing)
      th-TH          Buddhist calendar: 2026 renders as 2569 through a yyyy custom format
      ar-SA / he-IL  non-ASCII digit substitution
      zh-CN          the authored language, as the control

    Only machine-readable channels are asserted, plus one anti-vacuity rule: two cultures whose
    display output comes out identical means the culture never applied and the leg proves nothing.
#>
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Child) {
    $cultures = @('en-US', 'de-DE', 'fr-FR', 'th-TH', 'ar-SA', 'he-IL', 'zh-CN')
    $rows = @{}
    foreach ($c in $cultures) {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Culture $c -Child 2>&1 |
               ForEach-Object { "$_" }
        $map = @{}
        foreach ($l in $out) { if ($l -match '^KA_([A-Z0-9_]+)=(.*)$') { $map[$matches[1]] = $matches[2] } }
        $map['_exit'] = "$LASTEXITCODE"
        $map['_raw'] = ($out -join "`n")
        $rows[$c] = $map
    }
    $bad = 0
    # The three product expressions this whole measurement is about, checked in the source: a
    # revert at any of them leaves every dynamic leg above still green, which is exactly how a
    # fixed bug comes back.
    $lidSrc  = [IO.File]::ReadAllText((Join-Path $root 'ka-lid.ps1'))
    $coreSrc = [IO.File]::ReadAllText((Join-Path $root 'ka-core.ps1'))
    if ($lidSrc -notmatch "capturedAt = \(Get-Date -Format 'o'\)") {
        Write-Host '  FAIL ka-lid.ps1 no longer writes an offset-bearing capturedAt'; $bad++ }
    if ($coreSrc -notmatch 'capturedAt\)[^,]*,\s*\[Globalization\.CultureInfo\]::InvariantCulture') {
        Write-Host '  FAIL ka-core.ps1 parses capturedAt with the ambient culture again'; $bad++ }
    if ($coreSrc -notmatch "ToString\('yyyy-MM-dd HH:mm:ss', \[Globalization\.CultureInfo\]::InvariantCulture\)") {
        Write-Host '  FAIL Add-KaLog stamps with the ambient culture again (Get-KaEvidence reads it invariantly)'; $bad++ }
    foreach ($c in $cultures) {
        $m = $rows[$c]
        $problems = @()
        if ($m['_exit'] -ne '0') { $problems += "child exit=$($m['_exit'])" }
        if (-not $m['THREAD_CULTURE']) { $problems += 'child printed nothing - it died early' }
        elseif ($m['THREAD_CULTURE'] -ne $c) { $problems += "culture did not apply (thread=$($m['THREAD_CULTURE']))" }
        foreach ($k in @('LEAK_DECIMAL', 'LEAK_FILE')) {
            if ($m[$k] -and $m[$k] -ne '0') { $problems += "$k=$($m[$k])" }
        }
        # Both sentinels must say Unknown and nothing else may: that is the parse path working.
        if ($m['PARSE_UNKNOWN'] -ne '2') { $problems += "PARSE_UNKNOWN=$($m['PARSE_UNKNOWN']) want 2" }
        if ($m['JSON_ROUNDTRIP'] -ne 'ok') { $problems += "JSON_ROUNDTRIP=$($m['JSON_ROUNDTRIP'])" }
        foreach ($k in @('LOG_STAMP_DELTA', 'LIDSTAMP_DELTA')) {
            $d = $m[$k]
            if (-not $d) { $problems += "$k missing" }
            elseif ($d -notmatch '^-?\d+$') { $problems += "$k=$d is not a number" }
            elseif ([long]$d -lt 0 -or [long]$d -gt 300) { $problems += "$k=$d seconds off (writer and reader disagree)" }
        }
        if ($m['MINUTES_OK'] -ne 'True') { $problems += "Get-KaMinutesUntil failed ($($m['MINUTES_ERR']))" }
        if ($m['DURATION_DOTSTRING'] -notlike '*29*') { $problems += "1755.0 as a string read as [$($m['DURATION_DOTSTRING'])]" }
        if ($m['OFFSET_STABLE'] -ne 'ok') { $problems += "OFFSET_STABLE=$($m['OFFSET_STABLE'])" }
        foreach ($p in $problems) { Write-Host ('  FAIL {0,-7} {1}' -f $c, $p); $bad++ }
        if (-not $problems) {
            Write-Host ('  ok   {0,-7} decSep={1,-2} cal={2,-14} "5400s"={3,-9} 1755.0="{4}"' -f
                        $c, $m['DEC_SEP'], $m['CALENDAR'], ('"' + $m['SAMPLE_HOURS'] + '"'), $m['DURATION_DOTSTRING'])
        }
    }
    # Anti-vacuity: if no culture changed any display string, every assertion above was decoration.
    if ($rows['en-US']['SAMPLE_HOURS'] -eq $rows['de-DE']['SAMPLE_HOURS']) {
        Write-Output 'PROBE FAILED: en-US and de-DE rendered identically - the culture never reached the formatter'
        exit 1
    }
    if ($bad) { Write-Output "PROBE FAILED: $bad problem(s)"; exit 1 }
    Write-Output ('PROBE OK: machine-readable output holds across ' + $cultures.Count + ' cultures; only display strings localise')
    exit 0
}

# ------------------------------------------------------------------ child mode
try { [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo $Culture } catch { }
try { [Threading.Thread]::CurrentThread.CurrentUICulture = New-Object Globalization.CultureInfo $Culture } catch { }
$tc = [Threading.Thread]::CurrentThread.CurrentCulture
Write-Output ('KA_THREAD_CULTURE=' + $tc.Name)
Write-Output ('KA_DEC_SEP=' + $tc.NumberFormat.NumberDecimalSeparator)
Write-Output ('KA_DIGITS=' + $tc.NumberFormat.DigitSubstitution)
Write-Output ('KA_CALENDAR=' + $tc.Calendar.GetType().Name)

$env:KA_LANG = 'en'          # one language, so only the culture can change anything
$env:KA_DATA = Join-Path $root ('_tmp/culture-data-' + $Culture)   # scratch stays in the ignored _tmp
if (Test-Path -LiteralPath $env:KA_DATA) { Remove-Item -LiteralPath $env:KA_DATA -Recurse -Force }
New-Item -ItemType Directory -Force -Path $env:KA_DATA | Out-Null
. (Join-Path $root 'ka-core.ps1')

# --- display side: recorded, not asserted
Write-Output ('KA_SAMPLE_SECONDS=' + (Format-KaSeconds 90))
Write-Output ('KA_SAMPLE_HOURS=' + (Format-KaSeconds 5400))
Write-Output ('KA_TASKRESULT_0=' + (Format-KaTaskResult -Value 0))
Write-Output ('KA_DURATION_DOTSTRING=' + (Format-KaDuration '1755.0'))

# --- the parse path: -1 and $null are the two failure sentinels, and both must say Unknown
$unknown = 0
foreach ($v in @('-1', $null)) {
    $t = Format-KaDuration $v
    if ($t -like '*nknown*') { $unknown++ } else { Write-Output ('KA_SENTINEL_READS=' + $t) }
}
Write-Output ('KA_PARSE_UNKNOWN=' + $unknown)

# --- dates: what the platform does with a custom format. Recorded, not asserted: a Thai user
# reading a display timestamp in Buddhist year is correct localisation. What must not happen is
# one of these strings crossing a process boundary, which is what the log/lid deltas below check.
$dt = [DateTime]::new(2026, 5, 6, 7, 8, 9)
foreach ($fmt in @('yyyy-MM-dd HH:mm:ss', 'o')) {
    Write-Output ('KA_DATE_' + ($fmt -replace '[^A-Za-z]', '') + '=' + $dt.ToString($fmt))
}

# --- files this tool writes and reads back
$paths = Get-KaPath
$null = Write-KaJson $paths.state ([hashtable]@{ epoch = 1755000000; idleSec = 1755.5; percent = 99; tag = 'probe' })
$saved = Read-KaJson $paths.state
Write-Output ('KA_JSON_ROUNDTRIP=' + $(if ($saved -and [double]$saved.idleSec -eq 1755.5 -and [long]$saved.epoch -eq 1755000000) { 'ok' } else { 'MISMATCH' }))
Add-KaLog 'CULTURE-PROBE line'
# The writer/reader pair that broke before the fix: the log line above is read back by
# Get-KaEvidence with ParseExact under InvariantCulture. If the stamp came out in the current
# culture's calendar or digits, that parse yields a year 543 ahead (or fails) and the evidence
# timeline silently stops meaning anything.
$stampDelta = -1
$last = @(Get-Content -LiteralPath $paths.log -Encoding UTF8 | Where-Object { $_ -like '*CULTURE-PROBE line*' })[-1]
if ($last -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s') {
    try {
        $dt = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        $stampDelta = [Math]::Abs([DateTimeOffset]::new($dt).ToUnixTimeSeconds() - [DateTimeOffset]::Now.ToUnixTimeSeconds())
    } catch { $stampDelta = -2 }
} else { $stampDelta = -3 }
Write-Output ('KA_LOG_STAMP_DELTA=' + $stampDelta)

# The lid-backup stamp: written by whatever account ran an elevated apply and read back by the
# next ordinary run. It has to carry its UTC offset, or the same text means two different
# instants depending on what the reader assumed.
$written = (Get-Date -Format 'o')
$lidDelta = [Math]::Abs([DateTimeOffset]::Parse($written, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() -
                        [DateTimeOffset]::Now.ToUnixTimeSeconds())
Write-Output ('KA_LIDSTAMP_DELTA=' + $lidDelta)
$inv = [Globalization.CultureInfo]::InvariantCulture
# One sample, two parse strategies. Two independent Get-Date calls can straddle a second
# boundary on a loaded machine and read as an offset mismatch that does not exist - measured
# once on a CI runner (release run of 2026-09-08). The property under test is that 'o' carries
# its UTC offset, not that the clock stood still between two samples.
$oStamp = Get-Date -Format 'o'
$sStamp = Get-Date -Format 's'
$newA = [DateTimeOffset]::Parse($oStamp, $inv).ToUnixTimeSeconds()
$newB = [DateTimeOffset]::Parse($oStamp, $inv, [Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeSeconds()
$oldA = [DateTimeOffset]::Parse($sStamp, $inv).ToUnixTimeSeconds()
$oldB = [DateTimeOffset]::Parse($sStamp, $inv, [Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeSeconds()
Write-Output ('KA_OFFSET_STABLE=' + $(if ($newA -eq $newB) { 'ok' } else { 'MISMATCH' }))
Write-Output ('KA_NAKED_STAMP_DRIFT=' + [Math]::Abs($oldA - $oldB))
$report = Get-KaReport -Refresh
$mu = Get-KaMinutesUntil -Text '09:00'
Write-Output ('KA_MINUTES_OK=' + $mu.Ok)
Write-Output ('KA_MINUTES_ERR=' + $mu.Reason)

# Every file the tool writes must stay free of localized numbers: JSON and the log.
$fileLeak = 0
foreach ($f in @($paths.state, $paths.machine, $paths.log, $paths.config) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
    $t = [IO.File]::ReadAllText($f)
    # A JSON structural comma is always followed by whitespace, a quote or a bracket, so
    # "digit comma digit" inside one of these files can only be a localized number.
    foreach ($pat in @('\d[,\u066B\u066C]\d', '[\u0660-\u0669\u06F0-\u06F9\u0E50-\u0E59\uFBF0-\uFBF9]')) {
        foreach ($hit in [regex]::Matches($t, $pat)) {
            $fileLeak++
            $from = [Math]::Max(0, $hit.Index - 24)
            Write-Output ('KA_FILE_LEAK=' + (Split-Path $f -Leaf) + ' ctx=' + $t.Substring($from, [Math]::Min(56, $t.Length - $from)))
        }
    }
}
Write-Output ('KA_LEAK_FILE=' + $fileLeak)

# Same for the strings that go out over /api/report and in ka.ps1 -Json.
function Find-StringLeaves($obj, [string]$prefix, $acc) {
    if ($null -eq $obj) { return }
    if ($obj -is [string]) { [void]$acc.Add(@{ path = $prefix; value = $obj }); return }
    if ($obj -is [System.Collections.IDictionary]) { foreach ($k in $obj.Keys) { Find-StringLeaves $obj[$k] ($prefix + '.' + $k) $acc }; return }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $obj.PSObject.Properties) { Find-StringLeaves $p.Value ($prefix + '.' + $p.Name) $acc }
        return
    }
    if ($obj -is [DateTime]) { [void]$acc.Add(@{ path = $prefix; value = $obj.ToString('yyyy-MM-dd HH:mm:ss') }); return }
    if ($obj -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($v in $obj) { Find-StringLeaves $v ($prefix + '[' + $i + ']') $acc; $i++ }
        return
    }
}
$leaves = New-Object System.Collections.ArrayList
Find-StringLeaves $report 'root' $leaves
$dec = 0
foreach ($e in $leaves) {
    if ($e.value -match '\d[,\u066B]\d{1,2}(\D|$)') { $dec++; Write-Output ('KA_OBJ_DEC=' + $e.path + ' = ' + $e.value) }
    if ($e.value -match '[\u0660-\u0669\u06F0-\u06F9\u0E50-\u0E59\uFBF0-\uFBF9]') {
        $dec++; Write-Output ('KA_OBJ_DIGIT=' + $e.path + ' = ' + $e.value) }
}
Write-Output ('KA_LEAK_DECIMAL=' + $dec)
Remove-Item -LiteralPath $env:KA_DATA -Recurse -Force -ErrorAction SilentlyContinue
exit 0
