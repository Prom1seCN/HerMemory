using System.Diagnostics;
using System.Drawing;
using System.IO;

namespace HerMemory
{
    /// <summary>
    /// 托盘常驻：三态图标（形状与颜色分离，logo 定稿后替换形状）+ 菜单。
    /// 图标只生成一次缓存（必须在 STA 线程渲染——RenderTargetBitmap 在 MTA 线程会抛异常被吞，
    /// 这是"恒青 bug"的另一半根因：状态变了但新图标生成失败，旧图标原地不动）。
    /// </summary>
    public class TrayService : IDisposable
    {
        private readonly System.Windows.Forms.NotifyIcon _icon;
        private readonly System.Windows.Forms.ContextMenuStrip _menu;
        private readonly System.Windows.Forms.Timer _poll;
        private readonly System.Drawing.Icon _icoRun, _icoStop, _icoUnknown;
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
            // 图标三态缓存：构造函数运行在 WPF 主线程（STA），渲染合法
            _icoRun = MakeIcon("#22D3EE");
            _icoStop = MakeIcon("#90A4AE");
            _icoUnknown = MakeIcon("#EF5350");

            _menu = new System.Windows.Forms.ContextMenuStrip();

            var miStatus = new System.Windows.Forms.ToolStripMenuItem("状态：检测中…") { Enabled = false };
            var miStart = new System.Windows.Forms.ToolStripMenuItem("启动", null, (_, _) => RunGw("start"));
            var miStop = new System.Windows.Forms.ToolStripMenuItem("停止", null, (_, _) => RunGw("stop"));
            var miRestart = new System.Windows.Forms.ToolStripMenuItem("重启", null, (_, _) => RunGw("restart"));
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
            var miExit = new System.Windows.Forms.ToolStripMenuItem("退出", null, (_, _) =>
            {
                App.RequestExit();
            });

            _menu.Items.Add(miStatus);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miStart);
            _menu.Items.Add(miStop);
            _menu.Items.Add(miRestart);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miLogs);
            _menu.Items.Add(miMain);
            _menu.Items.Add(miWizard);
            _menu.Items.Add(miUnins);
            _menu.Items.Add(miAuto);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miExit);

            _icon = new System.Windows.Forms.NotifyIcon
            {
                Icon = _icoRun,
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
                // 顺序关键："not running" 也包含 "running"——必须先判否定
                if (lower.Contains("not running") || lower.Contains("stopped")) return ("stopped", raw);
                if (lower.Contains("running")) return ("running", raw);
                return ("unknown", raw);
            });
            _state = state;
            _busy = false;

            try
            {
                _icon.Icon = state switch
                {
                    "running" => _icoRun,
                    "stopped" => _icoStop,
                    _ => _icoUnknown,
                };
                _icon.Text = "HerMemory — " + state switch
                {
                    "running" => "运行中",
                    "stopped" => "已停止",
                    _ => "状态未知",
                };
                miStatus.Text = _icon.Text["HerMemory — ".Length..];
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

        // —— 图标生成：旋转 45° 菱形（记忆水晶剪影），32/16 双尺寸 ——
        private static Icon MakeIcon(string hex)
        {
            var c = (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex);
            var brush = new System.Windows.Media.SolidColorBrush(c);
            var pngs = new List<byte[]>();
            foreach (var size in new[] { 32, 16 })
            {
                var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap(size, size, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                var visual = new System.Windows.Media.DrawingVisual();
                using (var dc = visual.RenderOpen())
                {
                    double s = size, m = s * 0.12;
                    var center = s / 2;
                    var geo = new System.Windows.Media.StreamGeometry();
                    using (var ctx = geo.Open())
                    {
                        ctx.BeginFigure(new System.Windows.Point(center, m), true, true);
                        ctx.LineTo(new System.Windows.Point(s - m, center), true, true);
                        ctx.LineTo(new System.Windows.Point(center, s - m), true, true);
                        ctx.LineTo(new System.Windows.Point(m, center), true, true);
                    }
                    geo.Freeze();
                    dc.DrawGeometry(brush, null, geo);
                }
                bmp.Render(visual);
                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
                using var mem = new MemoryStream();
                enc.Save(mem);
                pngs.Add(mem.ToArray());
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
