using System;
using System.IO;
using System.Diagnostics;
using System.Text;
using System.Web.Script.Serialization;

namespace CodexUsageDesktop {
    public static class SelfTest {
        static int checks;
        static void Check(bool condition, string text) { if (!condition) throw new Exception(text); checks++; }
        static void Reject(Action action, string text) { bool rejected = false; try { action(); } catch { rejected = true; } Check(rejected, text); }
        static object Normalize(object value) { return new JavaScriptSerializer().DeserializeObject(new JavaScriptSerializer().Serialize(value)); }
        static void CheckParallelReader(string root) {
            string config = Path.Combine(root, "parallel-profiles.json");
            File.WriteAllText(config, "{\"profiles\":[{\"id\":\"personal\",\"label\":\"Personal\"},{\"id\":\"work\",\"label\":\"Work\"},{\"id\":\"disabled\",\"enabled\":false}]}");
            using (var started = new System.Threading.CountdownEvent(2))
            using (var releaseSlow = new System.Threading.ManualResetEventSlim(false)) {
                bool fastPublished = false;
                int reads = 0, publications = 0;
                object result = UsageReader.ReadProfilesWithReader(config, profile => {
                    System.Threading.Interlocked.Increment(ref reads);
                    started.Signal();
                    if (!started.Wait(5000)) throw new Exception("Profiles were read serially.");
                    if (UsageReader.Text(UsageReader.Get(profile, "id")) == "personal" && !releaseSlow.Wait(5000))
                        throw new TimeoutException("Fast profile did not publish independently.");
                    return new { id = UsageReader.Text(UsageReader.Get(profile, "id")), ok = true, fetchedAt = DateTimeOffset.UtcNow.ToString("o") };
                }, (snapshot, pending) => {
                    publications++;
                    var profiles = (object[])UsageReader.Get(Normalize(snapshot), "profiles");
                    if (pending && UsageReader.Get(profiles[1], "ok") is bool && (bool)UsageReader.Get(profiles[1], "ok")) {
                        fastPublished = (bool)UsageReader.Get(profiles[0], "pending");
                        releaseSlow.Set();
                    }
                });
                var finalProfiles = (object[])UsageReader.Get(Normalize(result), "profiles");
                Check(reads == 2, "Disabled profiles do not launch readers");
                Check(fastPublished, "Fast account is published before a blocked account finishes");
                Check(publications == 3, "Initial and two completed profile snapshots are published");
                Check((bool)UsageReader.Get(finalProfiles[0], "ok") && (bool)UsageReader.Get(finalProfiles[1], "ok"), "Independent reads complete successfully");
                Check(UsageReader.Text(UsageReader.Get(finalProfiles[0], "id")) == "personal" && UsageReader.Text(UsageReader.Get(finalProfiles[1], "id")) == "work", "Parallel completion preserves configuration order");
            }
            object failures = UsageReader.ReadProfilesWithReader(config, profile => {
                if (UsageReader.Text(UsageReader.Get(profile, "id")) == "personal") throw new TimeoutException("Fixture timeout");
                return new { id = "work", ok = true, fetchedAt = DateTimeOffset.UtcNow.ToString("o") };
            }, null);
            var failedProfiles = (object[])UsageReader.Get(Normalize(failures), "profiles");
            Check(!(bool)UsageReader.Get(failedProfiles[0], "ok") && (bool)UsageReader.Get(failedProfiles[1], "ok"), "One account timeout does not fail another account");
            File.WriteAllText(config, "{\"profiles\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"},{\"id\":\"d\"}]}");
            int active = 0, maximum = 0, completed = 0;
            UsageReader.ReadProfilesWithReader(config, profile => {
                int now = System.Threading.Interlocked.Increment(ref active);
                int previous;
                do { previous = maximum; if (previous >= now) break; } while (System.Threading.Interlocked.CompareExchange(ref maximum, now, previous) != previous);
                try { System.Threading.Thread.Sleep(30); return new { id = UsageReader.Text(UsageReader.Get(profile, "id")), ok = true }; }
                finally { System.Threading.Interlocked.Decrement(ref active); System.Threading.Interlocked.Increment(ref completed); }
            }, null);
            Check(maximum <= 2 && completed == 4, "Account concurrency is bounded to two readers");
        }
        static void CheckNativePipeline(string root) {
            string fixtureRoot = Path.Combine(root, "native-reader-fixture");
            Directory.CreateDirectory(fixtureRoot);
            File.WriteAllText(Path.Combine(fixtureRoot, "codex.cmd"), "@echo off\r\n\"%CODEX_USAGE_FIXTURE_EXE%\" --rpc-fixture\r\n", Encoding.ASCII);
            File.WriteAllText(Path.Combine(fixtureRoot, "profiles.json"), "{\"profiles\":[{\"id\":\"personal\",\"label\":\"Personal\",\"codexHome\":\"~/fixture-personal\"},{\"id\":\"work\",\"label\":\"Work\",\"codexHome\":\"~/fixture-work\"}]}");
            string[] names = { "PATH", "CODEX_USAGE_DATA_DIR", "CODEX_USAGE_READ_ID", "CODEX_USAGE_FIXTURE_EXE" };
            var previous = new string[names.Length];
            for (int i = 0; i < names.Length; i++) previous[i] = Environment.GetEnvironmentVariable(names[i]);
            try {
                Environment.SetEnvironmentVariable("PATH", fixtureRoot + Path.PathSeparator + previous[0]);
                Environment.SetEnvironmentVariable("CODEX_USAGE_DATA_DIR", fixtureRoot);
                Environment.SetEnvironmentVariable("CODEX_USAGE_READ_ID", "fixture-native-read");
                Environment.SetEnvironmentVariable("CODEX_USAGE_FIXTURE_EXE", Client.Self);
                string output = Path.Combine(fixtureRoot, "result.json");
                Check(UsageReader.Run(output) == 0, "Native reader completes both real fixture RPC processes");
                object payload = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(output));
                Check(UsageReader.Text(UsageReader.Get(payload, "readId")) == "fixture-native-read", "Native pipeline preserves request identity");
                Check(!(bool)UsageReader.Get(payload, "pending") && UsageReader.Number(UsageReader.Get(payload, "revision")) == 3, "Native pipeline atomically publishes the final completion revision");
                var profiles = (object[])UsageReader.Get(UsageReader.Get(payload, "data"), "profiles");
                Check(profiles.Length == 2 && (bool)UsageReader.Get(profiles[0], "ok") && (bool)UsageReader.Get(profiles[1], "ok"), "Both accounts survive process launch, RPC and result conversion");
            } finally { for (int i = 0; i < names.Length; i++) Environment.SetEnvironmentVariable(names[i], previous[i]); }
        }
        public static int RpcFixture() {
            string line;
            while ((line = Console.ReadLine()) != null) {
                var request = new JavaScriptSerializer().DeserializeObject(line);
                string id = UsageReader.Text(UsageReader.Get(request, "id"));
                if (id == "1") Console.WriteLine("{\"id\":\"1\",\"result\":{}}");
                if (id == "2") {
                    Console.WriteLine("{\"method\":\"notification\",\"params\":{}}");
                    Console.WriteLine("{\"id\":\"2\",\"result\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":100,\"resetsAt\":2000000000},\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":20}}}}");
                }
            }
            return 0;
        }
        public static int Run(string root) {
            Directory.CreateDirectory(root);
            string report = Path.Combine(root, "client-test.txt");
            try {
                Check(Client.ParseVersion("v0.5.0") > Client.ParseVersion("0.4.2"), "New release comparison");
                Check(Client.ParseVersion("0.5.0") == Client.ParseVersion("v0.5.0"), "Equal release comparison");
                Reject(() => Client.ParseVersion("v0.5.0-beta"), "Prerelease must not enter stable channel");
                Reject(() => Client.ParseVersion("../../malicious"), "Version traversal rejected");
                Reject(() => Client.AssetUrl("v0.5.0", "evil.exe"), "Foreign asset rejected");
                Reject(() => Client.SafeEntryPath(root, "../outside.ps1"), "Zip traversal rejected");
                Reject(() => Client.SafeEntryPath(root, "C:\\outside.ps1"), "Absolute payload path rejected");
                Reject(() => Client.SafeEntryPath(root, "file:stream"), "Alternate data stream rejected");
                using (var installer = Distribution.CreateInstallForm()) {
                    installer.Show();
                    System.Windows.Forms.Application.DoEvents();
                    Check(installer.AcceptButton != null && installer.CancelButton != null, "Installer offers explicit installation and cancellation");
                    using (var bitmap = new System.Drawing.Bitmap(installer.Width, installer.Height)) {
                        installer.DrawToBitmap(bitmap, new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height));
                        bitmap.Save(Path.Combine(root, "installer.png"));
                    }
                    installer.Close();
                }
                var fixtureInfo = UsageReader.ServerInfo(Client.Self, root);
                fixtureInfo.Arguments = "--rpc-fixture";
                var fixture = UsageReader.ReadRpc(fixtureInfo);
                var fixtureProfile = new JavaScriptSerializer().DeserializeObject("{\"id\":\"personal\",\"label\":\"Test\",\"codexHome\":\"~/fixture\"}");
                var converted = new JavaScriptSerializer().DeserializeObject(new JavaScriptSerializer().Serialize(UsageReader.ConvertResult(fixtureProfile, fixture)));
                Check(UsageReader.Number(UsageReader.Get(UsageReader.Get(converted, "fiveHour"), "remainingPercent")) == 0, "Native RPC exhausted quota survives conversion");
                Check(UsageReader.Number(UsageReader.Get(UsageReader.Get(converted, "weekly"), "remainingPercent")) == 80, "Native reader preserves independent weekly quota");
                Check(UsageReader.Iso(null) == null && UsageReader.Iso(-1) == null, "Missing reset is never invented");
                Check(UsageReader.Number("NaN") == null, "Invalid numeric quota rejected");
                var missing = UsageReader.Window(new System.Collections.Generic.Dictionary<string, object>(), 0);
                Check(UsageReader.Get(missing, "remainingPercent") == null, "Missing native quota is not zero");
                var mapFixture = new JavaScriptSerializer().DeserializeObject("{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":25}}}}");
                var mapped = new JavaScriptSerializer().DeserializeObject(new JavaScriptSerializer().Serialize(UsageReader.ConvertResult(fixtureProfile, mapFixture)));
                Check(UsageReader.Number(UsageReader.Get(UsageReader.Get(mapped, "fiveHour"), "remainingPercent")) == 75, "Native reader accepts mapped snapshots");
                CheckParallelReader(root);
                CheckNativePipeline(root);
                string previousData = Environment.GetEnvironmentVariable("CODEX_USAGE_DATA_DIR");
                string previousRead = Environment.GetEnvironmentVariable("CODEX_USAGE_READ_ID");
                try {
                    Environment.SetEnvironmentVariable("CODEX_USAGE_DATA_DIR", null);
                    Environment.SetEnvironmentVariable("CODEX_USAGE_READ_ID", "fixture-error-read");
                    string errorOutput = Path.Combine(root, "reader-error.json");
                    Check(UsageReader.Run(errorOutput) == 1, "Reader initialization failure returns an error");
                    object errorPayload = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(errorOutput));
                    Check(UsageReader.Text(UsageReader.Get(errorPayload, "readId")) == "fixture-error-read", "Reader failures retain the request identity");
                } finally {
                    Environment.SetEnvironmentVariable("CODEX_USAGE_DATA_DIR", previousData);
                    Environment.SetEnvironmentVariable("CODEX_USAGE_READ_ID", previousRead);
                }
                Check(UpdateAgent.FailureMessage(new System.Net.WebException()).Contains("网络"), "Network update error is actionable");
                Check(UpdateAgent.FailureMessage(new InvalidDataException()).Contains("校验"), "Verification failure distinguished from network");
                Check(UpdateAgent.FailureMessage(new UnauthorizedAccessException()).Contains("权限"), "Write permission failure distinguished");
                string hash = Client.Hash(Client.Self);
                long size = new FileInfo(Client.Self).Length;
                var manifest = new UpdateManifest { version = Client.CurrentVersion, exe = Client.ExeName, sha256 = hash, size = size };
                Client.ValidateManifest(manifest, "v" + Client.CurrentVersion);
                checks++;
                manifest.version = "99.0.0";
                Reject(() => Client.ValidateManifest(manifest, "v" + Client.CurrentVersion), "Manifest/tag mismatch rejected");
                manifest.version = Client.CurrentVersion;
                manifest.sha256 = "bad";
                Reject(() => Client.ValidateManifest(manifest, "v" + Client.CurrentVersion), "Invalid digest rejected");
                Reject(() => Client.VerifyFile(Client.Self, new string('0', 64), size), "Tampered update rejected");
                Reject(() => Client.VerifyFile(Client.Self, hash, size + 1), "Partial update rejected");
                string target = Path.Combine(root, "installed.exe");
                File.WriteAllText(target, "previous-version");
                Reject(() => Client.InstallCandidate(Client.Self, target, new string('0', 64), size), "Invalid update cannot replace installed client");
                Check(File.ReadAllText(target) == "previous-version", "Failed verification retains original");
                Client.InstallCandidate(Client.Self, target, hash, size);
                Check(Client.Hash(target) == hash, "Atomic installation uses verified bytes");
                Check(File.ReadAllText(target + ".bak") == "previous-version", "Rollback copy is preserved");
                // Exercise a second replacement with an existing backup as real updates do.
                Client.InstallCandidate(Client.Self, target, hash, size);
                Check(Client.Hash(target + ".bak") == hash, "Subsequent replacement rotates backup");
                string payload = Client.ExtractPayload(root);
                Check(File.Exists(Path.Combine(payload, "tray.ps1")), "Embedded UI extracted");
                Check(File.Exists(Path.Combine(payload, "CodexUsage.Controls.dll")), "Precompiled UI controls packaged");
                Check(!File.Exists(Path.Combine(payload, "ui-controls.cs")), "Packaged UI requires no runtime source compilation");
                string uninstallRoot = Path.Combine(root, "uninstall-fixture");
                Directory.CreateDirectory(Path.Combine(uninstallRoot, "data"));
                Directory.CreateDirectory(Path.Combine(uninstallRoot, "app"));
                Directory.CreateDirectory(Path.Combine(uninstallRoot, "updates"));
                File.WriteAllText(Path.Combine(uninstallRoot, "data", "ui-settings.json"), "keep-settings");
                File.WriteAllText(Path.Combine(uninstallRoot, "unrelated.txt"), "keep-user-file");
                File.WriteAllText(Path.Combine(uninstallRoot, Client.ExeName), "old-executable");
                File.WriteAllText(Path.Combine(uninstallRoot, Client.ExeName + ".bak"), "old-backup");
                Distribution.RemoveProgramFiles(uninstallRoot);
                Check(!Directory.Exists(Path.Combine(uninstallRoot, "app")) && !Directory.Exists(Path.Combine(uninstallRoot, "updates")), "Uninstall removes versioned program and updates");
                Check(!File.Exists(Path.Combine(uninstallRoot, Client.ExeName)) && !File.Exists(Path.Combine(uninstallRoot, Client.ExeName + ".bak")), "Uninstall removes executable and backup");
                Check(File.ReadAllText(Path.Combine(uninstallRoot, "data", "ui-settings.json")) == "keep-settings", "Uninstall preserves preferences");
                Check(File.ReadAllText(Path.Combine(uninstallRoot, "unrelated.txt")) == "keep-user-file", "Uninstall preserves unrelated files");
                Distribution.RemoveProgramFiles(uninstallRoot);
                checks++; // Repeated cleanup is safe.
                Check(File.Exists(Path.Combine(payload, "assets", "app.ico")), "Embedded application icon extracted");
                Check(!File.Exists(Path.Combine(payload, "auth.json")), "No account credentials packaged");
                Check(Client.ExtractPayload(root) == payload, "Extraction is idempotent");
                string legacy = Path.Combine(root, "legacy"); Directory.CreateDirectory(legacy);
                File.WriteAllText(Path.Combine(legacy, "ui-settings.json"), "{\"compactOpacity\":55}");
                string data = Path.Combine(root, "data");
                Client.PrepareData(data, payload, legacy);
                Check(File.ReadAllText(Path.Combine(data, "ui-settings.json")).Contains("55"), "Legacy UI settings migrate");
                Check(File.Exists(Path.Combine(data, "profiles.json")), "Account configuration is initialized");
                File.WriteAllText(Path.Combine(legacy, "ui-settings.json"), "{\"compactOpacity\":25}");
                Client.PrepareData(data, payload, legacy);
                Check(File.ReadAllText(Path.Combine(data, "ui-settings.json")).Contains("55"), "Updates preserve user preferences");
                string status = Path.Combine(data, "client-status.json");
                Client.AtomicJson(status, new { state = "checking" });
                Client.AtomicJson(status, new { state = "ready" });
                Check(File.ReadAllText(status).Contains("ready"), "Status file replacement is atomic");
                using (var ui = Client.StartUi(payload, data, "fixture", true)) {
                    if (!ui.WaitForExit(90000)) { ui.Kill(); throw new Exception("Packaged UI smoke test timed out."); }
                    Check(ui.ExitCode == 0, "Packaged UI passes native smoke test; see data/logs/tray.log");
                }
                File.WriteAllText(report, "PASS: " + checks + " client checks and packaged native UI smoke test." + Environment.NewLine, Encoding.UTF8);
                return 0;
            } catch (Exception ex) { File.WriteAllText(report, ex.ToString(), Encoding.UTF8); return 1; }
        }
    }
}
