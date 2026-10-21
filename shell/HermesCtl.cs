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

        /// <summary>gateway 进程是否仍活着——直接取 gateway.pid 里的 PID 判存活，不经过 CLI。
        /// 为什么不用 `gateway status`：CLI 读不到时会返回 "stopped"（见 State()），
        /// 那种误判会让调用方以为"已经停了"而继续删除 gateway 正持有的会话库。
        /// 另外本判据是纯本地文件读取，可以高频轮询（清空记忆前的等停需要它）。
        /// pid 文件由 gateway 自己在启动时写下，形如 {"pid": 28572, "kind": "hermes-gateway", …}。</summary>
        public static bool GatewayProcessAlive()
        {
            try
            {
                var pidFile = Path.Combine(HermesHome, "gateway.pid");
                if (!File.Exists(pidFile)) return false;
                var m = System.Text.RegularExpressions.Regex.Match(
                    File.ReadAllText(pidFile), "\"pid\"\\s*:\\s*(\\d+)");
                if (!m.Success) return false;
                var pid = int.Parse(m.Groups[1].Value);
                if (pid <= 0) return false;
                using var p = Process.GetProcessById(pid);   // 进程不在 → 抛 ArgumentException
                return !p.HasExited;
            }
            catch { return false; }
        }

        /// <summary>HERMES_HOME 的解析：① 本进程环境变量（含向导在「安装位置」页显式设的那个）
        /// ② **User 注册表**里的持久值 ③ 默认 %LOCALAPPDATA%\hermes。
        ///
        /// 为什么必须有 ②：进程环境块是**进程创建那一刻**从注册表合并来的快照。上游在安装期把
        /// HERMES_HOME 写进 User 注册表，但**已经启动的进程看不见这次更新**——资源管理器也不例外
        /// （它再 spawn 的本程序同样看不见）。于是「阶段 1 装完 → 关掉向导 → 之后重新运行安装包」
        /// 这条路上，新进程读不到自定义数据目录 → 回落成默认值 → 把「已有安装」误判成「全新安装」，
        /// 结果往默认目录再装一整套内核与运行时。注册表读取无副作用且恒为最新，故作为第二判据。</summary>
        public static string HermesHome
        {
            get
            {
                var v = Environment.GetEnvironmentVariable("HERMES_HOME");
                if (!string.IsNullOrEmpty(v)) return v;
                try { v = Environment.GetEnvironmentVariable("HERMES_HOME", EnvironmentVariableTarget.User); } catch { }
                if (!string.IsNullOrEmpty(v)) return v;
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes");
            }
        }

        public static string HermsExe
        {
            get
            {
                var p = Path.Combine(HermesHome, "bin", "hermes.exe");
                return File.Exists(p) ? p : "hermes";
            }
        }

        public static string LogsDir => Path.Combine(HermesHome, "logs");

        /// <summary>PM 托管的 venv 目录（v0.22 起）。没有则 null。
        ///
        /// 上游 v0.22 把依赖环境整体交给 pm：真正的位置记在
        /// <c>&lt;HERMES_HOME&gt;\installs\&lt;key&gt;\facts.json</c> 的
        /// <c>packages.venv.environment</c>，不再是 <c>hermes-agent\venv</c>。
        /// 这是 pm/environments.py:_recorded_venv 的同一口径；installs 下通常只有一个
        /// 条目（一个安装一棵树），多条目时取第一个 pyvenv.cfg 还在的。</summary>
        public static string? PmVenvDir
        {
            get
            {
                try
                {
                    var root = Path.Combine(HermesHome, "installs");
                    if (!Directory.Exists(root)) return null;
                    foreach (var d in Directory.GetDirectories(root))
                    {
                        var f = Path.Combine(d, "facts.json");
                        if (!File.Exists(f)) continue;
                        try
                        {
                            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(f));
                            if (!doc.RootElement.TryGetProperty("packages", out var pkgs)) continue;
                            if (!pkgs.TryGetProperty("venv", out var venv)) continue;
                            if (!venv.TryGetProperty("environment", out var envEl)) continue;
                            var env = envEl.GetString();
                            if (string.IsNullOrEmpty(env)) continue;
                            // 上游同样要求 pyvenv.cfg 在场：记录还在、树已被删的情况要能识别出来
                            if (File.Exists(Path.Combine(env!, "pyvenv.cfg"))) return env;
                        }
                        catch { }
                    }
                }
                catch { }
                return null;
            }
        }

        /// <summary>能直接跑脚本的解释器（微信扫码脚本用）。
        /// 先取 PM 托管环境的 python，再回落 v0.21 的 hermes-agent\venv。</summary>
        public static string? PythonExe
        {
            get
            {
                var env = PmVenvDir;
                if (!string.IsNullOrEmpty(env))
                {
                    var p = Path.Combine(env!, "Scripts", "python.exe");
                    if (File.Exists(p)) return p;
                }
                var legacy = Path.Combine(HermesHome, "hermes-agent", "venv", "Scripts", "python.exe");
                return File.Exists(legacy) ? legacy : null;
            }
        }

        /// <summary>「浏览器与电脑操作」是否已被用户拒装（v0.22 双形态）。
        /// 上游把选择记在 &lt;HERMES_HOME&gt;\installs\&lt;key&gt;\declined-packages.json，
        /// 修复安装时据此回显勾选框，避免把用户关掉的东西又默认勾上。</summary>
        public static bool HeavyToolsDeclined
        {
            get
            {
                try
                {
                    var root = Path.Combine(HermesHome, "installs");
                    if (!Directory.Exists(root)) return false;
                    foreach (var d in Directory.GetDirectories(root))
                    {
                        var f = Path.Combine(d, "declined-packages.json");
                        if (!File.Exists(f)) continue;
                        try
                        {
                            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(f));
                            if (!doc.RootElement.TryGetProperty("declined", out var arr)) continue;
                            foreach (var el in arr.EnumerateArray())
                            {
                                var n = el.GetString();
                                if (n == "agent-browser" || n == "cua-driver") return true;
                            }
                        }
                        catch { }
                    }
                }
                catch { }
                return false;
            }
        }

        /// <summary>判定“已安装”必须同时满足：① bin\hermes.exe 在场 ② 解释器链可用。
        /// 只查 ① 不够——2026-09-11 实录：uv 托管目录缺一个（精确版本目录）时 bin\hermes.exe 仍在，
        /// 但 venv 的 pyvenv.cfg 记的 home 已失效，任何 hermes 调用都报
        /// No Python at '"...\cpython-3.11.16-windows-x86_64-none\python.exe"'。
        /// 而启动判定若据此认为“已安装”，用户就**永远没有正常路径进入安装/修复流程**。</summary>
        public static bool Installed =>
            File.Exists(Path.Combine(HermesHome, "bin", "hermes.exe")) && InterpreterHealthy();

        /// <summary>解释器链是否可用：PM 记录的 venv 里要有解释器与 pyvenv.cfg；
        /// 没有 PM 记录时回落 v0.21 的 <c>hermes-agent\venv</c>（老安装升级途中两者都可能在）。</summary>
        public static bool InterpreterHealthy()
        {
            try
            {
                var env = PmVenvDir;
                if (!string.IsNullOrEmpty(env))
                    return File.Exists(Path.Combine(env!, "Scripts", "python.exe"));
                return LegacyVenvHealthy();
            }
            catch { return false; }
        }

        /// <summary>v0.21 布局：读 venv\pyvenv.cfg 的 home=，检查其中 python.exe 是否存在。
        /// 路径取自 pyvenv.cfg 本身，因此对 uv 托管（hermes\uv-python）与其它安装位置同样成立。</summary>
        private static bool LegacyVenvHealthy()
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
            // bash 解释器路径：上游探测 PortableGit 的位置写死在 %LOCALAPPDATA%\hermes\git，**不读
            // HERMES_HOME**，数据目录在别处时只能靠 HERMES_GIT_BASH_PATH。注册表里的 User 值不会传给
            // 已经在跑的本进程（环境块是启动那一刻的快照，资源管理器也不例外），所以这里显式取一次再
            // 传给子进程——否则托盘「启动」拉起的网关照样找不到 bash，得等一次重新登录才好。
            var bash = Environment.GetEnvironmentVariable("HERMES_GIT_BASH_PATH");
            if (string.IsNullOrWhiteSpace(bash) || !File.Exists(bash))
            { try { bash = Environment.GetEnvironmentVariable("HERMES_GIT_BASH_PATH", EnvironmentVariableTarget.User); } catch { } }
            if (string.IsNullOrWhiteSpace(bash) || !File.Exists(bash))
            {
                bash = null;   // 前两次可能留下一个指向不存在文件的路径，不能原样传给子进程
                foreach (var rel in new[] { @"git\bin\bash.exe", @"git\usr\bin\bash.exe" })
                {
                    var p = Path.Combine(HermesHome, rel);
                    if (File.Exists(p)) { bash = p; break; }
                }
            }
            if (!string.IsNullOrWhiteSpace(bash)) psi.EnvironmentVariables["HERMES_GIT_BASH_PATH"] = bash;
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

        /// <summary>能跑的 hermes 命令（bin\hermes.exe 优先，其次 PATH）。体检页用。</summary>
        public static string? WorkingCli()
        {
            try
            {
                var p = Path.Combine(HermesHome, "bin", "hermes.exe");
                if (File.Exists(p) && RunExit(p, "--version", 20) == 0) return p;
                if (RunExit("hermes", "--version", 20) == 0) return "hermes";
            }
            catch { }
            return null;
        }

        /// <summary>从 `hermes --version` 里取版本号（取不到返回空串）。</summary>
        public static string VersionOf(string exe)
        {
            try
            {
                var outp = RunCaptureRaw(exe, "--version", 20) ?? "";
                var m = System.Text.RegularExpressions.Regex.Match(outp, @"Hermes Agent v(\d+\.\d+\.\d+)");
                if (m.Success) return m.Groups[1].Value;
            }
            catch { }
            return "";
        }

        // ================= 每日新对话（设置页） =================
        // 机制：上游 v0.22 内核不再读 session_reset.*（定时轮换被移到社区插件），但 cron 支持
        // `--script X --no-agent`（不经过模型，跑完把 stdout 投递出去）。我们随包一个脚本
        // hermemory_daily_new.py，它调用内核自己的 promote_to_session_reset（与 /new 同一个路径），
        // 每天定时把活着的会话标记为重置 → 用户下一条消息就是新对话。
        //
        // 用户选择存我们自己的注册表键；cron 只是执行器。界面回显时以 jobs.json 里是否真有
        // 这个任务为准（用户可能在别处 pause/删掉它），对不上就如实显示。
        public const string DailyJobName = "HerMemory 每日新对话";
        public const string DailyScriptName = "hermemory_daily_new.py";
        private const string DailyRegKey = @"Software\HerMemory";

        /// <summary>默认凌晨 4 点：用户睡觉时重置，白天不会突然断上下文。</summary>
        public const string DailyDefaultTime = "04:00";

        public static (bool enabled, string time) GetDailyNewSession()
        {
            try
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(DailyRegKey);
                var enabled = (k?.GetValue("DailyNewSession") as string) == "1";
                var time = (k?.GetValue("DailyNewSessionTime") as string) ?? DailyDefaultTime;
                return (enabled, string.IsNullOrWhiteSpace(time) ? DailyDefaultTime : time);
            }
            catch { return (false, DailyDefaultTime); }
        }

        private static void SaveDailyNewSession(bool enabled, string time)
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(DailyRegKey);
            k.SetValue("DailyNewSession", enabled ? "1" : "0");
            k.SetValue("DailyNewSessionTime", time);
        }

        /// <summary>把随包脚本放进 $HERMES_HOME\scripts\（cron 的 --script 只认这个目录下的文件）。</summary>
        public static bool EnsureDailyScript(string sourceDir)
        {
            try
            {
                var dir = Path.Combine(HermesHome, "scripts");
                Directory.CreateDirectory(dir);
                var dst = Path.Combine(dir, DailyScriptName);
                var src = Path.Combine(sourceDir, "scripts", DailyScriptName);
                if (File.Exists(src)) File.Copy(src, dst, true);   // 脚本是发行版资产，跟着版本走
                return File.Exists(dst);
            }
            catch { return false; }
        }

        /// <summary>读 jobs.json 里那个任务的最小信息（存在 / 启用 / id）。
        /// 注意 JsonElement 依赖 JsonDocument 的生命周期，所以必须在 using 块内取值，
        /// 不能把 element 带出作用域。</summary>
        public static (bool exists, bool enabled, string? id) DailyJobInfo()
        {
            try
            {
                var file = Path.Combine(HermesHome, "cron", "jobs.json");
                if (!File.Exists(file)) return (false, false, null);
                using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(file));
                System.Text.Json.JsonElement arr;
                if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Array) arr = doc.RootElement;
                else if (doc.RootElement.TryGetProperty("jobs", out var j)) arr = j;
                else return (false, false, null);
                foreach (var job in arr.EnumerateArray())
                {
                    if (!job.TryGetProperty("name", out var n)) continue;
                    if ((n.GetString() ?? "") != DailyJobName) continue;
                    var enabled = !job.TryGetProperty("enabled", out var en)
                                  || en.ValueKind == System.Text.Json.JsonValueKind.True;
                    var id = job.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
                    return (true, enabled, id);
                }
                return (false, false, null);
            }
            catch { return (false, false, null); }
        }

        /// <summary>HH:mm → 5 段 cron；非法返回 null。</summary>
        public static string? CronOf(string time)
        {
            var m = System.Text.RegularExpressions.Regex.Match(time ?? "", @"^\s*(\d{1,2})\s*[:：]\s*(\d{1,2})\s*$");
            if (!m.Success) return null;
            var h = int.Parse(m.Groups[1].Value);
            var min = int.Parse(m.Groups[2].Value);
            if (h < 0 || h > 23 || min < 0 || min > 59) return null;
            return $"{min} {h} * * *";
        }

        /// <summary>保存设置并同步 cron。会跑 CLI，调用方应在后台线程调用。</summary>
        public static (bool ok, string message) SetDailyNewSession(bool enabled, string time, string sourceDir)
        {
            var cron = CronOf(time);
            if (enabled && cron == null) return (false, "时间格式应为 HH:mm，例如 04:00");

            SaveDailyNewSession(enabled, time);
            if (!enabled)
            {
                var infoOff = DailyJobInfo();
                if (infoOff.exists && infoOff.id != null) Run($"cron pause {infoOff.id}", 60);
                return (true, "已关闭：不会再自动开始新对话");
            }

            if (!EnsureDailyScript(sourceDir))
                return (false, "找不到随包脚本 scripts\\" + DailyScriptName + "，请重新运行安装包修复");

            var info = DailyJobInfo();
            if (!info.exists || info.id == null)
            {
                Run($"cron create \"{cron}\" --script {DailyScriptName} --no-agent --name \"{DailyJobName}\" --deliver local", 120);
                var created = DailyJobInfo();
                if (created.exists)
                    return (true, $"已开启：每天 {time} 自动开始新对话（下一条消息生效）");
                return (false, "创建定时任务失败。可手动执行 hermes cron create 查看原因");
            }

            Run($"cron edit {info.id} --schedule \"{cron}\"", 60);
            Run($"cron resume {info.id}", 60);
            return (true, $"已开启：每天 {time} 自动开始新对话（下一条消息生效）");
        }
    }
}
