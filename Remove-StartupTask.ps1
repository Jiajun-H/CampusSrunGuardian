#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$taskName = 'CampusSrunGuardian'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed the $taskName boot task."
} else {
    Write-Host "The $taskName boot task is not registered."
}

$programFilesPath = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('ProgramFiles')).TrimEnd('\')
$installDirectory = [IO.Path]::GetFullPath((Join-Path $programFilesPath 'CampusSrunGuardian'))
if (-not $installDirectory.StartsWith($programFilesPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to remove a path outside Program Files.'
}
if (Test-Path -LiteralPath $installDirectory) {
    $resolvedInstallDirectory = (Resolve-Path -LiteralPath $installDirectory).Path
    if (-not [String]::Equals($resolvedInstallDirectory, $installDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove an unexpected resolved path.'
    }
    Remove-Item -LiteralPath $resolvedInstallDirectory -Recurse -Force
    Write-Host 'Removed the installed program files. Credentials and logs were retained.'
}

$ssidPath = Join-Path $env:ProgramData 'CampusSrunGuardian\campus-ssid.txt'
if (Test-Path -LiteralPath $ssidPath) {
    Remove-Item -LiteralPath $ssidPath -Force
    Write-Host 'Removed the saved campus Wi-Fi guard. Credentials and logs were retained.'
}
