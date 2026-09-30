param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
if ([String]::IsNullOrWhiteSpace($Version)) {
    $Version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$') { throw 'Invalid project version.' }

$source = Join-Path $PSScriptRoot 'CampusSrunGuardian.cs'
$outputDirectory = Join-Path $PSScriptRoot 'bin'
$output = Join-Path $outputDirectory 'CampusSrunGuardian.exe'
$launcherSource = Join-Path $PSScriptRoot 'CampusSrunGuardianControlPanel.cs'
$launcherManifest = Join-Path $PSScriptRoot 'CampusSrunGuardianControlPanel.manifest'
$launcherOutput = Join-Path $PSScriptRoot 'CampusSrunGuardianControlPanel.exe'
$frameworkDirectory = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
if (-not (Test-Path -LiteralPath (Join-Path $frameworkDirectory 'csc.exe'))) {
    $frameworkDirectory = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
}
$compiler = Join-Path $frameworkDirectory 'csc.exe'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The Windows .NET Framework C# compiler was not found.'
}
if (-not (Test-Path -LiteralPath $source)) {
    throw "Source file not found: $source"
}
if (-not (Test-Path -LiteralPath $launcherSource) -or -not (Test-Path -LiteralPath $launcherManifest)) {
    throw 'The control-panel launcher source or manifest is missing.'
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$versionSource = Join-Path $outputDirectory 'AppVersion.g.cs'
$assemblyVersion = ($Version -split '-', 2)[0] + '.0'
$metadata = @"
using System.Reflection;
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$Version")]
internal static class AppMetadata { internal const string Version = "$Version"; }
"@
[IO.File]::WriteAllText($versionSource, $metadata, [Text.Encoding]::UTF8)
& $compiler /nologo /optimize+ /target:exe "/out:$output" /reference:System.dll /reference:System.Core.dll /reference:System.Security.dll /reference:System.Web.Extensions.dll $versionSource $source
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE."
}

& $compiler /nologo /optimize+ /target:winexe "/out:$launcherOutput" "/win32manifest:$launcherManifest" /reference:System.dll /reference:System.Windows.Forms.dll $versionSource $launcherSource
if ($LASTEXITCODE -ne 0) {
    throw "Control-panel launcher compilation failed with exit code $LASTEXITCODE."
}

Write-Host "Built $output"
Write-Host "Built $launcherOutput"
