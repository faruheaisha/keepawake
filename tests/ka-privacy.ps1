<#
    PRIVACY GATE - the "nothing leaves the machine" claim, checked against the source
    instead of against the README.

    PRIVACY.md promises a download-and-use product with no telemetry, no update check and no
    server of its own. That is only worth anything if a future commit cannot quietly break it.
    Four rules, all of them textual on purpose: they run in a second, need no network, no
    elevation, and no running worker.

      1. every http(s):// literal in shipped product code is a loopback URL;
      2. the set of network-capable client APIs in shipped code is an explicit allow-list, so
         a new HTTP/socket helper is a deliberate edit to this file, not an accident;
      3. the dashboard listener binds loopback prefixes only (no "+", "*", 0.0.0.0);
      4. no response ever carries Access-Control-Allow-*, which is what makes the X-Ka-Client
         header a real cross-origin boundary rather than a suggestion.

    A comment mentioning a URL counts: this scans literals, and the honest reading of rule 1 is
    "no non-loopback URL appears in the shipped text at all". Loopback examples in prose are
    fine, so the rule is not weakened to accommodate the docs - docs/ and README are out of
    scope here because a documented GitHub link is not an egress path.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/ka-privacy.ps1
            ... -Root <dir>     scan another copy (used to prove the gate can fail)
#>
[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Root)) { Write-Host "no such root: $Root"; exit 2 }

# Shipped product surface only: the engines, the CLI, the launchers, the panel.
$files = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
$files += @(Get-ChildItem -LiteralPath $Root -Filter '*.bat' -File | ForEach-Object { $_.FullName })
$dash = Join-Path $Root 'dashboard'
if (Test-Path -LiteralPath $dash) {
    $files += @(Get-ChildItem -LiteralPath $dash -File -Recurse | ForEach-Object { $_.FullName })
}
if (-not $files.Count) { Write-Host "nothing to scan under $Root"; exit 2 }

$fail = @()
$ok = @()

function Get-UrlHost {
    param([string]$Url)
    # http://127.0.0.1:$Port/, http://127.0.0.1:{port}/ and http://localhost:8791/ all have
    # to yield the bare host: the port may be a literal, an interpolated variable or a
    # dictionary placeholder, and none of those three spellings names a different server.
    $s = $Url -replace '^[a-zA-Z]+://', ''
    if ($s.StartsWith('[')) {
        # http://[::1]:8080/ - the host is bracketed, so strip to the closing bracket and
        # return it without them.
        $close = $s.IndexOf(']')
        if ($close -gt 0) { return $s.Substring(1, $close - 1).Trim().ToLowerInvariant() }
    }
    $s = $s -replace '[/\\].*$', ''
    $s = $s -replace ':.*$', ''
    return $s.Trim().ToLowerInvariant()
}

Write-Host ("scanning {0} shipped files under {1}" -f $files.Count, $Root)

# ---- 1. every URL literal is loopback -------------------------------------------------
$loopback = @('127.0.0.1', 'localhost', '::1')
$urls = 0
$nskip = 0
$hosts = @{}
foreach ($f in $files) {
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $f -Encoding UTF8)) {
        $i++
        foreach ($m in [regex]::Matches($line, 'https?://[^\s"''<>)\],;]+')) {
            # An xmlns URI is a namespace name that happens to be spelled as a URL. The SVG
            # 2000/svg one is in favicon.svg and inside one CSS data: URI; no code fetches
            # it, and a browser is told never to. Exempted narrowly - the attribute, not the
            # file type - so the same host in a fetch call would still fail this gate.
            $before = $line.Substring(0, $m.Index)
            if ($before -match "xmlns(:[A-Za-z0-9_-]+)?\s*=\s*[`"'']\s*$") { $nskip++; continue }
            $urls++
            $host_ = Get-UrlHost $m.Value
            if (-not $hosts.ContainsKey($host_)) { $hosts[$host_] = 0 }
            $hosts[$host_]++
            if ($host_ -notin $loopback) {
                $fail += ("{0}:{1} non-loopback URL literal: {2} (host={3})" -f `
                          (Split-Path -Leaf $f), $i, $m.Value, $host_)
            }
        }
    }
}
$ok += ("rule 1: {0} URL literal(s), hosts = {1}" -f $urls, `
        ((($hosts.Keys | Sort-Object) | ForEach-Object { "$_ x$($hosts[$_])" }) -join ', '))
$ok += ("rule 1: {0} xmlns namespace(s) exempt (namespace names, never fetched)" -f $nskip)

# ---- 2. network-capable APIs are an explicit allow-list -------------------------------
# Measured 2026-09-04: the only client call in the product is ka-core.ps1 talking to the
# panel it just started (a status probe and /api/server/stop). Anything else has to be
# added here by hand, which is the point.
$apiAllow = @{
    'Invoke-WebRequest'     = @('ka-core.ps1')
    # The dashboard's own listener. A server socket is not an egress path, but it is
    # network-capable code and it belongs on this list so that adding one is a decision.
    'System.Net.HttpListener' = @('ka-server.ps1')
}
# Every entry is matched as a literal string (see [regex]::Escape below): a pattern-looking
# entry here would never match anything and would read as coverage while being dead code.
$apiNames = @('Invoke-WebRequest', 'Invoke-RestMethod',
              'System.Net.WebClient', 'Net.WebClient',
              'Net.HttpWebRequest', 'Net.WebRequest', 'HttpClient', 'Sockets.TcpClient',
              'Sockets.UdpClient', 'DownloadFile', 'DownloadString', 'UploadFile',
              'UploadString', 'Start-BitsTransfer', 'curl.exe', 'wget',
              'System.Net.HttpListener', 'WinHttp', 'InternetOpen')
$hits = @{}
foreach ($f in $files) {
    $leaf = Split-Path -Leaf $f
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $f -Encoding UTF8)) {
        $i++
        foreach ($api in $apiNames) {
            if ($line -match [regex]::Escape($api)) {
                if (-not $hits.ContainsKey($api)) { $hits[$api] = @() }
                $hits[$api] += $leaf
            }
        }
    }
}
foreach ($api in ($hits.Keys | Sort-Object)) {
    $seen = @($hits[$api] | Sort-Object -Unique)
    $allowed = $apiAllow[$api]
    if (-not $allowed) {
        $fail += ("rule 2: network API '{0}' appears in {1} and is not allow-listed" -f $api, ($seen -join ', '))
        continue
    }
    foreach ($s in $seen) {
        if ($s -notin $allowed) {
            $fail += ("rule 2: network API '{0}' used by {1}; allow-list says {2}" -f $api, $s, ($allowed -join ', '))
        }
    }
}
# This one is here so an empty $hits cannot read as a pass: ka-core.ps1 really does call
# Invoke-WebRequest (measured 2026-09-04), so if the scan no longer sees it the scanner is
# broken, and "no findings" would be a lie rather than a clean bill.
if ('Invoke-WebRequest' -notin $hits.Keys) {
    $fail += 'rule 2: no Invoke-WebRequest hit anywhere - the scanner itself stopped working'
}
$ok += ("rule 2: network APIs in shipped code = {0}" -f (($hits.Keys | Sort-Object) -join ', '))

# ---- 3. the listener binds loopback only ----------------------------------------------
$srv = Join-Path $Root 'ka-server.ps1'
if (-not (Test-Path -LiteralPath $srv)) {
    $fail += 'rule 3: ka-server.ps1 is missing, so the bind surface cannot be checked'
} else {
    $prefixes = 0
    $badPrefix = 0
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $srv -Encoding UTF8)) {
        $i++
        if ($line -notmatch 'Prefixes\.Add') { continue }
        $prefixes++
        # Extract the URL itself rather than splitting on one quote style: the prefix could be
        # written single-quoted, and a Prefixes.Add this rule cannot read must fail the gate,
        # not quietly drop out of the count.
        $m = [regex]::Match($line, '[a-zA-Z]+://[^\s"''\)]+')
        if (-not $m.Success) {
            $fail += ("ka-server.ps1:{0} Prefixes.Add with no URL this gate can parse: {1}" -f $i, $line.Trim())
            continue
        }
        $host_ = Get-UrlHost $m.Value
        if ($host_ -notin $loopback) {
            $badPrefix++
            $fail += ("ka-server.ps1:{0} binds a non-loopback prefix: {1}" -f $i, $line.Trim())
        }
    }
    if ($prefixes -eq 0) { $fail += 'rule 3: no Prefixes.Add found in ka-server.ps1 - the check itself broke' }
    else { $ok += ("rule 3: {0} listener prefix(es), {1} non-loopback" -f $prefixes, $badPrefix) }
}

# ---- 4. CORS is never granted ----------------------------------------------------------
$corsLines = 0
# One pattern, three call shapes. Written double-quoted on purpose: inside a double-quoted
# PowerShell string a single quote is literal and only the double quote needs escaping, which
# is the one way to get both quote styles into a character class without ending the string.
$corsPat = "(Headers\.Add\s*\(\s*|AddHeader\s*\(\s*|Headers\[\s*)['`"]Access-Control"
foreach ($f in $files) {
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $f -Encoding UTF8)) {
        $i++
        # A response header being *set*. Prose about Access-Control-Allow-* is allowed; an
        # assignment is not, because that is what would open the /api/* surface to any origin.
        if ($line -match $corsPat) {
            $corsLines++
            $fail += ("{0}:{1} sets a CORS response header: {2}" -f (Split-Path -Leaf $f), $i, $line.Trim())
        }
    }
}
if (-not $corsLines) { $ok += 'rule 4: no Access-Control-Allow-* header is ever set' }

foreach ($s in $ok) { Write-Host ("  ok   {0}" -f $s) }
if ($fail.Count) {
    Write-Host ''
    Write-Host ("PRIVACY GATE FAILED: {0} finding(s)" -f $fail.Count) -ForegroundColor Red
    $fail | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Red }
    exit 1
}
Write-Host 'PRIVACY GATE OK: the shipped code contains no non-loopback endpoint and no CORS grant'
exit 0
