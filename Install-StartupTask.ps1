#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$taskName = 'CampusSrunGuardian'
$taskPath = '\'
$localServiceSid = 'S-1-5-19'
$builtExecutable = Join-Path $PSScriptRoot 'bin\CampusSrunGuardian.exe'
$builtControlPanelLauncher = Join-Path $PSScriptRoot 'CampusSrunGuardianControlPanel.exe'
$controlPanelSource = Join-Path $PSScriptRoot 'ControlPanel.ps1'
$installDirectory = Join-Path $env:ProgramFiles 'CampusSrunGuardian'
$controlPanelLauncher = Join-Path $installDirectory 'CampusSrunGuardianControlPanel.exe'
$isInstalledLauncherSource = [String]::Equals(
    [IO.Path]::GetFullPath($builtControlPanelLauncher),
    [IO.Path]::GetFullPath($controlPanelLauncher),
    [StringComparison]::OrdinalIgnoreCase)

function ConvertTo-TaskLogonTypeValue {
    param([Parameter(Mandatory = $true)][string]$LogonType)

    switch -Regex ($LogonType) {
        '^(None)$' { return 0 }
        '^(Password)$' { return 1 }
        '^(S4U)$' { return 2 }
        '^(Interactive|InteractiveToken)$' { return 3 }
        '^(Group)$' { return 4 }
        '^(ServiceAccount)$' { return 5 }
        '^(InteractiveOrPassword|InteractiveTokenOrPassword)$' { return 6 }
        default { throw "Unsupported scheduled-task logon type: $LogonType" }
    }
}

function Register-TaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DefinitionXml,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][int]$LogonType
    )

    $definition = [xml]$DefinitionXml
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($definition.NameTable)
    $namespaceManager.AddNamespace('task', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    foreach ($logonNode in @($definition.SelectNodes('//task:Principal/task:LogonType', $namespaceManager))) {
        $null = $logonNode.ParentNode.RemoveChild($logonNode)
    }

    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder = $scheduler.GetFolder($Path)
    # TASK_CREATE_OR_UPDATE=6; TASK_LOGON_SERVICE_ACCOUNT=5 for LocalService.
    $null = $folder.RegisterTask($Name, $definition.OuterXml, 6, $UserId, $null, $LogonType, $null)
}
if (-not (Test-Path -LiteralPath $builtExecutable)) {
    throw 'Run Build.ps1 first.'
}
foreach ($requiredFile in @($builtControlPanelLauncher, $controlPanelSource)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "Required control-panel file is missing: $requiredFile"
    }
}
foreach ($requiredFile in @(
    (Join-Path $PSScriptRoot 'README.md'),
    (Join-Path $PSScriptRoot 'VERSION'),
    (Join-Path $PSScriptRoot 'CHANGELOG.md'),
    (Join-Path $PSScriptRoot 'Install-StartupTask.ps1'),
    (Join-Path $PSScriptRoot 'Remove-StartupTask.ps1'),
    (Join-Path $PSScriptRoot 'Invoke-CampusSrunOnce.ps1')
)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "Required support file is missing: $requiredFile"
    }
}

# Confirm that this is the configured campus portal before capturing the
# currently connected Wi-Fi SSID or replacing the old task.
$statusOutput = @(& $builtExecutable --status 2>&1)
$statusExitCode = $LASTEXITCODE
if ($statusExitCode -notin @(0, 3) -or (($statusOutput -join "`n") -notmatch 'Portal:\s+10\.175\.100\.48')) {
    throw 'Could not confirm the campus SRun portal. The existing startup task was left unchanged.'
}

$wlanOutput = (& netsh.exe wlan show interfaces 2>$null | Out-String)
$campusSsids = @(
    foreach ($ssidMatch in [regex]::Matches($wlanOutput, '(?im)^\s*SSID\s*:\s*(?<ssid>[^\r\n]+?)\s*$')) {
        $ssid = $ssidMatch.Groups['ssid'].Value.Trim()
        if (-not [String]::IsNullOrWhiteSpace($ssid)) {
            $ssid
        }
    }
) | Select-Object -Unique
if ($campusSsids.Count -eq 0) {
    throw 'No connected Wi-Fi SSID was detected. The existing startup task was left unchanged.'
}

$installedBinDirectory = Join-Path $installDirectory 'bin'
$executable = Join-Path $installDirectory 'CampusSrunGuardian.exe'
$installedBuildExecutable = Join-Path $installedBinDirectory 'CampusSrunGuardian.exe'
$controlPanel = Join-Path $installDirectory 'ControlPanel.ps1'
$installScript = Join-Path $installDirectory 'Install-StartupTask.ps1'
$removeScript = Join-Path $installDirectory 'Remove-StartupTask.ps1'
$readme = Join-Path $installDirectory 'README.md'
$versionFile = Join-Path $installDirectory 'VERSION'
$changeLogFile = Join-Path $installDirectory 'CHANGELOG.md'
$wrapper = Join-Path $installDirectory 'Invoke-CampusSrunOnce.ps1'
$dataDirectory = Join-Path $env:ProgramData 'CampusSrunGuardian'
$ssidPath = Join-Path $dataDirectory 'campus-ssid.txt'
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $installedBinDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null

$wrapperSource = Join-Path $PSScriptRoot 'Invoke-CampusSrunOnce.ps1'
$installScriptSource = Join-Path $PSScriptRoot 'Install-StartupTask.ps1'
$removeScriptSource = Join-Path $PSScriptRoot 'Remove-StartupTask.ps1'
$readmeSource = Join-Path $PSScriptRoot 'README.md'
$versionSource = Join-Path $PSScriptRoot 'VERSION'
$changeLogSource = Join-Path $PSScriptRoot 'CHANGELOG.md'
if (-not (Test-Path -LiteralPath $wrapperSource)) {
    throw 'Invoke-CampusSrunOnce.ps1 is missing.'
}

$eventSubscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]</Select></Query></QueryList>
'@.Trim()
$ncsiSubscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-NCSI/Operational"><Select Path="Microsoft-Windows-NCSI/Operational">*[System[Provider[@Name='Microsoft-Windows-NCSI'] and EventID=4042] and EventData[Data[@Name='CapabilityChangeReason']='7' and Data[@Name='Capability']='1']]</Select></Query></QueryList>
'@.Trim()
$startBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
$escapedWrapper = [Security.SecurityElement]::Escape($wrapper)
$escapedWorkingDirectory = [Security.SecurityElement]::Escape($installDirectory)
$escapedStartBoundary = [Security.SecurityElement]::Escape($startBoundary)
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Runs a short SRun check on campus Wi-Fi events and every five minutes as a fallback.</Description>
    <Author>CampusSrunGuardian</Author>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription><![CDATA[$eventSubscription]]></Subscription><Delay>PT10S</Delay></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription><![CDATA[$ncsiSubscription]]></Subscription><Delay>PT5S</Delay></EventTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT5M</Interval></Repetition>
      <StartBoundary>$escapedStartBoundary</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="LocalService">
      <UserId>S-1-5-19</UserId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="LocalService">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -ExecutionPolicy Bypass -File &quot;$escapedWrapper&quot;</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
try {
    $null = [xml]$xml
} catch {
    throw "Generated task XML is invalid: $($_.Exception.Message)"
}

# Stage every file and the task definition before touching the old task.
$ssidJson = ConvertTo-Json -InputObject @($campusSsids) -Compress
$ssidStagingPath = $ssidPath + '.new'
[IO.File]::WriteAllText($ssidStagingPath, $ssidJson, [Text.Encoding]::UTF8)
$ssidAcl = New-Object Security.AccessControl.FileSecurity
$ssidAcl.SetAccessRuleProtection($true, $false)
$ssidAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalServiceSid, $null),
    [Security.AccessControl.FileSystemRights]::Read,
    [Security.AccessControl.AccessControlType]::Allow))
$ssidAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null),
    [Security.AccessControl.FileSystemRights]::FullControl,
    [Security.AccessControl.AccessControlType]::Allow))
$ssidAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null),
    [Security.AccessControl.FileSystemRights]::FullControl,
    [Security.AccessControl.AccessControlType]::Allow))
Set-Acl -LiteralPath $ssidStagingPath -AclObject $ssidAcl

$executableStagingPath = $executable + '.new'
$installedBuildExecutableStagingPath = $installedBuildExecutable + '.new'
$controlPanelLauncherStagingPath = $controlPanelLauncher + '.new'
$controlPanelStagingPath = $controlPanel + '.new'
$installScriptStagingPath = $installScript + '.new'
$removeScriptStagingPath = $removeScript + '.new'
$readmeStagingPath = $readme + '.new'
$versionStagingPath = $versionFile + '.new'
$changeLogStagingPath = $changeLogFile + '.new'
$wrapperStagingPath = $wrapper + '.new'
Copy-Item -LiteralPath $builtExecutable -Destination $executableStagingPath -Force
Copy-Item -LiteralPath $builtExecutable -Destination $installedBuildExecutableStagingPath -Force
if (-not $isInstalledLauncherSource) {
    Copy-Item -LiteralPath $builtControlPanelLauncher -Destination $controlPanelLauncherStagingPath -Force
}
Copy-Item -LiteralPath $controlPanelSource -Destination $controlPanelStagingPath -Force
Copy-Item -LiteralPath $installScriptSource -Destination $installScriptStagingPath -Force
Copy-Item -LiteralPath $removeScriptSource -Destination $removeScriptStagingPath -Force
Copy-Item -LiteralPath $readmeSource -Destination $readmeStagingPath -Force
Copy-Item -LiteralPath $versionSource -Destination $versionStagingPath -Force
Copy-Item -LiteralPath $changeLogSource -Destination $changeLogStagingPath -Force
Copy-Item -LiteralPath $wrapperSource -Destination $wrapperStagingPath -Force

$oldTaskXml = $null
$oldTaskUserId = $null
$oldTaskLogonType = $null
$oldTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if ($oldTask) {
    $oldTaskXml = Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath
    $oldTaskUserId = [string]$oldTask.Principal.UserId
    if ([String]::IsNullOrWhiteSpace($oldTaskUserId)) {
        $oldTaskUserId = [string]$oldTask.Principal.GroupId
    }
    $oldTaskLogonType = ConvertTo-TaskLogonTypeValue -LogonType ([string]$oldTask.Principal.LogonType)
    Stop-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    Write-Host "Removed the old $taskName resident monitor task."
}

try {
    Move-Item -LiteralPath $executableStagingPath -Destination $executable -Force
    Move-Item -LiteralPath $installedBuildExecutableStagingPath -Destination $installedBuildExecutable -Force
    if (-not $isInstalledLauncherSource) {
        Move-Item -LiteralPath $controlPanelLauncherStagingPath -Destination $controlPanelLauncher -Force
    }
    Move-Item -LiteralPath $controlPanelStagingPath -Destination $controlPanel -Force
    Move-Item -LiteralPath $installScriptStagingPath -Destination $installScript -Force
    Move-Item -LiteralPath $removeScriptStagingPath -Destination $removeScript -Force
    Move-Item -LiteralPath $readmeStagingPath -Destination $readme -Force
    Move-Item -LiteralPath $versionStagingPath -Destination $versionFile -Force
    Move-Item -LiteralPath $changeLogStagingPath -Destination $changeLogFile -Force
    Move-Item -LiteralPath $wrapperStagingPath -Destination $wrapper -Force
    Move-Item -LiteralPath $ssidStagingPath -Destination $ssidPath -Force
    Register-TaskXml -Name $taskName -Path $taskPath -DefinitionXml $xml -UserId $localServiceSid -LogonType 5
    $registeredTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    if (-not $registeredTask) {
        throw "Task Scheduler did not return the registered task at $taskPath$taskName."
    }
} catch {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    if ($oldTaskXml) {
        try {
            Register-TaskXml -Name $taskName -Path $taskPath -DefinitionXml $oldTaskXml -UserId $oldTaskUserId -LogonType $oldTaskLogonType
            Write-Warning 'The new task could not be registered; the previous task definition was restored.'
        } catch {
            Write-Warning 'The new task and previous task could not be registered. Run Remove-StartupTask.ps1 or retry Install-StartupTask.ps1 as Administrator.'
        }
    }
    throw
} finally {
    Remove-Item -LiteralPath $executableStagingPath, $installedBuildExecutableStagingPath, $controlPanelLauncherStagingPath, $controlPanelStagingPath, $installScriptStagingPath, $removeScriptStagingPath, $readmeStagingPath, $versionStagingPath, $changeLogStagingPath, $wrapperStagingPath, $ssidStagingPath -Force -ErrorAction SilentlyContinue
}

$shortcutCreated = $false
$startMenuDirectory = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$shortcutPath = Join-Path $startMenuDirectory '校园网自动认证.lnk'
try {
    New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $controlPanelLauncher
    $shortcut.WorkingDirectory = $installDirectory
    $shortcut.Description = '查看校园网状态、管理自动检查和账号设置'
    $shortcut.Save()
    $shortcutCreated = $true
} catch {
    Write-Warning "The program was installed, but the Start menu shortcut could not be created: $($_.Exception.Message)"
}

Write-Host "Installed the executable under $installDirectory."
Write-Host "Installed the graphical control panel under $installDirectory."
if ($shortcutCreated) {
    Write-Host 'Added Campus SRun Guardian to the Start menu.'
}
Write-Host "Captured the currently connected Wi-Fi SSID for the local-only guard."
Write-Host "Registered and verified $taskPath$taskName as LocalService with network-event triggers and a five-minute one-shot fallback."
Write-Host 'The executable exits after each check; this script does not start the task now.'
