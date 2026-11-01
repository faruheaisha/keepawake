param([Parameter(Mandatory = $true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The in-box .NET Framework C# compiler is unavailable.' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath)
$payload = $OutputPath + '.payload.zip'
$assemblyInfo = $OutputPath + '.assembly.cs'
$icon = $OutputPath + '.app.ico'
& (Join-Path $PSScriptRoot 'convert-icon.ps1') -InputPng (Join-Path $PSScriptRoot 'assets\keepawake-brand.png') -OutputIco $icon
$resourceArgs = @(
    ('/resource:{0},KeepAwake.Brand' -f (Join-Path $PSScriptRoot 'assets\keepawake-brand.png'))
    ('/resource:{0},KeepAwake.Dawn' -f (Join-Path $PSScriptRoot 'assets\keepawake-dawn.png'))
    ('/resource:{0},KeepAwake.AppIcon' -f $icon)
)
foreach ($svg in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'assets\icons') -Filter '*.svg' -File)) {
    $resourceArgs += '/resource:' + $svg.FullName + ',KeepAwake.Icon.' + $svg.Name
}
foreach ($scene in @('active', 'complete', 'settings', 'activity', 'about', 'focus', 'presentation', 'longtask')) {
    $resourceArgs += '/resource:' + (Join-Path $PSScriptRoot ('assets\keepawake-' + $scene + '.png')) + ',KeepAwake.Art.' + $scene
}
$versionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'ka-core.ps1')), '(?m)^\$script:KaVersion\s*=\s*[''"]([^''"]+)[''"]')
if (-not $versionMatch.Success) { throw 'Cannot read the application version.' }
$version = $versionMatch.Groups[1].Value
$assemblyVersion = ($version -split '-')[0]
[IO.File]::WriteAllText($assemblyInfo, ('using System.Reflection; [assembly: AssemblyTitle("KeepAwake")] [assembly: AssemblyProduct("KeepAwake")] [assembly: AssemblyDescription("Native Windows desktop keep-awake application")] [assembly: AssemblyVersion("' + $assemblyVersion + '")] [assembly: AssemblyFileVersion("' + $assemblyVersion + '")] [assembly: AssemblyInformationalVersion("' + $version + '")]'), [Text.Encoding]::UTF8)
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
# Embed the complete engine: the executable also works when copied on its own.
$stream = [IO.File]::Create($payload)
try {
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)) {
            $entry = $zip.CreateEntry($file.Name)
            $out = $entry.Open()
            try { $bytes = [IO.File]::ReadAllBytes($file.FullName); $out.Write($bytes, 0, $bytes.Length) }
            finally { $out.Dispose() }
        }
        foreach ($name in @('LICENSE', 'NOTICE', 'PRIVACY.md', 'SECURITY.md', '.github/CONTRIBUTING.md', '.github/TRADEMARKS.md')) {
            $entry = $zip.CreateEntry($name)
            $out = $entry.Open()
            try { $bytes = [IO.File]::ReadAllBytes((Join-Path $root $name)); $out.Write($bytes, 0, $bytes.Length) }
            finally { $out.Dispose() }
        }
        $integration = Join-Path $root 'integrations\mcp'
        if (Test-Path -LiteralPath $integration) {
            foreach ($file in @(Get-ChildItem -LiteralPath $integration -File -Recurse)) {
                $name = 'integrations/mcp/' + $file.FullName.Substring($integration.Length + 1).Replace('\', '/')
                $entry = $zip.CreateEntry($name)
                $out = $entry.Open()
                try { $bytes = [IO.File]::ReadAllBytes($file.FullName); $out.Write($bytes, 0, $bytes.Length) }
                finally { $out.Dispose() }
            }
        }
        $cliIntegration = Join-Path $root 'integrations\cli'
        if (Test-Path -LiteralPath $cliIntegration) {
            foreach ($file in @(Get-ChildItem -LiteralPath $cliIntegration -File -Recurse)) {
                $name = 'integrations/cli/' + $file.FullName.Substring($cliIntegration.Length + 1).Replace('\', '/')
                $entry = $zip.CreateEntry($name)
                $out = $entry.Open()
                try { $bytes = [IO.File]::ReadAllBytes($file.FullName); $out.Write($bytes, 0, $bytes.Length) }
                finally { $out.Dispose() }
            }
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }
try {
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ /utf8output `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
        /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
        ('/win32manifest:' + (Join-Path $PSScriptRoot 'app.manifest')) `
        ('/win32icon:' + $icon) $resourceArgs `
        ('/resource:' + $payload + ',KeepAwake.Payload') ('/out:' + $OutputPath) @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs' -File | ForEach-Object { $_.FullName }) $assemblyInfo
    if ($LASTEXITCODE -ne 0) { throw "Desktop compiler exited $LASTEXITCODE" }
} finally { Remove-Item -LiteralPath $payload, $assemblyInfo, $icon -Force -ErrorAction SilentlyContinue }
Write-Host "Desktop executable: $OutputPath"
