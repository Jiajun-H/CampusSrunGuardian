$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    try {
        Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -ErrorAction Stop | Out-Null
    } catch {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            "无法打开管理员控制面板。请确认 Windows 权限提示，然后重试。`r`n`r`n$($_.Exception.Message)",
            '无法启动控制面板', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        exit 1
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:root = $PSScriptRoot
$script:versionPath = Join-Path $script:root 'VERSION'
$script:appVersion = if (Test-Path -LiteralPath $script:versionPath) { [IO.File]::ReadAllText($script:versionPath).Trim() } else { '版本未知' }
$script:programFilesDirectory = Join-Path $env:ProgramFiles 'CampusSrunGuardian'
$script:installedExe = Join-Path $script:programFilesDirectory 'CampusSrunGuardian.exe'
$script:sourceExe = Join-Path $script:root 'bin\CampusSrunGuardian.exe'
$script:exePath = if (Test-Path -LiteralPath $script:sourceExe) { $script:sourceExe } else { $script:installedExe }
$script:installScript = Join-Path $script:root 'Install-StartupTask.ps1'
$script:removeScript = Join-Path $script:root 'Remove-StartupTask.ps1'
$script:taskName = 'CampusSrunGuardian'
$script:taskPath = '\'
$script:logPath = Join-Path $env:ProgramData 'CampusSrunGuardian\guardian.log'
$script:credentialPath = Join-Path $env:ProgramData 'CampusSrunGuardian\credentials.bin'
$script:readmePath = Join-Path $script:root 'README.md'
$script:powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:toolTip = New-Object System.Windows.Forms.ToolTip
$script:toolTip.AutoPopDelay = 12000
$script:toolTip.InitialDelay = 450
$script:toolTip.ReshowDelay = 150
$script:toolTip.ShowAlways = $true

function Format-PortalDiagnosticText {
    param([string]$Detail)
    $code = [regex]::Match($Detail, '\bE\d{4}\b').Value
    $meaning = switch ($code) {
        'E2531' { '门户提示账号不存在。请核对保存的账号和后缀。' }
        'E2553' { '门户明确提示账号或密码错误。请用刚才网页登录成功的信息重新保存。' }
        'E2620' { '门户提示账号已在线或达到设备限制。请在认证网页核对在线设备。' }
        'E2806' { '门户找不到账号对应的网络产品。请核对账号后缀或向网管咨询。' }
        'E2833' { '门户未在 DHCP 表中找到电脑地址。请联系网管核对网络登记。' }
        'E6529' { '身份验证失败，门户未提供具体原因；不能据此判定密码错误。' }
        default { $null }
    }
    if ($meaning) { return "$meaning （$code）" }
    if ($Detail -eq 'No detailed reason available.') { return '门户没有留下具体原因。' }
    if ([String]::IsNullOrWhiteSpace($Detail)) { return '门户没有提供具体原因。' }
    return "门户说明：$Detail"
}

function ConvertTo-FriendlyLine {
    param([string]$Line)

    if ([String]::IsNullOrWhiteSpace($Line)) { return $null }
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $message = $Line.Trim()
    $logMatch = [regex]::Match($message, '^(?<date>\d{4}-\d{2}-\d{2})\s+(?<time>\d{2}:\d{2}:\d{2})\s+\[(?<category>[^\]]+)\]\s*(?<body>.*)$')
    if ($logMatch.Success) {
        $timestamp = $logMatch.Groups['date'].Value + ' ' + $logMatch.Groups['time'].Value
        $message = $logMatch.Groups['body'].Value.Trim()
    }

    switch -Regex ($message) {
        '^Portal:' { return $null }
        '^Access ID:' { return $null }
        '^SRun-reported address:' { return $null }
        '^SRun session:\s*online$' { return [pscustomobject]@{ Time = $timestamp; Text = '校园网认证在线，无需重新登录。' } }
        '^SRun session:\s*offline$' { return [pscustomobject]@{ Time = $timestamp; Text = '校园网认证已掉线；自动检查会尝试恢复。' } }
        '^SRun session is already online\.' { return [pscustomobject]@{ Time = $timestamp; Text = '当前已在线，没有重复登录。' } }
        '^SRun authentication succeeded\.' { return [pscustomobject]@{ Time = $timestamp; Text = '登录成功，校园网已恢复。' } }
        '^Authentication succeeded\.' { return [pscustomobject]@{ Time = $timestamp; Text = '登录成功，校园网已恢复。' } }
        '^Login was accepted; online status was not confirmed\.' { return [pscustomobject]@{ Time = $timestamp; Text = '门户接受了登录请求，但还没确认网络恢复；稍后请刷新状态。' } }
        '^Login was accepted but online status was not confirmed\.' { return [pscustomobject]@{ Time = $timestamp; Text = '门户接受了登录请求，但还没确认网络恢复；稍后请刷新状态。' } }
        '^(?:SRun rejected the login|Portal rejected login): (?<code>.+)$' { return [pscustomobject]@{ Time = $timestamp; Text = ("自动登录被门户拒绝（{0}）；请看具体原因，或点账号检查按钮。" -f $Matches.code) } }
        '^Portal failure detail: (?<detail>.+)$' { return [pscustomobject]@{ Time = $timestamp; Text = (Format-PortalDiagnosticText $Matches.detail) } }
        '^Last recorded portal detail \(may be historical\): (?<detail>.+)$' { return [pscustomobject]@{ Time = $timestamp; Text = ('门户留下的最近一条认证记录（可能是历史记录）：' + (Format-PortalDiagnosticText $Matches.detail)) } }
        '^Diagnostic check only;' { return [pscustomobject]@{ Time = $timestamp; Text = '开始检查保存的账号和门户诊断记录；本次不会提交登录。' } }
        '^Saved account matches the current web session\.' { return [pscustomobject]@{ Time = $timestamp; Text = '程序保存的账号及后缀，与当前网页登录账号一致。' } }
        '^Saved account name matches the web session;' { return [pscustomobject]@{ Time = $timestamp; Text = '账号本身一致；门户没有返回可用于核对的登录后缀。学校登录页没有后缀选项时，请将后缀留空。' } }
        '^Saved account differs from the current web session\.' { return [pscustomobject]@{ Time = $timestamp; Text = '程序保存的账号或后缀与当前网页登录账号不同。请重新设置账号。' } }
        '^Saved password cannot be verified while' { return [pscustomobject]@{ Time = $timestamp; Text = '当前已经在线，无法判断保存的密码是否正确。可重新保存刚才网页登录成功的密码。' } }
        '^The session is offline; saved account comparison' { return [pscustomobject]@{ Time = $timestamp; Text = '当前尚未登录网页，暂时无法比较账号；正在查询门户留下的认证记录。' } }
        '^The portal did not provide an account name;' { return [pscustomobject]@{ Time = $timestamp; Text = '门户没有提供当前登录账号，无法完成账号比对。' } }
        '^The portal diagnostic record is unavailable\.' { return [pscustomobject]@{ Time = $timestamp; Text = '门户诊断记录暂时读不到；下次自动登录失败时会记录具体返回原因。' } }
        '^The account entered matches the previously saved account\.' { return [pscustomobject]@{ Time = $timestamp; Text = '这次输入的账号与原保存账号一致，已重新保存。' } }
        '^The account entered differs from the previously saved account\.' { return [pscustomobject]@{ Time = $timestamp; Text = '这次输入的账号或后缀与原保存值不同，已更新。' } }
        '^The password entered matches the previously saved password\.' { return [pscustomobject]@{ Time = $timestamp; Text = '这次输入的密码与原保存密码一致，已重新保存。' } }
        '^The password entered differs from the previously saved password\.' { return [pscustomobject]@{ Time = $timestamp; Text = '这次输入的密码与原保存密码不同，已更新。' } }
        '^SRun status unavailable:.*(ConnectFailure|Timeout|NameResolutionFailure|ProxyNameResolutionFailure)' { return [pscustomobject]@{ Time = $timestamp; Text = '暂时无法连接校园认证门户。请检查 Wi-Fi；自动检查稍后会重试。' } }
        '^SRun status unavailable:' { return [pscustomobject]@{ Time = $timestamp; Text = '暂时无法读取校园网状态。请点“刷新状态”；如果仍失败，请把这条记录发给维护者。' } }
        '^SRun portal is unreachable' { return [pscustomobject]@{ Time = $timestamp; Text = '当前连不上校园认证门户，本次跳过；自动检查稍后会再试。' } }
        '^Network request failed' { return [pscustomobject]@{ Time = $timestamp; Text = '网络请求没有完成。请检查 Wi-Fi 和校园网连接，再刷新状态。' } }
        '^Network route unavailable' { return [pscustomobject]@{ Time = $timestamp; Text = '电脑暂时没有可用网络路线；自动检查稍后会重试。' } }
        '^Access denied\.' { return [pscustomobject]@{ Time = $timestamp; Text = '系统没有允许任务读取账号。请重新保存账号，再选择“安装 / 修复自动检查”。' } }
        '^Credentials are not configured\.' { return [pscustomobject]@{ Time = $timestamp; Text = '还没有保存校园网账号。请先选择“设置 / 更换账号”。' } }
        '^No connected Wi-Fi SSID was detected\.' { return [pscustomobject]@{ Time = $timestamp; Text = '没有检测到已连接的 Wi-Fi。请先连接 zuel 开头的校园 Wi-Fi。' } }
        '^Could not confirm the campus SRun portal\.' { return [pscustomobject]@{ Time = $timestamp; Text = '无法确认校园认证门户。请连接校园 Wi-Fi 并确认门户可访问，再重试。' } }
        '^SRun challenge received\.' { return [pscustomobject]@{ Time = $timestamp; Text = '已连接校园认证门户。' } }
        '^SRun client IP is present\.' { return $null }
        '^Login fields were prepared locally and were not submitted\.' { return [pscustomobject]@{ Time = $timestamp; Text = '登录信息准备完成；本次没有提交登录。' } }
        '^(?:Encrypted credentials saved|Credentials saved with machine-scope DPAPI)\.' { return [pscustomobject]@{ Time = $timestamp; Text = '账号已加密保存在本机。' } }
        '^Removed the old CampusSrunGuardian resident monitor task\.' { return [pscustomobject]@{ Time = $timestamp; Text = '已清理旧版自动任务。' } }
        '^Installed the executable under ' { return [pscustomobject]@{ Time = $timestamp; Text = '后台程序已安装或更新。' } }
        '^Installed the graphical control panel under ' { return [pscustomobject]@{ Time = $timestamp; Text = '图形控制面板已安装。' } }
        '^Added Campus SRun Guardian to the Start menu\.' { return [pscustomobject]@{ Time = $timestamp; Text = '开始菜单中已添加“校园网自动认证”入口。' } }
        '^Captured the currently connected Wi-Fi SSID' { return [pscustomobject]@{ Time = $timestamp; Text = '已记录当前 Wi-Fi；自动检查只会在允许的校园网络上运行。' } }
        '^Registered and verified \\CampusSrunGuardian' { return [pscustomobject]@{ Time = $timestamp; Text = '自动检查已启用：开机和网络变化时检查，每 5 分钟补查一次。' } }
        '^The executable exits after each check' { return [pscustomobject]@{ Time = $timestamp; Text = '每次检查结束后程序都会退出，不会常驻占用资源。' } }
        '^The program was installed, but the Start menu shortcut could not be created:' { return [pscustomobject]@{ Time = $timestamp; Text = '程序已安装，但开始菜单入口没有创建；可从程序文件夹打开控制面板。' } }
        '^The CampusSrunGuardian boot task is not registered\.' { return [pscustomobject]@{ Time = $timestamp; Text = '当前没有已安装的自动检查任务。' } }
        '^Removed the CampusSrunGuardian boot task\.' { return [pscustomobject]@{ Time = $timestamp; Text = '自动检查任务已移除。' } }
        '^Removed the installed program files\.' { return [pscustomobject]@{ Time = $timestamp; Text = '程序文件已移除；账号凭据和运行记录保留。' } }
        '^Removed the saved campus Wi-Fi guard\.' { return [pscustomobject]@{ Time = $timestamp; Text = '已清除保存的 Wi-Fi 范围。' } }
        '^已暂停自动检查。$' { return [pscustomobject]@{ Time = $timestamp; Text = '自动检查已暂停。' } }
        '^已恢复自动检查。$' { return [pscustomobject]@{ Time = $timestamp; Text = '自动检查已恢复。' } }
        '^Next attempt in (?<seconds>\d+) seconds\.' { return [pscustomobject]@{ Time = $timestamp; Text = "将在 $($Matches.seconds) 秒后再次检查。" } }
        '^Background monitor started\.' { return $null }
        '^Operation failed: ' { return [pscustomobject]@{ Time = $timestamp; Text = '操作没有完成。请检查账号设置和校园网连接。' } }
        '^(InvalidDataException|UnauthorizedAccessException|IOException|Win32Exception)\.' { return [pscustomobject]@{ Time = $timestamp; Text = '系统执行操作时遇到问题。请重新打开控制面板；如果再次发生，请把最近活动发给维护者。' } }
        default { return [pscustomobject]@{ Time = $timestamp; Text = $message } }
    }
}

function Add-Output {
    param([string]$Text)
    if ([String]::IsNullOrWhiteSpace($Text)) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        $entry = ConvertTo-FriendlyLine -Line $line
        if ($null -eq $entry -or [String]::IsNullOrWhiteSpace($entry.Text)) { continue }
        $script:outputBox.AppendText("$($entry.Time)  $($entry.Text)`r`n")
    }
    $script:outputBox.SelectionStart = $script:outputBox.TextLength
    $script:outputBox.ScrollToCaret()
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentLine,
        [AllowNull()][string]$InputText = $null,
        [AllowNull()][string]$WorkingDirectory = $null
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ([IO.Path]::GetFileName($FilePath) -eq 'CampusSrunGuardian.exe') {
        $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    }
    if (-not [String]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    } elseif (-not [String]::IsNullOrWhiteSpace($script:root)) {
        $startInfo.WorkingDirectory = $script:root
    }
    if ($null -ne $InputText) { $startInfo.RedirectStandardInput = $true }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start $FilePath." }
    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = (($standardOutput, $standardError) -join "`r`n").Trim()
    }
}

function Get-PowerShellArgument {
    param([string]$Value)
    '"{0}"' -f $Value.Replace('"', '\"')
}

function Refresh-TaskState {
    try {
        $task = Get-ScheduledTask -TaskName $script:taskName -TaskPath $script:taskPath -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $script:taskName -TaskPath $script:taskPath -ErrorAction Stop
        $enabled = [bool]$task.Settings.Enabled
        $enabledText = if ($enabled) { '已开启' } else { '已暂停' }
        if ($info.LastRunTime.Year -lt 2000) { $lastRun = '还没有运行' } else { $lastRun = $info.LastRunTime.ToString('M/d HH:mm') }
        $credentialsText = if (Test-Path -LiteralPath $script:credentialPath) { '账号已保存' } else { '还没有保存账号' }
        $script:taskLabel.Text = "自动检查$enabledText  ·  $credentialsText  ·  最近运行：$lastRun"
        $script:taskLabel.ForeColor = if ($enabled) { [System.Drawing.Color]::FromArgb(28, 112, 82) } else { [System.Drawing.Color]::FromArgb(170, 98, 25) }
        $script:toggleButton.Enabled = $true
        $script:toggleButton.Text = if ($enabled) { '暂停自动检查' } else { '恢复自动检查' }
        $toggleHelp = if ($enabled) { '暂停后不会自动尝试登录；需要时可在这里恢复。' } else { '恢复后，计划任务会按开机、网络变化和兜底时间检查。' }
        $script:toolTip.SetToolTip($script:toggleButton, $toggleHelp)
        $script:removeButton.Enabled = $true
        $script:onceButton.Enabled = $enabled
        $script:installButton.Text = '修复自动检查'
    } catch {
        $credentialsText = if (Test-Path -LiteralPath $script:credentialPath) { '账号已保存' } else { '还没有保存账号' }
        $script:taskLabel.Text = "自动检查尚未安装  ·  $credentialsText"
        $script:taskLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 91, 25)
        $script:toggleButton.Enabled = $false
        $script:toggleButton.Text = '自动检查未安装'
        $script:removeButton.Enabled = $false
        $script:onceButton.Enabled = $false
        $script:installButton.Text = '安装自动检查'
    }
}

function Invoke-StatusCheck {
    if (-not (Test-Path -LiteralPath $script:exePath)) {
        [void][System.Windows.Forms.MessageBox]::Show('找不到程序文件。请重新下载完整发布包。', '文件缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try {
        $result = Invoke-CapturedProcess -FilePath $script:exePath -ArgumentLine '--status'
        Add-Output $result.Output
        if ($result.ExitCode -eq 0 -and $result.Output -match 'SRun session:\s+online') {
        $script:networkLabel.Text = '校园网已连接'
        $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(24, 105, 71)
            $script:statusDot.ForeColor = [System.Drawing.Color]::FromArgb(24, 150, 93)
            $script:statusDetailLabel.Text = '认证正常。程序不会重复登录。'
        } elseif ($result.ExitCode -eq 3 -or $result.Output -match 'SRun session:\s+offline') {
        $script:networkLabel.Text = '校园网认证已掉线'
        $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 91, 25)
            $script:statusDot.ForeColor = [System.Drawing.Color]::FromArgb(208, 133, 35)
            $script:statusDetailLabel.Text = '自动检查会在允许的校园 Wi-Fi 上尝试恢复；也可以点“立即检查并尝试恢复”。'
        } else {
        $script:networkLabel.Text = '暂时无法读取认证状态'
        $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 45, 45)
            $script:statusDot.ForeColor = [System.Drawing.Color]::FromArgb(189, 73, 73)
            $script:statusDetailLabel.Text = '检查 Wi-Fi 连接后点“刷新状态”；自动检查会在之后重试。'
        }
    } catch {
        Add-Output $_.Exception.Message
        $script:networkLabel.Text = '状态检查没有完成'
        $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 45, 45)
        $script:statusDot.ForeColor = [System.Drawing.Color]::FromArgb(189, 73, 73)
        $script:statusDetailLabel.Text = '请查看右侧“最近活动”中的处理建议。'
    }
    Refresh-TaskState
}

function Show-CredentialDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '设置校园网账号'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(470, 324)
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(247, 249, 252)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $dialogTitle = New-Object System.Windows.Forms.Label
    $dialogTitle.Text = '保存校园网登录信息'
    $dialogTitle.Location = New-Object System.Drawing.Point(22, 17)
    $dialogTitle.Size = New-Object System.Drawing.Size(420, 28)
    $dialogTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $dialogTitle.ForeColor = [System.Drawing.Color]::FromArgb(38, 55, 76)

    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Text = '账号 / 学号'
    $usernameLabel.Location = New-Object System.Drawing.Point(22, 64)
    $usernameLabel.Size = New-Object System.Drawing.Size(105, 24)
    $usernameBox = New-Object System.Windows.Forms.TextBox
    $usernameBox.Location = New-Object System.Drawing.Point(140, 60)
    $usernameBox.Size = New-Object System.Drawing.Size(302, 27)
    $usernameBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)

    $suffixLabel = New-Object System.Windows.Forms.Label
    $suffixLabel.Text = '账号后缀（可选）'
    $suffixLabel.Location = New-Object System.Drawing.Point(22, 107)
    $suffixLabel.Size = New-Object System.Drawing.Size(112, 24)
    $suffixBox = New-Object System.Windows.Forms.TextBox
    $suffixBox.Location = New-Object System.Drawing.Point(140, 103)
    $suffixBox.Size = New-Object System.Drawing.Size(302, 27)
    $suffixBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = '校园网密码'
    $passwordLabel.Location = New-Object System.Drawing.Point(22, 150)
    $passwordLabel.Size = New-Object System.Drawing.Size(105, 24)
    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location = New-Object System.Drawing.Point(140, 146)
    $passwordBox.Size = New-Object System.Drawing.Size(302, 27)
    $passwordBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $passwordBox.UseSystemPasswordChar = $true

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '账号如果带有 @ 后缀，只填 @ 后面的内容；没有后缀就留空。保存后，密码会在本机加密。'
    $hint.Location = New-Object System.Drawing.Point(22, 190)
    $hint.Size = New-Object System.Drawing.Size(420, 48)
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存账号'
    $saveButton.Location = New-Object System.Drawing.Point(248, 260)
    $saveButton.Size = New-Object System.Drawing.Size(92, 38)
    $saveButton.FlatStyle = 'Flat'
    $saveButton.FlatAppearance.BorderSize = 0
    $saveButton.BackColor = [System.Drawing.Color]::FromArgb(46, 105, 184)
    $saveButton.ForeColor = [System.Drawing.Color]::White
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(350, 260)
    $cancelButton.Size = New-Object System.Drawing.Size(92, 38)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.AcceptButton = $saveButton
    $dialog.CancelButton = $cancelButton

    $script:dialogUsernameBox = $usernameBox
    $script:dialogSuffixBox = $suffixBox
    $script:dialogPasswordBox = $passwordBox
    $script:credentialDialog = $dialog
    $saveButton.Add_Click({
        $username = $script:dialogUsernameBox.Text.Trim()
        $suffix = $script:dialogSuffixBox.Text.Trim().TrimStart('@')
        $password = $script:dialogPasswordBox.Text
        if ([String]::IsNullOrWhiteSpace($username) -or [String]::IsNullOrEmpty($password)) {
            [void][System.Windows.Forms.MessageBox]::Show('请填写账号和密码。', '信息不完整', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        try {
            $encodedLines = @(
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($username)),
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($suffix)),
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
            ) -join [Environment]::NewLine
            $result = Invoke-CapturedProcess -FilePath $script:exePath -ArgumentLine '--configure-stdin-base64' -InputText ($encodedLines + [Environment]::NewLine)
            $script:dialogPasswordBox.Clear()
            if ($result.ExitCode -eq 0) {
                Add-Output $result.Output
                [void][System.Windows.Forms.MessageBox]::Show('账号已保存。自动任务下次检查时会使用新账号。', '保存成功', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                $script:credentialDialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $script:credentialDialog.Close()
            } else {
                Add-Output $result.Output
                [void][System.Windows.Forms.MessageBox]::Show("保存失败：`r`n$($result.Output)", '保存失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        } catch {
            $script:dialogPasswordBox.Clear()
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

    $dialog.Controls.AddRange(@($dialogTitle, $usernameLabel, $usernameBox, $suffixLabel, $suffixBox, $passwordLabel, $passwordBox, $hint, $saveButton, $cancelButton))
    [void]$dialog.ShowDialog($script:mainForm)
    $passwordBox.Clear()
    $dialog.Dispose()
}

function Invoke-InstallOrRepair {
    if (-not (Test-Path -LiteralPath (Join-Path $script:root 'bin\CampusSrunGuardian.exe'))) {
        [void][System.Windows.Forms.MessageBox]::Show('发布包缺少程序文件。请重新下载完整 ZIP 并解压后再运行。', '文件缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    if (-not (Test-Path -LiteralPath $script:installScript)) {
        [void][System.Windows.Forms.MessageBox]::Show('发布包缺少安装脚本。', '文件缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try {
        $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0}' -f (Get-PowerShellArgument $script:installScript)
        $result = Invoke-CapturedProcess -FilePath $script:powershellExe -ArgumentLine $args
        Add-Output $result.Output
        if ($result.ExitCode -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('自动检查已安装。以后可以从 Windows 开始菜单打开“校园网自动认证”。后台会在开机、校园 Wi-Fi 变化时检查，并每 5 分钟补查一次。', '安装成功', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show('安装没有完成。请查看右侧“最近活动”中的说明；确认已连接校园 Wi-Fi 后再试。', '安装未完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } catch {
        Add-Output $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '安装失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Refresh-TaskState
}

function Toggle-Automation {
    try {
        $task = Get-ScheduledTask -TaskName $script:taskName -TaskPath $script:taskPath -ErrorAction Stop
        if ($task.Settings.Enabled) {
            Disable-ScheduledTask -TaskName $script:taskName -TaskPath $script:taskPath | Out-Null
            Stop-ScheduledTask -TaskName $script:taskName -TaskPath $script:taskPath -ErrorAction SilentlyContinue
            Add-Output '已暂停自动检查。'
        } else {
            Enable-ScheduledTask -TaskName $script:taskName -TaskPath $script:taskPath | Out-Null
            Add-Output '已恢复自动检查。'
        }
    } catch {
        Add-Output $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '操作失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Refresh-TaskState
}

function Invoke-OneTimeRecovery {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        '现在会读取校园网状态。如果已在线，只显示状态；如果已掉线，会提交一次登录请求。继续吗？',
        '立即检查并尝试恢复', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $result = Invoke-CapturedProcess -FilePath $script:exePath -ArgumentLine '--once'
        Add-Output $result.Output
        if ($result.Output -match 'SRun authentication succeeded') {
            [void][System.Windows.Forms.MessageBox]::Show('校园网认证已恢复。', '恢复成功', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } elseif ($result.Output -match 'already online') {
            [void][System.Windows.Forms.MessageBox]::Show('当前已经在线，没有提交登录。', '状态正常', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } elseif ($result.Output -match 'unreachable|Network request failed') {
            [void][System.Windows.Forms.MessageBox]::Show('门户暂时无法访问，本次未能检查或恢复；自动任务稍后会再试。', '暂时无法连接', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        } elseif ($result.ExitCode -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('检查已完成；请查看下方结果或最近日志确认状态。', '完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show('检查或恢复没有完成。请查看右侧“最近活动”中的处理建议。', '需要查看结果', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    } catch {
        Add-Output $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '操作失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Refresh-TaskState
}

function Show-RecentLog {
    $script:outputBox.Clear()
    if (-not (Test-Path -LiteralPath $script:logPath)) {
        Add-Output '还没有后台运行记录。安装自动检查后，这里会显示通俗说明。'
        return
    }
    try {
        $lines = Get-Content -LiteralPath $script:logPath -Tail 30 -Encoding UTF8 -ErrorAction Stop
        foreach ($line in $lines) { Add-Output $line }
        if ($script:outputBox.TextLength -eq 0) {
            Add-Output '目前没有需要处理的记录。'
        }
    } catch {
        Add-Output '读取运行记录失败。请重新打开控制面板；如果仍发生，请联系维护者。'
    }
}

function Invoke-AccountDiagnostics {
    try {
        $result = Invoke-CapturedProcess -FilePath $script:exePath -ArgumentLine '--diagnose'
        Add-Output $result.Output
        if ($result.ExitCode -ne 0) {
            [void][System.Windows.Forms.MessageBox]::Show('账号检查没有完成。请查看右侧最近活动中的说明。', '账号检查未完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    } catch {
        Add-Output '账号检查没有完成。请重新打开控制面板后再试。'
    }
}

function Invoke-Uninstall {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        '这会关闭自动检查并删除已安装的程序和开始菜单入口。校园网账号和运行记录会保留。继续吗？',
        '卸载自动检查', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (-not (Test-Path -LiteralPath $script:removeScript)) {
        [void][System.Windows.Forms.MessageBox]::Show('发布包缺少卸载脚本。', '文件缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try {
        $launcherProcessId = 0
        $hasLauncherProcess = [int]::TryParse($env:CAMPUS_SRUN_LAUNCHER_PID, [ref]$launcherProcessId)
        if ($hasLauncherProcess -and $launcherProcessId -gt 0) {
            $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} -WaitForProcessId {1}' -f (Get-PowerShellArgument $script:removeScript), $launcherProcessId
            Start-Process -FilePath $script:powershellExe -ArgumentList $args -WorkingDirectory $env:TEMP -WindowStyle Hidden -ErrorAction Stop | Out-Null
            Add-Output '已开始卸载。控制面板将关闭，程序会在关闭后完成清理。'
            [void][System.Windows.Forms.MessageBox]::Show('已开始卸载。点击“确定”关闭控制面板，后台程序会接着完成清理。账号和运行记录会保留。', '正在卸载', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $script:mainForm.Close()
            return
        } else {
            $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0}' -f (Get-PowerShellArgument $script:removeScript)
            $result = Invoke-CapturedProcess -FilePath $script:powershellExe -ArgumentLine $args -WorkingDirectory $env:TEMP
            Add-Output $result.Output
            if ($result.ExitCode -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show('自动检查已卸载。', '完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            } else {
                [void][System.Windows.Forms.MessageBox]::Show('卸载没有完成。请查看右侧“最近活动”中的说明。', '卸载未完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
    } catch {
        Add-Output $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '卸载失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Refresh-TaskState
}

$script:mainForm = New-Object System.Windows.Forms.Form
$script:mainForm.Text = '校园网自动认证 · ' + $script:appVersion
$script:mainForm.StartPosition = 'CenterScreen'
$script:mainForm.FormBorderStyle = 'FixedDialog'
$script:mainForm.MaximizeBox = $false
$script:mainForm.MinimizeBox = $true
$script:mainForm.AutoScaleMode = 'Font'
$script:mainForm.ClientSize = New-Object System.Drawing.Size(960, 700)
$script:mainForm.BackColor = [System.Drawing.Color]::FromArgb(244, 247, 251)
$script:mainForm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(960, 92)
$header.BackColor = [System.Drawing.Color]::FromArgb(28, 57, 91)
$title = New-Object System.Windows.Forms.Label
$title.Text = '校园网自动认证'
$title.Location = New-Object System.Drawing.Point(26, 15)
$title.Size = New-Object System.Drawing.Size(550, 38)
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '查看认证状态、设置账号，并管理自动检查。只在允许的校园 Wi-Fi 上运行。'
$subtitle.Location = New-Object System.Drawing.Point(29, 57)
$subtitle.Size = New-Object System.Drawing.Size(880, 22)
$subtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(218, 229, 242)
$header.Controls.AddRange(@($title, $subtitle))
$script:mainForm.Controls.Add($header)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(22, 108)
$statusPanel.Size = New-Object System.Drawing.Size(916, 116)
$statusPanel.BackColor = [System.Drawing.Color]::White
$statusPanel.BorderStyle = 'FixedSingle'
$statusDot = New-Object System.Windows.Forms.Label
$statusDot.Text = '●'
$statusDot.Location = New-Object System.Drawing.Point(22, 35)
$statusDot.Size = New-Object System.Drawing.Size(30, 32)
$statusDot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$statusDot.ForeColor = [System.Drawing.Color]::FromArgb(121, 135, 153)
$script:networkLabel = New-Object System.Windows.Forms.Label
$script:networkLabel.Text = '正在读取校园网状态…'
$script:networkLabel.Location = New-Object System.Drawing.Point(58, 20)
$script:networkLabel.Size = New-Object System.Drawing.Size(610, 36)
$script:networkLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(47, 61, 78)
$script:statusDetailLabel = New-Object System.Windows.Forms.Label
$script:statusDetailLabel.Text = '打开窗口时会读取状态；刷新状态不会提交登录。'
$script:statusDetailLabel.Location = New-Object System.Drawing.Point(60, 61)
$script:statusDetailLabel.Size = New-Object System.Drawing.Size(630, 30)
$script:statusDetailLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:statusDetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(94, 108, 125)
$script:statusButton = New-Object System.Windows.Forms.Button
$script:statusButton.Text = '刷新状态'
$script:statusButton.Location = New-Object System.Drawing.Point(744, 34)
$script:statusButton.Size = New-Object System.Drawing.Size(146, 44)
$script:statusButton.FlatStyle = 'Flat'
$script:statusButton.FlatAppearance.BorderSize = 0
$script:statusButton.BackColor = [System.Drawing.Color]::FromArgb(46, 105, 184)
$script:statusButton.ForeColor = [System.Drawing.Color]::White
$script:statusButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$script:statusButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$statusPanel.Controls.AddRange(@($statusDot, $script:networkLabel, $script:statusDetailLabel, $script:statusButton))
$script:mainForm.Controls.Add($statusPanel)
$script:toolTip.SetToolTip($script:statusButton, '只读取认证状态，不会提交登录。')

$automationPanel = New-Object System.Windows.Forms.Panel
$automationPanel.Location = New-Object System.Drawing.Point(22, 240)
$automationPanel.Size = New-Object System.Drawing.Size(430, 416)
$automationPanel.BackColor = [System.Drawing.Color]::White
$automationPanel.BorderStyle = 'FixedSingle'
$automationHeading = New-Object System.Windows.Forms.Label
$automationHeading.Text = '账号与自动检查'
$automationHeading.Location = New-Object System.Drawing.Point(18, 15)
$automationHeading.Size = New-Object System.Drawing.Size(380, 28)
$automationHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$automationHeading.ForeColor = [System.Drawing.Color]::FromArgb(38, 55, 76)
$script:taskLabel = New-Object System.Windows.Forms.Label
$script:taskLabel.Text = '正在读取自动检查设置…'
$script:taskLabel.Location = New-Object System.Drawing.Point(20, 49)
$script:taskLabel.Size = New-Object System.Drawing.Size(388, 50)
$script:taskLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:taskLabel.ForeColor = [System.Drawing.Color]::FromArgb(87, 101, 118)
$script:taskLabel.AutoEllipsis = $true
$actionHint = New-Object System.Windows.Forms.Label
$actionHint.Text = '选择要执行的操作；悬停在按钮上可查看说明。'
$actionHint.Location = New-Object System.Drawing.Point(20, 103)
$actionHint.Size = New-Object System.Drawing.Size(388, 22)
$actionHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$actionHint.ForeColor = [System.Drawing.Color]::FromArgb(112, 124, 140)

function New-PanelButton {
    param([string]$Text, [int]$Left, [int]$Top, [int]$Width, [int]$Height, [bool]$Primary = $false)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($Left, $Top)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = if ($Primary) { 0 } else { 1 }
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 218, 229)
    $button.BackColor = if ($Primary) { [System.Drawing.Color]::FromArgb(46, 105, 184) } else { [System.Drawing.Color]::FromArgb(247, 249, 252) }
    $button.ForeColor = if ($Primary) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(43, 61, 82) }
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $button
}

$script:configButton = New-PanelButton -Text '设置 / 更换账号' -Left 19 -Top 137 -Width 188 -Height 48 -Primary $true
$script:installButton = New-PanelButton -Text '安装自动检查' -Left 221 -Top 137 -Width 188 -Height 48
$script:toggleButton = New-PanelButton -Text '暂停自动检查' -Left 19 -Top 199 -Width 188 -Height 48
$script:onceButton = New-PanelButton -Text '立即检查并尝试恢复' -Left 221 -Top 199 -Width 188 -Height 48
$script:diagnoseButton = New-PanelButton -Text '检查账号设置（不提交登录）' -Left 19 -Top 260 -Width 390 -Height 36
$script:removeButton = New-PanelButton -Text '卸载自动检查' -Left 19 -Top 309 -Width 390 -Height 38
$script:removeButton.ForeColor = [System.Drawing.Color]::FromArgb(160, 55, 55)
$script:removeButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(226, 196, 196)
$removeHint = New-Object System.Windows.Forms.Label
$removeHint.Text = '会移除后台任务和程序文件；校园网账号与运行记录会保留。'
$removeHint.Location = New-Object System.Drawing.Point(21, 358)
$removeHint.Size = New-Object System.Drawing.Size(385, 42)
$removeHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$removeHint.ForeColor = [System.Drawing.Color]::FromArgb(112, 124, 140)
$automationPanel.Controls.AddRange(@($automationHeading, $script:taskLabel, $actionHint, $script:configButton, $script:installButton, $script:toggleButton, $script:onceButton, $script:diagnoseButton, $script:removeButton, $removeHint))
$script:mainForm.Controls.Add($automationPanel)
$script:toolTip.SetToolTip($script:configButton, '添加或更换校园网账号。密码会在本机加密保存。')
$script:toolTip.SetToolTip($script:installButton, '设置或修复开机、网络变化和每 5 分钟一次的自动检查。')
$script:toolTip.SetToolTip($script:toggleButton, '暂停后不会自动尝试登录；需要时可在这里恢复。')
$script:toolTip.SetToolTip($script:onceButton, '已在线时只显示状态；离线时会提交一次登录请求。')
$script:toolTip.SetToolTip($script:diagnoseButton, '比对保存的账号和当前网页登录账号，读取门户诊断原因。不会提交登录，也不能验证在线会话的密码。')
$script:toolTip.SetToolTip($script:removeButton, '删除自动任务和已安装程序；保留账号凭据与运行记录。')

$activityPanel = New-Object System.Windows.Forms.Panel
$activityPanel.Location = New-Object System.Drawing.Point(470, 240)
$activityPanel.Size = New-Object System.Drawing.Size(468, 416)
$activityPanel.BackColor = [System.Drawing.Color]::White
$activityPanel.BorderStyle = 'FixedSingle'
$activityHeading = New-Object System.Windows.Forms.Label
$activityHeading.Text = '最近活动'
$activityHeading.Location = New-Object System.Drawing.Point(18, 15)
$activityHeading.Size = New-Object System.Drawing.Size(250, 28)
$activityHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$activityHeading.ForeColor = [System.Drawing.Color]::FromArgb(38, 55, 76)
$activityHint = New-Object System.Windows.Forms.Label
$activityHint.Text = '用简明中文显示操作结果和后台记录；不会显示账号密码。'
$activityHint.Location = New-Object System.Drawing.Point(20, 46)
$activityHint.Size = New-Object System.Drawing.Size(425, 26)
$activityHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$activityHint.ForeColor = [System.Drawing.Color]::FromArgb(112, 124, 140)
$script:outputBox = New-Object System.Windows.Forms.TextBox
$script:outputBox.Location = New-Object System.Drawing.Point(18, 78)
$script:outputBox.Size = New-Object System.Drawing.Size(430, 264)
$script:outputBox.Multiline = $true
$script:outputBox.ReadOnly = $true
$script:outputBox.ScrollBars = 'Vertical'
$script:outputBox.WordWrap = $true
$script:outputBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:outputBox.BackColor = [System.Drawing.Color]::FromArgb(249, 251, 253)
$script:outputBox.ForeColor = [System.Drawing.Color]::FromArgb(48, 62, 79)
$script:outputBox.BorderStyle = 'FixedSingle'
$script:outputBox.Text = '正在读取最近活动…'
$script:logButton = New-PanelButton -Text '刷新运行记录' -Left 18 -Top 358 -Width 150 -Height 38
$script:guideButton = New-PanelButton -Text '打开使用指南' -Left 182 -Top 358 -Width 150 -Height 38 -Primary $true
$script:toolTip.SetToolTip($script:logButton, '重新读取后台运行记录，并翻译成易懂说明。')
$script:toolTip.SetToolTip($script:guideButton, '打开随程序提供的图形界面导览和常见问题。')
$activityPanel.Controls.AddRange(@($activityHeading, $activityHint, $script:outputBox, $script:logButton, $script:guideButton))
$script:mainForm.Controls.Add($activityPanel)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = '网络范围：安装时保存的 Wi-Fi，以及所有以 zuel 开头的 Wi-Fi（例如 zuel-dorm）。程序不会替你连接 Wi-Fi。'
$footer.Location = New-Object System.Drawing.Point(26, 665)
$footer.Size = New-Object System.Drawing.Size(910, 22)
$footer.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$footer.ForeColor = [System.Drawing.Color]::FromArgb(105, 118, 135)
$script:mainForm.Controls.Add($footer)

$script:statusButton.Add_Click({ Invoke-StatusCheck })
$script:configButton.Add_Click({ Show-CredentialDialog; Refresh-TaskState })
$script:installButton.Add_Click({ Invoke-InstallOrRepair })
$script:toggleButton.Add_Click({ Toggle-Automation })
$script:onceButton.Add_Click({ Invoke-OneTimeRecovery })
$script:logButton.Add_Click({ Show-RecentLog })
$script:diagnoseButton.Add_Click({ Invoke-AccountDiagnostics })
$script:guideButton.Add_Click({
    if (Test-Path -LiteralPath $script:readmePath) {
        Start-Process -FilePath $script:readmePath
    } else {
        [void][System.Windows.Forms.MessageBox]::Show('找不到使用指南。请从程序开始菜单中选择“打开文件所在位置”，或重新解压完整发布包。', '使用指南不可用', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})
$script:removeButton.Add_Click({ Invoke-Uninstall })

Refresh-TaskState
Show-RecentLog
$script:mainForm.Add_Shown({ Invoke-StatusCheck })
[void]$script:mainForm.ShowDialog()
