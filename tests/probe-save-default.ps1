# "存为默认" is a headline feature of the panel and the only write path that goes over HTTP,
# and Set-KaConfig was just rewritten (sparse file, vocabulary on the write side). So this
# drives it the way the dashboard does: a real server, a real POST, a real file on disk -
# in an isolated data root, so the install on this machine is not the thing being edited.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot
$work = Join-Path $root '_tmp/save-default-run'   # scratch stays in the ignored _tmp, never beside the shipped tests
$port = 18791
$fail = New-Object System.Collections.Generic.List[string]
function Bad([string]$m) { $script:fail.Add($m); Write-Output ('  FAIL ' + $m) }
function Ok([string]$m)  { Write-Output ('  ok   ' + $m) }
function Call([string]$Path, [string]$Method = 'GET', [string]$Body = $null) {
    $uri = "http://127.0.0.1:$port$Path"
    $p = @{ Uri = $uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = 10;
            Headers = @{ 'X-Ka-Client' = 'ka-dashboard' } }
    if ($Body) {
        # http.sys answers 411 unless a request with a body also says how long it is.
        # ($Body is typed [string], so an omitted argument arrives as "" - not $null.)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $p['ContentType'] = 'application/json'
        $p['Body'] = $bytes
    }
    try {
        $r = Invoke-WebRequest @p
        return @{ status = [int]$r.StatusCode; body = ($r.Content | ConvertFrom-Json); raw = $r.Content }
    } catch {
        $resp = $_.Exception.Response
        $code = -1
        $text = ''
        if ($resp) {
            $code = [int]$resp.StatusCode
            try {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream())
                $text = $sr.ReadToEnd()
                $sr.Dispose()
            } catch { }
        }
        if (-not $text -and $_.ErrorDetails -and $_.ErrorDetails.Message) {
            # PS 5.1 hands the 4xx body to ErrorDetails instead of the response stream, and
            # fetch() in the browser reads that same body - so an empty $raw here would be
            # this client's blind spot, not the server's.
            $text = $_.ErrorDetails.Message
        }
        $bodyOut = $null
        try { if ($text) { $bodyOut = $text | ConvertFrom-Json } } catch { }
        return @{ status = $code; body = $bodyOut; raw = $text; msg = $_.Exception.Message }
    }
}

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$data = Join-Path $work 'data'
New-Item -ItemType Directory -Force -Path $data | Out-Null

Write-Output '--- start a panel against an isolated data root'
$prev = $env:KA_DATA
$env:KA_DATA = $data
$svc = Start-Process -FilePath 'powershell.exe' `
     -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'ka-server.ps1') + '" -Port ' + $port) `
     -WindowStyle Hidden -PassThru
$cfgPath = Join-Path $data 'config.json'
try {
    if (-not $svc) { throw 'Start-Process gave us no server process at all' }
    $up = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if ($svc.HasExited) { throw "the panel exited with code $($svc.ExitCode) - is port $port already taken?" }
        $ping = Call '/api/ping'
        if ($ping.status -eq 200 -and $ping.body.ok) { $up = $true; break }
    }
    if (-not $up) { throw 'the panel never answered on the test port' }
    Ok ("panel is up (pid $($svc.Id), port $port)")

    Write-Output '--- a real POST /api/config, the way the dashboard sends it'
    $r = Call '/api/config' 'POST' '{"patch":{"keepDisplayOn":false,"antiLockIntervalSec":90}}'
    if ($r.status -ne 200) { Bad "POST /api/config returned $($r.status): $($r.raw)" }
    else { Ok 'POST /api/config accepted the form' }
    $g = Call '/api/config'
    if ($g.status -ne 200) { Bad "GET /api/config returned $($g.status)" }
    if (-not $g.body) { Bad 'GET /api/config had no body' }
    else {
        if ([bool]$g.body.keepDisplayOn) { Bad 'the panel still reports the display held on after saving it off' }
        else { Ok 'keepDisplayOn=false came back as false' }
        if ([int]$g.body.antiLockIntervalSec -ne 90) { Bad "antiLockIntervalSec is $($g.body.antiLockIntervalSec), not 90" }
        else { Ok 'antiLockIntervalSec=90 came back as 90' }
    }
    if (-not (Test-Path -LiteralPath $cfgPath)) { Bad 'the save never wrote config.json' }
    else {
        $disk = [IO.File]::ReadAllText($cfgPath)
        if ($disk -notmatch '"keepDisplayOn":\s*false') { Bad "the file does not hold the choice: $($disk.Trim())" }
        else { Ok 'the file holds the choice as a real boolean' }
        if ($disk -match '"awayMode"|"batteryFloorPercent"|"logMaxKb"') { Bad "the file copied defaults nobody chose: $($disk.Trim())" }
        else { Ok 'the file left the untouched defaults to the code' }
    }

    Write-Output '--- a value the vocabulary does not accept must be a 400, not a 500 or a silent default'
    $hash = $null
    if (Test-Path -LiteralPath $cfgPath) { $hash = (Get-FileHash -LiteralPath $cfgPath).Hash }
    $r = Call '/api/config' 'POST' '{"patch":{"keepDisplayOn":"maybe"}}'
    if ($r.status -eq 200) { Bad 'POST accepted "maybe" for a boolean' }
    elseif ($r.status -ne 400) { Bad "POST refused with status $($r.status) - the dashboard can only show a reason on 400" }
    else {
        Ok 'POST /api/config refused it with 400'
        if (-not $r.body.reason) { Bad ('400 without a reason the panel can show: ' + $r.raw) }
        elseif ($r.body.reason -notmatch 'keepDisplayOn') { Bad "the reason does not name the key: $($r.body.reason)" }
        else { Ok 'the reason names the key, so the panel can say what went wrong' }
    }
    $after = $null
    if ($hash -and (Test-Path -LiteralPath $cfgPath)) { $after = (Get-FileHash -LiteralPath $cfgPath).Hash }
    if ($hash -and $after -ne $hash) { Bad 'the refused save still changed config.json' }
    elseif ($hash) { Ok 'the refused save left config.json byte-for-byte alone' }

    Write-Output '--- and the server that answers is the one we started'
    $st = Call '/api/ping'
    if ($st.body.pid -ne $svc.Id) { Bad "/api/ping says pid=$($st.body.pid) but we started $($svc.Id)" }
    else { Ok "/api/ping is answered by the process we started (pid $($svc.Id))" }
} catch {
    Bad "the probe could not finish: $($_.Exception.Message)"
} finally {
    Write-Output '--- stop it again'
    if ($svc) {
        [void](Call '/api/server/stop' 'POST' '{}')
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Id $svc.Id -ErrorAction SilentlyContinue)) { Ok 'the panel process exited on request' }
        else {
            Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
            Bad 'the panel did not exit on /api/server/stop; the probe had to kill it'
        }
    }
    if ($null -eq $prev) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prev }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
if ($fail.Count) {
    Write-Output ('PROBE FAILED: ' + $fail.Count + ' assertion(s)')
    $fail | ForEach-Object { Write-Output ('  - ' + $_) }
    exit 1
}
Write-Output 'PROBE OK: 存为默认 over HTTP stores what the form showed, and refuses what it cannot honour'
