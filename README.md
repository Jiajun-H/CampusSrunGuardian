# Campus SRun Guardian

面向 ZUEL 校园网 SRun 门户的 Windows 自动检查与认证恢复工具。默认针对门户 `10.175.100.48`，只在安装时捕获的 Wi-Fi 或名称以 `zuel` 开头的 Wi-Fi 上检查。

程序不是常驻后台服务。Windows 在开机、网络事件和五分钟兜底时间触发计划任务；每次检查结束后进程退出。检测到会话已在线时不会重复登录，检测到离线时才尝试恢复认证。

## 普通用户：下载和设置

1. 从 GitHub Releases 下载最新的 `CampusSrunGuardian-版本号.zip`，解压到一个长期保留的文件夹。
2. 双击 `Start-CampusSrunGuardian.cmd`，在 Windows 提示时允许管理员权限。
3. 在窗口中选择“设置 / 更换账号”，填写校园网账号和密码。
4. 连接校园 Wi-Fi 后，选择“安装自动检查”。窗口会检查门户、捕获当前 Wi-Fi，并安装计划任务。

以后双击同一个 `Start-CampusSrunGuardian.cmd` 即可查看认证状态、暂停或恢复自动检查、立即检查、查看日志、修改账号或卸载。安装后即使关闭控制面板，计划任务仍会按设置运行。安装操作本身不会立即提交登录。

## 控制面板

- **检查认证状态**：只读查询当前 SRun 会话。
- **设置 / 更换账号**：用密码框输入账号；密码不会显示，也不会出现在命令行参数中。保存后由 Windows DPAPI 在本机加密。
- **安装自动检查**：安装或修复计划任务。需要连接到该校园门户，并且 Windows 已连接到校园 Wi-Fi。
- **暂停 / 恢复自动检查**：切换计划任务的启用状态。
- **立即检查 / 恢复**：显示确认框；离线时会提交一次登录请求。
- **查看最近日志**：查看认证拒绝或程序错误等记录。
- **卸载自动检查**：移除计划任务和 Program Files 中的程序文件；保留加密凭据和日志。

## Wi-Fi 范围

安装时会保存当前连接的 SSID。自动检查也接受所有以 `zuel` 开头的 SSID，大小写不敏感，例如 `zuel-dorm`。程序不会扫描、选择或连接 Wi-Fi，也不会保存 Wi-Fi 密码；Windows 必须先连接到已保存的网络。

## 构建与打包

在 Windows PowerShell 中运行 `Build.ps1` 可使用 Windows .NET Framework C# 编译器构建命令行程序。运行 `Package-Release.ps1` 会构建程序并生成可直接使用的 ZIP 包，输出在 `dist\`。

源码和高级命令：

```powershell
.\bin\CampusSrunGuardian.exe --status
.\bin\CampusSrunGuardian.exe --configure
.\bin\CampusSrunGuardian.exe --prepare-login
.\bin\CampusSrunGuardian.exe --once
.\Install-StartupTask.ps1
.\Remove-StartupTask.ps1
```

- `--status` 只读查询状态。
- `--configure` 会提示输入账号和密码，需管理员 PowerShell。
- `--prepare-login` 获取挑战并准备字段，不提交登录。
- `--once` 离线时会提交登录请求；在线时不操作。
- 安装和卸载脚本需要管理员权限。

## 安全与已知限制

- 凭据在本机使用 DPAPI machine-scope 加密，凭据文件 ACL 限制为 LocalService、SYSTEM 和本机管理员。日志不记录密码或登录令牌。
- 门户地址使用 HTTP。SRun 挑战字段的编码不等于传输加密；仅应在可信校园网络中使用。
- 登录成功只有在门户返回成功且随后状态查询确认在线时才会记录为成功。
- 当前任务注册和在线状态查询已确认；离线后的真实自动登录尚未验证。不要为了验证而主动断开依赖中的远程连接。
- 事件触发无法覆盖所有静默会话过期情况；五分钟兜底任务用于再次检查。若 Windows 未报告较早的网络变化，恢复最多可能延迟约五分钟。
- 此项目目前针对 `10.175.100.48` 和以 `zuel` 开头的 Wi-Fi，其他学校的 SRun 参数和 SSID 规则可能不同。

## 第三方组件

本项目使用 MIT 许可证，详见 [LICENSE](LICENSE)。程序依赖 Windows 自带的 .NET Framework、Windows PowerShell、Task Scheduler 和 `netsh`，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
