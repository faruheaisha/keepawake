# Isolated panel test: invalid writes are refused and a partial request times out.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$data = Join-Path $root ('_tmp\http-audit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $data -Force | Out-Null
$env:KA_DATA = $data
. (Join-Path $root 'ka-core.ps1')
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$bootEpoch = Get-KaLeaseBootEpoch
$uptime = Get-KaLeaseUptimeMs
$leaseId = 'a' * 32; $tokenHash = 'b' * 64
$ledger = @{ version = 1; manual = @{ active = $false; expiresEpoch = 0; keepDisplayOn = $false; antiLock = $false; options = @{} }
    leases = @(@{ id = $leaseId; owner = 'test'; tokenHash = $tokenHash; reason = 'test task'; createdEpoch = $now
        expiresEpoch = ($now + 120); keepDisplayOn = $false; antiLock = $false; requestId = ''; requestMinutes = 2; bootEpoch = $bootEpoch; expiresUptimeMs = ($uptime + 120000) })
    tombstones = @(); clockEpoch = $now; clockUptimeMs = $uptime }
[IO.File]::WriteAllText((Join-Path $data 'leases.json'), ($ledger | ConvertTo-Json -Depth 8))
[IO.File]::WriteAllText((Join-Path $data 'intent.json'), '{"desired":"awake","expiresEpoch":0,"minutes":0,"updatedAt":0}')
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$exe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args_ = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $root 'ka-server.ps1')),
           '-Port',"$port",'-DataDir',('"{0}"' -f $data))
$server = Start-Process $exe -ArgumentList $args_ -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $data 'server.out') -RedirectStandardError (Join-Path $data 'server.err')
function Request([string]$Path, [string]$Body = '', [int]$Timeout = 20000) {
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port$Path")
    $req.Timeout = $Timeout; $req.ReadWriteTimeout = $Timeout
    $req.Headers.Add('X-Ka-Client', 'ka-dashboard')
    if ($Body) {
        $req.Method = 'POST'; $req.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body); $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    try { $res = $req.GetResponse() } catch [Net.WebException] { $res = $_.Exception.Response; if (-not $res) { throw } }
    try {
        $reader = New-Object IO.StreamReader($res.GetResponseStream())
        try { $bodyText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return @{ status = [int]$res.StatusCode; frame = $res.Headers['X-Frame-Options']; body = $bodyText }
    }
    finally { $res.Close() }
}
$slow = $null
try {
    $deadline = (Get-Date).AddSeconds(20); $ready = $false
    while ((Get-Date) -lt $deadline) {
        try { if ((Request '/api/ping').status -eq 200) { $ready = $true; break } } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw 'panel did not start' }
    foreach ($body in @('{"minutes":"oops"}', '{"antiLock":"false"}', '{"minutes":null}',
            '{"antiLockMethod":"invalid"}', '{"antiLockIntervalSec":9}', '{"unexpected":true}',
            '{"expireAt":"2000-01-01T00:00"}', '{"expireAt":"2030-01-01T00:00","minutes":10}', '[]')) {
        if ((Request '/api/start' $body).status -ne 400) { throw "invalid input was not refused: $body" }
    }
    if ((Request '/').frame -ne 'DENY') { throw 'panel can be framed' }
    $stateResponse = Request '/api/state'
    $state = $stateResponse.body | ConvertFrom-Json
    if ($stateResponse.status -ne 200 -or -not $state.leases.readable -or @($state.leases.items).Count -ne 1 -or
        $state.leases.items[0].id -ne $leaseId -or $stateResponse.body.Contains($tokenHash)) {
        throw 'task list is missing, unreadable or leaks a token hash'
    }
    if ((Request '/api/leases/release' ('{"id":"' + $leaseId + '"}')).status -ne 200) { throw 'user could not release task' }
    $released = Get-Content -LiteralPath (Join-Path $data 'leases.json') -Raw | ConvertFrom-Json
    if (@($released.leases).Count -ne 0) { throw 'released task remains in the ledger' }
    # Recreate the fixture, pause it, then explicitly stop. A paused lease never
    # starts a worker; stopping cancels the automatic resume before cleanup.
    [IO.File]::WriteAllText((Join-Path $data 'leases.json'), ($ledger | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText((Join-Path $data 'intent.json'), '{"desired":"awake","expiresEpoch":0,"minutes":0,"updatedAt":0}')
    if ((Request '/api/pause' '{"minutes":15}').status -ne 200) { throw 'pause request failed' }
    $pausedState = (Request '/api/state').body | ConvertFrom-Json
    if (-not $pausedState.leases.paused -or $pausedState.running) { throw 'panel did not report paused state' }
    if ((Request '/api/stop' '{}').status -ne 200) { throw 'global stop failed while paused' }
    $afterStop = Get-Content -LiteralPath (Join-Path $data 'leases.json') -Raw | ConvertFrom-Json
    if (@($afterStop.leases).Count -ne 0 -or $afterStop.pause) { throw 'stop did not cancel paused tasks' }
    $keeperEnd = (Get-Date).AddSeconds(20)
    do {
        $keepers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
            "$($_.CommandLine)" -like '*integrations\mcp\keeper.ps1*' -and "$($_.CommandLine)" -like "*$data*" })
        if ($keepers.Count) { Start-Sleep -Milliseconds 250 }
    } while ($keepers.Count -and (Get-Date) -lt $keeperEnd)
    if ($keepers.Count) { throw 'paused fixture keeper did not exit' }
    $slow = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    $stream = $slow.GetStream()
    $partial = [Text.Encoding]::ASCII.GetBytes("POST /api/config HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nX-Ka-Client: ka-dashboard`r`nContent-Length: 1024`r`n`r`n{}")
    $stream.Write($partial, 0, $partial.Length)
    Start-Sleep -Milliseconds 250
    if ((Request '/api/ping' '' 6000).status -ne 200) { throw 'panel stayed blocked by partial body' }
    Write-Host 'PROBE OK: invalid start parameters, framing and partial request timeout'
} finally {
    if ($slow) { $slow.Close() }
    try { [void](Request '/api/server/stop' '{}') } catch {}
    if (-not $server.WaitForExit(5000)) { try { $server.Kill() } catch {} }
}
