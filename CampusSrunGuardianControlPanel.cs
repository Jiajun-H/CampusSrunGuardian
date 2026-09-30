using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class CampusSrunGuardianControlPanel
{
    [STAThread]
    private static int Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "ControlPanel.ps1");
            if (!File.Exists(script))
            {
                ShowError("找不到控制面板文件。请确认程序文件夹完整，或重新解压发布包。");
                return 2;
            }

            string windows = Environment.GetEnvironmentVariable("WINDIR");
            string powershell = Path.Combine(windows, @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
            {
                ShowError("找不到 Windows PowerShell 5.1，无法打开控制面板。");
                return 3;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script),
                WorkingDirectory = Path.GetTempPath(),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.EnvironmentVariables["CAMPUS_SRUN_LAUNCHER_PID"] = Process.GetCurrentProcess().Id.ToString();

            var standardOutput = new StringBuilder();
            var standardError = new StringBuilder();
            using (var process = new Process { StartInfo = startInfo })
            {
                process.OutputDataReceived += (sender, args) =>
                {
                    if (args.Data != null) standardOutput.AppendLine(args.Data);
                };
                process.ErrorDataReceived += (sender, args) =>
                {
                    if (args.Data != null) standardError.AppendLine(args.Data);
                };

                if (!process.Start())
                {
                    ShowError("Windows PowerShell 没有启动。");
                    return 4;
                }

                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                process.WaitForExit();

                if (process.ExitCode != 0)
                {
                    string details = (standardError.ToString() + Environment.NewLine + standardOutput.ToString()).Trim();
                    if (details.Length > 2400) details = details.Substring(0, 2400) + Environment.NewLine + "（错误内容过长，已截断）";
                    ShowError("控制面板没有正常启动。请把此提示中的内容发给维护者。" +
                        (details.Length == 0 ? "" : Environment.NewLine + Environment.NewLine + details));
                    return process.ExitCode;
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            ShowError("启动控制面板时遇到问题：" + ex.Message);
            return 1;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, "Campus SRun Guardian " + AppMetadata.Version, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
