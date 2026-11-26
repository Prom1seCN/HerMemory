using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;

namespace HerMemory
{
    /// <summary>
    /// 应用内对话窗口：嵌 Hermes 自己的 webapp（apps/desktop 构建出的静态 bundle，
    /// 由 Gateway 在 webapp.port 上提供）。用 WebView2 而不是自绘聊天，是因为那个 bundle
    /// 就是官方 Desktop 的同一套界面——会话、流式、工具卡片、审批全在里面，重写只会更差。
    ///
    /// 三个必须处理好的失败面：
    ///  · Gateway 没跑 → 说清楚"去主界面启动"，而不是白屏；
    ///  · 机器上没有 WebView2 运行时 → 退化成系统浏览器打开，功能不丢；
    ///  · 页面里点外链 → 交给系统浏览器，不在对话窗口里迷路。
    /// </summary>
    public partial class ChatWindow : Window
    {
        private static ChatWindow? _open;

        private string _url = "http://127.0.0.1:9120/";
        private bool _booted;

        public static void Open(Window? owner)
        {
            if (_open != null) { try { _open.Activate(); } catch { } return; }
            _open = new ChatWindow();
            try { if (owner != null && owner.IsVisible) _open.Owner = owner; } catch { }
            _open.Closed += (_, _) => _open = null;
            _open.Show();
        }

        public ChatWindow()
        {
            InitializeComponent();
            Loaded += async (_, _) => await BootAsync();
        }

        /// <summary>自检用：不只看 WebView2 起没起，还要看页面里到底有没有东西——
        /// 地址加载成功但 JS 崩了会是一张白屏，那种"成功"比失败更难查。</summary>
        public async Task<string> DiagnosticsAsync()
        {
            try
            {
                var core = View.CoreWebView2;
                if (core == null) return "webview=null overlay=" + OverlayTitle.Text;
                var title = await core.ExecuteScriptAsync("document.title");
                var nodes = await core.ExecuteScriptAsync("document.querySelectorAll('*').length");
                var textLen = await core.ExecuteScriptAsync("(document.body && document.body.innerText || '').length");
                return $"webview=ready url={core.Source} title={title} nodes={nodes} textLen={textLen} state={StateText.Text}";
            }
            catch (Exception ex) { return "diag-error: " + ex.Message; }
        }

        private async Task BootAsync()
        {
            if (_booted) return;
            _booted = true;
            _url = ResolveWebappUrl();
            await ConnectAsync();
        }

        /// <summary>webapp 端口从 config.yaml 的 webapp 块读，缺省 9120（上游默认）。
        /// 不走 `hermes config get`——那要起一个 Python，窗口会干等一秒多。</summary>
        private static string ResolveWebappUrl()
        {
            var port = 9120;
            try
            {
                var cfg = Path.Combine(HermesCtl.HermesHome, "config.yaml");
                if (File.Exists(cfg))
                {
                    var inWebapp = false;
                    foreach (var raw in File.ReadAllLines(cfg))
                    {
                        if (raw.Length == 0 || raw[0] == ' ' || raw[0] == '\t')
                        {
                            if (inWebapp)
                            {
                                var t = raw.Trim();
                                if (t.StartsWith("port:", StringComparison.Ordinal))
                                {
                                    var v = t.Substring(5).Trim().Trim('"', '\'');
                                    if (int.TryParse(v, out var p) && p > 0 && p < 65536) port = p;
                                }
                            }
                            continue;
                        }
                        inWebapp = raw.TrimStart().StartsWith("webapp:", StringComparison.Ordinal);
                    }
                }
            }
            catch { }
            return $"http://127.0.0.1:{port}/";
        }

        private async Task ConnectAsync()
        {
            Overlay.Visibility = Visibility.Visible;
            View.Visibility = Visibility.Collapsed;
            BtnRetry.Visibility = Visibility.Collapsed;
            BtnOpenBrowser2.Visibility = Visibility.Collapsed;
            OverlayBar.Visibility = Visibility.Visible;
            StateText.Text = "";
            OverlayTitle.Text = "正在连接对话界面……";
            OverlayText.Text = "";

            if (!await ProbeAsync(_url))
            {
                OverlayBar.Visibility = Visibility.Collapsed;
                OverlayTitle.Text = "Gateway 没有在运行";
                OverlayText.Text = "对话界面由 Gateway 提供。回到主界面点「启动」，等状态变成「AI 在线」再重试。";
                BtnRetry.Visibility = Visibility.Visible;
                BtnOpenBrowser2.Visibility = Visibility.Visible;
                return;
            }

            try
            {
                var dataDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "HerMemory", "WebView2");
                Directory.CreateDirectory(dataDir);
                var env = await CoreWebView2Environment.CreateAsync(null, dataDir);
                await View.EnsureCoreWebView2Async(env);

                var core = View.CoreWebView2;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = true;
                core.Settings.IsZoomControlEnabled = true;
                // 页面里 target=_blank / 外链：交给系统浏览器，对话窗口只负责对话。
                core.NewWindowRequested += (_, e) =>
                {
                    e.Handled = true;
                    OpenExternal(e.Uri);
                };

                core.Navigate(_url);
                View.Visibility = Visibility.Visible;
                Overlay.Visibility = Visibility.Collapsed;
                StateText.Text = "已连接";
            }
            catch (Exception ex)
            {
                OverlayBar.Visibility = Visibility.Collapsed;
                OverlayTitle.Text = "对话界面无法启动";
                OverlayText.Text = "这台机器可能缺少 WebView2 运行时。\n\n"
                    + "可以直接用浏览器打开同一个地址，功能完全一样。\n\n"
                    + ex.GetType().Name + "：" + ex.Message;
                BtnRetry.Visibility = Visibility.Visible;
                BtnOpenBrowser2.Visibility = Visibility.Visible;
                StateText.Text = "不可用";
            }
        }

        private static async Task<bool> ProbeAsync(string url)
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(4) };
                using var resp = await http.GetAsync(url);
                return resp.IsSuccessStatusCode;
            }
            catch { return false; }
        }

        private void BtnReload_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (View.CoreWebView2 != null && View.Visibility == Visibility.Visible)
                {
                    View.CoreWebView2.Reload();
                    return;
                }
            }
            catch { }
            _booted = false;
            _ = BootAsync();
        }

        private void BtnRetry_Click(object sender, RoutedEventArgs e) => _ = ConnectAsync();

        private void BtnBrowser_Click(object sender, RoutedEventArgs e) => OpenExternal(_url);

        private static void OpenExternal(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        }
    }
}
