<#
.SYNOPSIS
    ka-server.ps1 - the local HTTP server behind the dashboard.

.DESCRIPTION
    Listens on 127.0.0.1 only. Zero install, zero login, nothing leaves the machine.

    Threat model worth stating, because a localhost server gets it wrong more often
    than not: any web page open in this browser could otherwise POST to
    http://127.0.0.1:8791/api/start and quietly change this machine's power
    behaviour. Two rules close that:

      1. every /api/ request must carry the custom header X-Ka-Client. A cross-origin
         page cannot send it: the browser sends a CORS preflight first, and this server
         never answers with Access-Control-Allow-*;
      2. when an Origin header is present it must name this exact host and port, and the
         Host header must be 127.0.0.1 / localhost - which also blocks DNS rebinding.

    Static files come from a fixed whitelist, so no request can walk out of dashboard/.
    GET never changes anything; every mutation is a POST.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-server.ps1 -Port 8791
    powershell -NoProfile -ExecutionPolicy Bypass -File ka-server.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$SelfTest,
    [int]$StateTtlSec = 1,
    [string]$DataDir = ''
)

# Before ka-core is dot-sourced, so config/state/log and the hint file all resolve to the
# data root the caller meant rather than to whatever this process would guess.
if ($DataDir) { $env:KA_DATA = $DataDir }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ka-gate.ps1')
if (-not (Test-KaLanguageMode)) { exit 2 }
. (Join-Path $PSScriptRoot 'ka-core.ps1')

$cfg = Get-KaConfig
if ($Port -le 0) { $Port = [int]$cfg.port }
$paths = Get-KaPath
$dashDir = $paths.dashboard

# Fixed name -> on-disk file + content type. Unknown names are 404, never resolved.
$staticMap = @{
    '/'            = @{ file = 'index.html';  type = 'text/html; charset=utf-8' }
    '/index.html'  = @{ file = 'index.html';  type = 'text/html; charset=utf-8' }
    '/app.js'      = @{ file = 'app.js';      type = 'application/javascript; charset=utf-8' }
    '/i18n.js'     = @{ file = 'i18n.js';     type = 'application/javascript; charset=utf-8' }
    '/styles.css'  = @{ file = 'styles.css';  type = 'text/css; charset=utf-8' }
    '/favicon.svg' = @{ file = 'favicon.svg'; type = 'image/svg+xml' }
}

function Invoke-KaReason {
    <#
        A one-field error body. Built with ConvertTo-Json rather than a quoted literal so
        a value that came from the request (an Origin, an exception message) cannot break
        out of the string and forge JSON.
    #>
    param([string]$Reason)
    return (@{ ok = $false; reason = $reason } | ConvertTo-Json -Compress)
}

function ConvertTo-KaJsonSafe {
    param($Object, [int]$Depth = 9)
    try { return ($Object | ConvertTo-Json -Depth $Depth) } catch {
        Add-KaLog "FAIL pid=$PID json serialize: $($_.Exception.Message)"
        # Not ConvertTo-KaJsonSafe: that is the call that just failed.
        return (@{ ok = $false; reason = (Get-KaText 'api.serialize') } | ConvertTo-Json -Compress)
    }
}

function Send-KaResponse {
    param($Ctx, [int]$Status, [string]$Body, [string]$ContentType = 'application/json; charset=utf-8')
    try {
        $res = $Ctx.Response
        $res.StatusCode = $Status
        $res.ContentType = $ContentType
        $res.SendChunked = $false
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Flush()
    } catch {
        # A client that navigated away is normal, never fatal to the loop.
    } finally {
        try { $Ctx.Response.Close() } catch { }
        try { $Ctx.Request.Close() } catch { }
    }
}

function Read-KaBody {
    param($Ctx, [int]$MaxBytes = 65536)
    try {
        $req = $Ctx.Request
        if (-not $req.HasEntityBody) { return $null }
        $len = [int]$req.ContentLength64
        if ($len -gt $MaxBytes) { throw (Get-KaText 'server.bodyTooBig' @{ size = $len }) }
        $stream = $req.InputStream
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 8192
        $total = 0
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            if ($total -gt $MaxBytes) { throw (Get-KaText 'server.bodyTooBig' @{ size = $total }) }
            $ms.Write($buf, 0, $n)
        }
        $ms.Position = 0
        $text = (New-Object IO.StreamReader($ms, [Text.Encoding]::UTF8)).ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json
    } catch {
        return @{ __badBody = "$($_.Exception.Message)" }
    }
}

function Test-KaAllowed {
    <#
        Returns $null when the request may proceed, otherwise @{ code; value } describing
        what was denied. The caller turns the code into a localized sentence for the HTTP
        body - and into nothing but the code for the log, which stays machine vocabulary.
    #>
    param($Ctx, [string]$Path)
    $req = $Ctx.Request

    $host_ = "$($req.Headers['Host'])"
    if (-not $host_) { $host_ = "$($req.UserHostName)" }
    $hostOk = ($host_ -match '^(127\.0\.0\.1|localhost)(:\d+)?$')
    if (-not $hostOk) { return @{ code = 'host'; value = $host_ } }

    if ($Path -notlike '/api/*') { return $null }

    $origin = "$($req.Headers['Origin'])"
    if ($origin) {
        $originOk = ($origin -match '^https?://(127\.0\.0\.1|localhost)(:\d+)?$')
        if (-not $originOk) { return @{ code = 'origin'; value = $origin } }
    }
    if ("$($req.Headers['X-Ka-Client'])" -ne 'ka-dashboard') {
        return @{ code = 'client' }
    }
    return $null
}

function Get-KaRequestLang {
    <#
        The dashboard knows which language it is rendering, so it says so on every request.
        Anything other than zh/en is ignored and the server's own detection stands.
    #>
    param($Ctx)
    $v = "$($Ctx.Request.Headers['X-Ka-Lang'])".Trim().ToLowerInvariant()
    if ($v -eq 'zh' -or $v -eq 'en') { return $v }
    return ''
}

# ---------------------------------------------------------------- api handlers
$script:StateCache = $null
$script:StateCacheAt = 0
$script:StateCacheLang = ''

function Get-KaStateCached {
    # Prose inside the state (guard detail, report advice) comes from the message catalog,
    # so the cache has to be keyed on the language it was built in. Two panels open in
    # different languages must not serve each other's sentences.
    $uiLang = Get-KaUiLanguage
    $now = Get-KaEpoch
    if ($script:StateCache -and ($now - $script:StateCacheAt) -lt $StateTtlSec -and
        $script:StateCacheLang -eq $uiLang) { return $script:StateCache }
    $s = Get-KaFullState
    $script:StateCache = $s
    $script:StateCacheAt = $now
    $script:StateCacheLang = $uiLang
    return $s
}

function Invalidate-KaStateCache { $script:StateCache = $null; $script:StateCacheAt = 0 }

function Invoke-KaApi {
    <#
        Returns @{ status; body; type } for one /api/ call. Never throws: a handler bug
        must degrade to a 500, not to a dead dashboard.
    #>
    param([string]$Method, [string]$Path, $Body, [string]$Query)

    $q = @{}
    # [Uri]::Query keeps its leading '?'; without trimming it the first pair of every
    # real request lands under "?hours" and silently falls back to the default.
    if ($Query) {
        foreach ($pair in ($Query.TrimStart('?') -split '&')) {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) { $q[$kv[0].ToLower()] = [uri]::UnescapeDataString($kv[1]) }
        }
    }

    switch ($Method.ToUpper()) {

        'GET' {
            switch ($Path) {
                '/api/ping' {
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe @{
                        ok = $true; version = $script:KaVersion; pid = $PID; port = $Port
                        epoch = Get-KaEpoch; root = $paths.root; data = $paths.data }) }
                }
                '/api/state' { return @{ status = 200; body = (ConvertTo-KaJsonSafe (Get-KaStateCached)) } }
                '/api/config' { return @{ status = 200; body = (ConvertTo-KaJsonSafe (Get-KaConfig)) } }
                '/api/report' { return @{ status = 200; body = (ConvertTo-KaJsonSafe (Get-KaReport)) } }
                '/api/machine' {
                    $m = Read-KaJson $paths.machine
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe @{ ok = [bool]$m; machine = $m }) }
                }
                '/api/log' {
                    $tail = 60
                    if ($q['tail']) { [void][int]::TryParse($q['tail'], [ref]$tail) }
                    $tail = [int](Get-KaBounded $tail 1 500 60)
                    $lines = @()
                    try {
                        if (Test-Path -LiteralPath $paths.log) {
                            $lines = @(Get-Content -LiteralPath $paths.log -Tail $tail -ErrorAction SilentlyContinue | ForEach-Object { "$_" })
                        }
                    } catch { }
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe @{ ok = $true; lines = $lines; path = $paths.log }) }
                }
                '/api/evidence' {
                    $hours = 24
                    if ($q['hours']) { [void][int]::TryParse($q['hours'], [ref]$hours) }
                    $hours = [int](Get-KaBounded $hours 1 720 24)
                    $ev = Get-KaSleepEvidence -Since (Get-Date).AddHours(-$hours)
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe @{ ok = [bool]$ev.queriesOk; hours = $hours; evidence = $ev }) }
                }
                '/api/sleepstates' {
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe (Get-KaSleepStates)) }
                }
                default { return @{ status = 404; body = (Invoke-KaReason (Get-KaText 'api.unknown')) } }
            }
        }

        'POST' {
            if ($Body -and $Body.__badBody) {
                return @{ status = 400; body = (Invoke-KaReason (Get-KaText 'api.badJson' @{ msg = "$($Body.__badBody)" })) }
            }
            $b = if ($Body) { $Body } else { [PSCustomObject]@{} }

            switch ($Path) {
                '/api/start' {
                    $minutes = 0.0
                    if ($b.minutes) { [void][double]::TryParse("$($b.minutes)", [ref]$minutes) }
                    $minutes = [double](Get-KaBounded $minutes 0 10080 0)
                    $ov = @{}
                    if ($null -ne $b.keepDisplayOn) { $ov.keepDisplayOn = [bool]$b.keepDisplayOn }
                    if ($null -ne $b.antiLock)      { $ov.antiLock = [bool]$b.antiLock }
                    if ($null -ne $b.awayMode)      { $ov.awayMode = [bool]$b.awayMode }
                    if ($null -ne $b.batteryAllowDisplayOff) { $ov.batteryAllowDisplayOff = [bool]$b.batteryAllowDisplayOff }
                    if ($b.antiLockMethod -in @('key', 'mouse')) { $ov.antiLockMethod = [string]$b.antiLockMethod }
                    # Every tuning knob the dashboard shows must actually reach the worker:
                    # a key missing here is a control that looks live but does nothing.
                    if ($b.antiLockIntervalSec)     { $ov.antiLockIntervalSec = [int](Get-KaBounded $b.antiLockIntervalSec 10 3600 240) }
                    if ($b.reassertSec)             { $ov.reassertSec = [int](Get-KaBounded $b.reassertSec 15 3600 60) }
                    if ($null -ne $b.batteryFloorPercent) { $ov.batteryFloorPercent = [int](Get-KaBounded $b.batteryFloorPercent 0 90 20) }
                    $r = Start-KaProtection -Minutes $minutes -Override $ov
                    Invalidate-KaStateCache
                    Add-KaLog "api start pid=$PID minutes=$minutes ok=$($r.Ok) override=$($ov.Count)"
                    return @{ status = $(if ($r.Ok) { 200 } else { 500 }); body = (ConvertTo-KaJsonSafe $r) }
                }
                '/api/stop' {
                    $r = Stop-KaProtection -Reason 'dashboard'
                    Invalidate-KaStateCache
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe (@{ ok = $true } + $r)) }
                }
                '/api/config' {
                    $patch = @{}
                    if ($b.patch) {
                        foreach ($prop in $b.patch.PSObject.Properties) { $patch[$prop.Name] = $prop.Value }
                    }
                    if (-not $patch.Count) {
                        return @{ status = 400; body = (ConvertTo-KaJsonSafe @{ ok = $false; reason = (Get-KaText 'config.empty') }) }
                    }
                    # Set-KaConfig throws on a value it refuses. That is a bad request, not a
                    # server fault: the visitor needs to see which key and which value.
                    try {
                        $ok = Set-KaConfig -Patch $patch
                    } catch {
                        return @{ status = 400; body = (ConvertTo-KaJsonSafe @{ ok = $false; reason = $_.Exception.Message }) }
                    }
                    Invalidate-KaStateCache
                    if (-not $ok) {
                        return @{ status = 500; body = (ConvertTo-KaJsonSafe @{
                            ok = $false; config = (Get-KaConfig)
                            reason = (Get-KaText 'config.writeFail' @{
                                path = (Get-KaPath).config; error = (Get-KaLastWriteCode) }) }) }
                    }
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe @{ ok = $true; config = (Get-KaConfig) }) }
                }
                '/api/guard/install' {
                    $r = Install-KaGuard
                    Invalidate-KaStateCache
                    Add-KaLog "api guard install pid=$PID ok=$($r.Ok) $($r.Reason)"
                    return @{ status = $(if ($r.Ok) { 200 } else { 500 }); body = (ConvertTo-KaJsonSafe $r) }
                }
                '/api/guard/uninstall' {
                    $r = Uninstall-KaGuard
                    Invalidate-KaStateCache
                    Add-KaLog "api guard uninstall pid=$PID ok=$($r.Ok) $($r.Reason)"
                    return @{ status = $(if ($r.Ok) { 200 } else { 500 }); body = (ConvertTo-KaJsonSafe $r) }
                }
                '/api/check' {
                    $r = Get-KaReport -Refresh
                    Invalidate-KaStateCache
                    return @{ status = 200; body = (ConvertTo-KaJsonSafe @{ ok = $true; recommendedIntervalSec = $r.recommendedIntervalSec; recommendedWhy = $r.recommendedWhy }) }
                }
                '/api/server/stop' {
                    $script:KaShutdown = $true
                    return @{ status = 200; body = '{"ok":true,"stopping":true}' }
                }
                default { return @{ status = 404; body = (Invoke-KaReason (Get-KaText 'api.unknown')) } }
            }
        }

        default { return @{ status = 405; body = (Invoke-KaReason (Get-KaText 'api.method')) } }
    }
}

function Send-KaStatic {
    param($Ctx, [string]$Path)
    $entry = $staticMap[$Path]
    if (-not $entry) { return Send-KaResponse $Ctx 404 (Invoke-KaReason (Get-KaText 'api.noFile')) }
    $file = Join-Path $dashDir $entry.file
    if (-not (Test-Path -LiteralPath $file)) {
        return Send-KaResponse $Ctx 404 (Invoke-KaReason (Get-KaText 'api.dashMissing'))
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($file)
        $Ctx.Response.StatusCode = 200
        $Ctx.Response.ContentType = $entry.type
        $Ctx.Response.ContentLength64 = $bytes.Length
        # The dashboard re-reads state every couple of seconds; caching index.html would
        # make an upgrade look like it never happened.
        $Ctx.Response.Headers.Add('Cache-Control', 'no-store')
        $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Ctx.Response.OutputStream.Flush()
    } catch { } finally {
        try { $Ctx.Response.Close() } catch { }
        try { $Ctx.Request.Close() } catch { }
    }
}

# ---------------------------------------------------------------- self test
if ($SelfTest) {
    Write-Host 'SELFTEST - exercising handlers without opening a socket'
    $r = Invoke-KaApi -Method 'GET' -Path '/api/ping' -Body $null -Query ''
    Write-Host ("  ping    -> {0} {1}" -f $r.status, ($r.body.Substring(0, [Math]::Min(90, $r.body.Length))))
    if ($r.status -ne 200) { exit 1 }
    $r = Invoke-KaApi -Method 'GET' -Path '/api/config' -Body $null -Query ''
    Write-Host ("  config  -> {0}" -f $r.status)
    if ($r.status -ne 200) { exit 1 }
    $r = Invoke-KaApi -Method 'GET' -Path '/api/log' -Body $null -Query 'tail=3'
    Write-Host ("  log     -> {0} ({1} chars)" -f $r.status, $r.body.Length)
    $r = Invoke-KaApi -Method 'POST' -Path '/api/start' -Body (@{ __badBody = 'x' }) -Query ''
    Write-Host ("  badbody -> {0} (expect 400)" -f $r.status)
    if ($r.status -ne 400) { exit 1 }
    $r = Invoke-KaApi -Method 'GET' -Path '/api/nope' -Body $null -Query ''
    Write-Host ("  unknown -> {0} (expect 404)" -f $r.status)
    if ($r.status -ne 404) { exit 1 }
    $r = Invoke-KaApi -Method 'DELETE' -Path '/api/stop' -Body $null -Query ''
    Write-Host ("  delete  -> {0} (expect 405)" -f $r.status)
    if ($r.status -ne 405) { exit 1 }
    foreach ($p in @('/', '/app.js', '/i18n.js', '/styles.css', '/..%2fka-core.ps1', '/favicon.svg')) {
        Write-Host ("  static  {0,-20} -> {1}" -f $p, $(if ($staticMap.ContainsKey($p)) { 'whitelisted' } else { '404 (rejected)' }))
    }
    Write-Host 'SELFTEST OK'
    exit 0
}

# ---------------------------------------------------------------- listen
$listener = New-Object System.Net.HttpListener
$started = $false
try {
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    $started = $true
} catch {
    Add-KaLog "server dual-prefix start failed pid=$PID port=$Port fallback=127.0.0.1 msg=$($_.Exception.Message)"
}
if (-not $started) {
    try {
        $listener.Close()
    } catch { }
    $listener = New-Object System.Net.HttpListener
    try {
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
        $started = $true
    } catch {
        Add-KaLog "server start failed pid=$PID port=$Port msg=$($_.Exception.Message)"
    }
}
if (-not $started) {
    Write-Host (Get-KaText 'server.console.cantListen' @{ port = $Port }) -ForegroundColor Red
    Write-Host (Get-KaText 'server.console.portBusy') -ForegroundColor DarkGray
    exit 1
}

# One handle per port, in a file this panel owns outright (see Get-KaServerHintPath): the
# shared `.server.json` let the second panel overwrite the first's pid at start and delete it
# at exit, which made a still-running panel unfindable.
$serverHint = Get-KaServerHintPath $Port
if (-not (Write-KaJson $serverHint @{ pid = $PID; port = $Port; url = "http://127.0.0.1:$Port/";
                                      startedEpoch = Get-KaEpoch; root = (Get-KaProgramRoot);
                                      data = (Get-KaDataRoot) } -Depth 3)) {
    # Worth a log line: without the hint, a panel started with a relative path cannot be
    # found again by Stop-KaServer and squats the port for the rest of the session.
    Add-KaLog "WARN pid=$PID server-hint-unwritable $serverHint"
}
Add-KaLog "SERVER pid=$PID port=$Port url=http://127.0.0.1:$Port/"
Write-Host (Get-KaText 'server.console.ready' @{ port = $Port })

$script:KaShutdown = $false
try {
    while ($listener.IsListening -and -not $script:KaShutdown) {
        $ctx = $listener.GetContext()
        try {
            $script:KaReqLang = Get-KaRequestLang -Ctx $ctx
            $path = $ctx.Request.Url.AbsolutePath
            $deny = Test-KaAllowed -Ctx $ctx -Path $path
            if ($deny) {
                # The log is machine vocabulary: a code, not the localized sentence, so an
                # English visitor's probe cannot write Chinese (or vice versa) into ka.log.
                Add-KaLog "REJECT $path $($ctx.Request.HttpMethod) : deny=$($deny.code)"
                $why = switch ($deny.code) {
                    'host'   { Get-KaText 'api.host' @{ host = $deny.value } }
                    'origin' { Get-KaText 'api.origin' @{ origin = $deny.value } }
                    default  { Get-KaText 'api.client' }
                }
                Send-KaResponse $ctx 403 (ConvertTo-KaJsonSafe @{ ok = $false; reason = $why })
                continue
            }
            if ($path -like '/api/*') {
                $body = $null
                if ($ctx.Request.HttpMethod -eq 'POST') { $body = Read-KaBody $ctx }
                $res = Invoke-KaApi -Method $ctx.Request.HttpMethod -Path $path -Body $body -Query $ctx.Request.Url.Query
                Send-KaResponse $ctx $res.status $res.body $(if ($res.type) { $res.type } else { 'application/json; charset=utf-8' })
            } else {
                Send-KaStatic -Ctx $ctx -Path $path
            }
        } catch {
            Add-KaLog "server request error: $($_.Exception.Message)"
            Send-KaResponse $ctx 500 (Invoke-KaReason (Get-KaText 'api.internal'))
        } finally {
            # A request that sends no X-Ka-Lang must not be answered in whoever asked last.
            $script:KaReqLang = ''
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    # Ours, and only while it is still ours: if a successor already re-bound this port it
    # owns the file now, and deleting it would strand that panel without a handle.
    try {
        $mine = Read-KaJson $serverHint
        if ($mine -and [int]$mine.pid -eq $PID) {
            Remove-Item -LiteralPath $serverHint -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    Add-KaLog "SERVER EXIT pid=$PID"
    Write-Host (Get-KaText 'server.console.exited')
}
