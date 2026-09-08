using System.Diagnostics;
using System.IO;

namespace HerMemory
{
    /// <summary>exe 与托盘共用的 hermes 操作层。</summary>
    internal static class HermesCtl
    {
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
                CreateNoWindow = true,
            };
            psi.EnvironmentVariables["NO_COLOR"] = "1";
            return psi;
        }

        /// <summary>gateway 原始状态输出。注意停止时输出为 "✗ Gateway is not running"——包含 "running"。</summary>
        public static string RawStatus(int timeoutSec = 15)
        {
            try
            {
                using var p = Process.Start(HermsPsi("gateway status"))!;
                var so = p.StandardOutput.ReadToEnd();
                var se = p.StandardError.ReadToEnd();
                p.WaitForExit(timeoutSec * 1000);
                return so + se;
            }
            catch { return ""; }
        }

        /// <summary>状态二态：running / stopped。顺序关键：先判否定，"not running" 也包含 "running"；读取失败一律按停止。</summary>
        public static string State()
        {
            var lower = RawStatus().ToLowerInvariant();
            if (lower.Contains("not running") || lower.Contains("stopped")) return "stopped";
            if (lower.Contains("running")) return "running";
            return "stopped";
        }

        public static string Run(string args, int timeoutSec = 120)
        {
            try
            {
                using var p = Process.Start(HermsPsi(args))!;
                var so = p.StandardOutput.ReadToEnd();
                var se = p.StandardError.ReadToEnd();
                p.WaitForExit(timeoutSec * 1000);
                return so + se;
            }
            catch { return ""; }
        }

        /// <summary>任意命令捕获（卸载器用：schtasks 等）。</summary>
        public static string? RunCaptureRaw(string exe, string args, int timeoutSec)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = exe,
                    Arguments = args,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                };
                using var p = Process.Start(psi)!;
                var so = p.StandardOutput.ReadToEnd();
                var se = p.StandardError.ReadToEnd();
                p.WaitForExit(timeoutSec * 1000);
                return so + se;
            }
            catch { return null; }
        }

        public static bool EnvHasWeixin()
        {
            try
            {
                var env = Path.Combine(HermesHome, ".env");
                return File.Exists(env) && File.ReadAllLines(env)
                    .Any(l => l.StartsWith("WEIXIN_ACCOUNT_ID=", StringComparison.Ordinal));
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
                var keyEnv = "HERMES_CUSTOM_" +
                    new string(hostId.ToUpperInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray()).Trim('_') +
                    "_API_KEY";

                Run($"config set model.base_url {baseUrl}", 30);
                Run($"config set {keyEnv} {apiKey}", 30);
                Run("config set model.provider custom", 30);
                Run("config set model.api_key ${{{keyEnv}}}", 30);
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
