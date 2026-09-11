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
                    // **绝不能在这里直接取 .Result**：若上面 Kill 失败（进程卡在不可中断状态），
                    // 读取任务永不完成，访问 .Result 会无限阻塞——那个超时就形同虚设，
                    // 且本方法持有 _sync 全局锁，会把整个进程的所有 hermes 调用一起拖死。
                    // 故等一小会儿后只取**已完成**的读取任务，未完成的丢弃（返回部分输出好过挂死）。
                    try { Task.WaitAll(new Task[] { so, se }, 5000); } catch { }
                    var sb = new System.Text.StringBuilder();
                    if (so.IsCompletedSuccessfully) sb.Append(so.Result);
                    if (se.IsCompletedSuccessfully) sb.Append(se.Result);
                    return sb.ToString();
                }
                catch { return ""; }
            }
        }

        /// <summary>执行原生命令并返回**退出码**（成败只能靠退出码判断时用，如 `schtasks /Query /TN`——
        /// 其失败信息随系统语言变化，解析输出不可靠）。取不到退出码一律返回 -1。</summary>
        public static int RunExit(string exe, string args, int timeoutSec)
        {
            lock (_sync)
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
                        RedirectStandardInput = true,
                        CreateNoWindow = true,
                    };
                    using var p = Process.Start(psi)!;
                    try { p.StandardInput.Close(); } catch { }
                    var so = p.StandardOutput.ReadToEndAsync();
                    var se = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutSec * 1000)) { try { p.Kill(true); } catch { } return -1; }
                    try { Task.WaitAll(new Task[] { so, se }, 3000); } catch { }
                    return p.ExitCode;
                }
                catch { return -1; }
            }
        }

        // —— gateway 计划任务的精确标识（与 install.ps1 第 11 段同一口径）——
        // 上游 get_task_name()：默认 profile 即此名，命名 profile 为 Hermes_Gateway_<X>；我方只装默认 profile。
        public const string GatewayTaskName = "Hermes_Gateway";

        /// <summary>上游 _write_task_script() 落在 <HERMES_HOME>\gateway-service\<task>.vbs ——
        /// 这才是 Scheduled Task 的 Action 实际执行的文件（.cmd 只是兼容产物）。</summary>
        public static string GatewayLauncherVbs =>
            Path.Combine(HermesHome, "gateway-service", GatewayTaskName + ".vbs");

        /// <summary>gateway 计划任务是否**真正可用**：任务在 + 其启动脚本在。
        /// 只看任务名会被断链任务（脚本已被删）骗到——那种情况必须重装而不是跳过。
        /// 判存走退出码，不解析 schtasks 的本地化输出。</summary>
        public static bool GatewayTaskUsable()
        {
            if (!File.Exists(GatewayLauncherVbs)) return false;
            return RunExit("schtasks", $"/Query /TN \"{GatewayTaskName}\"", 30) == 0;
        }

        /// <summary>删除 gateway 计划任务（按精确名删，不解析输出——中文 Windows 的字段名是「任务名:」）。</summary>
        public static void DeleteGatewayTask() =>
            RunExit("schtasks", $"/Delete /TN \"{GatewayTaskName}\" /F", 30);

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

        /// <summary>判定“已安装”必须同时满足：① bin\hermes.exe 在场 ② venv 的解释器链可用。
        /// 只查 ① 不够——2026-09-11 实录：uv 托管目录缺一个（精确版本目录）时 bin\hermes.exe 仍在，
        /// 但 venv 的 pyvenv.cfg 记的 home 已失效，任何 hermes 调用都报
        /// No Python at '"...\cpython-3.11.16-windows-x86_64-none\python.exe"'。
        /// 而启动判定若据此认为“已安装”，用户就**永远没有正常路径进入安装/修复流程**。</summary>
        public static bool Installed =>
            File.Exists(Path.Combine(HermesHome, "bin", "hermes.exe")) && InterpreterHealthy();

        /// <summary>解释器链是否可用：读 venv\pyvenv.cfg 的 home=，检查其中 python.exe 是否存在。
        /// 路径取自 pyvenv.cfg 本身，因此对 uv 托管（hermes\uv-python）与其它安装位置同样成立。</summary>
        public static bool InterpreterHealthy()
        {
            try
            {
                var cfg = Path.Combine(HermesHome, "hermes-agent", "venv", "pyvenv.cfg");
                if (!File.Exists(cfg)) return false;
                foreach (var line in File.ReadAllLines(cfg))
                {
                    var t = line.Trim();
                    if (!t.StartsWith("home", StringComparison.OrdinalIgnoreCase)) continue;
                    var eq = t.IndexOf('=');
                    if (eq < 0) continue;
                    var home = t.Substring(eq + 1).Trim().Trim('"');
                    if (home.Length == 0) return false;
                    return File.Exists(Path.Combine(home, "python.exe"));
                }
                return false;
            }
            catch { return false; }
        }

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
        // 旧实现 `Process.GetProcessesByName("rclone").Length > 0` 会命中**任意** rclone
        //（用户拿 rclone 挂网盘/搬数据时被误报为"同步服务运行中"）。
        // 新实现按产品约定端口判可达——docs/ONBOARDING.md 规定同步服务为
        // `rclone serve webdav <vault> --addr 0.0.0.0:5005`，故 127.0.0.1:5005 可连即视为运行中。
        // 非默认端口部署可用环境变量 HERMEMORY_WEBDAV_PORT 覆盖。
        private const int DefaultWebDavPort = 5005;

        public static bool WebDavRunning()
        {
            var port = DefaultWebDavPort;
            var ov = Environment.GetEnvironmentVariable("HERMEMORY_WEBDAV_PORT");
            if (int.TryParse(ov, out var p) && p > 0 && p < 65536) port = p;

            if (TcpReachable(port)) return true;

            // 兜底：rclone 进程确实来自本产品目录（未来若由安装器托管 rclone，这里仍能判到；
            // 系统别处装的 rclone 不认，避免误报）
            try
            {
                foreach (var pr in Process.GetProcessesByName("rclone"))
                {
                    using (pr)
                    {
                        try
                        {
                            var f = pr.MainModule?.FileName ?? "";
                            if (f.Length > 0 && f.StartsWith(HermesHome, StringComparison.OrdinalIgnoreCase))
                                return true;
                        }
                        catch { }   // MainModule 对高权限/异位数进程会抛
                    }
                }
            }
            catch { }
            return false;
        }

        /// <summary>本机回环端口是否可连（400ms 上限；无监听时 Windows 立即回 RST，不会等满）。</summary>
        private static bool TcpReachable(int port)
        {
            try
            {
                using var c = new System.Net.Sockets.TcpClient();
                var ar = c.BeginConnect("127.0.0.1", port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(400)) return false;
                c.EndConnect(ar);
                return true;
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
