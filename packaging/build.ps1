<#
    Build what a person downloads: the portable zip, the per-user setup.exe Inno compiles out of a
    staging directory written here, and the SHA256SUMS covering both. All three come out of
    `Get-KaReleaseFile`, the one manifest of what a release carries — the zip and the installer can
    therefore never disagree about what the product is, which is the same class of bug that made the
    probes keep their own file lists.

    Nothing here is guessed: the version is *parsed* out of ka-core.ps1 rather than run, so a
    machine in ConstrainedLanguage mode still packages correctly, and the finished zip is read
    back and compared with the manifest entry by entry (names and byte lengths). A zip that
    carries one file the manifest does not name — somebody's `config.json`, a `_tmp/` — fails
    the build instead of shipping somebody's machine.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File packaging\build.ps1
        ... -OutDir <dir>       where dist lands (default: <repo>\dist)
        ... -Stage              also write the staging directory Inno compiles from
        ... -Sum                (re)write SHA256SUMS for what is already in -OutDir and stop.
                                Combined with any of the switches below it is a no-op - the full
                                build hashes at the end anyway.
        ... -Smoke              extract the finished zip and run it from a scratch data root
        ... -Installer          compile the per-user setup.exe with Inno Setup (implies -Stage)
        ... -ShowVersion        print the version the build would use and stop

    -ShowVersion exists for CI: the tag, the file names and the installer's version field all
    have to agree with ka-core.ps1, and the way to keep three readers honest is to give them
    one parser. It is called that rather than -Version because PowerShell variable names are
    case-insensitive, and $version is the variable the build flow itself assigns.

    -Smoke exists because "the archive has the right entries" and "the archive works" are two
    different claims, and the second is the one a person who downloaded it cares about. It runs
    against its own KA_DATA, so the machine this builds on keeps its own config, log and intent.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$Stage,
    [switch]$Sum,
    [switch]$Smoke,
    [switch]$Installer,
    [switch]$ShowVersion
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$defaultOutDir = Join-Path $root 'dist'
if (-not $OutDir) { $OutDir = $defaultOutDir }
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

function Get-KaBuildVersion {
    # Parsed, not executed: reading ka-core.ps1 means Add-Type never runs during a build.
    $core = Join-Path $root 'ka-core.ps1'
    $m = [regex]::Match([IO.File]::ReadAllText($core), '(?m)^\$script:KaVersion\s*=\s*[''"]([^''"]+)[''"]')
    if (-not $m.Success) { throw "no `$script:KaVersion literal found in $core" }
    $v = $m.Groups[1].Value
    # This string becomes a file name, and CI compares it against the git tag. Anything that is
    # not a plain version stops here rather than writing outside dist/.
    if ($v -notmatch '^\d+\.\d+(\.\d+)?(-[0-9A-Za-z.\-]+)?$') { throw "ka-core.ps1 says version '$v', which is not usable as a file name" }
    return $v
}

function Get-KaManifest {
    . (Join-Path $root 'tests/ka-release-files.ps1')
    # The manifest is a filesystem spelling (dashboard\app.js); a zip entry is always '/'.
    @(Get-KaReleaseFile | ForEach-Object { $_.Replace('\', '/') })
}

function Copy-ManifestTo([string]$Dest, [string[]]$Names) {
    foreach ($n in $Names) {
        $src = Join-Path $root ($n -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { throw "the manifest names $n but it is not in the tree" }
        $dst = Join-Path $Dest ($n -replace '/', '\')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst)
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

function New-KaZip([string]$ZipPath, [string[]]$Names) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ZipPath)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $fs = [IO.File]::Open($ZipPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $arch = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($n in $Names) {
                $src = Join-Path $root ($n -replace '/', '\')
                $bytes = [IO.File]::ReadAllBytes($src)
                $e = $arch.CreateEntry($n, [IO.Compression.CompressionLevel]::Optimal)
                $es = $e.Open()
                try { $es.Write($bytes, 0, $bytes.Length) } finally { $es.Dispose() }
            }
        } finally { $arch.Dispose() }
    } finally { $fs.Dispose() }
}

function Test-KaZip([string]$ZipPath, [string[]]$Names) {
    # Read it back with the same API a user's Explorer uses. What is measured here is the
    # artifact, not the intent: extra entries and short entries both fail the build.
    $want = @{}
    foreach ($n in $Names) { $want[$n] = (Get-Item -LiteralPath (Join-Path $root ($n -replace '/', '\'))).Length }
    $problems = @()
    $z = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $have = @{}
        foreach ($e in $z.Entries) {
            if (-not $e.Name) { continue }        # a directory entry carries no bytes
            $key = $e.FullName.Replace('\', '/')
            if ($have.ContainsKey($key)) { $problems += "duplicate entry $key"; continue }
            $have[$key] = $e.Length
        }
        foreach ($extra in @($have.Keys | Where-Object { -not $want.ContainsKey($_) })) { $problems += "entry not in the manifest: $extra" }
        foreach ($missing in @($want.Keys | Where-Object { -not $have.ContainsKey($_) })) { $problems += "manifest file missing from the zip: $missing" }
        foreach ($shared in @($have.Keys | Where-Object { $want.ContainsKey($_) })) {
            if ([long]$have[$shared] -ne [long]$want[$shared]) { $problems += "size mismatch for $shared : zip=$($have[$shared]) disk=$($want[$shared])" }
        }
    } finally { $z.Dispose() }
    return $problems
}

function Set-KaSums([string]$Dir) {
    $sum = Join-Path $Dir 'SHA256SUMS'
    $lines = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -ne 'SHA256SUMS' } | Sort-Object Name)) {
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += ('{0}  {1}' -f $h, $f.Name)      # two spaces: the sha256sum text format
    }
    if (-not $lines.Count) { Write-Host "  no artifacts in $Dir - nothing to hash"; return }
    [IO.File]::WriteAllText($sum, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Host ("  SHA256SUMS <- {0} file(s)" -f $lines.Count)
    foreach ($l in $lines) { Write-Host "    $l" }
}

function Invoke-KaSmoke([string]$ZipPath, [string]$Version) {
    <#
        "The archive has the right entries" and "the archive works" are different claims, and the
        second is the one a person who downloaded it cares about. So: unzip with the same API
        Explorer uses, run what came out, and read back what it says about itself.

        It runs under **in-box** Windows PowerShell rather than whatever hosts this build, because
        that is what a downloader's ka.bat gets. It runs against a scratch KA_DATA because the
        machine doing the packaging must keep its own config, log and intent - the returned paths
        are the proof that the override was taken, not an assumption about it.
    #>
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { return @("in-box PowerShell is not at $ps - the smoke has nothing to run under") }

    $work = Join-Path $root ('_tmp\smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $app = Join-Path $work 'app'
    $data = Join-Path $work 'data'
    $problems = @()
    try {
        $null = New-Item -ItemType Directory -Force -Path $app, $data
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $app
        $entry = Join-Path $app 'ka.ps1'
        if (-not (Test-Path -LiteralPath $entry)) { return @('the extracted archive has no ka.ps1') }
        $before = @(Get-ChildItem -LiteralPath $app -Recurse -File | ForEach-Object { $_.FullName.Substring($app.Length + 1) })

        $stdoutFile = Join-Path $work 'status.json'
        $stderrFile = Join-Path $work 'status.err'
        $prevData = $env:KA_DATA
        try {
            $env:KA_DATA = $data
            # OutputEncoding is forced to UTF-8: the JSON echoes the scratch paths back, and on a
            # box whose OEM codepage is 936 those bytes would arrive as mojibake and the two
            # path assertions below would fail on a perfectly good artifact.
            $child = '-NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; & ''' + $entry + ''' status -Json"'
            $proc = Start-Process -FilePath $ps -ArgumentList $child -NoNewWindow -Wait -PassThru `
                                  -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            $code = [int]$proc.ExitCode
        } finally {
            if ($null -eq $prevData) { Remove-Item Env:KA_DATA -ErrorAction SilentlyContinue } else { $env:KA_DATA = $prevData }
        }

        $text = ''
        if (Test-Path -LiteralPath $stdoutFile) { $text = [IO.File]::ReadAllText($stdoutFile, (New-Object Text.UTF8Encoding($false))) }
        if ($code -ne 0) {
            $err = ''
            if (Test-Path -LiteralPath $stderrFile) { $err = ([IO.File]::ReadAllText($stderrFile)).Trim() }
            $problems += ('the extracted ka.ps1 status -Json exited {0}{1}' -f $code, $(if ($err) { ": $err" } else { '' }))
        }

        $obj = $null
        try { $obj = $text | ConvertFrom-Json }
        catch { $problems += ('status -Json did not print parseable JSON: {0}' -f $_.Exception.Message) }
        if (-not $obj) { return $problems }

        if ([string]$obj.version -ne $Version) { $problems += "the artifact reports version '$($obj.version)' but the build is $Version" }
        $roots = [ordered]@{ dataRoot = $data; programRoot = $app }
        foreach ($k in $roots.Keys) {
            $got = [string]$obj.$k
            try { $got = [IO.Path]::GetFullPath($got) } catch { }
            $want = [IO.Path]::GetFullPath($roots[$k])
            if ($got.TrimEnd('\') -ine $want.TrimEnd('\')) { $problems += "the artifact's $k is '$got', not the scratch path it was handed" }
        }
        if ($obj.dataError) { $problems += "the artifact reports a data-root problem: $($obj.dataError)" }

        $after = @(Get-ChildItem -LiteralPath $app -Recurse -File | ForEach-Object { $_.FullName.Substring($app.Length + 1) })
        $wrote = @($after | Where-Object { $before -notcontains $_ })
        if ($wrote.Count) { $problems += ('the run wrote into its own program directory: {0}' -f ($wrote -join ', ')) }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $problems
}

. (Join-Path $PSScriptRoot 'ka-iscc.ps1')

function Start-KaInstaller([string]$Version, [string]$Staging) {
    <#
        Inno Setup is a separate tool, so the honest states here are "compiled it" and
        "cannot compile it here" - never "skipped it quietly", which is how a release ends up
        published with one of its two artifacts missing.

        The paths are only passed on the command line when -OutDir moved the output. Otherwise
        KeepAwake.iss resolves "..\dist" and "..\dist\staging" relative to itself, which keeps
        a quoted /D value holding a path with spaces off the critical path: that spelling is
        the one thing about this step that cannot be checked on a machine without Inno.
    #>
    $iss = Join-Path $PSScriptRoot 'KeepAwake.iss'
    if (-not (Test-Path -LiteralPath $iss)) { throw "no $iss - there is no installer script to compile" }
    if (-not (Test-Path -LiteralPath $Staging)) { throw "no staging directory at $Staging - Inno installs from it, so build with -Stage (or -Installer, which implies it)" }
    $iscc = Get-KaIscc
    if (-not $iscc) {
        throw 'Inno Setup 6 (or 7) is not installed here. Install it ("winget install JRSoftware.InnoSetup" or "choco install innosetup") and run this again - the setup.exe is not optional in a release.'
    }
    $cmdArgs = @('/DMyAppVersion=' + $Version)
    if ([IO.Path]::GetFullPath($OutDir) -ine [IO.Path]::GetFullPath($defaultOutDir)) {
        $cmdArgs += ('/DSourceDir="{0}"' -f $Staging)
        $cmdArgs += ('/DOutDir="{0}"' -f $OutDir)
    }
    $cmdArgs += ('"{0}"' -f $iss)
    $proc = Start-Process -FilePath $iscc -ArgumentList ($cmdArgs -join ' ') -WorkingDirectory $PSScriptRoot -NoNewWindow -Wait -PassThru
    $setup = Join-Path $OutDir ('KeepAwake-{0}-setup.exe' -f $Version)
    if (-not (Test-Path -LiteralPath $setup)) {
        throw ("ISCC exited {0} and left no {1}. If -OutDir was overridden, Inno's command line may not have taken the quoted path: the fallback is to run ISCC from packaging\ with the .iss defaults." -f [int]$proc.ExitCode, (Split-Path -Leaf $setup))
    }
    if ([int]$proc.ExitCode -ne 0) { throw "ISCC exited $([int]$proc.ExitCode) even though it produced $(Split-Path -Leaf $setup)" }
    $mb = [math]::Round((Get-Item -LiteralPath $setup).Length / 1MB, 2)
    Write-Host ("  ok   {0} : {1} MB (compiled by {2})" -f (Split-Path -Leaf $setup), $mb, $iscc)
}

$version = Get-KaBuildVersion
if ($ShowVersion) { Write-Output $version; exit 0 }   # stdout holds nothing but the version
$names = Get-KaManifest
Write-Host ("packaging KeepAwake v{0}  ({1} files from tests/ka-release-files.ps1)" -f $version, $names.Count)

# -Sum alone means "hash what is already there and stop". It must not swallow the other switches:
# the full build reaches the same Set-KaSums at the end of this file, and exiting here would print
# a fresh SHA256SUMS over artifacts this run never rebuilt.
if ($Sum -and -not ($Stage -or $Installer -or $Smoke)) { Set-KaSums $OutDir; exit 0 }

if (-not (Test-Path -LiteralPath (Join-Path $root 'tests/ka-release-files.ps1'))) { throw 'tests/ka-release-files.ps1 is missing - there is no manifest to build from' }
if (-not $names.Count) { throw 'the manifest came back empty' }

$zipName = 'KeepAwake-{0}-portable.zip' -f $version
$zipPath = Join-Path $OutDir $zipName
New-KaZip $zipPath $names
$problems = @(Test-KaZip $zipPath $names)
if ($problems.Count) {
    foreach ($p in $problems) { Write-Host "  FAIL $p" -ForegroundColor Red }
    throw "the zip does not match the manifest ($($problems.Count) problem(s))"
}
$mb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
Write-Host ("  ok   $zipName : {0} entries, all present with matching byte lengths, {1} MB" -f $names.Count, $mb)

if ($Smoke) {
    $smokes = @(Invoke-KaSmoke $zipPath $version)
    if ($smokes.Count) {
        foreach ($p in $smokes) { Write-Host "  FAIL $p" -ForegroundColor Red }
        throw "the portable zip did not run ($($smokes.Count) problem(s))"
    }
    Write-Host '  ok   smoke: extracted, ran "status -Json" under in-box PowerShell, answered with this version, and wrote nothing into itself'
}

# -Installer implies staging: Inno has no file list of its own, so it needs the directory the
# manifest was copied into.
$stg = Join-Path $OutDir 'staging'
if ($Stage -or $Installer) {
    # Inno installs from here, so the installer gets its file list from the same manifest and
    # the .iss carries none of its own.
    if (Test-Path -LiteralPath $stg) { Remove-Item -LiteralPath $stg -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $stg
    Copy-ManifestTo $stg $names
    $got = @(Get-ChildItem -LiteralPath $stg -File -Recurse | ForEach-Object { $_.FullName.Substring($stg.Length + 1).Replace('\', '/') })
    $extra = @($got | Where-Object { $names -notcontains $_ })
    $missing = @($names | Where-Object { $got -notcontains $_ })
    if ($extra.Count -or $missing.Count) { throw "staging does not match the manifest: extra=[$($extra -join ' ')] missing=[$($missing -join ' ')]" }
    Write-Host ("  ok   staging: {0} files in {1}" -f $got.Count, $stg)
}

if ($Installer) { Start-KaInstaller $version $stg }

Set-KaSums $OutDir
exit 0
