using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace CodexUsageDesktop {
    public static class Distribution {
        const string RegistryPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexUsage";

        public static bool ConfirmInstall() {
            using (var form = CreateInstallForm()) return form.ShowDialog() == DialogResult.OK;
        }

        public static Form CreateInstallForm() {
                var form = new Form();
                form.Text = "安装 Codex 额度";
                form.Icon = Icon.ExtractAssociatedIcon(Client.Self);
                form.StartPosition = FormStartPosition.CenterScreen;
                form.ClientSize = new Size(520, 350);
                form.AutoScaleDimensions = new SizeF(96, 96);
                form.AutoScaleMode = AutoScaleMode.Dpi;
                form.FormBorderStyle = FormBorderStyle.FixedDialog;
                form.MaximizeBox = false;
                form.MinimizeBox = false;
                form.Font = new Font("Microsoft YaHei UI", 10);
                form.BackColor = Color.FromArgb(27, 30, 37);
                form.ForeColor = Color.FromArgb(235, 238, 245);
                var title = new Label { Text = "Codex 额度  v" + Client.CurrentVersion, Location = new Point(26, 24), AutoSize = true, Font = new Font(form.Font.FontFamily, 18, FontStyle.Bold) };
                var description = new Label { Text = "个人与工作账号，一眼查看剩余额度。\r\n\r\n• 仅安装到当前用户，无需管理员权限\r\n• 创建桌面和开始菜单快捷方式\r\n• 后台下载更新，重启或退出时安装\r\n• 首次使用请在右键菜单中登录自己的账号", Location = new Point(28, 78), Size = new Size(464, 142) };
                var path = new Label { Text = "安装位置：\r\n" + Client.InstallRoot, Location = new Point(28, 228), Size = new Size(464, 50), AutoEllipsis = true };
                var install = new Button { Text = "安装并启动", Location = new Point(342, 295), Size = new Size(150, 34), DialogResult = DialogResult.OK, BackColor = Color.FromArgb(179, 165, 239), ForeColor = Color.FromArgb(25, 27, 33), FlatStyle = FlatStyle.Flat };
                var cancel = new Button { Text = "取消", Location = new Point(240, 295), Size = new Size(90, 34), DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.Flat };
                form.Controls.AddRange(new Control[] { title, description, path, install, cancel });
                form.AcceptButton = install;
                form.CancelButton = cancel;
                return form;
        }

        public static void Register(string target) {
            // Metadata only: no elevation, service, scheduled task or startup registration.
            using (var key = Registry.CurrentUser.CreateSubKey(RegistryPath)) {
                key.SetValue("DisplayName", "Codex 额度");
                key.SetValue("DisplayVersion", Client.CurrentVersion);
                key.SetValue("Publisher", "lv5accelerator-xy (independent project)");
                key.SetValue("DisplayIcon", target + ",0");
                key.SetValue("InstallLocation", Client.InstallRoot);
                key.SetValue("UninstallString", Client.Quote(target) + " --uninstall");
                key.SetValue("URLInfoAbout", "https://github.com/" + Client.Repository);
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
        }

        public static int Uninstall() {
            if (!Client.SamePath(Client.Self, Path.Combine(Client.InstallRoot, Client.ExeName))) throw new InvalidOperationException("请从 Windows 设置中的已安装应用执行卸载。");
            bool created;
            using (var mutex = new System.Threading.Mutex(true, "Local\\CodexUsageDesktopClient", out created)) {
                if (!created) {
                    MessageBox.Show("请先右键托盘图标选择“退出”，再运行卸载。", "Codex 额度", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 1;
                }
                if (MessageBox.Show("卸载 Codex 额度客户端和快捷方式？\r\n\r\n将保留界面设置、日志以及 Codex 账号登录信息，方便以后重新安装。", "卸载 Codex 额度", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return 0;
                string helper = Path.Combine(Path.GetTempPath(), "CodexUsage-Uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
                File.Copy(Client.Self, helper);
                Process.Start(new ProcessStartInfo(helper, "--finish-uninstall " + Process.GetCurrentProcess().Id) { UseShellExecute = false });
                return 0;
            }
        }

        public static int FinishUninstall(int parentId) {
            if (!Client.SamePath(Path.GetDirectoryName(Client.Self), Path.GetTempPath()) || !Path.GetFileName(Client.Self).StartsWith("CodexUsage-Uninstall-", StringComparison.Ordinal)) throw new InvalidOperationException("Invalid uninstall helper location.");
            try {
                using (var parent = Process.GetProcessById(parentId)) {
                    if (!Client.SamePath(parent.MainModule.FileName, Path.Combine(Client.InstallRoot, Client.ExeName))) throw new InvalidOperationException("Invalid uninstall parent.");
                    if (!parent.WaitForExit(30000)) throw new IOException("客户端尚未退出，请稍后重试。");
                }
            } catch (ArgumentException) { }
            bool created;
            using (var mutex = new System.Threading.Mutex(true, "Local\\CodexUsageDesktopClient", out created)) {
                if (!created) throw new IOException("客户端仍在运行，请退出后重试卸载。");
                RemoveProgramFiles(Client.InstallRoot);
                RemoveShortcuts();
                Registry.CurrentUser.DeleteSubKeyTree(RegistryPath, false);
                using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)) {
                    if (run != null) run.DeleteValue("CodexUsage", false);
                }
            }
            MessageBox.Show("客户端已卸载。设置和账号登录信息已保留。", "Codex 额度", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        public static void RemoveProgramFiles(string root) {
            // Deliberate allowlist: never remove data or any external Codex profile.
            foreach (string name in new[] { "app", "updates" }) {
                string path = Path.Combine(root, name);
                if (Directory.Exists(path)) Directory.Delete(path, true);
            }
            foreach (string name in new[] { Client.ExeName, Client.ExeName + ".bak", Client.ExeName + ".next", "post-update.pending" }) File.Delete(Path.Combine(root, name));
        }

        static void RemoveShortcuts() {
            Type type = Type.GetTypeFromProgID("WScript.Shell");
            dynamic shell = Activator.CreateInstance(type);
            foreach (string folder in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Programs), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) }) {
                string path = Path.Combine(folder, "Codex 额度.lnk");
                if (!File.Exists(path)) continue;
                dynamic shortcut = shell.CreateShortcut(path);
                if (Client.SamePath((string)shortcut.TargetPath, Path.Combine(Client.InstallRoot, Client.ExeName))) File.Delete(path);
            }
        }
    }
}
