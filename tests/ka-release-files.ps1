<#
    One list: what the portable zip carries. probe-fresh-data.ps1 and probe-motw.ps1 each used to
    hold their own copy of it, and when PRIVACY.md / SECURITY.md / CHANGELOG.md landed only one of
    the two noticed - two lists of the same thing drift by construction. Release packaging (CI)
    reads this file too, so "what the probe measured" and "what gets shipped" cannot disagree.

    Dot-source it:   . (Join-Path $PSScriptRoot 'ka-release-files.ps1')
    Run it directly: it prints the list, one path per line, relative to the repo root.

    Deliberately absent: tests/, _tmp/, .gitignore, .gitattributes, and every runtime file
    (config.json, intent.json, state.json, machine.json, ka.log, ka-lid-backup.json). A zip that
    carries one of those is shipping somebody's machine.
#>
function Get-KaReleaseFile {
    @('ka.ps1', 'ka-core.ps1', 'ka-gate.ps1', 'ka-worker.ps1', 'ka-server.ps1', 'ka-guard.ps1',
      'ka-lid.ps1', 'ka-tray.ps1',
      'ka.bat', 'panel.bat', 'on.bat', 'off.bat', 'tray.bat',
      'README.md', 'PRIVACY.md', 'SECURITY.md', 'CHANGELOG.md', 'LICENSE', 'NOTICE',
      'dashboard\index.html', 'dashboard\app.js', 'dashboard\styles.css', 'dashboard\i18n.js')
}
if ($MyInvocation.InvocationName -eq '.') { return }
foreach ($f in Get-KaReleaseFile) { Write-Output $f }
