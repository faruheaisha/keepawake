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

    Dot-source it:   . (Join-Path $PSScriptRoot 'ka-release-files.ps1')
    Run it directly: it prints the list, one path per line, relative to the repo root.

    Deliberately absent: tests/, _tmp/, .gitignore, .gitattributes, and every runtime file
    (config.json, intent.json, state.json, machine.json, ka.log, ka-lid-backup.json). A zip that
    carries one of those is shipping somebody's machine.
#>
function Get-KaReleaseFile {
    $root = Split-Path -Parent $PSScriptRoot
    $code = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | ForEach-Object { $_.Name })
    $code += @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File | ForEach-Object { $_.Name })
    # Forward or backslash both appear in this repository's history; the callers normalise. The
    # recursion is what catches a dashboard that grows a subdirectory - a flat list would drop it.
    $dash = Join-Path $root 'dashboard'
    $code += @(Get-ChildItem -LiteralPath $dash -File -Recurse |
        ForEach-Object { 'dashboard\' + $_.FullName.Substring($dash.Length + 1) })

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
    @($code) + @('README.md', 'PRIVACY.md', 'SECURITY.md', 'CHANGELOG.md', 'LICENSE', 'NOTICE')
}
if ($MyInvocation.InvocationName -eq '.') { return }
foreach ($f in Get-KaReleaseFile) { Write-Output $f }
