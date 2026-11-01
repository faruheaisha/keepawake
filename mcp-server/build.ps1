<# Build the optional self-contained Windows MCP package and include dependency notices. #>
[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64',
    [string]$Dotnet = 'dotnet.exe',
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
$stage = Join-Path $root ('_tmp\mcp-stage-' + [guid]::NewGuid().ToString('N'))
$publish = Join-Path $stage 'publish'
$package = Join-Path $stage 'package'
[void](New-Item -ItemType Directory -Force -Path $publish, $package, (Join-Path $package 'third-party'))
try {
    & $Dotnet restore (Join-Path $PSScriptRoot 'KeepAwake.Mcp.csproj') -r $Runtime --locked-mode -p:SelfContained=true -p:PublishSingleFile=true
    if ($LASTEXITCODE -ne 0) { throw "MCP locked restore failed with exit code $LASTEXITCODE" }
    & $Dotnet publish (Join-Path $PSScriptRoot 'KeepAwake.Mcp.csproj') -c Release -r $Runtime --self-contained true --no-restore `
        -p:PublishSingleFile=true -o $publish
    if ($LASTEXITCODE -ne 0) { throw "MCP publish failed with exit code $LASTEXITCODE" }
    Copy-Item -LiteralPath (Join-Path $publish 'KeepAwake.Mcp.exe') -Destination $package
    foreach ($name in @('ka-core.ps1','ka-gate.ps1','ka-worker.ps1','ka-guard.ps1','LICENSE','NOTICE','PRIVACY.md')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $package
    }
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $package 'integrations'))
    Copy-Item -LiteralPath (Join-Path $root 'integrations\mcp') -Destination (Join-Path $package 'integrations\mcp') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $package 'README.md')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'packages.lock.json') -Destination (Join-Path $package 'third-party\packages.lock.json')

    $assets = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'obj\project.assets.json') | ConvertFrom-Json
    $packageRoot = @($assets.packageFolders.PSObject.Properties.Name | Where-Object { Test-Path -LiteralPath $_ })[0]
    if (-not $packageRoot) { throw 'NuGet package cache could not be located for license verification.' }
    $lock = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'packages.lock.json') | ConvertFrom-Json
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dep in $lock.dependencies.'net10.0'.PSObject.Properties) {
        $id = $dep.Name.ToLowerInvariant(); $version = [string]$dep.Value.resolved
        $nuspec = Join-Path (Join-Path (Join-Path $packageRoot $id) $version) ($id + '.nuspec')
        [xml]$xml = Get-Content -Raw -Encoding UTF8 -LiteralPath $nuspec
        $license = $xml.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='license']")
        if (-not $license -or $license.GetAttribute('type') -ne 'expression' -or $license.InnerText -notin @('MIT','Apache-2.0')) {
            throw "Review the license for $($dep.Name) $version before distributing it."
        }
        $copyright = $xml.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='copyright']")
        $lines.Add(('{0} {1}: {2}; {3}' -f $dep.Name, $version, $license.InnerText, $(if ($copyright) { $copyright.InnerText } else { '' })))
        $dependencyRoot = Split-Path -Parent $nuspec
        foreach ($notice in @(Get-ChildItem -LiteralPath $dependencyRoot -File | Where-Object { $_.Name -match '^(LICENSE|NOTICE|THIRD-PARTY-NOTICES)(\.|$)' })) {
            $notices = Join-Path $package 'third-party\packages'
            [void](New-Item -ItemType Directory -Force -Path $notices)
            Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $notices ($id + '-' + $notice.Name))
        }
    }
    $runtimeId = 'Microsoft.NETCore.App.Runtime.' + $Runtime
    $runtimeInfo = @($assets.project.frameworks.'net10.0'.downloadDependencies | Where-Object { $_.name -eq $runtimeId }) | Select-Object -First 1
    if (-not $runtimeInfo -or "$($runtimeInfo.version)" -notmatch '^\[([^,]+),') { throw 'Could not determine the bundled runtime version.' }
    $runtimeVersion = $Matches[1]
    $runtimeRoot = Join-Path (Join-Path $packageRoot $runtimeId.ToLowerInvariant()) $runtimeVersion
    Copy-Item -LiteralPath (Join-Path $runtimeRoot 'LICENSE.TXT') -Destination (Join-Path $package 'third-party\dotnet-MIT.txt')
    Copy-Item -LiteralPath (Join-Path $runtimeRoot 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $package 'third-party\dotnet-notices.txt')
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $package 'third-party\mcp-sdk-Apache-2.0.txt')
    $lines.Add(('{0} {1}: MIT' -f $runtimeId, $runtimeVersion))
    [IO.File]::WriteAllLines((Join-Path $package 'third-party\licenses.txt'), $lines, (New-Object Text.UTF8Encoding($false)))
    [void](New-Item -ItemType Directory -Force -Path $OutDir)
    $zip = Join-Path $OutDir ('KeepAwake-MCP-' + $Runtime + '.zip')
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $package '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Host "MCP package: $zip"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
