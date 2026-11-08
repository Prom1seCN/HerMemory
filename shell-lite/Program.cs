// HerMemory 托盘薄壳：只做四件事——起服务、开面板、自启、退出。
// 界面全部交给 v0.23 的 Web Dashboard（hermes dashboard），这里不再自绘任何页面。
using System.Diagnostics;
using System.Net.Http;
using Microsoft.Win32;

namespace HerMemoryTray;

internal static class Program
{
    private const string PanelUrl = "http://127.0.0.1:9119/";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "HerMemory";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(1.2) };

    private static string HermesHome =>
        Environment.GetEnvironmentVariable("HERMES_HOME")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes");

    private static string HermesExe => Path.Combine(HermesHome, "bin", "hermes.exe");

    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }

    internal sealed class TrayContext : ApplicationContext
    {
        private readonly NotifyIcon _icon;
        private readonly ToolStripMenuItem _autostart;
        private readonly ToolStripMenuItem _gateway;
        private readonly System.Windows.Forms.Timer _timer;

        public TrayContext()
        {
            _autostart = new ToolStripMenuItem("开机自动启动", null, (_, _) => ToggleAutostart()) { Checked = IsAutostart() };
            _gateway = new ToolStripMenuItem("网关：检查中…", null, (_, _) => ToggleGateway());

            var menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("打开管理面板", null, (_, _) => OpenPanel()) { Font = new Font(SystemFonts.MenuFont, FontStyle.Bold) });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(_gateway);
            menu.Items.Add(_autostart);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("退出", null, (_, _) => ExitApp()));

            _icon = new NotifyIcon
            {
                Icon = LoadIcon(),
                Visible = true,
                Text = "HerMemory",
                ContextMenuStrip = menu,
            };
            _icon.DoubleClick += (_, _) => OpenPanel();

            _timer = new System.Windows.Forms.Timer { Interval = 15000 };
            _timer.Tick += (_, _) => RefreshGatewayState();
            _timer.Start();
            RefreshGatewayState();

            // 启动即拉起面板（用户双击托盘程序的预期就是“打开它”）
            OpenPanel();
        }

        private static Icon LoadIcon()
        {
            try
            {
                var stream = typeof(TrayContext).Assembly.GetManifestResourceStream("app.ico");
                if (stream != null) return new Icon(stream);
            }
            catch { }
            return SystemIcons.Application;
        }

        private static bool IsAutostart()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(RunValue) != null;
            }
            catch { return false; }
        }

        private void ToggleAutostart()
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                if (IsAutostart()) key.DeleteValue(RunValue, false);
                else key.SetValue(RunValue, $"\"{Environment.ProcessPath}\"");
                _autostart.Checked = IsAutostart();
                Notify(_autostart.Checked ? "已开启开机自动启动" : "已关闭开机自动启动");
            }
            catch (Exception ex) { Notify("设置开机自启失败：" + ex.Message); }
        }

        private async Task<bool> PanelUp()
        {
            try
            {
                using var resp = await Http.GetAsync(PanelUrl);
                return resp.IsSuccessStatusCode;
            }
            catch { return false; }
        }

        private static bool GatewayRunning()
        {
            try { return File.Exists(Path.Combine(HermesHome, "gateway.pid")); }
            catch { return false; }
        }

        private void RefreshGatewayState() => _gateway.Text = GatewayRunning() ? "网关：运行中" : "网关：已停止（点击启动）";

        private void ToggleGateway()
        {
            RunHermes(GatewayRunning() ? "gateway stop" : "gateway start");
            Task.Delay(1200).ContinueWith(_ => RefreshGatewayState());
        }

        private async void OpenPanel()
        {
            if (!await PanelUp())
            {
                RunHermes("dashboard --no-open --port 9119");
                for (var i = 0; i < 20 && !await PanelUp(); i++) await Task.Delay(500);
            }
            try { Process.Start(new ProcessStartInfo(PanelUrl) { UseShellExecute = true }); }
            catch (Exception ex) { Notify("打开浏览器失败：" + ex.Message); }
        }

        private static void RunHermes(string args)
        {
            try
            {
                var psi = new ProcessStartInfo(HermesExe, args)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    WorkingDirectory = HermesHome,
                };
                Process.Start(psi);
            }
            catch { }
        }

        private void Notify(string text)
        {
            _icon.BalloonTipTitle = "HerMemory";
            _icon.BalloonTipText = text;
            _icon.ShowBalloonTip(2500);
        }

        private void ExitApp()
        {
            _icon.Visible = false;
            _icon.Dispose();
            ExitThread();
        }
    }
}
