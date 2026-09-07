using System.Diagnostics;
using System.Drawing;
using System.IO;

namespace HerMemory
{
    /// <summary>
    /// 托盘常驻（阶段 C）：三态图标 + 启停/重启/日志/自启菜单。
    /// 图标程序生成（菱形=记忆水晶剪影），三态同形变色——形状与颜色分离，logo 定稿后替换。
    /// </summary>
    public class TrayService : IDisposable
    {
        private readonly System.Windows.Forms.NotifyIcon _icon;
        private readonly System.Windows.Forms.ContextMenuStrip _menu;
        private readonly System.Windows.Forms.Timer _poll;
        private string _state = "unknown";          // running / stopped / unknown
        private bool _busy;

        public event Action? OpenWizard;

        private string HermesHome => Environment.GetEnvironmentVariable("HERMES_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes");

        private string HermsExe
        {
            get
            {
                var p = Path.Combine(HermesHome, "bin", "hermes.exe");
                return File.Exists(p) ? p : "hermes";
            }
        }

        private string LogsDir => Path.Combine(HermesHome, "logs");

        public static bool IsInstalled() =>
            File.Exists(Path.Combine(
                Environment.GetEnvironmentVariable("HERMES_HOME")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes"),
                "bin", "hermes.exe"));

        public TrayService()
        {
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
            var miWizard = new System.Windows.Forms.ToolStripMenuItem("安装向导…", null, (_, _) => OpenWizard?.Invoke());
            var miAuto = new System.Windows.Forms.ToolStripMenuItem("开机自启", null, (_, _) => ToggleAutostart())
            {
                CheckOnClick = true,
                Checked = AutostartEnabled(),
            };
            var miExit = new System.Windows.Forms.ToolStripMenuItem("退出", null, (_, _) =>
            {
                Dispose();
                System.Windows.Application.Current.Shutdown();
            });

            _menu.Items.Add(miStatus);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miStart);
            _menu.Items.Add(miStop);
            _menu.Items.Add(miRestart);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miLogs);
            _menu.Items.Add(miWizard);
            _menu.Items.Add(miAuto);
            _menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            _menu.Items.Add(miExit);

            _icon = new System.Windows.Forms.NotifyIcon
            {
                Icon = MakeIcon("#22D3EE"),
                Text = "HerMemory",
                Visible = true,
                ContextMenuStrip = _menu,
            };
            _icon.DoubleClick += (_, _) => RunGw("status", silent: false);

            _poll = new System.Windows.Forms.Timer { Interval = 10_000 };
            _poll.Tick += async (_, _) => await PollAsync(miStatus);
            _poll.Start();
            _ = PollAsync(miStatus);
        }

        // —— 状态轮询：hermes gateway status 输出含 running/stopped ——
        private async Task PollAsync(System.Windows.Forms.ToolStripMenuItem miStatus)
        {
            if (_busy) return;
            _busy = true;
            try
            {
                var text = await Task.Run(() => RunCapture(HermsExe, "gateway status", 15)) ?? "";
                var lower = text.ToLowerInvariant();
                if (lower.Contains("running")) _state = "running";
                else if (lower.Contains("stop") || lower.Contains("not ")) _state = "stopped";
                else _state = "unknown";
            }
            catch { _state = "unknown"; }
            _busy = false;

            var color = _state switch
            {
                "running" => "#22D3EE",
                "stopped" => "#90A4AE",
                _ => "#EF5350",
            };
            var label = _state switch
            {
                "running" => "状态：运行中",
                "stopped" => "状态：已停止",
                _ => "状态：未知",
            };
            try
            {
                _icon.Icon?.Dispose();
                _icon.Icon = MakeIcon(color);
                _icon.Text = "HerMemory — " + label;
                miStatus.Text = label;
            }
            catch { }
        }

        private void RunGw(string cmd, bool silent = true)
        {
            Task.Run(() =>
            {
                var r = RunCapture(HermsExe, $"gateway {cmd}", 120);
                if (!silent)
                {
                    var brief = (r ?? "").Trim();
                    if (brief.Length > 300) brief = brief[..300];
                    _icon.ShowBalloonTip(4000, "HerMemory", string.IsNullOrWhiteSpace(brief) ? "命令已执行。" : brief, System.Windows.Forms.ToolTipIcon.Info);
                }
                _busy = false; // 触发下轮轮询刷新
                _poll.Start();
            });
            _poll.Stop(); // 执行命令期间暂停轮询，避免状态抖动
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

        private static string? RunCapture(string exe, string args, int timeoutSec)
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
