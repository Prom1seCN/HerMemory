# 审查修复：exe 逻辑级低级错误（跑完即删）
import io, re

def rd(p): return io.open(p, encoding="utf-8-sig").read()
def wr(p, t): io.open(p, "w", encoding="utf-8-sig", newline="\n").write(t)
ok = []

# ========== 1) HermesCtl：并发串行化 + 防死锁读取 ==========
p = "HermesCtl.cs"
t = rd(p)

old = '''    internal static class HermesCtl
    {'''
assert old in t
t = t.replace(old, '''    internal static class HermesCtl
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
''', 1)
ok.append("HermesCtl: 串行锁 + 并发读取")

old = '''        public static string RawStatus(int timeoutSec = 15)
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
        }'''
assert old in t, "RawStatus"
t = t.replace(old, '''        public static string RawStatus(int timeoutSec = 15) => RunPsi(HermsPsi("gateway status"), timeoutSec);''', 1)

old = '''        public static string Run(string args, int timeoutSec = 120)
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
        }'''
assert old in t, "Run"
t = t.replace(old, '''        public static string Run(string args, int timeoutSec = 120) => RunPsi(HermsPsi(args), timeoutSec);''', 1)

old = '''        public static string? RunCaptureRaw(string exe, string args, int timeoutSec)
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
        }'''
assert old in t, "RunCaptureRaw"
t = t.replace(old, '''        public static string? RunCaptureRaw(string exe, string args, int timeoutSec)
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
            var s = RunPsi(psi, timeoutSec);
            return string.IsNullOrEmpty(s) ? null : s;
        }''', 1)
wr(p, t)

# ========== 2) MainWindow：档位表读真实数值（自定义档此前显示空） ==========
p = "MainWindow.xaml.cs"
t = rd(p)

old = '''                limit = System.Text.RegularExpressions.Regex.Match(outp, @"(2200|5000|10000)").Groups[1].Value;'''
assert old in t, "limit regex"
t = t.replace(old, '''                limit = System.Text.RegularExpressions.Regex.Match(outp, @"(\\d{3,7})").Groups[1].Value;''', 1)
old = '''                usr = System.Text.RegularExpressions.Regex.Match(outp2, @"(1375|3000|5000)").Groups[1].Value;'''
assert old in t, "usr regex"
t = t.replace(old, '''                usr = System.Text.RegularExpressions.Regex.Match(outp2, @"(\\d{3,7})").Groups[1].Value;''', 1)
ok.append("档位表：自定义档回显真实数值")

# ========== 3) API 页进页走统一入口（此前不显示状态提示/当前模型，且重复拉一次配置） ==========
old = '''            ShowPage("PageApi");                       // 先切页面，数据异步跟随
            FocusCfg();
            _ = Task.Run(async () =>
            {
                var s = await Task.Run(HermesCtl.State);
                _lastState = s;
                var (url, _, key) = HermesCtl.GetModelCfg();
                await Dispatcher.InvokeAsync(() =>
                {
                    CfgUrl.Text = url;
                    CfgKey.Text = key;
                    if (key.Length == 0) CfgHint.Text = "未读取到 Key，请直接填写。";
                });
            });'''
assert old in t, "LinkApi"
t = t.replace(old, '''            ShowPage("PageApi");                       // 先切页面，数据异步跟随
            FocusCfg();
            _ = Task.Run(async () =>
            {
                var s = await Task.Run(HermesCtl.State);
                _lastState = s;
                await Dispatcher.InvokeAsync(() => UpdateCfgRegion(s, load: true));
            });''', 1)
ok.append("API 页：进页走统一入口（状态提示 + 当前模型 + 预填）")

# ========== 4) 微信流程：gateway install 走 HermesCtl（获得 NO_COLOR + 串行锁） ==========
old = '''                await Task.Run(() => RunCapture(HermsExe, "gateway install", 600));'''
assert old in t, "gateway install"
t = t.replace(old, '''                await Task.Run(() => HermesCtl.Run("gateway install", 600));''', 1)
ok.append("微信流程：gateway install 统一走 HermesCtl")

# ========== 5) 关闭询问窗：跟随主题（此前深色模式下白底弹窗） ==========
old = '''                Background = new System.Windows.Media.SolidColorBrush(
                    (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FAFBFC")),
            };'''
assert old in t, "dlg bg"
t = t.replace(old, '''                Background = System.Windows.Application.Current.Resources["WindowBg"] as System.Windows.Media.Brush
                    ?? new System.Windows.Media.SolidColorBrush(
                        (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FAFBFC")),
            };''', 1)
old = '''                Foreground = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromArgb(255, 15, 23, 42)),
            });'''
assert old in t, "q fg"
t = t.replace(old, '''                Foreground = System.Windows.Application.Current.Resources["Ink"] as System.Windows.Media.Brush
                    ?? System.Windows.Media.Brushes.Black,
            });''', 1)
old = '''                Foreground = System.Windows.Media.Brushes.DimGray,
                Margin = new Thickness(0, 16, 0, 0),
            };'''
assert old in t, "remember fg"
t = t.replace(old, '''                Foreground = System.Windows.Application.Current.Resources["Ink"] as System.Windows.Media.Brush
                    ?? System.Windows.Media.Brushes.DimGray,
                Margin = new Thickness(0, 16, 0, 0),
            };''', 1)
ok.append("关闭询问窗：跟随主题（深/浅）")

# ========== 6) 卸载：补删内嵌发行包缓存；执行期禁用勾选项 ==========
old = '''            BtnUninsRun.IsEnabled = false;
            BtnUninsBack.IsEnabled = false;'''
assert old in t, "unins disable"
t = t.replace(old, '''            BtnUninsRun.IsEnabled = false;
            BtnUninsBack.IsEnabled = false;
            UninsVault.IsEnabled = false;
            UninsExe.IsEnabled = false;''', 1)

old = '''            var hh = HermesCtl.HermesHome;'''
assert old in t, "payload del anchor"
t = t.replace(old, '''            SetUnins("移除内嵌发行包缓存……", 33);
            try
            {
                var cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HerMemory");
                if (Directory.Exists(cache)) Directory.Delete(cache, true);
            }
            catch { }

            var hh = HermesCtl.HermesHome;''', 1)
ok.append("卸载：补删 payload 缓存 + 执行期禁用勾选")

# ========== 7) 模型列表临时文件唯一化（避免并发/残留复用） ==========
old = '''            var tmp = Path.Combine(Path.GetTempPath(), "hm-models-exe.json");'''
assert old in t, "tmp"
t = t.replace(old, '''            var tmp = Path.Combine(Path.GetTempPath(), $"hm-models-{Guid.NewGuid():N}.json");''', 1)
old = '''            var body = File.Exists(tmp) ? File.ReadAllText(tmp) : "";
            return (code, body);'''
assert old in t, "tmp read"
t = t.replace(old, '''            var body = File.Exists(tmp) ? File.ReadAllText(tmp) : "";
            try { File.Delete(tmp); } catch { }
            return (code, body);''', 1)
ok.append("模型列表：临时文件唯一化并清理")

wr(p, t)

# ========== 8) 托盘：启停后立即刷新状态（不必等下一个 10 秒轮询） ==========
p = "TrayService.cs"
t = rd(p)
old = '''        private string _state = "unknown";
        private bool _busy;'''
assert old in t
t = t.replace(old, '''        private string _state = "unknown";
        private bool _busy;
        private System.Windows.Forms.ToolStripMenuItem? _miStatus;''', 1)
old = '''            var miStatus = new System.Windows.Forms.ToolStripMenuItem("状态：检测中…") { Enabled = false };'''
assert old in t
t = t.replace(old, '''            var miStatus = new System.Windows.Forms.ToolStripMenuItem("状态：检测中…") { Enabled = false };
            _miStatus = miStatus;''', 1)
old = '''                _poll.Start();
            });
        }'''
assert old in t, "RunGw tail"
t = t.replace(old, '''                _poll.Start();
                // 立即刷新一次：不必等下一个 10 秒轮询（避免 tooltip/菜单显示旧状态）
                if (_miStatus != null) _ = PollAsync(_miStatus);
            });
        }''', 1)
wr(p, t)
ok.append("托盘：启停后立即刷新状态")

print("已修复：")
for i, s in enumerate(ok, 1): print(f"  {i}. {s}")
