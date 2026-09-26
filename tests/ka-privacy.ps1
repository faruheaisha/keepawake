<#
    PRIVACY GATE - the "nothing leaves the machine" claim, checked against the source
    instead of against the README.

    PRIVACY.md promises a download-and-use product with no telemetry, no update check and no
    server of its own. That is only worth anything if a future commit cannot quietly break it.
    Four rules, all of them textual on purpose: they run in a second, need no network, no
    elevation, and no running worker.

      1. every http(s):// literal in shipped product code is a loopback URL;
      2. the network-capable families touched by shipped code form an explicit allow-list, so
         a new HTTP/socket/DNS helper - or a downloader named in an argument list - is a
         deliberate edit to this file, not an accident;
      3. the dashboard listener binds loopback prefixes only (no "+", "*", 0.0.0.0);
      4. every response header the panel sets is named on an allow-list, and no Access-Control-*
         is ever among them - that is what makes the X-Ka-Client header a real cross-origin
         boundary rather than a suggestion;

    A comment mentioning a URL counts: this scans literals, and the honest reading of rule 1 is
    "no non-loopback URL appears in the shipped text at all". Loopback examples in prose are
    fine, so the rule is not weakened to accommodate the docs - docs/ and README are out of
    scope here because a documented GitHub link is not an egress path. packaging/ is in scope
    since 2026-09-26: the installer runs before any of this code does, so it is not documentation.

    Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/ka-privacy.ps1
            ... -Root <dir>     scan another copy (used to prove the gate can fail)
#>
[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Root)) { Write-Host "no such root: $Root"; exit 2 }

# Shipped product surface only: the engines, the CLI, the launchers, the panel - and the installer,
# which is the first thing a downloader runs and used to be outside this scan entirely (measured
# 2026-09-26: packaging/ holds 4 files and zero 'http' substrings, so this closed a door nobody had
# walked through yet rather than a hole; a [Run] openurl or a Start-Process of a downloader added
# there would have been invisible to the file that exists to make "nothing leaves the machine" a
# checked claim).
$files = @(Get-ChildItem -LiteralPath $Root -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
$files += @(Get-ChildItem -LiteralPath $Root -Filter '*.bat' -File | ForEach-Object { $_.FullName })
$dash = Join-Path $Root 'dashboard'
if (Test-Path -LiteralPath $dash) {
    $files += @(Get-ChildItem -LiteralPath $dash -File -Recurse | ForEach-Object { $_.FullName })
}
$pack = Join-Path $Root 'packaging'
if (Test-Path -LiteralPath $pack) {
    $files += @(Get-ChildItem -LiteralPath $pack -File -Recurse | ForEach-Object { $_.FullName })
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

# ---- 2. network-capable code is an explicit allow-list -------------------------------
# Measured 2026-09-04: the only client call in the product is ka-core.ps1 talking to the
# panel it just started (a status probe and /api/server/stop). Anything else has to be
# added here by hand, which is the point.
#
# Measured 2026-09-26: what is scanned used to be a list of API *names to look for*, and such a
# list is fail-open by construction. A raw TCP socket plus a DNS lookup added to ka-worker.ps1 -
# connect host built as 'telemetry' + '.example' + '.com' - left this gate at exit 0: no name on
# the list matched, and rule 1 cannot see a host assembled out of pieces. So the markers below are
# families, not products: every BCL network type lives under System.Net, a P-Invoke has to spell
# its DLL name, and an external downloader has to be named in the argument list. Anything new
# inside a family is a finding until somebody allow-lists it here, which is the decision the rule
# exists to force. It does not make an unguessable capability impossible - it makes silence about
# one require an edit to this file.
$apiAllow = @{
    'Invoke-WebRequest' = @('ka-core.ps1')
    # Broader than the two above on purpose: catches [Net.WebRequest] and FtpWebRequest spelled
    # without the Invoke- prefix.
    'WebRequest'        = @('ka-core.ps1')
    # The dashboard's own listener. A server socket is not an egress path, but it is
    # network-capable code and it belongs on this list so that adding one is a decision.
    'System.Net'        = @('ka-server.ps1')
    'HttpListener'      = @('ka-server.ps1')
}
# Every entry is matched as a literal string (see [regex]::Escape below): a pattern-looking
# entry here would never match anything and would read as coverage while being dead code.
$apiNames = @('Invoke-WebRequest', 'Invoke-RestMethod',
              'System.Net', 'Sockets', 'Net.Dns', 'HttpListener', 'WebClient', 'WebRequest',
              'HttpClient', 'TcpListener', 'Sockets.TcpClient', 'Sockets.UdpClient', 'UdpClient',
              'Smtp', 'MailMessage',
              'DownloadFile', 'DownloadString', 'UploadFile', 'UploadString',
              'Start-BitsTransfer', 'bitsadmin', 'curl.exe', 'wget',
              'certutil', 'mshta', 'regsvr32', 'rundll32', 'urlmon', 'winhttp', 'wininet',
              'ws2_32', 'xmlhttp', 'WinHttp', 'InternetOpen')
foreach ($listed in $apiAllow.Keys) {
    if ($apiNames -notcontains $listed) {
        $fail += ("rule 2: allow-list names '{0}' but the scan never looks for it - dead cover" -f $listed)
    }
}
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
# These are here so an empty $hits cannot read as a pass: ka-core.ps1 really does call
# Invoke-WebRequest and ka-server.ps1 really does new up System.Net.HttpListener (measured
# 2026-09-04, re-measured 2026-09-26 with the markers above hitting exactly those two files).
# If the scan stops seeing either, the scanner is broken, and "no findings" would be a lie
# rather than a clean bill.
foreach ($must in @('Invoke-WebRequest', 'System.Net')) {
    if ($must -notin $hits.Keys) {
        $fail += ("rule 2: no {0} hit anywhere - the scanner itself stopped working" -f $must)
    }
}
$ok += ("rule 2: network APIs in shipped code = {0}" -f (($hits.Keys | Sort-Object) -join ', '))

# ---- 3. the listener binds loopback only ----------------------------------------------
# This rule reads one file by name. A listener that appeared somewhere else is not invisible:
# rule 2 catches the type in a file that never had it, and rule 1 reads the prefix literal -
# measured, not reasoned, by the 'a second listener, in another file' leg of
# tests/ka-privacy-mutation.ps1.
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

# ---- 4. every response header that gets set is a known one ----------------------------
# This rule used to look for one string being set: "Access-Control". Same flaw rule 2 shipped with,
# found the same way - a header named in pieces ('Access-' + 'Control-Allow-Origin') and a header
# nobody thought of (an X-Ka-Machine carrying %COMPUTERNAME%) both leave it silent. So the rule is
# now about the *channel*: HttpListener has exactly three ways to set a response header
# (Headers.Add, Headers.Set / Headers['Name'] =, AddHeader), which is a closed set, so enumerating
# the writes is discovery rather than a list of things to look for. Every name written has to be
# allow-listed here, and a name this gate cannot read is a finding instead of a skip - the same
# choice rule 3 makes for an unparsable Prefixes.Add.
# Measured 2026-09-26: shipped code writes exactly one header, ka-server.ps1:346 Cache-Control.
# The typed properties (ContentType, ContentLength64, StatusCode) are not this channel and are not
# policed here; reading a REQUEST header ($req.Headers['Host']) is not writing a response header.
$hdrAllow = @('Cache-Control')
$corsLines = 0
$hdrSeen = 0
$hdrAddPat = "(Headers\.(?:Add|Set)\s*\(\s*|AddHeader\s*\(\s*)"
foreach ($f in $files) {
    $i = 0
    foreach ($line in (Get-Content -LiteralPath $f -Encoding UTF8)) {
        $i++
        $name = $null
        $m = [regex]::Match($line, ($hdrAddPat + "(?<q>['`"])(?<n>[^'`"]+)\k<q>"))
        if ($m.Success) { $name = $m.Groups['n'].Value }
        else {
            $m = [regex]::Match($line, "Headers\[\s*(?<q>['`"])(?<n>[^'`"]+)\k<q>\s*\]\s*=")
            if ($m.Success) { $name = $m.Groups['n'].Value }
        }
        if ($null -eq $name) {
            if (-not [regex]::IsMatch($line, $hdrAddPat) -and
                -not [regex]::IsMatch($line, "Headers\[\s*[^'\]]+\]\s*=")) { continue }
            $hdrSeen++
            $fail += ("{0}:{1} sets a response header whose name this gate cannot read: {2}" -f `
                      (Split-Path -Leaf $f), $i, $line.Trim())
            continue
        }
        $hdrSeen++
        if ($name -like 'Access-Control*') {
            $corsLines++
            $fail += ("{0}:{1} sets a CORS response header: {2}" -f (Split-Path -Leaf $f), $i, $line.Trim())
        }
        elseif ($name -notin $hdrAllow) {
            $fail += ("{0}:{1} sets response header '{2}'; the allow-list says {3}" -f `
                      (Split-Path -Leaf $f), $i, $name, ($hdrAllow -join ', '))
        }
    }
}
if (-not $hdrSeen) {
    $fail += 'rule 4: no response header write anywhere - either the panel sets none, or the pattern stopped matching'
}
$ok += ("rule 4: {0} response header write(s), {1} CORS grant(s), names allowed = {2}" -f `
        $hdrSeen, $corsLines, ($hdrAllow -join ', '))

foreach ($s in $ok) { Write-Host ("  ok   {0}" -f $s) }
if ($fail.Count) {
    Write-Host ''
    Write-Host ("PRIVACY GATE FAILED: {0} finding(s)" -f $fail.Count) -ForegroundColor Red
    $fail | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Red }
    exit 1
}
Write-Host 'PRIVACY GATE OK: the shipped code contains no non-loopback endpoint and no CORS grant'
exit 0
