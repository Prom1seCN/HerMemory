using System.Diagnostics;
using System.Drawing;
using System.IO;

namespace HerMemory
{
    /// <summary>
    /// 托盘常驻：图标 = logo 本体（与 exe 图标同源，仅分辨率不同），状态走文字（tooltip + 菜单首项）。
    /// 图标在构造函数一次性加载缓存（WPF 主线程 STA）。
    /// </summary>
    public class TrayService : IDisposable
    {
        private readonly System.Windows.Forms.NotifyIcon _icon;
        private readonly System.Windows.Forms.ContextMenuStrip _menu;
        private readonly System.Windows.Forms.Timer _poll;

        // —— 图标：与 exe 图标完全同源（logo 双菱·分距200，tray-{32,16}.png 嵌入资源），仅分辨率不同 ——
        // 状态指示走文字（悬停 tooltip + 菜单首项），图标本身不再变色。
        private readonly System.Drawing.Icon _icoLogo;
        private string _state = "unknown";
        private bool _busy;
        private System.Windows.Forms.ToolStripMenuItem? _miStatus;

        /// <summary>创建托盘时的 UI 线程 Dispatcher。WinForms 控件的属性只能在创建它们的线程上写，
        /// 而托盘的状态更新有两条路径落在**线程池线程**上：PollAsync 的 await 之后（此处无
        /// SynchronizationContext 可回落）、RunGw 的 Task.Run 内部。故统一经 Ui() marshal。</summary>
        private readonly System.Windows.Threading.Dispatcher? _ui;

        /// <summary>状态变化（state: running/stopped/unknown, raw: 原始输出）。</summary>
        public event Action<string, string>? StatusChanged;
        /// <summary>左键单击托盘（用户要求：打开主界面）。</summary>
        public event Action? OpenMain;
        /// <summary>菜单点"安装向导"。</summary>
        public event Action? OpenWizard;
        /// <summary>菜单点"卸载"。</summary>
        public event Action? OpenUninstall;
        /// <summary>菜单点"微信绑定…"。</summary>
        public event Action? OpenWeixin;

        private string LogsDir => HermesCtl.LogsDir;

        public TrayService()
        {
            // 图标加载一次缓存（构造函数运行在 WPF 主线程 STA）
            _icoLogo = MakeIcon();
            _ui = System.Windows.Threading.Dispatcher.CurrentDispatcher;

            // 开机自启自愈：exe 被移动/重命名后，Run 键里存的旧路径会让自启项静默失效
            //（登录时 Windows 找不到目标，不报错、也不启动）。启动时改回当前路径即可。
            try { if (AutostartEnabled() && AutostartStale()) WriteAutostart(); } catch { }

            _menu = new System.Windows.Forms.ContextMenuStrip();

            var miStatus = new System.Windows.Forms.ToolStripMenuItem("状态：检测中……") { Enabled = false };
            _miStatus = miStatus;
            var miStart = new System.Windows.Forms.ToolStripMenuItem("启动", null, (_, _) => RunGw("start"));
            var miStop = new System.Windows.Forms.ToolStripMenuItem("停止", null, (_, _) => RunGw("stop"));
            var miLogs = new System.Windows.Forms.ToolStripMenuItem("打开日志文件夹", null, (_, _) =>
            {
                if (Directory.Exists(LogsDir))
                    Process.Start(new ProcessStartInfo("explorer.exe", $"\"{LogsDir}\"") { UseShellExecute = true });
            });
            var miMain = new System.Windows.Forms.ToolStripMenuItem("打开主界面", null, (_, _) => OpenMain?.Invoke());
            var miWeixin = new System.Windows.Forms.ToolStripMenuItem("微信绑定…", null, (_, _) => OpenWeixin?.Invoke());
            var miWizard = new System.Windows.Forms.ToolStripMenuItem("安装向导…", null, (_, _) => OpenWizard?.Invoke());
            var miUnins = new System.Windows.Forms.ToolStripMenuItem("卸载…", null, (_, _) => OpenUninstall?.Invoke());
            var miAuto = new System.Windows.Forms.ToolStripMenuItem("开机自启", null, (_, _) => ToggleAutostart())
            {
                CheckOnClick = true,
                Checked = AutostartEnabled(),
            };
            var miMinimize = new System.Windows.Forms.ToolStripMenuItem("关闭时最小化到托盘", null, (_, _) =>
                HermesCtl.SetCloseMinimize(!HermesCtl.CloseMinimizeEnabled()))
            {
                CheckOnClick = true,
                Checked = HermesCtl.CloseMinimizeEnabled(),
            };
            var miDark = new System.Windows.Forms.ToolStripMenuItem("深色模式")
            {
                CheckOnClick = true,
                Checked = Theme.IsDark,
            };
            miDark.Click += (_, _) => Theme.SetDark(miDark.Checked);
            var miExit = new System.Windows.Forms.ToolStripMenuItem("退出", null, (_, _) =>
            {
                App.RequestExit();
            });

            _menu.Items.Add(miStatus);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miStart);
            _menu.Items.Add(miStop);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miLogs);
            _menu.Items.Add(miMain);
            _menu.Items.Add(miWeixin);
            _menu.Items.Add(miWizard);
            _menu.Items.Add(miUnins);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miAuto);
            _menu.Items.Add(miMinimize);
            _menu.Items.Add(miDark);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miExit);

            _icon = new System.Windows.Forms.NotifyIcon
            {
                Icon = _icoLogo,
                Text = "HerMemory",
                Visible = true,
                ContextMenuStrip = _menu,
            };
            _icon.MouseClick += (_, a) => { if (a.Button == System.Windows.Forms.MouseButtons.Left) OpenMain?.Invoke(); };
            _icon.DoubleClick += (_, _) => OpenMain?.Invoke();

            _poll = new System.Windows.Forms.Timer { Interval = 10_000 };
            _poll.Tick += async (_, _) => await PollAsync(miStatus);
            _poll.Start();
            _ = PollAsync(miStatus);
        }

        /// <summary>把 WinForms 控件操作 marshal 回托盘创建线程（WPF UI 线程）。
        /// 退出期 Dispatcher 可能已拒绝新工作——吞掉异常，绝不让托盘逻辑把进程带崩。</summary>
        private void Ui(Action act)
        {
            try
            {
                if (_ui == null || _ui.CheckAccess()) act();
                else _ui.BeginInvoke(act);
            }
            catch { }
        }

        private async Task PollAsync(System.Windows.Forms.ToolStripMenuItem miStatus)
        {
            if (_busy) return;
            _busy = true;
            string state;
            string raw;
            try
            {
                (state, raw) = await Task.Run(() =>
                {
                    var raw = HermesCtl.RawStatus();
                    var lower = raw.ToLowerInvariant();
                    // 顺序关键："not running" 也包含 "running"——必须先判否定；二态，读取失败按停止
                    if (lower.Contains("not running") || lower.Contains("stopped")) return ("stopped", raw);
                    if (lower.Contains("running")) return ("running", raw);
                    return ("stopped", raw);
                });
            }
            catch
            {
                // 轮询失败不该中断轮询：给一个中性状态即可，下一次 tick 会重试
                (state, raw) = ("stopped", "");
            }
            finally
            {
                _busy = false;   // 必须 finally：异常时不清标记 = 轮询永久停摆（状态从此不再更新）
            }
            _state = state;

            Ui(() =>
            {
                try
                {
                    // 图标恒为 logo（与 exe 图标同源）；状态只走文字
                    _icon.Text = "HerMemory — " + (state == "running" ? "运行中" : "已停止");
                    miStatus.Text = state == "running" ? "状态：运行中" : "状态：已停止";
                }
                catch { }
            });
            StatusChanged?.Invoke(state, raw);
        }

        private void RunGw(string cmd, bool silent = true)
        {
            Ui(() => { try { _poll.Stop(); } catch { } }); // 命令执行期间暂停轮询，避免状态抖动
            Task.Run(() =>
            {
                try
                {
                    var r = HermesCtl.Run($"gateway {cmd}", 120);
                    if (!silent)
                    {
                        var brief = r.Trim();
                        if (brief.Length > 300) brief = brief[..300];
                        Ui(() =>
                        {
                            try
                            {
                                _icon.ShowBalloonTip(4000, "HerMemory",
                                    string.IsNullOrWhiteSpace(brief) ? "命令已执行。" : brief,
                                    System.Windows.Forms.ToolTipIcon.Info);
                            }
                            catch { }
                        });
                    }
                }
                catch { }
                finally
                {
                    // 必须 finally：异常时若没重启轮询，托盘状态会永久冻结
                    Ui(() => { try { _poll.Start(); } catch { } });
                    // 立即刷新一次：不必等下一个 10 秒轮询（避免 tooltip/菜单显示旧状态）
                    if (_miStatus != null) _ = PollAsync(_miStatus);
                }
            });
        }

        // —— 开机自启：HKCU Run 键（默认关；用户勾选即开） ——
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "HerMemory";

        private static bool AutostartEnabled()
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(RunValue) != null;
        }

        /// <summary>Run 键里存的路径是否已不是当前 exe（exe 被移动/重命名 → 自启项静默失效）。</summary>
        private static bool AutostartStale()
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            var stored = (k?.GetValue(RunValue) as string ?? "").Trim().Trim('"');
            var cur = (Environment.ProcessPath ?? "").Trim('"');
            return stored.Length > 0 && cur.Length > 0
                && !string.Equals(stored, cur, StringComparison.OrdinalIgnoreCase);
        }

        private static void WriteAutostart()
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
            k.SetValue(RunValue, $"\"{Environment.ProcessPath}\"");
        }

        private static void ToggleAutostart()
        {
            if (AutostartEnabled())
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
                k.DeleteValue(RunValue, false);
            }
            else WriteAutostart();
        }

        // —— 图标：与 exe 图标完全同源（logo 双菱·分距200），从嵌入资源加载 32/16 双尺寸 PNG ——
        // 换 logo 只换 assets PNG + app.ico，不动代码。
        private static System.Drawing.Icon MakeIcon()
        {
            var asm = System.Reflection.Assembly.GetExecutingAssembly();
            var pngs = new List<byte[]>();
            foreach (var size in new[] { 32, 16 })
            {
                using var s = asm.GetManifestResourceStream($"tray-{size}.png")
                    ?? throw new InvalidOperationException($"missing embedded tray icon tray-{size}.png");
                using var ms = new MemoryStream();
                s.CopyTo(ms);
                pngs.Add(ms.ToArray());
            }
            return IconFromPngs(pngs.ToArray(), new[] { 32, 16 });
        }

        private static Icon IconFromPngs(byte[][] pngs, int[] sizes)
        {
            using var outMs = new MemoryStream();
            using (var bw = new BinaryWriter(outMs))
            {
                bw.Write((short)0); bw.Write((short)1); bw.Write((short)pngs.Length);
                int offset = 6 + 16 * pngs.Length;
                for (int i = 0; i < pngs.Length; i++)
                {
                    bw.Write((byte)sizes[i]); bw.Write((byte)sizes[i]); bw.Write((byte)0); bw.Write((byte)0);
                    bw.Write((short)1); bw.Write((short)32);
                    bw.Write(pngs[i].Length); bw.Write(offset);
                    offset += pngs[i].Length;
                }
                foreach (var png in pngs) bw.Write(png);
            }
            return new Icon(new MemoryStream(outMs.ToArray()));
        }

        public void Dispose()
        {
            // 逐项 try：任何一项失败都不能阻断其余清理（否则托盘图标会残留在通知区）
            try { _poll.Stop(); } catch { }
            try { _poll.Dispose(); } catch { }
            try { _icon.Visible = false; } catch { }
            try { _icon.Dispose(); } catch { }
            try { _menu.Dispose(); } catch { }
            try { _icoLogo.Dispose(); } catch { }
            GC.SuppressFinalize(this);
        }
    }
}
