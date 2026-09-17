using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace CodexUsageDesktop {
    public static class UsageReader {
        public static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static object Get(object value, string name) { object result; return Map(value).TryGetValue(name, out result) ? result : null; }
        public static string Text(object value) { return value == null ? "" : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture); }
        public static double? Number(object value) {
            if (value == null) return null;
            double result;
            return double.TryParse(Text(value), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out result) && !double.IsNaN(result) && !double.IsInfinity(result) ? (double?)result : null;
        }
        public static string Home(string path) {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return path == "~" ? root : path.StartsWith("~/") || path.StartsWith(@"~\") ? Path.Combine(root, path.Substring(2)) : Path.GetFullPath(path);
        }
        public static string FindCli() {
            var paths = new List<string>();
            foreach (string folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)) {
                if (string.IsNullOrWhiteSpace(folder)) continue;
                foreach (string name in new[] { "codex.exe", "codex.cmd" }) paths.Add(Path.Combine(folder.Trim('"'), name));
            }
            string user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            paths.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\OpenAI\Codex\bin\codex.exe"));
            paths.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"npm\codex.cmd"));
            paths.Add(Path.Combine(user, @".codex\packages\standalone\current\bin\codex.exe"));
            paths.Add(Path.Combine(user, @".codex\packages\standalone\current\codex.exe"));
            foreach (string candidate in paths) if (File.Exists(candidate)) return candidate;
            foreach (string root in new[] { Path.Combine(user, @".vscode\extensions"), Path.Combine(user, @".cursor\extensions") }) {
                if (!Directory.Exists(root)) continue;
                try {
                    foreach (var folder in new DirectoryInfo(root).GetDirectories("openai.*").OrderByDescending(d => d.LastWriteTimeUtc)) {
                        if (!folder.Name.StartsWith("openai.chatgpt-") && !folder.Name.StartsWith("openai.codex-")) continue;
                        string bin = Path.Combine(folder.FullName, "bin");
                        if (Directory.Exists(bin)) {
                            string match = Directory.GetFiles(bin, "codex.exe", SearchOption.AllDirectories).FirstOrDefault();
                            if (match != null) return match;
                        }
                    }
                } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            return null;
        }
        public static ProcessStartInfo ServerInfo(string cli, string home) {
            bool script = Path.GetExtension(cli).Equals(".cmd", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(cli).Equals(".bat", StringComparison.OrdinalIgnoreCase);
            var info = new ProcessStartInfo(script ? Environment.GetEnvironmentVariable("ComSpec") : cli);
            if (script && (cli.Contains("%") || cli.Contains("\""))) throw new InvalidDataException("Codex CLI 路径包含不支持的字符。");
            info.Arguments = script ? "/d /s /c \"\"" + cli + "\" app-server --listen stdio://\"" : "app-server --listen stdio://";
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardInput = info.RedirectStandardOutput = info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
            info.EnvironmentVariables["CODEX_HOME"] = home;
            info.EnvironmentVariables["CODEX_NON_INTERACTIVE"] = "1";
            return info;
        }
        static void Send(Process process, object value) {
            process.StandardInput.WriteLine(new JavaScriptSerializer().Serialize(value)); process.StandardInput.Flush();
        }
        public static object Response(Process process, string id, int timeout) {
            var clock = Stopwatch.StartNew();
            var serializer = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 };
            while (clock.ElapsedMilliseconds < timeout) {
                var line = process.StandardOutput.ReadLineAsync();
                if (!line.Wait(Math.Max(1, timeout - (int)clock.ElapsedMilliseconds))) throw new TimeoutException("额度读取超时，请重试。");
                if (line.Result == null) throw new IOException("Codex 连接已关闭，请检查 CLI 和账号登录状态。");
                if (line.Result.Length > 1024 * 1024) throw new InvalidDataException("Codex 响应过大。");
                object message;
                try { message = serializer.DeserializeObject(line.Result); } catch (ArgumentException) { continue; }
                if (Text(Get(message, "id")) != id) continue;
                if (Get(message, "error") != null) throw new InvalidOperationException("Codex 未能读取额度，请重新登录或稍后重试。");
                return Get(message, "result");
            }
            throw new TimeoutException("额度读取超时，请重试。");
        }
        public static object ReadRpc(ProcessStartInfo info) {
            using (var process = new Process { StartInfo = info })
            using (var job = new ProcessJob()) {
                try {
                    if (!process.Start()) throw new IOException("无法启动 Codex。");
                    job.Attach(process);
                    // Drain stderr continuously without logging potentially private service output.
                    process.ErrorDataReceived += (s, e) => { };
                    process.BeginErrorReadLine();
                    Send(process, new { method = "initialize", id = "1", @params = new { clientInfo = new { name = "codex-dual-usage-dashboard", version = Client.CurrentVersion }, capabilities = new { experimentalApi = true } } });
                    Response(process, "1", 15000);
                    Send(process, new { method = "initialized" });
                    Send(process, new { method = "account/rateLimits/read", id = "2", @params = (object)null });
                    return Response(process, "2", 20000);
                } finally {
                    try { process.StandardInput.Close(); } catch { }
                    try { if (!process.HasExited) process.Kill(); } catch { }
                }
            }
        }
        public static string Iso(object value) {
            var seconds = Number(value);
            if (!seconds.HasValue || seconds <= 0) return null;
            try { return DateTimeOffset.FromUnixTimeSeconds((long)seconds.Value).ToString("o"); } catch (ArgumentOutOfRangeException) { return null; }
        }
        public static Dictionary<string, object> Window(object raw, int index) {
            if (raw == null) return null;
            double? minutes = Number(Get(raw, "windowDurationMins"));
            double? used = Number(Get(raw, "usedPercent"));
            if (used.HasValue) used = Math.Max(0, Math.Min(100, used.Value));
            string kind = "window-" + (index + 1), label = "额度窗口 " + (index + 1);
            if (minutes.HasValue && minutes > 0) {
                if (minutes <= 360) { kind = "5h"; label = "5 小时"; }
                else if (minutes >= 10000) { kind = "weekly"; label = "Weekly"; }
                else if (minutes >= 1440) { kind = "multi-day"; label = Math.Round(minutes.Value / 1440) + " 天"; }
            }
            return new Dictionary<string, object> { { "kind", kind }, { "label", label }, { "usedPercent", used }, { "remainingPercent", used.HasValue ? (double?)(100 - used.Value) : null }, { "windowMinutes", minutes }, { "resetsAt", Iso(Get(raw, "resetsAt")) } };
        }
        public static object ConvertResult(object profile, object result) {
            object snapshot = Get(result, "rateLimits");
            if (snapshot == null) { var map = Map(Get(result, "rateLimitsByLimitId")); snapshot = Get(map, "codex") ?? map.Values.FirstOrDefault(v => v != null); }
            if (snapshot == null) throw new InvalidDataException("Codex 未提供额度信息。");
            var windows = new[] { Window(Get(snapshot, "primary"), 0), Window(Get(snapshot, "secondary"), 1) }.Where(w => w != null).ToArray();
            object rawLimit = Get(snapshot, "individualLimit"), individual = null;
            if (rawLimit != null) {
                double? remaining = Number(Get(rawLimit, "remainingPercent"));
                individual = new { limit = Get(rawLimit, "limit"), used = Get(rawLimit, "used"), remainingPercent = remaining.HasValue ? (double?)Math.Max(0, Math.Min(100, remaining.Value)) : null, resetsAt = Iso(Get(rawLimit, "resetsAt")) };
            }
            return new { id = Text(Get(profile, "id")), label = Text(Get(profile, "label")), codexHome = Text(Get(profile, "codexHome")), ok = true, fetchedAt = DateTimeOffset.UtcNow.ToString("o"), planType = Text(Get(snapshot, "planType")), accountId = Get(result, "accountId"), ordinaryUsageAllowed = Get(result, "ordinaryUsageAllowed"), individualLimit = individual, fiveHour = windows.FirstOrDefault(w => Text(Get(w, "kind")) == "5h"), weekly = windows.FirstOrDefault(w => Text(Get(w, "kind")) == "weekly"), windows };
        }
        public static object ReadProfiles(string config, string cli) {
            var parsed = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(config, Encoding.UTF8));
            var profiles = Get(parsed, "profiles") as IEnumerable;
            if (profiles == null) throw new InvalidDataException("账号配置无效。");
            var results = new List<object>();
            foreach (object profile in profiles) {
                if (Get(profile, "enabled") is bool && !(bool)Get(profile, "enabled")) continue;
                try { results.Add(ConvertResult(profile, ReadRpc(ServerInfo(cli, Home(Text(Get(profile, "codexHome"))))))); }
                catch (Exception ex) { results.Add(new { id = Text(Get(profile, "id")), label = Text(Get(profile, "label")), ok = false, fetchedAt = DateTimeOffset.UtcNow.ToString("o"), error = ex.Message }); }
            }
            return new { profiles = results, fetchedAt = DateTimeOffset.UtcNow.ToString("o") };
        }
        public static int Run(string output) {
            try {
                string data = Environment.GetEnvironmentVariable("CODEX_USAGE_DATA_DIR");
                if (string.IsNullOrWhiteSpace(data)) throw new InvalidOperationException("客户端数据目录未配置。");
                string cli = FindCli();
                if (cli == null) throw new FileNotFoundException("未找到 Codex CLI，请打开“账号与首次使用”安装。");
                Client.AtomicJson(output, new { ok = true, data = ReadProfiles(Path.Combine(data, "profiles.json"), cli) });
                return 0;
            } catch (Exception ex) { Client.AtomicJson(output, new { ok = false, error = ex.Message }); return 1; }
        }
    }
    // Killing the reader also closes this job, terminating cmd wrappers and server children.
    public sealed class ProcessJob : IDisposable {
        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr info, uint length);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct Basic { public long ProcessTime, JobTime; public uint Flags; public UIntPtr Min, Max; public uint Active; public UIntPtr Affinity; public uint Priority, Scheduling; }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct Extended { public Basic Basic; public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob; }
        IntPtr handle;
        public ProcessJob() {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new IOException("无法创建后台进程容器。");
            var info = new Extended(); info.Basic.Flags = 0x2000;
            int size = System.Runtime.InteropServices.Marshal.SizeOf(info);
            IntPtr pointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(size);
            try {
                System.Runtime.InteropServices.Marshal.StructureToPtr(info, pointer, false);
                if (!SetInformationJobObject(handle, 9, pointer, (uint)size)) { Dispose(); throw new IOException("无法配置后台进程容器。"); }
            } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(pointer); }
        }
        public void Attach(Process process) { if (!AssignProcessToJobObject(handle, process.Handle)) throw new IOException("无法管理 Codex 后台进程，请检查系统策略。"); }
        public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
    }
}
