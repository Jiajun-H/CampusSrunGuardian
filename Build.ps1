$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'CampusSrunGuardian.cs'
$outputDirectory = Join-Path $PSScriptRoot 'bin'
$output = Join-Path $outputDirectory 'CampusSrunGuardian.exe'
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

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
& $compiler /nologo /optimize+ /target:exe "/out:$output" /reference:System.dll /reference:System.Core.dll /reference:System.Security.dll /reference:System.Web.Extensions.dll $source
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE."
}

Write-Host "Built $output"
