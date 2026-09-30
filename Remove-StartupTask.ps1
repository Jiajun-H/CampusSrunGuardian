#Requires -RunAsAdministrator
param([int]$WaitForProcessId = 0)
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

if ($WaitForProcessId -gt 0) {
    Wait-Process -Id $WaitForProcessId -Timeout 60 -ErrorAction SilentlyContinue
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

$startMenuDirectory = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $startMenuDirectory '校园网自动认证.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Host 'Removed the Start menu shortcut.'
}

$ssidPath = Join-Path $env:ProgramData 'CampusSrunGuardian\campus-ssid.txt'
if (Test-Path -LiteralPath $ssidPath) {
    Remove-Item -LiteralPath $ssidPath -Force
    Write-Host 'Removed the saved campus Wi-Fi guard. Credentials and logs were retained.'
}
