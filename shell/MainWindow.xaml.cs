using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace HerMemory
{
    public partial class MainWindow : Window
    {
        // —— 路径与环境 ——
        private string? _repoRoot;                    // 含 install.ps1 的发行版根目录
        private string HermesHome => Environment.GetEnvironmentVariable("HERMES_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "hermes");
        private string VaultDocs => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "vault", "HerMemory", "docs");
        private string HermsExe
        {
            get
            {
                var p = Path.Combine(HermesHome, "bin", "hermes.exe");
                return File.Exists(p) ? p : "hermes";
            }
        }

        private string? _answersPath;                 // 本次静默安装的答案文件（成功后删除）
        private string? _provBase, _provModel;
        private CancellationTokenSource? _qrCts;
        private System.Windows.Threading.DispatcherTimer? _tipTimer;

        /// <summary>托盘模式：默认开主界面（日常页），X 询问最小化/退出。</summary>
        public bool HomeMode { get; set; }
        /// <summary>托盘菜单"退出"置位：跳过最小化询问，真退出。</summary>
        public static bool ReallyExit;

        public MainWindow()
        {
            InitializeComponent();
            ThemeGlyph.Text = Theme.IsDark ? "☾" : "☀";
            Loaded += async (_, _) =>
            {
                if (HomeMode)
                {
                    ShowPage("PageHome");
                    UpdateHomeStatus(HermesCtl.State());
                }
                else
                {
                    await RunPrecheckAsync();
                }
            };
        }

        // ================= 主界面（托盘模式日常页） =================
        private System.Windows.Threading.DispatcherTimer? _homeTimer;

        /// <summary>托盘模式点"安装向导"：回向导首页重跑预检（本机已装时多步会自动跳过）。</summary>
        public void GoWelcome()
        {
            ShowFromTray();
            ShowPage("PageWelcome");
            PrecheckStatus.Text = "正在检查环境…";
            PrecheckStatus.Foreground = Brush("#78909C");
            BtnStart.IsEnabled = false;
            _ = RunPrecheckAsync();
        }

        public void UpdateHomeStatus(string state)
        {
            _lastState = state;
            HomeStatus.Text = state switch
            {
                "running" => "Gateway 运行中——AI 在线",
                "stopped" => "Gateway 已停止——AI 离线",
                _ => "Gateway 状态未知，请点重启",
            };
            HomeStatus.Foreground = Brush(state switch
            {
                "running" => "#2E7D32",
                "stopped" => "#90A4AE",
                _ => "#C62828",
            });
            UpdateTierTable();
            UpdateCfgRegion(state);
            WebDavStatus.Text = HermesCtl.WebDavRunning()
                ? "同步服务（WebDAV）：运行中"
                : "同步服务（WebDAV）：未运行";
        }

        private string _cfgState = "";
        private bool _cfgSaving;
        private string _lastState = "unknown";

        /// <summary>模型接口配置区：仅 Gateway 停止时可编辑；进入可编辑态自动加载当前配置。</summary>
        private void UpdateCfgRegion(string state, bool load = false)
        {
            var editable = state == "stopped";
            CfgUrl.IsEnabled = editable;
            CfgKey.IsEnabled = editable;
            CfgSave.IsEnabled = editable;
            CfgHint.Text = editable
                ? "Gateway 已停止，可修改；保存后启动生效。"
                : "Gateway 运行中，停止后可修改。";
            if (load || (editable && _cfgState != "stopped"))
            {
                _ = Task.Run(() =>
                {
                    var (url, _, key) = HermesCtl.GetModelCfg();
                    Dispatcher.Invoke(() => { CfgUrl.Text = url; CfgKey.Text = key; });
                });
            }
            _cfgState = state;
        }

        private async void CfgSave_Click(object sender, RoutedEventArgs e)
        {
            if (_cfgSaving) return;
            var url = new string(CfgUrl.Text.Where(c => c >= 0x21 && c <= 0x7E).ToArray()).TrimEnd('/');
            var key = new string(CfgKey.Text.Where(c => c >= 0x21 && c <= 0x7E).ToArray());
            if (url.Length == 0 || key.Length == 0) { CfgHint.Text = "请填写 API 地址与 API Key。"; return; }
            _cfgSaving = true;
            CfgHint.Text = "正在保存……";
            var ok = await Task.Run(() => HermesCtl.SetModelCfg(url, key));
            _cfgSaving = false;
            CfgHint.Text = ok ? "已保存，启动 Gateway 后生效。" : "保存失败，请重试。";
        }

        private async void UpdateTierTable()
        {
            var limit = ""; var usr = "";
            try
            {
                var outp = await Task.Run(() => HermesCtl.Run("config get memory.memory_char_limit", 20));
                limit = System.Text.RegularExpressions.Regex.Match(outp, @"(2200|5000|10000)").Groups[1].Value;
                var outp2 = await Task.Run(() => HermesCtl.Run("config get memory.user_char_limit", 20));
                usr = System.Text.RegularExpressions.Regex.Match(outp2, @"(1375|3000|5000)").Groups[1].Value;
            }
            catch { }
            await Dispatcher.InvokeAsync(() =>
            {
            HomeTierCurrent.Text = limit.Length > 0 && usr.Length > 0
                ? $"当前：MEMORY {limit} 字符 / USER {usr} 字符"
                : "";
            var std = (limit, usr) switch
            {
                ("2200", "1375") => 1,
                ("5000", "3000") => 2,
                ("10000", "5000") => 3,
                _ => 4,
            };
            var accent = System.Windows.Application.Current.Resources["Accent"] as System.Windows.Media.Brush ?? Brush("#0E7490");
            var gray = Brush("#546E7A");
            for (int i = 1; i <= 4; i++)
            {
                var on = i == std;
                var wm = FindName("TierM" + i) as TextBlock;
                var wu = FindName("TierU" + i) as TextBlock;
                if (i == 4)
                {
                    if (wm != null) { wm.Text = std == 4 ? limit : "/"; wm.FontWeight = on ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal; wm.Foreground = on ? accent : gray; }
                    if (wu != null) { wu.Text = std == 4 ? usr : "/"; wu.FontWeight = on ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal; wu.Foreground = on ? accent : gray; }
                    continue;
                }
                if (wm != null) { wm.FontWeight = on ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal; wm.Foreground = on ? accent : gray; }
                if (wu != null) { wu.FontWeight = on ? System.Windows.FontWeights.Bold : System.Windows.FontWeights.Normal; wu.Foreground = on ? accent : gray; }
                }
            });
        }

        private bool _homeBusy;

        private async void HomeCtl_Click(object sender, RoutedEventArgs e)
        {
            if (_homeBusy) return;
            _homeBusy = true;
            var cmd = sender == HomeStart ? "start" : sender == HomeStop ? "stop" : "restart";
            HomeStatus.Text = cmd == "stop" ? "正在停止…" : cmd == "restart" ? "正在重启…" : "正在启动…";
            HomeStatus.Foreground = Brush("#78909C");
            var pre = _lastState;
            await Task.Run(() => HermesCtl.Run($"gateway {cmd}", 120));
            var st = await Task.Run(HermesCtl.State);
            for (int i = 0; i < 3 && st == pre; i++)   // 状态未翻转则稍候重读（进程收尾有延迟）
            {
                await Task.Delay(1500);
                st = await Task.Run(HermesCtl.State);
            }
            _lastState = st;
            UpdateHomeStatus(st);
            _homeBusy = false;
        }

        // ================= 关闭行为：注册表勾选（托盘菜单可改）= 直接最小化；否则每次询问 =================
        protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
        {
            if (ReallyExit || !HomeMode) { base.OnClosing(e); return; }

            if (HermesCtl.CloseMinimizeEnabled()) { e.Cancel = true; HideToTray(); return; }

            // 未勾选（缺省）：每次都询问；勾"记住"并最小化 → 以后直接最小化（托盘菜单可改回）
            e.Cancel = true;
            var remember = false;
            var minimize = ShowCloseDialog(out remember);
            if (minimize)
            {
                if (remember) HermesCtl.SetCloseMinimize(true);
                HideToTray();
            }
            else { ReallyExit = true; Close(); }
        }

        // ================= 子页导航（主界面入口按钮） =================
        private void LinkMemory_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageMemory");
            UpdateTierTable();
        }

        private void LinkApi_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageApi");                       // 先切页面，数据异步跟随
            FocusCfg();
            _ = Task.Run(async () =>
            {
                var s = await Task.Run(HermesCtl.State);
                _lastState = s;
                await Dispatcher.InvokeAsync(() => UpdateCfgRegion(s, load: true));
            });
        }

        private void LinkWebdav_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageWebdav");
            WebDavStatus.Text = HermesCtl.WebDavRunning()
                ? "同步服务（WebDAV）：运行中"
                : "同步服务（WebDAV）：未运行";
        }

        private void FocusCfg()
        {
            Dispatcher.InvokeAsync(() =>
            {
                if (CfgUrl.IsEnabled)
                {
                    CfgUrl.Focus();
                    CfgUrl.CaretIndex = CfgUrl.Text.Length;
                }
            }, System.Windows.Threading.DispatcherPriority.Background);
        }

        private void BtnBack_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageHome");
            HomeStatus.Text = _lastState switch
            {
                "running" => "Gateway 运行中——AI 在线",
                "stopped" => "Gateway 已停止——AI 离线",
                _ => "Gateway 状态未知，请点重启",
            };
        }

        private void BtnTheme_Click(object sender, RoutedEventArgs e)
        {
            Theme.SetDark(!Theme.IsDark);
            ThemeGlyph.Text = Theme.IsDark ? "☾" : "☀";
        }

        private void HideToTray()
        {
            Hide();
            WindowState = WindowState.Minimized;
        }

        public void ShowFromTray()
        {
            Show();
            WindowState = WindowState.Normal;
            Activate();
        }

        /// <summary>关闭询问：最小化到托盘 / 退出；勾"记住"以后不再弹（托盘菜单可改回）。</summary>
        private bool ShowCloseDialog(out bool remember)
        {
            remember = false;
            var dlg = new Window
            {
                Title = "HerMemory",
                Width = 460,
                SizeToContent = SizeToContent.Height,
                MinHeight = 170,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Owner = this,
                ResizeMode = ResizeMode.NoResize,
                Background = new System.Windows.Media.SolidColorBrush(
                    (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FAFBFC")),
            };
            var rememberBox = new System.Windows.Controls.CheckBox
            {
                Content = "记住此选择，以后不再询问",
                FontSize = 12.5,
                Foreground = System.Windows.Media.Brushes.DimGray,
                Margin = new Thickness(0, 16, 0, 0),
            };
            string? result = null;
            var stack = new System.Windows.Controls.StackPanel { Margin = new Thickness(28, 24, 28, 20) };
            stack.Children.Add(new TextBlock
            {
                Text = "要退出 HerMemory，还是最小化到系统托盘？",
                FontSize = 14.5,
                TextWrapping = TextWrapping.Wrap,
                Foreground = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromArgb(255, 15, 23, 42)),
            });
            stack.Children.Add(new TextBlock
            {
                Text = "最小化后 AI 仍在后台运行。",
                FontSize = 12,
                Foreground = System.Windows.Media.Brushes.Gray,
                Margin = new Thickness(0, 6, 0, 0),
            });
            stack.Children.Add(rememberBox);
            var row = new System.Windows.Controls.StackPanel
            {
                Orientation = System.Windows.Controls.Orientation.Horizontal,
                HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
                Margin = new Thickness(0, 20, 0, 0),
            };
            var appRes = System.Windows.Application.Current.Resources;
            var bTray = new System.Windows.Controls.Button { Content = "最小化到托盘", Style = appRes["AccentButton"] as Style, FontSize = 13.5, Padding = new Thickness(18, 8, 18, 8) };
            var bExit = new System.Windows.Controls.Button { Content = "退出", Style = appRes["GhostButton"] as Style, FontSize = 13.5, Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(18, 8, 18, 8) };
            bTray.Click += (_, _) => { result = "tray"; dlg.Close(); };
            bExit.Click += (_, _) => { result = "exit"; dlg.Close(); };
            row.Children.Add(bTray);
            row.Children.Add(bExit);
            stack.Children.Add(row);
            dlg.Content = stack;
            dlg.ShowDialog();
            remember = rememberBox.IsChecked == true;
            return result == "tray";
        }

        private static string? ReadCloseAction()
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\HerMemory");
            return k?.GetValue("CloseAction") as string;
        }

        private static void WriteCloseAction(string action)
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\HerMemory");
            k.SetValue("CloseAction", action);
        }

        // ================= 页 1：预检 =================
        private async Task RunPrecheckAsync()
        {
            var notes = new List<string>();
            // 仓库定位：从 exe 所在目录逐级向上找 install.ps1
            _repoRoot = FindRepoRoot();
            notes.Add(_repoRoot != null
                ? "√ 安装源已就位"
                : "× 未找到 install.ps1——请把本程序放在发行版仓库目录内运行");

            bool git = await Task.Run(() => RunCapture("git", "--version") != null);
            notes.Add(git ? "√ git 已安装" : "× 缺 git：请先安装 Git for Windows（git-scm.com）");

            bool net = await Task.Run(async () =>
            {
                try
                {
                    using var h = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
                    using var r = new HttpRequestMessage(HttpMethod.Head, "https://github.com");
                    var resp = await h.SendAsync(r);
                    return true;
                }
                catch { return false; }
            });
            notes.Add(net ? "√ 网络可达 GitHub" : "× 无法连上 GitHub——请开一次代理后再安装（安装完成后日常使用不再需要）");

            bool allOk = _repoRoot != null && git && net;
            PrecheckStatus.Text = string.Join(Environment.NewLine, notes);
            PrecheckStatus.Foreground = new System.Windows.Media.SolidColorBrush(allOk
                ? (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#2E7D32")
                : (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#C62828"));
            BtnStart.IsEnabled = allOk;
        }

        private static string? FindRepoRoot()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            for (int hop = 0; dir != null && hop < 6; hop++, dir = dir.Parent)
            {
                if (File.Exists(Path.Combine(dir.FullName, "install.ps1"))) return dir.FullName;
            }
            return null;
        }

        private void ShowPage(string name)
        {
            foreach (var child in ((Grid)Content).Children)
                if (child is Grid g) g.Visibility = g.Name == name ? Visibility.Visible : Visibility.Collapsed;
        }

        // ================= 页 2：参数 =================
        private void BtnStart_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageParams");
        }

        private void BtnDocs_Click(object sender, RoutedEventArgs e)
        {
            var docs = Path.Combine(VaultDocs);
            if (!Directory.Exists(docs) && _repoRoot != null) docs = Path.Combine(_repoRoot, "docs");
            if (Directory.Exists(docs)) Process.Start(new ProcessStartInfo("explorer.exe", $"\"{docs}\"") { UseShellExecute = true });
        }

        private async void BtnModels_Click(object sender, RoutedEventArgs e)
        {
            var url = CleanAscii(UrlBox.Text).TrimEnd('/');
            var key = CleanAscii(KeyBox.Text);
            if (url.Length == 0 || key.Length == 0)
            {
                ParamStatus.Text = "请填写 API 地址与 API Key。";
                ParamStatus.Foreground = Brush("#C62828");
                return;
            }
            BtnModels.IsEnabled = false;
            ParamStatus.Text = "正在获取模型列表……";
            ParamStatus.Foreground = Brush("#78909C");
            var (code, body) = await Task.Run(() => CurlModels(url, key));
            List<string> ids = new();
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var arr) && arr.ValueKind == JsonValueKind.Array)
                    foreach (var m in arr.EnumerateArray())
                        if (m.TryGetProperty("id", out var id)) ids.Add(id.GetString() ?? "");
            }
            catch { }
            ids = ids.Where(s => s.Length > 0).Distinct().ToList();
            if (code == "200" && ids.Count > 0)
            {
                ModelCombo.ItemsSource = ids;
                ModelCombo.SelectedIndex = 0;
                ParamStatus.Text = $"已获取 {ids.Count} 个可用模型，请选择默认模型。";
                ParamStatus.Foreground = Brush("#2E7D32");
            }
            else if (code == "401" || code == "403")
            {
                ParamStatus.Text = $"[{code}] 认证未通过，请检查 API Key。";
                ParamStatus.Foreground = Brush("#C62828");
            }
            else if (code == "000" || code.Length == 0)
            {
                ParamStatus.Text = "[连接超时] 无法连接该地址，请检查网络或代理设置。";
                ParamStatus.Foreground = Brush("#C62828");
            }
            else
            {
                ParamStatus.Text = $"[{code}] 获取失败，请核对地址与 Key。";
                ParamStatus.Foreground = Brush("#C62828");
            }
            BtnModels.IsEnabled = true;
        }

        private void BtnNext_Click(object sender, RoutedEventArgs e)
        {
            var url = CleanAscii(UrlBox.Text).TrimEnd('/');
            var key = CleanAscii(KeyBox.Text);
            var model = ModelCombo.SelectedItem as string ?? "";
            if (url.Length == 0 || key.Length == 0 || model.Length == 0)
            {
                ParamStatus.Text = "请完整填写地址与 Key，并选择模型。";
                ParamStatus.Foreground = Brush("#C62828");
                return;
            }
            _provBase = url;
            _provModel = model;
            var tier = Tier1.IsChecked == true ? "1" : Tier2.IsChecked == true ? "2" : "3";
            StartInstall(tier, url, key, model);
        }

        // ================= 页 3：安装 =================
        private static readonly Dictionary<string, int> ProgressMap = new()
        {
            ["precheck"] = 5, ["upstream"] = 45, ["files"] = 55, ["memory-tier"] = 62,
            ["config-ai"] = 78, ["wechat"] = 82, ["gateway"] = 92, ["done"] = 100
        };

        private void StartInstall(string tier, string url, string key, string model)
        {
            ShowPage("PageInstall");
            InstallBar.Value = 2;
            InstallTitle.Text = "正在安装，首次约 5-10 分钟。";
            InstallDetail.Text = "";
            StartTips();

            Task.Run(async () =>
            {
                try
                {
                    // 1. 答案文件（key 明文短暂落盘，成功后即删）
                    _answersPath = Path.Combine(Path.GetTempPath(), $"hermemory-answers-{Guid.NewGuid():N}.json");
                    var payload = JsonSerializer.Serialize(new Dictionary<string, string>
                    {
                        ["memoryTier"] = tier, ["baseUrl"] = url, ["apiKey"] = key, ["model"] = model
                    });
                    await File.WriteAllTextAsync(_answersPath, payload, new UTF8Encoding(false));

                    // 2. 静默安装
                    var psi = new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{Path.Combine(_repoRoot!, "install.ps1")}\" -AnswersFile \"{_answersPath}\"",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true,
                        StandardOutputEncoding = Encoding.UTF8,
                    };
                    int exit;
                    using (var p = Process.Start(psi)!)
                    {
                        p.OutputDataReceived += (_, a) =>
                        {
                            if (a.Data == null) return;
                            var line = a.Data;
                            if (line.StartsWith("##HM-PROGRESS## "))
                            {
                                var step = line["##HM-PROGRESS## ".Length..].Trim();
                                if (ProgressMap.TryGetValue(step, out var pct))
                                    Dispatcher.Invoke(() => InstallBar.Value = pct);
                            }
                            else
                            {
                                Dispatcher.Invoke(() => InstallDetail.Text = line);
                            }
                        };
                        p.BeginErrorReadLine();
                        p.BeginOutputReadLine();
                        await p.WaitForExitAsync();
                        exit = p.ExitCode;
                    }

                    if (exit != 0)
                    {
                        Dispatcher.Invoke(() =>
                        {
                            InstallTitle.Text = "安装未成功";
                            InstallDetail.Text += Environment.NewLine + "已完成步骤将自动跳过；排除问题后点击“重新安装”继续。";
                        });
                        // 答案文件保留：续装还要用（成功才删）
                        Dispatcher.Invoke(() => AddRetryButton());
                        return;
                    }

                    // 成功：用完即删
                    try { File.Delete(_answersPath); } catch { }
                    _answersPath = null;

                    // 3. 微信扫码
                    StopTips();
                    Dispatcher.Invoke(() => { ShowPage("PageQr"); StartQrFlow(); });
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() =>
                    {
                        InstallTitle.Text = "安装出错";
                        InstallDetail.Text = ex.Message;
                        AddRetryButton();
                    });
                }
            });
        }

        private void StartTips()
        {
            var lines = new List<string>();
            try
            {
                if (_repoRoot != null)
                    lines.AddRange(File.ReadAllLines(Path.Combine(_repoRoot, "docs", "INSTALL_TIPS.md"))
                        .Select(l => l.Trim())
                        .Where(l => l.Length > 0 && !l.StartsWith("#")));
            }
            catch { }
            if (lines.Count == 0) lines.Add("安装进行中，请稍候。");
            var i = 0;
            InstallTip.Text = "提示：" + lines[0];
            _tipTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            _tipTimer.Tick += (_, _) => { i = (i + 1) % lines.Count; InstallTip.Text = "提示：" + lines[i]; };
            _tipTimer.Start();
        }

        private void StopTips() => _tipTimer?.Stop();

        private void AddRetryButton()
        {
            StopTips();

            if (InstallTitle.Text != "安装未成功" && InstallTitle.Text != "安装出错") return;
            // 复用扫码页的重试思路：这里直接放一个"重新安装"按钮
            var btn = new System.Windows.Controls.Button { Content = "重新安装", Style = (Style)Resources["AccentButton"], Margin = new Thickness(0, 18, 0, 0) };
            btn.Click += (_, _) =>
            {
                ((StackPanel)InstallTitle.Parent).Children.Remove(btn);
                ShowPage("PageParams");
            };
            ((StackPanel)InstallTitle.Parent).Children.Add(btn);
        }

        // ================= 页 4：微信扫码 =================
        private void StartQrFlow() => Task.Run(() => WeChatFlowAsync().Wait());

        private async Task WeChatFlowAsync()
        {
            _qrCts = new CancellationTokenSource(TimeSpan.FromMinutes(8));
            var ct = _qrCts.Token;

            SetQr("正在检查微信接入状态……");
            if (EnvHasWeixin()) { await AfterWechatAsync(); return; }

            SetQr("正在启动微信接入，浏览器将自动打开二维码页面。");
            try
            {
                bool urlOpened = false;
                var psi = new ProcessStartInfo
                {
                    FileName = HermsExe,
                    Arguments = "gateway setup",
                    UseShellExecute = false,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                };
                psi.EnvironmentVariables["NO_COLOR"] = "1"; // 颜色码会污染 URL 提取与关键词答题
                using var p = Process.Start(psi)!;
                StdinWriter = p.StandardInput;
                StdinWriter.AutoFlush = true;
                var readerTask = Task.Run(() =>
                {
                    try
                    {
                        while (!p.StandardOutput.EndOfStream)
                        {
                            var line = p.StandardOutput.ReadLine();
                            if (line == null) break;
                            // 自动开浏览器：提取二维码链接
                            var idx = line.IndexOf("https://liteapp.weixin.qq.com", StringComparison.OrdinalIgnoreCase);
                            if (!urlOpened && idx >= 0)
                            {
                                var url = line[idx..].Trim();
                                var end = url.IndexOfAny(new[] { ' ', '\t', ')', '\x1b' });
                                if (end > 0) url = url[..end];
                                try
                                {
                                    Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                                    urlOpened = true;
                                    SetQr("二维码已在浏览器打开，请使用微信扫码确认，8 分钟内有效。");
                                }
                                catch { }
                            }
                            FeedWizardAnswer(line);
                        }
                    }
                    catch { }
                });
                _ = Task.Run(() => { try { p.StandardError.ReadToEnd(); } catch { } });

                // 轮询 .env 等凭据落盘
                while (!ct.IsCancellationRequested)
                {
                    if (EnvHasWeixin()) break;
                    await Task.Delay(2000, CancellationToken.None);
                }
                try { if (!p.HasExited) p.Kill(true); } catch { }

                if (ct.IsCancellationRequested && !EnvHasWeixin())
                {
                    SetQr("二维码已超时或未完成扫码。");
                    Dispatcher.Invoke(() => BtnQrRetry.Visibility = Visibility.Visible);
                    return;
                }

                ApplyAllowlist();
                await AfterWechatAsync();
            }
            catch (Exception ex)
            {
                SetQr("微信接入异常：" + ex.Message);
                Dispatcher.Invoke(() => BtnQrRetry.Visibility = Visibility.Visible);
            }
        }

        // 向导自动答题：按上游 gateway setup 的题目关键词喂答案
        private void FeedWizardAnswer(string line)
        {
            string? answer = null;
            if (line.Contains("Select platform", StringComparison.OrdinalIgnoreCase))
            {
                // 平台菜单：找出含 weixin/wechat 的选项序号
                answer = null; // 序号在后续菜单行里给出，见下
            }
            if (System.Text.RegularExpressions.Regex.IsMatch(line, @"^\s*\d+[\.\)]") &&
                line.Contains("weixin", StringComparison.OrdinalIgnoreCase))
            {
                var num = System.Text.RegularExpressions.Regex.Match(line, @"^\s*(\d+)").Groups[1].Value;
                answer = num;
            }
            else if (line.Contains("Start QR login", StringComparison.OrdinalIgnoreCase))
            {
                answer = ""; // 回车确认
            }
            else if (line.Contains("direct messages", StringComparison.OrdinalIgnoreCase))
            {
                answer = "3"; // allowlist
            }
            else if (line.Contains("user IDs", StringComparison.OrdinalIgnoreCase))
            {
                answer = ""; // 预填
            }
            else if (line.Contains("group chats", StringComparison.OrdinalIgnoreCase))
            {
                answer = "1"; // 禁用群聊
            }
            if (answer != null)
            {
                try { StdinWriter?.WriteLine(answer); StdinWriter?.Flush(); } catch { }
            }
        }

        private StreamWriter? StdinWriter;

        private void SetQr(string text) => Dispatcher.Invoke(() => QrStatus.Text = text);

        private bool EnvHasWeixin()
        {
            try
            {
                var env = Path.Combine(HermesHome, ".env");
                return File.Exists(env) && File.ReadAllLines(env).Any(l => l.StartsWith("WEIXIN_ACCOUNT_ID=", StringComparison.Ordinal));
            }
            catch { return false; }
        }

        // 与 install.ps1 相同的 allowlist 兜底：防止向导默认 pairing 拦截首条消息
        private void ApplyAllowlist()
        {
            try
            {
                var envFile = Path.Combine(HermesHome, ".env");
                var acctDir = Path.Combine(HermesHome, "weixin", "accounts");
                string wxUserId = "";
                var latest = new DirectoryInfo(acctDir).Exists
                    ? new DirectoryInfo(acctDir).GetFiles("*.json").OrderBy(f => f.LastWriteTime).LastOrDefault()
                    : null;
                if (latest != null)
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(File.ReadAllText(latest.FullName));
                        if (doc.RootElement.TryGetProperty("user_id", out var uid)) wxUserId = uid.GetString() ?? "";
                    }
                    catch { }
                }
                if (wxUserId.Length == 0) return;
                var lines = new List<string>(File.Exists(envFile) ? File.ReadAllLines(envFile) : Array.Empty<string>());
                void Upsert(string key, string val)
                {
                    int i = lines.FindIndex(l => l.StartsWith(key + "=", StringComparison.Ordinal));
                    if (i >= 0) lines[i] = $"{key}={val}"; else lines.Add($"{key}={val}");
                }
                Upsert("WEIXIN_DM_POLICY", "allowlist");
                Upsert("WEIXIN_ALLOWED_USERS", wxUserId);
                File.WriteAllLines(envFile, lines, new UTF8Encoding(false));
                SetQr("微信已连接，消息授权仅限当前微信 ID。");
            }
            catch { }
        }

        private async Task AfterWechatAsync()
        {
            // gateway 服务（计划任务）缺则补装；失败不阻塞完成
            SetQr("检查 gateway 服务……");
            bool taskExists = await Task.Run(() =>
            {
                var r = RunCapture("schtasks", "/Query /FO LIST");
                return r != null && r.Contains("hermes", StringComparison.OrdinalIgnoreCase);
            });
            if (!taskExists)
            {
                SetQr("正在安装 gateway 服务，约一两分钟。");
                await Task.Run(() => RunCapture(HermsExe, "gateway install", 600));
            }

            var warn = taskExists ? "" : "gateway 计划任务未注册，不影响微信使用，可稍后补装。";
            Dispatcher.Invoke(() =>
            {
                DoneText.Text = "HerMemory 已就绪。" + warn + Environment.NewLine +
                    "在微信发送首条消息，AI 将自我介绍并引导完成剩余部署。" + Environment.NewLine +
                    "② 记忆是纯文本：vault\\HerMemory\\memory\\ 下任何文件随时可看可改，开新对话即生效。";
                ShowPage("PageDone");
            });
        }

        private void BtnQrRetry_Click(object sender, RoutedEventArgs e)
        {
            BtnQrRetry.Visibility = Visibility.Collapsed;
            StartQrFlow();
        }

        private void BtnQrSkip_Click(object sender, RoutedEventArgs e)
        {
            _qrCts?.Cancel();
            Dispatcher.Invoke(() =>
            {
                DoneText.Text = "安装完成，微信暂未接入。" + Environment.NewLine +
                    "可随时重新接入：运行 gateway-run.bat 或重新运行安装向导。";
                ShowPage("PageDone");
            });
        }

        // ================= 页 5：完成 =================
        private void BtnGuide_Click(object sender, RoutedEventArgs e)
        {
            var candidates = new[]
            {
                Path.Combine(VaultDocs, "GUIDE.md"),
                _repoRoot == null ? "" : Path.Combine(_repoRoot, "docs", "GUIDE.md"),
            };
            foreach (var g in candidates)
            {
                if (g.Length == 0 || !File.Exists(g)) continue;
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{g}\"") { UseShellExecute = true });
                return;
            }
            var dir = Directory.Exists(VaultDocs) ? VaultDocs
                : (_repoRoot != null && Directory.Exists(Path.Combine(_repoRoot, "docs")) ? Path.Combine(_repoRoot, "docs") : "");
            if (dir.Length > 0)
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dir}\"") { UseShellExecute = true });
        }

        private void BtnFinish_Click(object sender, RoutedEventArgs e) => Close();

        // ================= 卸载 =================
        private static string VaultDir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "vault");

        private void BtnUninstall_Click(object sender, RoutedEventArgs e)
        {
            _homeTimer?.Stop();
            ShowPage("PageUninstall");
        }

        private void BtnUninsCancel_Click(object sender, RoutedEventArgs e)
        {
            UninsBar.Visibility = Visibility.Collapsed;
            ShowPage(HomeMode ? "PageHome" : "PageWelcome");
            if (HomeMode) UpdateHomeStatus(HermesCtl.State());
        }

        private void BtnUninsRun_Click(object sender, RoutedEventArgs e)
        {
            var delVault = UninsVault.IsChecked == true;
            var delExe = UninsExe.IsChecked == true;
            if (delVault)
            {
                var r = System.Windows.MessageBox.Show(this,
                    "最后确认：删除整个 vault？其中为全部文档与 AI 记忆，删除后不可恢复。",
                    "删除 vault", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
                if (r != MessageBoxResult.Yes) { UninsVault.IsChecked = false; return; }
            }
            BtnUninsRun.IsEnabled = false;
            BtnUninsCancel.IsEnabled = false;
            UninsBar.Visibility = Visibility.Visible;
            UninsBar.Value = 2;
            _ = Task.Run(() => DoUninstall(delVault, delExe));
        }

        private void SetUnins(string text, int? pct = null) => Dispatcher.Invoke(() =>
        {
            UninsStatus.Text = text;
            if (pct.HasValue) UninsBar.Value = pct.Value;
        });

        private void DoUninstall(bool delVault, bool delExe)
        {
            SetUnins("停止网关……", 5);
            HermesCtl.Run("gateway stop", 60);

            SetUnins("移除登录项与计划任务……", 15);
            try
            {
                var vbs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "Hermes_Gateway.vbs");
                if (File.Exists(vbs)) File.Delete(vbs);
            }
            catch { }
            try
            {
                var q = HermesCtl.RunCaptureRaw("schtasks", "/Query /FO LIST", 30) ?? "";
                foreach (System.Text.RegularExpressions.Match m in
                    System.Text.RegularExpressions.Regex.Matches(q, @"TaskName:\s*(\S*hermes\S*)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                {
                    HermesCtl.RunCaptureRaw("schtasks", $"/Delete /TN \"{m.Groups[1].Value}\" /F", 30);
                }
            }
            catch { }

            SetUnins("移除自启项与偏好设置……", 25);
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                    k?.DeleteValue("HerMemory", false);
                Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(@"Software\HerMemory", false);
            }
            catch { }

            SetUnins("移除注入槽位……", 35);
            try
            {
                var slot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".hermes.md");
                if (File.Exists(slot) && ((new FileInfo(slot).Attributes & FileAttributes.ReparsePoint) != 0
                    || new FileInfo(slot).Length == 0)) File.Delete(slot);
            }
            catch { }

            var hh = HermesCtl.HermesHome;
            if (Directory.Exists(hh))
            {
                var tops = Directory.GetFileSystemEntries(hh);
                for (int i = 0; i < tops.Length; i++)
                {
                    SetUnins($"正在移除内核与配置……", 35 + (int)(45.0 * (i + 1) / tops.Length));
                    try
                    {
                        if (Directory.Exists(tops[i])) Directory.Delete(tops[i], true);
                        else File.Delete(tops[i]);
                    }
                    catch { }
                }
                try { Directory.Delete(hh, true); } catch { }
            }

            var pct = 80;
            if (delVault)
            {
                SetUnins("删除 vault……", pct);
                try { if (Directory.Exists(VaultDir)) Directory.Delete(VaultDir, true); } catch { }
                pct = 92;
            }

            if (delExe)
            {
                // 自删：进程退出后由 cmd 延迟删除 exe 自身
                var exe = Environment.ProcessPath;
                if (exe != null && File.Exists(exe))
                {
                    try
                    {
                        Process.Start(new ProcessStartInfo("cmd.exe",
                            $"/c ping -n 3 127.0.0.1 > nul & del /f /q \"{exe}\"")
                        { CreateNoWindow = true, UseShellExecute = false });
                    }
                    catch { }
                }
            }

            SetUnins("卸载完成。", 100);
            Dispatcher.Invoke(() =>
            {
                UninsStatus.Text = delExe ? "卸载完成——本程序文件也将被移除。" : "卸载完成，已移除全部软件痕迹" + (delVault ? "。" : "；vault 已保留。");
                BtnUninsClose.Visibility = Visibility.Visible;
            });
        }

        private void BtnUninsDone_Click(object sender, RoutedEventArgs e) => App.RequestExit();

        public void ShowUninstall()
        {
            _homeTimer?.Stop();
            ShowPage("PageUninstall");
        }

        // ================= 工具 =================
        private static string CleanAscii(string s) =>
            new string(s.Where(c => c >= 0x21 && c <= 0x7E).ToArray());

        private static System.Windows.Media.Brush Brush(string hex) =>
            new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));

        private static string? RunCapture(string exe, string args, int timeoutSec = 30)
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

        private static (string code, string body) CurlModels(string url, string key)
        {
            var tmp = Path.Combine(Path.GetTempPath(), "hm-models-exe.json");
            string Run(string extra)
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "curl.exe",
                    Arguments = $"-sL {extra} --max-time 20 -o \"{tmp}\" -w \"%{{http_code}}\" \"{url}/models\" -H \"Authorization: Bearer {key}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true,
                };
                using var p = Process.Start(psi)!;
                var code = p.StandardOutput.ReadToEnd().Trim();
                p.WaitForExit(30000);
                return code;
            }
            var code = Run("--noproxy \"*\"");
            if (code == "000") code = Run("");
            var body = File.Exists(tmp) ? File.ReadAllText(tmp) : "";
            return (code, body);
        }
    }
}
