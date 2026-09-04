$ErrorActionPreference = 'Continue'
<#
    Mark-of-the-Web, measured end to end, because this tool is a download and the answer decides
    whether the release needs an unblock step in the docs or not.

    Three things get judged, and the third is the only reason the first two are interesting:
      A. an unstamped copy vs the same copy with Zone.Identifier (Zone 3) on every file - run the
         way a downloader runs them, and the outputs have to agree;
      B. a zip that carries the mark, extracted the way Windows extracts it - do the files inside
         come out marked? (Explorer's ExtractAll and Expand-Archive are not the same code path;
         this measures the one that can be scripted and says which one it was.)
      C. does the inline Add-Type -TypeDefinition still compile? The shipped tool carries no dll,
         so the only thing MOTW could plausibly break is compiling C# out of a marked script into
         a temp assembly. If that failed, every power primitive would degrade silently to
         "unknown" and the tool would become an expensive way to say nothing.

    Each copy gets its own KA_DATA so the real install is never touched.
#>
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root ('_tmp/motw-run-' + [guid]::NewGuid().ToString('N'))   # scratch stays in the ignored _tmp
$ps64 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

. (Join-Path $root 'tests/ka-release-files.ps1')   # shared manifest; resolved via $root because the self-test runs a copy of this file from _tmp
$files = @(Get-KaReleaseFile)
$bad = @()
function Shipped-Copy([string]$Dir) {
    $null = New-Item -ItemType Directory -Force -Path $Dir
    $n = 0
    foreach ($f in $files) {
        $src = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $src)) { $script:bad += "$f is not in the source tree - the shipped file list is stale"; continue }
        $dst = Join-Path $Dir $f
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $dst)
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $n++
    }
    return $n
}
function Mark-One([string]$Path) {
    Set-Content -LiteralPath ($Path + ':Zone.Identifier') `
        -Value "[ZoneTransfer]`r`nZoneId=3`r`nReferrerUrl=https://github.com/`r`nHostUrl=https://github.com/`r`n" -Encoding Ascii
}
function Mark-Everything([string]$Dir) {
    Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object { Mark-One $_.FullName }
}
function Count-Marks([string]$Dir) {
    $c = 0
    Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object {
        if (Get-Item -LiteralPath ($_.FullName + ':Zone.Identifier') -ErrorAction SilentlyContinue) { $c++ }
    }
    return $c
}
function Invoke-Leg([string]$Exe, [string]$Arguments, [string]$Data) {
    $env:KA_DATA = $Data
    $tag = Join-Path $env:TEMP ('ka-motw-' + [guid]::NewGuid().ToString('N'))
    try {
        $p = Start-Process -FilePath $Exe -Wait -NoNewWindow -PassThru `
            -RedirectStandardOutput "$tag.out" -RedirectStandardError "$tag.err" -ArgumentList $Arguments
        @{ Exit = $p.ExitCode
           Out  = if (Test-Path -LiteralPath "$tag.out") { [IO.File]::ReadAllText("$tag.out") } else { '' }
           Err  = if (Test-Path -LiteralPath "$tag.err") { [IO.File]::ReadAllText("$tag.err") } else { '' } }
    } finally { Remove-Item -LiteralPath "$tag.out", "$tag.err" -Force -ErrorAction SilentlyContinue }
}
# Both legs read the clock at their own second, so a live value changes *form* between them
# ("59.9 秒" then "1 分钟", "676" then "676.8") - collapsing digits alone to '#' left '###' vs
# '#.#' and the probe failed on an unchanged product. So compare the shape: which lines appear,
# in what order, with which labels. The unit list covers both languages, including the bare
# English forms the tool really prints ("1.5 h", "29.2 min", "59.5 s" - taken from
# tests/probe-culture.ps1, not guessed); the lookahead keeps a number followed by an ordinary
# word ("port 8791 setting") from being eaten as a duration. This does not hide the failure the
# probe exists for - exit code and stderr are compared as they are, a reading that turns into
# "unknown" still differs from a number, and leg C separately requires the native layer to build
# and answer out of marked sources.
$norm = { param($s)
    (($s -split "`r?`n") | ForEach-Object {
        $_ -replace '[0-9]+([.,][0-9]+)?\s*(小时|分钟|秒|天|seconds?|minutes?|hours?|days?|secs?|mins?|hrs?|[smdh])(?![A-Za-z])', 'DUR' `
          -replace '[0-9]+([.,][0-9]+)?', 'N'
    }) -join "`n"
}

# Question C, asked of one directory: build the native layer from whatever is there and call
# through it. Whether the helper itself is marked follows the directory it is copied into.
$childSrc = Join-Path $root '_tmp/motw-native-child.ps1'   # scratch stays in the ignored _tmp
@'
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ka-core.ps1')
if (-not ('Ka.Native' -as [type])) { Write-Output 'NATIVE=missing'; exit 1 }
$s = [Ka.Native]::PowerStatus()
Write-Output ('NATIVE=loaded KNOWN=' + $s.known + ' IL=' + [Ka.Native]::SelfIntegrityRid() +
              ' CAPS=' + [bool][Ka.Native]::GetPowerCapabilitiesRaw() + ' IDLE=' + [math]::Round([Ka.Native]::SecondsSinceInput(), 1))
'@ | Set-Content -LiteralPath $childSrc -Encoding UTF8
function Native-Leg([string]$Dir, [switch]$Mark) {
    $c = Join-Path $Dir 'motw-native-child.ps1'
    Copy-Item -LiteralPath $childSrc -Destination $c -Force
    if ($Mark) { Mark-One $c }
    Invoke-Leg $ps64 ('-NoProfile -ExecutionPolicy Bypass -File "' + $c + '"') (Join-Path $work ('data-' + (Split-Path -Leaf $Dir)))
}

$plain = Join-Path $work 'plain'
$web = Join-Path $work 'web'
$copied = Shipped-Copy $plain
Shipped-Copy $web | Out-Null
Mark-Everything $web
$totalN = (Get-ChildItem -LiteralPath $web -Recurse -File).Count
$markedN = Count-Marks $web
Write-Output ("shipped file list: $copied files; the web copy carries Zone.Identifier on $markedN of $totalN")
if ($copied -ne $files.Count) { $bad += "only $copied of $($files.Count) shipped files were copied - fix the list above" }
if ($markedN -ne $totalN) { $bad += "only $markedN of $totalN files got marked - the 'marked' leg is not measuring a download" }
if ($bad) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output 'PROBE FAILED: setup'; exit 1 }

Write-Output '--- A. powershell -File ka.ps1 status, marked and unmarked'
$stPlain = Invoke-Leg $ps64 ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $plain 'ka.ps1') + '" status') (Join-Path $work 'd-plain')
$stWeb = Invoke-Leg $ps64 ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $web 'ka.ps1') + '" status') (Join-Path $work 'd-web')
Write-Output ('  unstamped: exit=' + $stPlain.Exit + ' chars=' + $stPlain.Out.Length + ' stderr=' + $stPlain.Err.Trim().Length)
Write-Output ('  stamped  : exit=' + $stWeb.Exit + ' chars=' + $stWeb.Out.Length + ' stderr=' + $stWeb.Err.Trim().Length)
# Guarding the guard: a shape comparison can also pass by having nothing left in it. The
# normalised status must still be the multi-line report it came from, header included - the CLI
# prints "== 防休眠 Keep-Awake" / "== Keep-Awake", so that token survives either language.
$shapeLines = @(((& $norm $stWeb.Out) -split "`r?`n") | Where-Object { $_.Trim().Length })
if ($shapeLines.Count -lt 5) { $bad += "leg A compares $($shapeLines.Count) line(s) - the shape check has nothing left to see" }
if ((& $norm $stWeb.Out) -notmatch 'Keep-Awake') { $bad += 'the normalised status lost its header line - the shape check is comparing noise' }
if ($stPlain.Exit -ne $stWeb.Exit) { $bad += "exit code changed once the files are marked ($($stPlain.Exit) vs $($stWeb.Exit))" }
if ((& $norm $stPlain.Out) -ne (& $norm $stWeb.Out)) {
    $bad += 'status output changed once the files are marked (after normalising numbers and duration units)'
    Write-Output '    --- unstamped'
    ((& $norm $stPlain.Out) -split "`n" | Select-Object -First 4) | ForEach-Object { Write-Output "    $_" }
    Write-Output '    --- stamped'
    ((& $norm $stWeb.Out) -split "`n" | Select-Object -First 4) | ForEach-Object { Write-Output "    $_" }
}
if ($stWeb.Err.Trim().Length) { $bad += 'the marked leg wrote to stderr: ' + (($stWeb.Err -split "`n") | Select-Object -First 1) }

Write-Output '--- C. inline Add-Type compiled out of a marked ka-core.ps1'
$nPlain = Native-Leg $plain
$nWeb = Native-Leg $web -Mark
Write-Output ('  unstamped: ' + $nPlain.Out.Trim())
Write-Output ('  stamped  : ' + $nWeb.Out.Trim())
if ($nPlain.Out -notmatch 'NATIVE=loaded KNOWN=True') { $bad += "native layer did not build in the unstamped leg: [$($nPlain.Out.Trim())] stderr=$($nPlain.Err.Trim())" }
if ($nWeb.Out -notmatch 'NATIVE=loaded KNOWN=True') { $bad += "native layer did not build from MARKED sources: [$($nWeb.Out.Trim())] stderr=$($nWeb.Err.Trim())" }
if ((& $norm $nPlain.Out) -ne (& $norm $nWeb.Out)) { $bad += 'the marked and unmarked native answers differ' }

Write-Output '--- double-click path: ka.bat status out of the marked copy'
$bat = Invoke-Leg (Join-Path $env:windir 'System32\cmd.exe') ('/c call "' + (Join-Path $web 'ka.bat') + '" status') (Join-Path $work 'd-bat')
$batFirst = (($bat.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
Write-Output ('  exit=' + $bat.Exit + ' chars=' + $bat.Out.Trim().Length + ' stderr=' + $bat.Err.Trim().Length)
Write-Output ('  first line: ' + $batFirst)
if ($bat.Exit -ne 0) { $bad += "ka.bat status exited $($bat.Exit) from the marked copy" }
if ($bat.Out.Trim().Length -lt 40) { $bad += 'ka.bat produced almost nothing from the marked copy' }
Write-Output ('  marks still present after being run: ' + (Count-Marks $web) + ' of ' + (Get-ChildItem -LiteralPath $web -Recurse -File).Count +
              ' (one of them is motw-native-child.ps1, copied in by leg C; the product itself wrote nothing here)')

Write-Output '--- B. marked zip -> Expand-Archive'
$zip = Join-Path $work 'ka.zip'
Compress-Archive -Path (Join-Path $plain '*') -DestinationPath $zip -Force
Mark-One $zip
$zipOut = Join-Path $work 'zipout'
Expand-Archive -LiteralPath $zip -DestinationPath $zipOut -Force
$zipFiles = (Get-ChildItem -LiteralPath $zipOut -Recurse -File).Count
$inZip = Count-Marks $zipOut
Write-Output ("  Expand-Archive of a marked zip: $inZip of $zipFiles extracted files carry a mark" +
              " ($($files.Count) shipped + the probe's own helper)")
$zNative = Native-Leg $zipOut -Mark:([bool]$inZip)
Write-Output ('  run from the extracted copy: ' + $zNative.Out.Trim())
if ($zNative.Out -notmatch 'NATIVE=loaded KNOWN=True') { $bad += "the zip-extracted copy could not build the native layer: [$($zNative.Out.Trim())]" }
$zStatus = Invoke-Leg $ps64 ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $zipOut 'ka.ps1') + '" status') (Join-Path $work 'd-zip')
if ($zStatus.Exit -ne $stPlain.Exit) { $bad += "status from the extracted copy exited $($zStatus.Exit), the direct copy exited $($stPlain.Exit)" }
Write-Output ('  measured verdict: ' + $(if ($inZip -eq 0) { 'Expand-Archive does not propagate the mark - extraction unblocks' } else { 'the mark survives Expand-Archive' }))

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $childSrc -Force -ErrorAction SilentlyContinue
foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
Write-Output ('PROBE OK: a Zone-3 download of ' + $copied + ' files behaves exactly like an unmarked one, native layer compiles either way (exit=' + $stPlain.Exit + ')')
