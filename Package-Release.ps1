param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
if ([String]::IsNullOrWhiteSpace($Version)) {
    $Version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
}
if ($Version -ne [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()) {
    throw 'Update VERSION before packaging a different release.'
}
$buildScript = Join-Path $PSScriptRoot 'Build.ps1'
$exe = Join-Path $PSScriptRoot 'bin\CampusSrunGuardian.exe'
$controlPanelLauncher = Join-Path $PSScriptRoot 'CampusSrunGuardianControlPanel.exe'
$distRoot = Join-Path $PSScriptRoot 'dist'
$packageName = "CampusSrunGuardian-$Version"
$packageDirectory = Join-Path $distRoot $packageName
$archive = Join-Path $distRoot "$packageName.zip"

& $buildScript -Version $Version
if (-not (Test-Path -LiteralPath $exe)) {
    throw 'The build did not produce CampusSrunGuardian.exe.'
}
if (-not (Test-Path -LiteralPath $controlPanelLauncher)) {
    throw 'The build did not produce CampusSrunGuardianControlPanel.exe.'
}
if (Test-Path -LiteralPath $packageDirectory) {
    throw "Package directory already exists: $packageDirectory. Move it aside before packaging again."
}
if (Test-Path -LiteralPath $archive) {
    throw "Release archive already exists: $archive. Move it aside before packaging again."
}

New-Item -ItemType Directory -Path (Join-Path $packageDirectory 'bin') -Force | Out-Null
Copy-Item -LiteralPath $exe -Destination (Join-Path $packageDirectory 'bin\CampusSrunGuardian.exe')
Copy-Item -LiteralPath $controlPanelLauncher -Destination $packageDirectory
foreach ($name in @(
    'ControlPanel.ps1',
    'CampusSrunGuardianControlPanel.cs',
    'CampusSrunGuardianControlPanel.manifest',
    'Start-CampusSrunGuardian.cmd',
    'Install-StartupTask.ps1',
    'Remove-StartupTask.ps1',
    'Invoke-CampusSrunOnce.ps1',
    'README.md',
    'VERSION',
    'CHANGELOG.md',
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
