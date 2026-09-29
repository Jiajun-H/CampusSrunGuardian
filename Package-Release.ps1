param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$')]
    [string]$Version = '0.1.0'
)

$ErrorActionPreference = 'Stop'
$buildScript = Join-Path $PSScriptRoot 'Build.ps1'
$exe = Join-Path $PSScriptRoot 'bin\CampusSrunGuardian.exe'
$distRoot = Join-Path $PSScriptRoot 'dist'
$packageName = "CampusSrunGuardian-$Version"
$packageDirectory = Join-Path $distRoot $packageName
$archive = Join-Path $distRoot "$packageName.zip"

& $buildScript
if (-not (Test-Path -LiteralPath $exe)) {
    throw 'The build did not produce CampusSrunGuardian.exe.'
}
if (Test-Path -LiteralPath $packageDirectory) {
    throw "Package directory already exists: $packageDirectory. Move it aside before packaging again."
}
if (Test-Path -LiteralPath $archive) {
    throw "Release archive already exists: $archive. Move it aside before packaging again."
}

New-Item -ItemType Directory -Path (Join-Path $packageDirectory 'bin') -Force | Out-Null
Copy-Item -LiteralPath $exe -Destination (Join-Path $packageDirectory 'bin\CampusSrunGuardian.exe')
foreach ($name in @(
    'ControlPanel.ps1',
    'Start-CampusSrunGuardian.cmd',
    'Install-StartupTask.ps1',
    'Remove-StartupTask.ps1',
    'Invoke-CampusSrunOnce.ps1',
    'README.md',
    'THIRD_PARTY_NOTICES.md',
    'LICENSE'
)) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Release file is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination $packageDirectory
}

Compress-Archive -Path (Join-Path $packageDirectory '*') -DestinationPath $archive -CompressionLevel Optimal
Write-Host "Created $archive"
