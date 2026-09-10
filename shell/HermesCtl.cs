using System.Diagnostics;
using System.IO;

namespace HerMemory
{
    /// <summary>exe 与托盘共用的 hermes 操作层。</summary>
    internal static class HermesCtl
    {
        // hermes CLI 并发调用会争用配置存储（并发读取偶发空输出 → 配置回显缺失、状态误判）。
        // 工程纪律：全进程串行调用。
        private static readonly object _sync = new object();

        /// <summary>统一的进程执行：stdout/stderr 并发读取（避免单侧缓冲满导致死锁）+ 超时强杀。</summary>
        private static string RunPsi(ProcessStartInfo psi, int timeoutSec)
        {
            lock (_sync)
            {
                try
                {
                    using var p = Process.Start(psi)!;
                    // CreateNoWindow 下子进程会拿到"无窗口但真实存在"的控制台，stdin 是有效输入缓冲区——
                    // 上游任何 input() 都会永久阻塞（2026-09-10 gateway install 死锁实录）。
                    // 关闭 stdin 写端 → 子进程立刻 EOF → prompt 走其默认值，不再挂死。
                    try { p.StandardInput.Close(); } catch { }
                    var so = p.StandardOutput.ReadToEndAsync();
                    var se = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutSec * 1000))
                    {
                        try { p.Kill(true); } catch { }
                    }
                    try { Task.WaitAll(new Task[] { so, se }, 5000); } catch { }
                    return (so.Result ?? "") + (se.Result ?? "");
                }
                catch { return ""; }
            }
        }

        public static string HermesHome => Environment.GetEnvironmentVariable("HERMES_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes");

        public static string HermsExe
        {
            get
            {
                var p = Path.Combine(HermesHome, "bin", "hermes.exe");
                return File.Exists(p) ? p : "hermes";
            }
        }

        public static string LogsDir => Path.Combine(HermesHome, "logs");

        public static bool Installed =>
            File.Exists(Path.Combine(HermesHome, "bin", "hermes.exe"));

        /// <summary>统一构造 hermes 进程：NO_COLOR 关颜色码（URL 提取与关键词答题都依赖干净输出）。</summary>
        private static ProcessStartInfo HermsPsi(string args)
        {
            var psi = new ProcessStartInfo
            {
                FileName = HermsExe,
                Arguments = args,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true,
            };
            psi.EnvironmentVariables["NO_COLOR"] = "1";
            // 非交互标记：上游 is_noninteractive()（hermes_cli/setup.py）只认这个变量，**不检查 stdin**。
            // 不设它时 `gateway install` 等子命令会走 input() 等输入——GUI 进程无控制台 → 永久阻塞。
            // 置 1 后 prompt_yes_no 直接返回其默认值，子命令正常执行完。hermes 全部调用统一带上。
            psi.EnvironmentVariables["HERMES_NONINTERACTIVE"] = "1";
            return psi;
        }

        /// <summary>gateway 原始状态输出。注意停止时输出为 "✗ Gateway is not running"——包含 "running"。</summary>
        public static string RawStatus(int timeoutSec = 15) => RunPsi(HermsPsi("gateway status"), timeoutSec);

        /// <summary>状态二态：running / stopped。顺序关键：先判否定，"not running" 也包含 "running"；读取失败一律按停止。</summary>
        public static string State()
        {
            var lower = RawStatus().ToLowerInvariant();
            if (lower.Contains("not running") || lower.Contains("stopped")) return "stopped";
            if (lower.Contains("running")) return "running";
            return "stopped";
        }

        public static string Run(string args, int timeoutSec = 120) => RunPsi(HermsPsi(args), timeoutSec);

        /// <summary>任意命令捕获（卸载器用：schtasks 等）。</summary>
        public static string? RunCaptureRaw(string exe, string args, int timeoutSec)
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = args,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true,
            };
            var s = RunPsi(psi, timeoutSec);
            return string.IsNullOrEmpty(s) ? null : s;
        }

        public static bool EnvHasWeixin()
        {
            try
            {
                var env = Path.Combine(HermesHome, ".env");
                return File.Exists(env) && File.ReadAllLines(env)
                    .Any(l => l.StartsWith("WEIXIN_ACCOUNT_ID=", StringComparison.Ordinal)
                              && l.Length > "WEIXIN_ACCOUNT_ID=".Length);
            }
            catch { return false; }
        }

        // —— 模型接口配置（对齐 install.ps1 的 custom provider 机制） ——
        public static (string baseUrl, string keyEnv, string keyValue) GetModelCfg()
        {
            var baseUrl = Clean(Run("config get model.base_url", 20));
            var apiRef = Clean(Run("config get model.api_key", 20));   // 形如 ${HERMES_CUSTOM_X_API_KEY}
            var m = System.Text.RegularExpressions.Regex.Match(apiRef, @"\$\{([A-Z0-9_]+)\}");
            var keyEnv = m.Success ? m.Groups[1].Value : "";
            var keyValue = "";
            if (keyEnv.Length > 0)
            {
                var env = Path.Combine(HermesHome, ".env");
                if (File.Exists(env))
                    keyValue = File.ReadAllLines(env)
                        .Where(l => l.StartsWith(keyEnv + "=", StringComparison.Ordinal))
                        .Select(l => l[(keyEnv.Length + 1)..])
                        .FirstOrDefault() ?? "";
            }
            return (baseUrl, keyEnv, keyValue);
        }

        private static string Clean(string s)
        {
            s = new string(s.Where(c => c >= 0x21 && c <= 0x7E).ToArray());
            return s.Trim().Trim('"').Trim();
        }

        /// <summary>写入 BaseURL/Key（须在 Gateway 停止时调用）。与 install.ps1 同构：key 进 .env 的 HERMES_CUSTOM_*，config 引用之。</summary>
        public static bool SetModelCfg(string baseUrl, string apiKey)
        {
            try
            {
                baseUrl = new string(baseUrl.Where(c => c >= 0x21 && c <= 0x7E).ToArray()).TrimEnd('/');
                apiKey = new string(apiKey.Where(c => c >= 0x21 && c <= 0x7E).ToArray());
                if (baseUrl.Length == 0 || apiKey.Length == 0) return false;

                var u = new Uri(baseUrl);
                var hostId = u.Host;
                if (u.Port > 0) hostId += "_" + u.Port;
                // 与 install.ps1 同构命名：非 [A-Z0-9] 连续段折叠为单个下划线（防止两侧产生不同 env 名）
                var keyEnv = "HERMES_CUSTOM_" +
                    System.Text.RegularExpressions.Regex.Replace(hostId.ToUpperInvariant(), @"[^A-Z0-9]+", "_").Trim('_') +
                    "_API_KEY";

                Run($"config set model.base_url {baseUrl}", 30);
                Run($"config set {keyEnv} {apiKey}", 30);
                Run("config set model.provider custom", 30);
                Run($"config set model.api_key ${{{keyEnv}}}", 30);   // 注意 $ 前缀：必须插值出真实 env 名（曾是漏 $ 的字面量事故：${{keyEnv}} 写进 yaml → 网关 401）
                Run("config set model.api_mode chat_completions", 30);

                // .env：写入新键、清除其他 HERMES_CUSTOM_* 旧键
                var env = Path.Combine(HermesHome, ".env");
                var lines = File.Exists(env) ? File.ReadAllLines(env).ToList() : new List<string>();
                lines = lines.Where(l => !l.StartsWith("HERMES_CUSTOM_", StringComparison.Ordinal)).ToList();
                lines.Add($"{keyEnv}={apiKey}");
                File.WriteAllLines(env, lines, new System.Text.UTF8Encoding(false));
                return true;
            }
            catch { return false; }
        }

        // —— 同步服务（WebDAV）：只展示，不启停（启停由用户与 AI 对话完成） ——
        public static bool WebDavRunning()
        {
            try { return Process.GetProcessesByName("rclone").Length > 0; }
            catch { return false; }
        }

        // —— 关闭行为记忆：HKCU\Software\HerMemory\CloseAction（"tray" = 点 X 直接最小化不再询问；缺省 = 每次询问） ——
        public static bool CloseMinimizeEnabled()
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\HerMemory");
            return k?.GetValue("CloseAction") as string == "tray";
        }

        public static void SetCloseMinimize(bool enabled)
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\HerMemory");
            if (enabled) k.SetValue("CloseAction", "tray");
            else k.DeleteValue("CloseAction", false);
        }
    }
}
