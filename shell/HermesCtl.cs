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

        /// <summary>状态三分类。顺序关键：先判否定，"not running" 也包含 "running"。</summary>
        public static string State()
        {
            var lower = RawStatus().ToLowerInvariant();
            if (lower.Contains("not running") || lower.Contains("stopped")) return "stopped";
            if (lower.Contains("running")) return "running";
            return "unknown";
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
