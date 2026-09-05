<#
    Where the Inno Setup compiler is, in one place.

    packaging/build.ps1 needs it to compile the installer and tests/probe-iss.ps1 needs it to
    compile the same script as a check. Two search orders describing one tool is how a release
    finds the compiler and the probe does not, so both dot-source this.
#>

function Get-KaIscc {
    <#
        Prefer the 6.x compiler: KeepAwake.iss is authored against Inno Setup 6's defaults - and
        6.7.3 is what "winget install JRSoftware.InnoSetup" and CI's "choco install innosetup"
        put here. Finding only a 7.x is still worth using, but it has to say so: reporting "Inno
        Setup is not installed" on a machine that has it installed is a false negative that
        wastes a release attempt, and silently compiling with a different major version than the
        script assumes is worse than an honest warning.
    #>
    $found = @()
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) { $found += $cmd.Source }
    foreach ($var in @('ProgramFiles(x86)', 'ProgramFiles', 'LocalAppData')) {
        $base = [Environment]::GetEnvironmentVariable($var)
        if (-not $base) { continue }
        foreach ($ver in @('Inno Setup 6', 'Inno Setup 7')) {
            $found += (Join-Path $base "$ver\ISCC.exe")
            $found += (Join-Path $base "Programs\$ver\ISCC.exe")
        }
    }
    $present = @($found | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $present.Count) { return $null }
    $six = @($present | Where-Object { $_ -like '*Inno Setup 6*' })
    if ($six.Count) { return $six[0] }
    Write-Host ('  note: no Inno Setup 6 found - using {0}, and KeepAwake.iss is authored against 6 defaults' -f $present[0])
    return $present[0]
}
