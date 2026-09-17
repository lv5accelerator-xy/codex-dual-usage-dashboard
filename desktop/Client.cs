using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace CodexUsageDesktop {
    public sealed class UpdateManifest {
        public string version { get; set; }
        public string exe { get; set; }
        public string sha256 { get; set; }
        public long size { get; set; }
    }
    public sealed class ReleaseAsset { public string name { get; set; } public string browser_download_url { get; set; } }
    public sealed class ReleaseInfo {
        public string tag_name { get; set; }
        public bool draft { get; set; }
        public bool prerelease { get; set; }
        public List<ReleaseAsset> assets { get; set; }
    }
    public sealed class PendingUpdate { public string Path; public UpdateManifest Manifest; }

    public static class Client {
        public const string Repository = "lv5accelerator-xy/codex-dual-usage-dashboard";
        public const string ExeName = "CodexUsage.exe";
        public static string CurrentVersion { get { return Assembly.GetExecutingAssembly().GetName().Version.ToString(3); } }
        public static string Self { get { return Assembly.GetExecutingAssembly().Location; } }
        public static string InstallRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexUsage"); } }
        static string LogPath;
        static readonly object LogGate = new object();

        [STAThread]
        public static int Main(string[] args) {
            Application.EnableVisualStyles();
            try {
                if (args.Length == 2 && args[0] == "--read-usage") return UsageReader.Run(Path.GetFullPath(args[1]));
                if (args.Length == 1 && args[0] == "--rpc-fixture") return SelfTest.RpcFixture();
                if (args.Length == 2 && args[0] == "--self-test") return SelfTest.Run(Path.GetFullPath(args[1]));
                if (args.Length == 2 && args[0] == "--finish-uninstall") return Distribution.FinishUninstall(int.Parse(args[1]));
                if (args.Length == 1 && args[0] == "--uninstall") return Distribution.Uninstall();
                Directory.CreateDirectory(InstallRoot);
                LogPath = Path.Combine(InstallRoot, "client.log");
                if (args.Length == 5 && args[0] == "--apply-update") return ApplyUpdate(args);
                if (args.Length > 0 && args[0] != "--post-update" && args[0] != "--rollback-recovered") throw new ArgumentException("Unknown client argument.");
                string target = Path.Combine(InstallRoot, ExeName);
                string data = Path.Combine(InstallRoot, "data");
                Directory.CreateDirectory(data);
                bool created;
                using (var mutex = new Mutex(true, "Local\\CodexUsageDesktopClient", out created)) {
                    if (!created) { File.WriteAllText(Path.Combine(data, "show.request"), "show"); return 0; }
                    if (!SamePath(Self, target)) {
                        if (!Distribution.ConfirmInstall()) return 0;
                        // Install/update only while no installed client owns this mutex.
                        if (File.Exists(target)) {
                            var installed = Version.Parse(FileVersionInfo.GetVersionInfo(target).FileVersion);
                            if (installed <= Assembly.GetExecutingAssembly().GetName().Version) InstallCandidate(Self, target, Hash(Self), new FileInfo(Self).Length);
                        } else File.Copy(Self, target);
                        PrepareData(data, null, Path.GetDirectoryName(Self));
                        CreateShortcuts(target);
                        mutex.ReleaseMutex();
                        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
                        return 0;
                    }
                    CreateShortcuts(target);
                    Distribution.Register(target);
                    string payload = ExtractPayload(InstallRoot);
                    PrepareData(data, payload, null);
                    string marker = Path.Combine(InstallRoot, "post-update.pending");
                    bool afterUpdate = args.Contains("--post-update") || File.Exists(marker);
                    TryDelete(marker);
                    return RunClient(target, data, payload, afterUpdate);
                }
            } catch (Exception ex) {
                Log(ex.ToString());
                if (args.Contains("--post-update") || File.Exists(Path.Combine(InstallRoot, "post-update.pending"))) {
                    TryDelete(Path.Combine(InstallRoot, "post-update.pending"));
                    try { if (Rollback(Path.Combine(InstallRoot, ExeName))) return 1; } catch (Exception rollbackError) { Log(rollbackError.ToString()); }
                }
                MessageBox.Show("客户端启动失败：\r\n" + ex.Message + "\r\n\r\n日志：" + LogPath, "Codex 额度", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        static int RunClient(string target, string data, string payload, bool afterUpdate) {
            string token = Guid.NewGuid().ToString("N");
            string readyFile = Path.Combine(data, "client-ui-ready.txt");
            TryDelete(readyFile);
            TryDelete(Path.Combine(data, "restart.request"));
            var agent = new UpdateAgent(data);
            using (var ui = StartUi(payload, data, token, false)) {
                DateTime started = DateTime.UtcNow;
                DateTime nextCheck = started.AddSeconds(10);
                Task check = null;
                bool ready = false;
                while (!ui.WaitForExit(500)) {
                    if (!ready && File.Exists(readyFile)) {
                        try { ready = File.ReadAllText(readyFile).Trim() == token; } catch (IOException) { }
                    }
                    if (!ready && (DateTime.UtcNow - started).TotalSeconds > 45) {
                        ui.Kill(); ui.WaitForExit();
                        if (afterUpdate && Rollback(target)) return 1;
                        throw new InvalidOperationException("界面未能完成启动，请查看 data/logs/tray.log。");
                    }
                    string request = Path.Combine(data, "check-update.request");
                    if (check == null || check.IsCompleted) {
                        if (ready && (File.Exists(request) || DateTime.UtcNow >= nextCheck)) {
                            TryDelete(request);
                            check = Task.Run((Action)agent.Check);
                            nextCheck = DateTime.UtcNow.AddHours(6);
                        }
                    }
                }
                if (!ready && ui.ExitCode != 0) {
                    if (afterUpdate && Rollback(target)) return ui.ExitCode;
                    throw new InvalidOperationException("界面启动失败，请查看 data/logs/tray.log。");
                }
                PendingUpdate pending = agent.Pending;
                if (pending != null) {
                    bool restart = File.Exists(Path.Combine(data, "restart.request"));
                    TryDelete(Path.Combine(data, "restart.request"));
                    string arguments = "--apply-update " + Process.GetCurrentProcess().Id + " " + Quote(target) + " " + pending.Manifest.sha256 + " " + (restart ? "restart" : "exit");
                    Process.Start(new ProcessStartInfo(pending.Path, arguments) { UseShellExecute = false, CreateNoWindow = true });
                }
                return ui.ExitCode;
            }
        }

        public static Process StartUi(string payload, string data, string token, bool smoke) {
            var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"));
            info.Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(Path.Combine(payload, "tray.ps1")) + (smoke ? " -SmokeTest" : "");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = payload;
            info.EnvironmentVariables["CODEX_USAGE_DATA_DIR"] = data;
            info.EnvironmentVariables["CODEX_USAGE_CLIENT_PATH"] = Self;
            info.EnvironmentVariables["CODEX_USAGE_CLIENT_VERSION"] = CurrentVersion;
            info.EnvironmentVariables["CODEX_USAGE_LAUNCH_ID"] = token;
            return Process.Start(info);
        }

        static int ApplyUpdate(string[] args) {
            int pid = int.Parse(args[1]);
            string target = Path.GetFullPath(args[2]);
            if (!SamePath(target, Path.Combine(InstallRoot, ExeName))) throw new InvalidOperationException("Invalid update target.");
            if (!Path.GetFullPath(Self).StartsWith(Path.Combine(InstallRoot, "updates") + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Invalid update staging location.");
            if (!Regex.IsMatch(args[3], "^[a-fA-F0-9]{64}$") || Hash(Self) != args[3].ToLowerInvariant()) throw new InvalidOperationException("Update checksum mismatch.");
            try {
                using (var parent = Process.GetProcessById(pid)) {
                    if (!SamePath(parent.MainModule.FileName, target)) throw new InvalidOperationException("Invalid update parent.");
                    if (!parent.WaitForExit(30000)) throw new InvalidOperationException("Client did not exit; update postponed.");
                }
            } catch (ArgumentException) { /* parent already exited */ }
            bool ownsUpdateLock;
            using (var updateLock = new Mutex(true, "Local\\CodexUsageDesktopClient", out ownsUpdateLock)) {
                if (!ownsUpdateLock) throw new InvalidOperationException("Client is already running; update postponed.");
                InstallCandidate(Self, target, args[3], new FileInfo(Self).Length);
            }
            AtomicJson(Path.Combine(InstallRoot, "data", "client-status.json"), new { state = "installed", version = CurrentVersion, message = "更新已安装，下次启动生效" });
            if (args[4] == "restart" || args[4] == "rollback") {
                try { Process.Start(new ProcessStartInfo(target, args[4] == "rollback" ? "--rollback-recovered" : "--post-update") { UseShellExecute = false }); }
                catch { Rollback(target); throw; }
            } else File.WriteAllText(Path.Combine(InstallRoot, "post-update.pending"), CurrentVersion);
            return 0;
        }

        static bool Rollback(string target) {
            string backup = target + ".bak";
            if (!File.Exists(backup)) return false;
            // A running executable cannot replace itself. Use the existing helper copy.
            string helper = Path.Combine(InstallRoot, "updates", "rollback.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(helper));
            File.Copy(backup, helper, true);
            Process.Start(new ProcessStartInfo(helper, "--apply-update " + Process.GetCurrentProcess().Id + " " + Quote(target) + " " + Hash(helper) + " rollback") { UseShellExecute = false });
            Log("Startup failed; restoring previous client.");
            return true;
        }

        public static void InstallCandidate(string candidate, string target, string hash, long size) {
            VerifyFile(candidate, hash, size);
            AssemblyName.GetAssemblyName(candidate); // A readable managed executable, not a partial download.
            string stage = target + ".next";
            File.Copy(candidate, stage, true);
            VerifyFile(stage, hash, size);
            if (File.Exists(target)) File.Replace(stage, target, target + ".bak", true);
            else File.Move(stage, target);
        }

        public static string ExtractPayload(string root) {
            string destination = Path.Combine(root, "app", CurrentVersion);
            if (File.Exists(Path.Combine(destination, ".complete"))) return destination;
            string staging = destination + ".staging";
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            Directory.CreateDirectory(staging);
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexUsage.Payload.zip")) {
                if (resource == null) throw new InvalidOperationException("Embedded UI payload is missing.");
                using (var zip = new ZipArchive(resource, ZipArchiveMode.Read)) {
                    foreach (var entry in zip.Entries) {
                        string path = SafeEntryPath(staging, entry.FullName);
                        if (string.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(path); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(path));
                        using (var input = entry.Open()) using (var output = File.Create(path)) input.CopyTo(output);
                    }
                }
            }
            File.WriteAllText(Path.Combine(staging, ".complete"), CurrentVersion);
            if (Directory.Exists(destination)) Directory.Delete(destination, true);
            Directory.Move(staging, destination);
            return destination;
        }

        public static string SafeEntryPath(string root, string entry) {
            if (Path.IsPathRooted(entry) || entry.Contains(":")) throw new InvalidDataException("Unsafe payload path.");
            string full = Path.GetFullPath(Path.Combine(root, entry));
            if (!full.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsafe payload path.");
            return full;
        }

        public static void PrepareData(string data, string payload, string legacy) {
            Directory.CreateDirectory(data);
            foreach (string name in new[] { "ui-settings.json", "profiles.json" }) {
                string target = Path.Combine(data, name);
                if (!File.Exists(target) && !string.IsNullOrEmpty(legacy) && File.Exists(Path.Combine(legacy, name))) File.Copy(Path.Combine(legacy, name), target);
            }
            if (payload != null && !File.Exists(Path.Combine(data, "profiles.json"))) File.Copy(Path.Combine(payload, "profiles.json"), Path.Combine(data, "profiles.json"));
        }

        static void CreateShortcuts(string target) {
            try {
                Type type = Type.GetTypeFromProgID("WScript.Shell");
                dynamic shell = Activator.CreateInstance(type);
                foreach (string folder in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Programs), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) }) {
                    string path = Path.Combine(folder, "Codex 额度.lnk");
                    if (File.Exists(path)) continue;
                    dynamic shortcut = shell.CreateShortcut(path);
                    shortcut.TargetPath = target;
                    shortcut.WorkingDirectory = InstallRoot;
                    shortcut.IconLocation = target + ",0";
                    shortcut.Description = "个人与工作账号的 Codex 额度监视器";
                    shortcut.Save();
                }
            } catch (Exception ex) { Log("Shortcut creation: " + ex.Message); }
        }

        public static Version ParseVersion(string value) {
            if (!Regex.IsMatch(value ?? "", "^v?[0-9]+\\.[0-9]+\\.[0-9]+$")) throw new InvalidDataException("Invalid release version.");
            return Version.Parse(value.TrimStart('v'));
        }
        public static string AssetUrl(string tag, string name) {
            ParseVersion(tag);
            if (name != ExeName && name != "update.json") throw new InvalidDataException("Invalid release asset.");
            return "https://github.com/" + Repository + "/releases/download/" + tag + "/" + name;
        }
        public static void ValidateManifest(UpdateManifest manifest, string tag) {
            if (manifest == null || manifest.exe != ExeName || ParseVersion(manifest.version) != ParseVersion(tag) || !Regex.IsMatch(manifest.sha256 ?? "", "^[a-fA-F0-9]{64}$") || manifest.size < 1024 || manifest.size > 30 * 1024 * 1024) throw new InvalidDataException("Invalid update manifest.");
        }
        public static string Hash(string path) {
            using (var sha = SHA256.Create()) using (var input = File.OpenRead(path)) return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
        }
        public static void VerifyFile(string path, string hash, long size) {
            if (new FileInfo(path).Length != size || !string.Equals(Hash(path), hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Downloaded update failed SHA-256 verification.");
        }
        public static void AtomicJson(string path, object value) {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temporary = path + ".tmp";
            File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(value), new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
        }
        public static string Quote(string value) { return "\"" + value.Replace("\"", "") + "\""; }
        public static bool SamePath(string a, string b) { return string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); }
        public static void TryDelete(string path) { try { File.Delete(path); } catch (IOException) { } }
        public static void Log(string text) { lock (LogGate) { try { if (LogPath != null) File.AppendAllText(LogPath, DateTime.Now.ToString("o") + " " + text + Environment.NewLine); } catch { } } }
    }

    public sealed class UpdateAgent {
        readonly string data;
        readonly object gate = new object();
        PendingUpdate pending;
        public PendingUpdate Pending { get { lock (gate) return pending; } }
        public UpdateAgent(string directory) { data = directory; Status("idle", "启动后自动检查更新", Client.CurrentVersion); }
        void Status(string state, string message, string version) { Client.AtomicJson(Path.Combine(data, "client-status.json"), new { state, message, version, checkedAt = DateTime.UtcNow.ToString("o") }); }
        public void Check() {
            try {
                if (Pending != null) return;
                Status("checking", "正在检查客户端更新…", Client.CurrentVersion);
                var json = new JavaScriptSerializer();
                var release = json.Deserialize<ReleaseInfo>(Encoding.UTF8.GetString(Download("https://api.github.com/repos/" + Client.Repository + "/releases/latest", 1024 * 1024)));
                if (release.draft || release.prerelease || Client.ParseVersion(release.tag_name) <= Client.ParseVersion(Client.CurrentVersion)) { Status("current", "已是最新版本", Client.CurrentVersion); return; }
                foreach (string name in new[] { "update.json", Client.ExeName }) {
                    if (release.assets == null || !release.assets.Any(a => a.name == name && a.browser_download_url == Client.AssetUrl(release.tag_name, name))) throw new InvalidDataException("Release assets are incomplete.");
                }
                var manifest = json.Deserialize<UpdateManifest>(Encoding.UTF8.GetString(Download(Client.AssetUrl(release.tag_name, "update.json"), 65536)));
                Client.ValidateManifest(manifest, release.tag_name);
                Status("downloading", "正在后台下载 v" + manifest.version, manifest.version);
                string folder = Path.Combine(Path.GetDirectoryName(data), "updates");
                Directory.CreateDirectory(folder);
                string candidate = Path.Combine(folder, "CodexUsage-" + manifest.version + ".exe");
                string temporary = candidate + ".tmp";
                int lastPercent = -1;
                File.WriteAllBytes(temporary, Download(Client.AssetUrl(release.tag_name, Client.ExeName), 30 * 1024 * 1024, delegate(long received, long total) {
                    int percent = (int)Math.Min(100, received * 100 / Math.Max(1, manifest.size));
                    if (percent != lastPercent) { lastPercent = percent; Status("downloading", "正在下载 v" + manifest.version + " · " + percent + "%", manifest.version); }
                }));
                Client.VerifyFile(temporary, manifest.sha256, manifest.size);
                Version assemblyVersion = AssemblyName.GetAssemblyName(temporary).Version;
                if (assemblyVersion.ToString(3) != manifest.version) throw new InvalidDataException("Executable version does not match the manifest.");
                if (File.Exists(candidate)) File.Delete(candidate);
                File.Move(temporary, candidate);
                lock (gate) pending = new PendingUpdate { Path = candidate, Manifest = manifest };
                Status("ready", "新版 v" + manifest.version + " 已下载，重启即可更新", manifest.version);
            } catch (Exception ex) {
                Client.Log("Update check: " + ex.Message);
                Status("error", FailureMessage(ex) + " · 点击立即检查更新重试", Client.CurrentVersion);
            }
        }
        public static string FailureMessage(Exception ex) {
            if (ex is WebException) return "网络连接失败";
            if (ex is InvalidDataException || ex is BadImageFormatException) return "更新校验失败，已保留当前版本";
            if (ex is UnauthorizedAccessException) return "更新目录无写入权限";
            if (ex is IOException) return "更新文件写入失败，请检查磁盘空间";
            return "更新信息无效或服务暂不可用";
        }
        static byte[] Download(string url, int limit, Action<long, long> progress = null) {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.UserAgent = "CodexUsage/" + Client.CurrentVersion;
            request.Timeout = 20000;
            request.ReadWriteTimeout = 20000;
            request.Accept = "application/vnd.github+json, application/octet-stream";
            using (var response = (HttpWebResponse)request.GetResponse()) {
                string host = response.ResponseUri.Host;
                if (response.ResponseUri.Scheme != "https" || !(host == "api.github.com" || host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com")) throw new InvalidDataException("Unexpected update download host.");
                if (response.ContentLength > limit) throw new InvalidDataException("Update download is too large.");
                using (var input = response.GetResponseStream()) using (var output = new MemoryStream()) {
                    var buffer = new byte[32768]; int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) > 0) {
                        if (output.Length + read > limit) throw new InvalidDataException("Update download is too large.");
                        output.Write(buffer, 0, read);
                        if (progress != null) progress(output.Length, response.ContentLength);
                    }
                    return output.ToArray();
                }
            }
        }
    }
}
