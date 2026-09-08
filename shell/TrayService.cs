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

        /// <summary>状态变化（state: running/stopped/unknown, raw: 原始输出）。</summary>
        public event Action<string, string>? StatusChanged;
        /// <summary>左键单击托盘（用户要求：打开主界面）。</summary>
        public event Action? OpenMain;
        /// <summary>菜单点"安装向导"。</summary>
        public event Action? OpenWizard;
        /// <summary>菜单点"卸载"。</summary>
        public event Action? OpenUninstall;

        private string LogsDir => HermesCtl.LogsDir;

        public TrayService()
        {
            // 图标加载一次缓存（构造函数运行在 WPF 主线程 STA）
            _icoLogo = MakeIcon();

            _menu = new System.Windows.Forms.ContextMenuStrip();

            var miStatus = new System.Windows.Forms.ToolStripMenuItem("状态：检测中…") { Enabled = false };
            var miStart = new System.Windows.Forms.ToolStripMenuItem("启动", null, (_, _) => RunGw("start"));
            var miStop = new System.Windows.Forms.ToolStripMenuItem("停止", null, (_, _) => RunGw("stop"));
            var miLogs = new System.Windows.Forms.ToolStripMenuItem("打开日志文件夹", null, (_, _) =>
            {
                if (Directory.Exists(LogsDir))
                    Process.Start(new ProcessStartInfo("explorer.exe", $"\"{LogsDir}\"") { UseShellExecute = true });
            });
            var miMain = new System.Windows.Forms.ToolStripMenuItem("打开主界面", null, (_, _) => OpenMain?.Invoke());
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

        private async Task PollAsync(System.Windows.Forms.ToolStripMenuItem miStatus)
        {
            if (_busy) return;
            _busy = true;
            var (state, raw) = await Task.Run(() =>
            {
                var raw = HermesCtl.RawStatus();
                var lower = raw.ToLowerInvariant();
                // 顺序关键："not running" 也包含 "running"——必须先判否定；二态，读取失败按停止
                if (lower.Contains("not running") || lower.Contains("stopped")) return ("stopped", raw);
                if (lower.Contains("running")) return ("running", raw);
                return ("stopped", raw);
            });
            _state = state;
            _busy = false;

            try
            {
                // 图标恒为 logo（与 exe 图标同源）；状态只走文字
                _icon.Text = "HerMemory — " + (state == "running" ? "运行中" : "已停止");
                miStatus.Text = state == "running" ? "状态：运行中" : "状态：已停止";
            }
            catch { }
            StatusChanged?.Invoke(state, raw);
        }

        private void RunGw(string cmd, bool silent = true)
        {
            _poll.Stop(); // 命令执行期间暂停轮询，避免状态抖动
            Task.Run(() =>
            {
                var r = HermesCtl.Run($"gateway {cmd}", 120);
                if (!silent)
                {
                    var brief = r.Trim();
                    if (brief.Length > 300) brief = brief[..300];
                    _icon.ShowBalloonTip(4000, "HerMemory",
                        string.IsNullOrWhiteSpace(brief) ? "命令已执行。" : brief,
                        System.Windows.Forms.ToolTipIcon.Info);
                }
                _poll.Start();
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

        private static void ToggleAutostart()
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey);
            if (AutostartEnabled()) k.DeleteValue(RunValue, false);
            else k.SetValue(RunValue, $"\"{Environment.ProcessPath}\"");
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
            _poll.Stop();
            _icon.Visible = false;
            _icon.Dispose();
            _menu.Dispose();
            GC.SuppressFinalize(this);
        }
    }
}
