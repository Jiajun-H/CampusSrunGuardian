$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath $powershell -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:root = $PSScriptRoot
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
$script:powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Add-Output {
    param([string]$Text)
    if ([String]::IsNullOrWhiteSpace($Text)) { return }
    $script:outputBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Text`r`n")
    $script:outputBox.SelectionStart = $script:outputBox.TextLength
    $script:outputBox.ScrollToCaret()
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentLine,
        [AllowNull()][string]$InputText = $null
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
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
        $enabledText = if ($enabled) { '已启用' } else { '已暂停' }
        if ($info.LastRunTime.Year -lt 2000) { $lastRun = '尚未运行' } else { $lastRun = $info.LastRunTime.ToString('yyyy/M/d HH:mm:ss') }
        $credentialsText = if (Test-Path -LiteralPath $script:credentialPath) { '账号已配置' } else { '尚未配置账号' }
        $script:taskLabel.Text = "自动检查：$enabledText    $credentialsText    上次运行：$lastRun"
        $script:taskLabel.ForeColor = if ($enabled) { [System.Drawing.Color]::FromArgb(24, 105, 71) } else { [System.Drawing.Color]::FromArgb(160, 91, 25) }
        $script:toggleButton.Enabled = $true
        $script:toggleButton.Text = if ($enabled) { '暂停自动检查' } else { '恢复自动检查' }
        $script:removeButton.Enabled = $true
        $script:onceButton.Enabled = $enabled
        $script:installButton.Text = '重新安装 / 修复'
    } catch {
        $script:taskLabel.Text = '自动检查尚未安装。先配置账号，再选择“安装自动检查”。'
        $script:taskLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 91, 25)
        $script:toggleButton.Enabled = $false
        $script:toggleButton.Text = '暂停 / 恢复自动检查'
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
            $script:networkLabel.Text = '校园网认证：在线'
            $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(24, 105, 71)
        } elseif ($result.ExitCode -eq 3 -or $result.Output -match 'SRun session:\s+offline') {
            $script:networkLabel.Text = '校园网认证：离线；自动任务会在允许的 Wi-Fi 上尝试恢复'
            $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 91, 25)
        } else {
            $script:networkLabel.Text = '暂时无法读取认证状态；查看下方信息'
            $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 45, 45)
        }
    } catch {
        Add-Output $_.Exception.Message
        $script:networkLabel.Text = '状态检查出错；查看下方信息'
        $script:networkLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 45, 45)
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
    $dialog.ClientSize = New-Object System.Drawing.Size(430, 270)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Text = '校园网账号'
    $usernameLabel.Location = New-Object System.Drawing.Point(22, 24)
    $usernameLabel.Size = New-Object System.Drawing.Size(105, 24)
    $usernameBox = New-Object System.Windows.Forms.TextBox
    $usernameBox.Location = New-Object System.Drawing.Point(135, 20)
    $usernameBox.Size = New-Object System.Drawing.Size(270, 26)

    $suffixLabel = New-Object System.Windows.Forms.Label
    $suffixLabel.Text = '账号后缀（可选）'
    $suffixLabel.Location = New-Object System.Drawing.Point(22, 66)
    $suffixLabel.Size = New-Object System.Drawing.Size(110, 24)
    $suffixBox = New-Object System.Windows.Forms.TextBox
    $suffixBox.Location = New-Object System.Drawing.Point(135, 62)
    $suffixBox.Size = New-Object System.Drawing.Size(270, 26)

    $passwordLabel = New-Object System.Windows.Forms.Label
    $passwordLabel.Text = '校园网密码'
    $passwordLabel.Location = New-Object System.Drawing.Point(22, 108)
    $passwordLabel.Size = New-Object System.Drawing.Size(105, 24)
    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location = New-Object System.Drawing.Point(135, 104)
    $passwordBox.Size = New-Object System.Drawing.Size(270, 26)
    $passwordBox.UseSystemPasswordChar = $true

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '后缀只填 @ 后面的部分；没有后缀就留空。保存后密码会加密保存在本机。'
    $hint.Location = New-Object System.Drawing.Point(22, 145)
    $hint.Size = New-Object System.Drawing.Size(385, 42)
    $hint.ForeColor = [System.Drawing.Color]::DimGray

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = '保存账号'
    $saveButton.Location = New-Object System.Drawing.Point(220, 205)
    $saveButton.Size = New-Object System.Drawing.Size(88, 34)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object System.Drawing.Point(317, 205)
    $cancelButton.Size = New-Object System.Drawing.Size(88, 34)
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
                Add-Output '校园网账号已加密保存。'
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

    $dialog.Controls.AddRange(@($usernameLabel, $usernameBox, $suffixLabel, $suffixBox, $passwordLabel, $passwordBox, $hint, $saveButton, $cancelButton))
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
            [void][System.Windows.Forms.MessageBox]::Show('自动检查已安装并核验。它会按开机、网络事件和五分钟兜底触发；本次未立即运行。', '安装成功', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("安装未完成：`r`n$($result.Output)", '安装失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
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
        '现在读取 SRun 状态；如果检测到离线，程序会提交一次登录。要继续吗？',
        '立即检查 / 恢复', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $result = Invoke-CapturedProcess -FilePath $script:exePath -ArgumentLine '--once'
        Add-Output $result.Output
        if ($result.Output -match 'SRun authentication succeeded') {
            [void][System.Windows.Forms.MessageBox]::Show('校园网认证已恢复。', '恢复成功', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } elseif ($result.Output -match 'already online') {
            [void][System.Windows.Forms.MessageBox]::Show('当前已经在线，没有提交登录。', '状态正常', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } elseif ($result.Output -match 'unreachable') {
            [void][System.Windows.Forms.MessageBox]::Show('门户暂时无法访问，本次未能检查或恢复；自动任务稍后会再试。', '暂时无法连接', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        } elseif ($result.ExitCode -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('检查已完成；请查看下方结果或最近日志确认状态。', '完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("检查或恢复未成功。请查看日志。`r`n$($result.Output)", '需要查看日志', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    } catch {
        Add-Output $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '操作失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Refresh-TaskState
}

function Show-RecentLog {
    if (-not (Test-Path -LiteralPath $script:logPath)) {
        Add-Output '还没有运行日志。'
        return
    }
    try {
        $lines = Get-Content -LiteralPath $script:logPath -Tail 60 -ErrorAction Stop
        Add-Output ($lines -join "`r`n")
    } catch {
        Add-Output $_.Exception.Message
    }
}

function Invoke-Uninstall {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        '这会移除自动任务和已安装的程序文件。账号凭据和日志会保留。继续吗？',
        '卸载自动检查', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if (-not (Test-Path -LiteralPath $script:removeScript)) {
        [void][System.Windows.Forms.MessageBox]::Show('发布包缺少卸载脚本。', '文件缺失', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try {
        $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0}' -f (Get-PowerShellArgument $script:removeScript)
        $result = Invoke-CapturedProcess -FilePath $script:powershellExe -ArgumentLine $args
        Add-Output $result.Output
        if ($result.ExitCode -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('自动检查已卸载。', '完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("卸载未完成：`r`n$($result.Output)", '卸载失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } catch {
        Add-Output $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '卸载失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    Refresh-TaskState
}

$script:mainForm = New-Object System.Windows.Forms.Form
$script:mainForm.Text = '校园网自动认证'
$script:mainForm.StartPosition = 'CenterScreen'
$script:mainForm.FormBorderStyle = 'FixedDialog'
$script:mainForm.MaximizeBox = $false
$script:mainForm.MinimizeBox = $false
$script:mainForm.ClientSize = New-Object System.Drawing.Size(760, 535)
$script:mainForm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$headerPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$headerPanel.Dock = 'Top'
$headerPanel.Height = 82
$headerPanel.FlowDirection = 'TopDown'
$headerPanel.WrapContents = $false
$headerPanel.Padding = New-Object System.Windows.Forms.Padding(16, 8, 8, 2)

$script:networkLabel = New-Object System.Windows.Forms.Label
$script:networkLabel.Text = '校园网认证：尚未查询'
$script:networkLabel.Size = New-Object System.Drawing.Size(710, 30)
$script:networkLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$script:taskLabel = New-Object System.Windows.Forms.Label
$script:taskLabel.Text = '正在读取自动检查状态…'
$script:taskLabel.Size = New-Object System.Drawing.Size(710, 30)
$script:taskLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:taskLabel.ForeColor = [System.Drawing.Color]::DimGray
$headerPanel.Controls.Add($script:networkLabel)
$headerPanel.Controls.Add($script:taskLabel)

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = 'Top'
$buttonPanel.Height = 142
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(14, 8, 8, 8)
$buttonPanel.WrapContents = $true
$buttonPanel.AutoScroll = $false

$script:statusButton = New-Object System.Windows.Forms.Button
$script:statusButton.Text = '检查认证状态'
$script:configButton = New-Object System.Windows.Forms.Button
$script:configButton.Text = '设置 / 更换账号'
$script:installButton = New-Object System.Windows.Forms.Button
$script:installButton.Text = '安装自动检查'
$script:toggleButton = New-Object System.Windows.Forms.Button
$script:toggleButton.Text = '暂停 / 恢复自动检查'
$script:onceButton = New-Object System.Windows.Forms.Button
$script:onceButton.Text = '立即检查 / 恢复'
$script:logButton = New-Object System.Windows.Forms.Button
$script:logButton.Text = '查看最近日志'
$script:removeButton = New-Object System.Windows.Forms.Button
$script:removeButton.Text = '卸载自动检查'
foreach ($button in @($script:statusButton, $script:configButton, $script:installButton, $script:toggleButton, $script:onceButton, $script:logButton, $script:removeButton)) {
    $button.Size = New-Object System.Drawing.Size(166, 42)
    $button.Margin = New-Object System.Windows.Forms.Padding(6)
    $buttonPanel.Controls.Add($button)
}

$script:outputBox = New-Object System.Windows.Forms.TextBox
$script:outputBox.Dock = 'Fill'
$script:outputBox.Multiline = $true
$script:outputBox.ReadOnly = $true
$script:outputBox.ScrollBars = 'Vertical'
$script:outputBox.WordWrap = $false
$script:outputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:outputBox.Text = '操作结果和最近日志会显示在这里。账号密码不会写入此窗口日志。'

$footer = New-Object System.Windows.Forms.Label
$footer.Dock = 'Bottom'
$footer.Height = 36
$footer.Padding = New-Object System.Windows.Forms.Padding(16, 7, 8, 4)
$footer.ForeColor = [System.Drawing.Color]::DimGray
$footer.Text = '自动任务只在已保存的 Wi-Fi 或名称以 zuel 开头的 Wi-Fi 上尝试检查。'

$script:statusButton.Add_Click({ Invoke-StatusCheck })
$script:configButton.Add_Click({ Show-CredentialDialog; Refresh-TaskState })
$script:installButton.Add_Click({ Invoke-InstallOrRepair })
$script:toggleButton.Add_Click({ Toggle-Automation })
$script:onceButton.Add_Click({ Invoke-OneTimeRecovery })
$script:logButton.Add_Click({ Show-RecentLog })
$script:removeButton.Add_Click({ Invoke-Uninstall })

$script:mainForm.Controls.Add($script:outputBox)
$script:mainForm.Controls.Add($buttonPanel)
$script:mainForm.Controls.Add($headerPanel)
$script:mainForm.Controls.Add($footer)
Refresh-TaskState
[void]$script:mainForm.ShowDialog()
