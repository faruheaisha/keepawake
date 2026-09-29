<#
    One list: what the portable zip carries. probe-fresh-data.ps1 and probe-motw.ps1 each used to
    hold their own copy of it, and when PRIVACY.md / SECURITY.md / CHANGELOG.md landed only one of
    the two noticed - two lists of the same thing drift by construction. Release packaging (CI)
    reads this file too, so "what the probe measured" and "what gets shipped" cannot disagree.

    The code half of the list is *discovered from the tree*, not typed. It used to be 17 hand-typed
    names, and a hand-typed list can only fail one way: a file that exists in the repository and is
    not in the list is simply not in the release. Nothing would have gone red - `build.ps1` checks the
    zip against this manifest in both directions (extra and missing both throw), so an omission here
    is a build that passes and a product that dies on the downloader's machine with "is not
    recognized as the name of a cmdlet". The same invariant already holds everywhere else in this
    repository: tests/ka-privacy.ps1 treats "root `*.ps1` + root `*.bat` + `dashboard/**`" as the
    shipped surface, and tests/ka-encoding.ps1 as the BOM/LF surface. Three gates and the build now
    read the same three directories, so the layout convention is the thing under test:

        a file at the repository root ships. If it should not, it does not belong at the root.

    The documents stay named by hand on purpose - README/PRIVACY/SECURITY/CHANGELOG/LICENSE/NOTICE is
    an editorial decision about what a downloader reads, and a new `.md` at the root is not a program.

    Because that sentence is the one hand-typed half, the line above is now *checked* instead of
    assumed: every file at the repository root has to be claimed - by the code globs, by the named
    documents, or as repository plumbing - and an unclaimed one stops the build. Before that, the
    root walk was an extension allow-list wearing the word "discovered": a `run.cmd` or `helper.vbs`
    dropped at the root matched no glob, so it quietly joined the set of things that are "not in the
    release", which is exactly the failure favicon.svg had.

    Dot-source it:   . (Join-Path $PSScriptRoot 'ka-release-files.ps1')
    Run it directly: it prints the list, one path per line, relative to the repo root.

    Deliberately absent: tests/, _tmp/, .gitignore, .gitattributes, and every runtime file
    (config.json, intent.json, state.json, machine.json, ka.log, ka-lid-backup.json). A zip that
    carries one of those is shipping somebody's machine. The runtime files are excluded by asking git
    what it ignores rather than by typing their names again - `.gitignore` already holds that list
    with the reasons, and a second copy of a list is the thing this file exists to remove.
#>
function Get-KaGitIgnoredName {
    <#
        Names git declares ignored (so: this machine's runtime litter, not repository content).
        Empty when the tree is not a git repository - a _tmp copy assembled by a probe holds only
        files someone put there on purpose, and "git could not answer" must not become "nothing is
        ignored" in the one place where it would let a stray file through unclaimed... which it does
        not: an unclaimed file then throws, and the probe that wants it shipped says so.

        Arguments, not a stdin pipe, and `--` in front of them: PowerShell 5.1 puts a UTF-8 BOM on
        the child's stdin (measured - `git check-ignore --stdin` answered the first name back as
        "\357\273\277ka.log", which matches no rule), and `--` is what keeps a file literally named
        `-C` from being read as an option instead of as a name.
    #>
    param([string]$Root, [string[]]$Names)
    if (-not $Names.Count) { return @() }
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { return @() }
    $gitPath = [string](Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if (-not $gitPath) { return @() }
    $out = @(& $gitPath -C $Root check-ignore --no-index -- $Names 2>$null)
    return @($out | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}

function Get-KaReleaseFile {
    $root = Split-Path -Parent $PSScriptRoot
    $code = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | ForEach-Object { $_.Name })
    $code += @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File | ForEach-Object { $_.Name })
    # .gitattributes pins *.cmd to eol=crlf and tests/ka-encoding.ps1 has a family for it, so a
    # second-language entry point at the root is a program, not a surprise: glob it like the others.
    $code += @(Get-ChildItem -LiteralPath $root -Filter '*.cmd' -File | ForEach-Object { $_.Name })
    # Forward or backslash both appear in this repository's history; the callers normalise. The
    # recursion is what catches a dashboard that grows a subdirectory - a flat list would drop it.
    $dash = Join-Path $root 'dashboard'
    $code += @(Get-ChildItem -LiteralPath $dash -File -Recurse |
        ForEach-Object { 'dashboard\' + $_.FullName.Substring($dash.Length + 1) })

    $docs = @('README.md', 'PRIVACY.md', 'SECURITY.md', 'CHANGELOG.md', 'PITFALLS.md', 'LICENSE', 'NOTICE')
    # Read by git and by nobody who downloaded a zip.
    $plumbing = @('.gitignore', '.gitattributes')

    # A discovery that quietly returns nothing is worse than a list, because it looks like a pass.
    # These are the files an entry point has to be able to dot-source; if any of them is not in
    # front of us, the derivation above is broken, not the product.
    foreach ($must in @('ka.ps1', 'ka-core.ps1', 'ka-gate.ps1', 'ka-server.ps1', 'ka-worker.ps1',
                        'ka.bat', 'on.bat', 'off.bat', 'panel.bat', 'tray.bat')) {
        if ($code -notcontains $must) {
            throw "release manifest: $($must) is not in front of us, so the tree scan above is broken - check the filters and the layout, not the product"
        }
    }
    if (@($code | Where-Object { $_ -like 'dashboard\*' }).Count -lt 4) {
        throw 'release manifest: fewer than four dashboard files found - the dashboard scan stopped reaching the dashboard'
    }

    # The claiming half: everything at the root must be accounted for, because "the root ships" is a
    # promise about the root, not about the three extensions someone thought of first.
    $atRoot = @(Get-ChildItem -LiteralPath $root -File -Force | ForEach-Object { $_.Name })
    $ignored = @(Get-KaGitIgnoredName -Root $root -Names $atRoot)
    $stray = @()
    foreach ($n in $atRoot) {
        if ($ignored -contains $n) { continue }
        if ($code -contains $n) { continue }
        if ($docs -contains $n) { continue }
        if ($plumbing -contains $n) { continue }
        $stray += $n
    }
    if ($stray.Count) {
        throw ("release manifest: {0} {1} at the repository root and no rule claims it - it would silently not ship (that is how favicon.svg got away). Ship it, move it out of the root, or name it as plumbing with a reason." `
            -f ($stray -join ', '), $(if ($stray.Count -gt 1) { 'are' } else { 'is' }))
    }

    @($code) + $docs
}
if ($MyInvocation.InvocationName -eq '.') { return }
foreach ($f in Get-KaReleaseFile) { Write-Output $f }
