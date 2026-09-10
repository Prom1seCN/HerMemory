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
        private string? _answersPath;                 // 本次静默安装的答案文件（成功后删除）
        private string? _provBase, _provModel;
        private CancellationTokenSource? _qrCts;
        private System.Windows.Threading.DispatcherTimer? _tipTimer;

        /// <summary>托盘模式：默认开主界面（日常页），X 询问最小化/退出。</summary>
        public bool HomeMode { get; set; }
        /// <summary>托盘菜单"退出"置位：跳过最小化询问，真退出。</summary>
        public static bool ReallyExit;

        /// <summary>本程序 exe 路径。单文件发布下 Assembly.Location 恒为空字符串（IL3000），只能用 ProcessPath。</summary>
        private static string SelfPath => Environment.ProcessPath ?? "";

        public MainWindow()
        {
            InitializeComponent();
            // 标题栏保持纯名字（用户定：不显示构建时间戳）
            ThemeGlyph.Text = Theme.IsDark ? "☾" : "☀";
            Loaded += async (_, _) =>
            {
                ApplyGirlIcon();   // 右上角女孩图标：随主题（Assets 为相对路径，用绝对资源文件流加载）
                if (HomeMode) GoHome();
                else await RunPrecheckAsync();
            };
        }

        /// <summary>进入日常主界面：置 HomeMode、显示首页、刷新网关状态。
        /// 构造 Loaded 与完成页「完成」按钮共用（运行中切换不会自动触发 Loaded）。</summary>
        public void GoHome()
        {
            HomeMode = true;
            ShowPage("PageHome");
            HomeFooter.Text = string.Join(Environment.NewLine,
                "关闭窗口默认最小化到托盘，可在托盘菜单修改",
                $"同步库位于 {VaultDir}",
                $"记忆文件位于 {Path.Combine(VaultDir, "HerMemory", "memory")}");
            _ = Task.Run(async () =>
            {
                var s = await Task.Run(HermesCtl.State);
                await Dispatcher.InvokeAsync(() => UpdateHomeStatus(s));
            });
        }

        /// <summary>安装成功：置为日常态（关窗走"最小化到托盘"），但停在完成页——点「完成」才进主界面。</summary>
        public void PrepareHome() => HomeMode = true;

        // ================= 主界面（托盘模式日常页） =================

        /// <summary>托盘模式点"安装向导"：回向导首页重跑预检（本机已装时多步会自动跳过）。</summary>
        public void GoWelcome()
        {
            ShowFromTray();
            ShowPage("PageWelcome");
            PrecheckStatus.Text = "正在检查环境……";
            PrecheckStatus.Foreground = Brush("#78909C");
            BtnStart.IsEnabled = false;
            _ = RunPrecheckAsync();
        }

        public void UpdateHomeStatus(string state)
        {
            _lastState = state;
            HomeStatus.Text = state switch
            {
                "running" => "Gateway 运行中，AI 在线",
                _ => "Gateway 已停止，AI 离线",
            };
            HomeStatus.Foreground = Brush(state == "running" ? "#2E7D32" : "#90A4AE");
            UpdateTierTable();
            UpdateCfgRegion(state);
            WebDavStatus.Text = HermesCtl.WebDavRunning()
                ? "同步服务（WebDAV）：运行中"
                : "同步服务（WebDAV）：未运行";
        }

        private string _cfgState = "";
        private bool _cfgSaving;
        private string _lastState = "unknown";

        /// <summary>模型接口配置区：字段恒可用（光标恒在）；保存时校验 Gateway 已停止。进页回显当前默认模型。</summary>
        private void UpdateCfgRegion(string state, bool load = false)
        {
            string baseHint = state == "stopped"
                ? "Gateway 已停止，可修改；保存后启动生效。"
                : "Gateway 运行中；修改可保存，保存后需停止再启动才生效。";
            CfgHint.Text = baseHint;
            if (load || (state == "stopped" && _cfgState != "stopped"))
            {
                _ = Task.Run(() =>
                {
                    var (url, _, key) = HermesCtl.GetModelCfg();
                    var def = "";
                    try { def = HermesCtl.Run("config get model.default", 20).Trim().Trim('"'); } catch { }
                    Dispatcher.Invoke(() =>
                    {
                        CfgUrl.Text = url;
                        CfgKey.Text = key;
                        if (def.Length > 0 && def.Length < 80 && !def.Contains("not set", StringComparison.OrdinalIgnoreCase))
                            CfgHint.Text = baseHint + $"当前默认模型：{def}，可获取列表后切换。";
                    });
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
            // 运行中同样允许保存：hermes config set 写的是配置文件，不影响正在跑的进程；
            // 文案已承诺"可保存"（UpdateCfgRegion），此处不得拒绝——否则出现"能编辑但保存不了"的死结。
            var state = await Task.Run(HermesCtl.State);
            var ok2 = await Task.Run(() => HermesCtl.SetModelCfg(url, key));
            var model = CleanAscii(CfgModelCombo.SelectedItem as string ?? "");
            if (ok2 && model.Length > 0)
                await Task.Run(() => HermesCtl.Run($"config set model.default \"{model}\"", 30));
            _cfgSaving = false;
            CfgHint.Foreground = Brush(ok2 ? "#2E7D32" : "#C62828");
            if (!ok2) { CfgHint.Text = "保存失败，请重试。"; return; }
            var suffix = model.Length > 0 ? $"（默认模型：{model}）" : "";
            CfgHint.Text = state == "running"
                ? $"已保存{suffix}；Gateway 正在运行，需停止后重新启动才生效。"
                : $"已保存{suffix}，启动 Gateway 后生效。";
            _cfgState = state;
        }

        /// <summary>API 设置页 · 地址检测：与向导同一实现（ProbeUrl，探 {url}/models；无 Key 时 401 也算地址可达）。</summary>
        private async void CfgCheck_Click(object sender, RoutedEventArgs e)
        {
            var url = CleanAscii(CfgUrl.Text).TrimEnd('/');
            if (url.Length == 0)
            {
                CfgHint.Text = "请先填写 API 地址。";
                CfgHint.Foreground = Brush("#C62828");
                return;
            }
            CfgCheck.IsEnabled = false;
            CfgHint.Text = "正在检测地址……";
            CfgHint.Foreground = Brush("#78909C");
            var (level, msg) = await Task.Run(() => ProbeUrl(url, ""));
            CfgHint.Text = msg;
            CfgHint.Foreground = Brush(level == 0 ? "#C62828" : level == 1 ? "#EF6C00" : "#2E7D32");
            CfgCheck.IsEnabled = true;
        }

        /// <summary>API 设置页 · 拉模型列表：与向导同一实现（CurlModels），选中后随"保存"写入 model.default。</summary>
        private async void CfgFetchModels_Click(object sender, RoutedEventArgs e)
        {
            var url = CleanAscii(CfgUrl.Text).TrimEnd('/');
            var key = CleanAscii(CfgKey.Text);
            if (url.Length == 0 || key.Length == 0)
            {
                CfgHint.Text = "请先填写 API 地址与 API Key。";
                CfgHint.Foreground = Brush("#C62828");
                return;
            }
            CfgFetchModels.IsEnabled = false;
            CfgHint.Text = "正在获取模型列表……";
            CfgHint.Foreground = Brush("#78909C");
            var (code, body) = await Task.Run(() => CurlModels(url, key));
            var ids = new List<string>();
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
                CfgModelCombo.ItemsSource = ids;
                CfgModelCombo.SelectedIndex = 0;
                CfgHint.Text = $"已获取 {ids.Count} 个可用模型，选中后保存即切换默认模型。";
                CfgHint.Foreground = Brush("#2E7D32");
            }
            else
            {
                CfgHint.Text = code == "401" || code == "403" ? $"[{code}] 认证未通过，请检查 API Key。"
                    : code == "000" || code.Length == 0 ? "[连接超时] 无法连接该地址。"
                    : $"[{code}] 获取失败，请核对地址与 Key。";
                CfgHint.Foreground = Brush("#C62828");
            }
            CfgFetchModels.IsEnabled = true;
        }

        private async void UpdateTierTable()
        {
            var limit = ""; var usr = "";
            try
            {
                var outp = await Task.Run(() => HermesCtl.Run("config get memory.memory_char_limit", 20));
                limit = System.Text.RegularExpressions.Regex.Match(outp, @"(\d{3,7})").Groups[1].Value;
                var outp2 = await Task.Run(() => HermesCtl.Run("config get memory.user_char_limit", 20));
                usr = System.Text.RegularExpressions.Regex.Match(outp2, @"(\d{3,7})").Groups[1].Value;
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
            var cmd = sender == HomeStart ? "start" : "stop";
            HomeStatus.Text = cmd == "stop" ? "正在停止……" : "正在启动……";
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

        /// <summary>刷新：立即重取 Gateway/WebDAV/档位/配置区状态（与 10s 托盘轮询同一入口）。</summary>
        private async void BtnRefresh_Click(object sender, RoutedEventArgs e)
        {
            if (_homeBusy) return;
            _homeBusy = true;
            HomeStatus.Text = "正在刷新……";
            HomeStatus.Foreground = Brush("#78909C");
            var st = await Task.Run(HermesCtl.State);
            _lastState = st;
            UpdateHomeStatus(st);
            _homeBusy = false;
        }

        // ================= 一键导出（原生实现，包结构与 export.sh 一致） =================
        private bool _exporting;

        private void BtnExport_Click(object sender, RoutedEventArgs e) => ShowExportDialog();

        private void ShowExportDialog()
        {
            if (_exporting) return;
            _exporting = true;
            var appRes = System.Windows.Application.Current.Resources;
            var dlg = new Window
            {
                Title = "一键导出",
                Width = 540,
                SizeToContent = SizeToContent.Height,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Owner = this,
                ResizeMode = ResizeMode.NoResize,
                Background = appRes["WindowBg"] as System.Windows.Media.Brush,
            };
            var status = new TextBlock
            {
                Text = "正在准备导出……",
                FontSize = 13.5,
                TextWrapping = TextWrapping.Wrap,
                Foreground = appRes["Ink"] as System.Windows.Media.Brush,
            };
            var bar = new System.Windows.Controls.ProgressBar
            {
                Height = 8,
                IsIndeterminate = true,
                Margin = new Thickness(0, 16, 0, 0),
            };
            var pathText = new TextBlock
            {
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = System.Windows.Media.Brushes.Gray,
                Margin = new Thickness(0, 10, 0, 0),
                Visibility = Visibility.Collapsed,
            };
            string? zipPath = null;
            var btnOpen = new System.Windows.Controls.Button
            {
                Content = "打开所在文件夹",
                Style = appRes["AccentButton"] as Style,
                FontSize = 13.5,
                Padding = new Thickness(18, 8, 18, 8),
                Visibility = Visibility.Collapsed,
            };
            btnOpen.Click += (_, _) =>
            {
                if (zipPath != null)
                    Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{zipPath}\"") { UseShellExecute = true });
            };
            var btnClose = new System.Windows.Controls.Button
            {
                Content = "关闭",
                Style = appRes["GhostButton"] as Style,
                FontSize = 13.5,
                Margin = new Thickness(12, 0, 0, 0),
                Padding = new Thickness(18, 8, 18, 8),
            };
            btnClose.Click += (_, _) => dlg.Close();
            var row = new System.Windows.Controls.StackPanel
            {
                Orientation = System.Windows.Controls.Orientation.Horizontal,
                HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
                Margin = new Thickness(0, 18, 0, 0),
            };
            row.Children.Add(btnOpen);
            row.Children.Add(btnClose);
            var stack = new System.Windows.Controls.StackPanel { Margin = new Thickness(28, 24, 28, 20) };
            stack.Children.Add(status);
            stack.Children.Add(bar);
            stack.Children.Add(pathText);
            stack.Children.Add(row);
            dlg.Content = stack;
            dlg.Closed += (_, _) => _exporting = false;

            void Report(string m) => Dispatcher.Invoke(() => status.Text = m);

            _ = Task.Run(() =>
            {
                var (ok, msg, zip) = DoExport(Report);
                Dispatcher.Invoke(() =>
                {
                    bar.IsIndeterminate = false;
                    bar.Value = ok ? 100 : 0;
                    status.Text = msg;
                    if (ok && zip != null)
                    {
                        zipPath = zip;
                        pathText.Text = zip;
                        pathText.Visibility = Visibility.Visible;
                        btnOpen.Visibility = Visibility.Visible;
                    }
                });
            });
            dlg.ShowDialog();
        }

        /// <summary>导出主流程：vault 拷贝 + hermes backup 热备 + README_REBORN → staging → zip 到桌面。
        /// 包结构与 export.sh 一致：zip 内单一顶层目录 hermemory-export-&lt;时间戳&gt;/{vault/, hermes-home.zip, README_REBORN.md}。</summary>
        private (bool ok, string msg, string? zip) DoExport(Action<string> report)
        {
            try
            {
                var vault = VaultDir;
                if (!Directory.Exists(vault))
                    return (false, $"导出中止：同步库不存在（{vault}）。", null);

                var ts = DateTime.Now.ToString("yyyyMMdd-HHmmss");
                var name = $"hermemory-export-{ts}";
                var stageParent = Path.Combine(Path.GetTempPath(), name + "-stage");
                var stage = Path.Combine(stageParent, name);
                Directory.CreateDirectory(stage);

                report("① 复制文档库（vault）……");
                int skipped = 0;
                CopyDirTolerant(vault, Path.Combine(stage, "vault"), ref skipped);

                report("② 生成 AI 端全量备份（hermes backup，数据库热备不锁库）……");
                var backup = Path.Combine(stage, "hermes-home.zip");
                var bout = HermesCtl.Run($"backup -o \"{backup}\"", 900);
                if (!File.Exists(backup))
                {
                    // 中止时清掉已铺开的 staging，否则整份 vault 副本会烂在 temp 里
                    try { Directory.Delete(stageParent, true); } catch { }
                    return (false, "导出中止：hermes backup 未产出备份包。\n" + Tail(bout), null);
                }

                var reborn = Path.Combine(vault, "HerMemory", "docs", "README_REBORN.md");
                if (!File.Exists(reborn) && _repoRoot != null)
                {
                    var alt = Path.Combine(_repoRoot, "docs", "README_REBORN.md");
                    if (File.Exists(alt)) reborn = alt;
                }
                var hasReborn = File.Exists(reborn);
                if (hasReborn) File.Copy(reborn, Path.Combine(stage, "README_REBORN.md"), true);

                report("③ 打包 zip……");
                var dest = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    name + ".zip");
                if (File.Exists(dest)) File.Delete(dest);
                System.IO.Compression.ZipFile.CreateFromDirectory(stageParent, dest,
                    System.IO.Compression.CompressionLevel.Fastest, false);

                try { Directory.Delete(stageParent, true); } catch { }

                var mb = new FileInfo(dest).Length / 1024.0 / 1024.0;
                var msg = $"导出完成（{mb:F1} MB），已保存到桌面。";
                if (skipped > 0)
                    msg += $"\n注意：{skipped} 个文件被其他程序占用，未包含在内。关闭占用程序后可重新导出。";
                if (!hasReborn)
                    msg += "\n注意：未找到 README_REBORN.md，恢复指引未随包（不影响数据完整性）。";
                return (true, msg, dest);
            }
            catch (Exception ex)
            {
                return (false, "导出失败：" + ex.Message, null);
            }
        }

        /// <summary>递归复制；单文件失败（占用/权限）跳过并计数，不让整次导出报废。</summary>
        private static void CopyDirTolerant(string src, string dst, ref int skipped)
        {
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(src))
            {
                try { File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true); }
                catch { skipped++; }
            }
            foreach (var d in Directory.GetDirectories(src))
                CopyDirTolerant(d, Path.Combine(dst, Path.GetFileName(d)), ref skipped);
        }

        private static string Tail(string s, int n = 200)
        {
            s = (s ?? "").Trim();
            return s.Length <= n ? s : s[^n..];
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

        // ================= 微信绑定（绑定 / 换绑夺回 / 解绑）=================
        // 微信官方限制：一个微信同一时刻只活一个绑定。上游无 logout/unbind 命令——绑定态=两处文件：
        //   {HermesHome}\weixin\accounts\*.json（token，含 context_token 缓存）+ .env 的 WEIXIN_* 键（源码实证）。
        // 本层编排：停 gateway → 文件清理 → （重绑走安装同款 WeChatFlowAsync 二维码流）→ 起 gateway。绝不触碰 vault。

        private bool _wxRebind;   // QR 流来源：true=主界面重绑（成功/跳过回 PageWeixin 并重启 gateway），false=安装向导（走 PageDone）
        private bool _wxPrevRunning;  // 进入微信流程前 Gateway 是否在运行：用于恢复原状，避免把用户主动停掉的 Gateway 强行拉起

        public void ShowWeixin()
        {
            ShowPage("PageWeixin");
            UpdateWeixinStatus();
        }

        private void LinkWeixin_Click(object sender, RoutedEventArgs e) => ShowWeixin();

        /// <summary>绑定状态回显：未绑定 / 已绑定（user_id + saved_at + 被顶提示）。</summary>
        private void UpdateWeixinStatus()
        {
            var bound = EnvHasWeixin();
            BtnWxUnbind.IsEnabled = bound;
            if (!bound)
            {
                BtnWxBind.Content = "绑定微信";
                WxBindStatus.Text = "未绑定";
                return;
            }
            BtnWxBind.Content = "重新绑定";
            string uid = "", saved = "";
            try
            {
                var acctDir = Path.Combine(HermesHome, "weixin", "accounts");
                var latest = Directory.Exists(acctDir)
                    ? new DirectoryInfo(acctDir).GetFiles("*.json").OrderBy(f => f.LastWriteTime).LastOrDefault()
                    : null;
                if (latest != null)
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(latest.FullName));
                    if (doc.RootElement.TryGetProperty("user_id", out var u)) uid = u.GetString() ?? "";
                    if (doc.RootElement.TryGetProperty("saved_at", out var s)) saved = s.GetString() ?? "";
                }
            }
            catch { }
            WxBindStatus.Text = "已绑定"
                + (uid.Length > 0 ? $"：微信 ID {uid}" : "")
                + (saved.Length > 0 ? $"（{saved}）" : "") + "。";
        }

        /// <summary>清理微信凭据（解绑/换绑共用）：accounts 全目录文件 + .env 的 WEIXIN_* 键。绝不触碰其他配置与 vault。</summary>
        private static void CleanWeixinCredentials(string hermesHome)
        {
            try
            {
                var acctDir = Path.Combine(hermesHome, "weixin", "accounts");
                if (Directory.Exists(acctDir))
                    foreach (var f in Directory.GetFiles(acctDir)) { try { File.Delete(f); } catch { } }
                var envFile = Path.Combine(hermesHome, ".env");
                if (File.Exists(envFile))
                {
                    var keep = File.ReadAllLines(envFile).Where(l => !l.StartsWith("WEIXIN_", StringComparison.Ordinal)).ToArray();
                    File.WriteAllLines(envFile, keep, new UTF8Encoding(false));
                }
            }
            catch { }
        }

        private async void BtnWxBind_Click(object sender, RoutedEventArgs e)
        {
            if (EnvHasWeixin())
            {
                var r = System.Windows.MessageBox.Show(
                    "扫码后本机夺回绑定，原绑定设备将失效。继续？",
                    "重新绑定微信", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (r != MessageBoxResult.Yes) return;
            }
            BtnWxBind.IsEnabled = false;
            BtnWxUnbind.IsEnabled = false;
            WxBindStatus.Text = "正在准备二维码……";
            _wxPrevRunning = await Task.Run(HermesCtl.State) == "running";
            await Task.Run(() =>
            {
                try { HermesCtl.Run("gateway stop", 60); } catch { }
                CleanWeixinCredentials(HermesHome);
            });
            BtnWxBind.IsEnabled = true;
            _wxRebind = true;
            ShowPage("PageQr");
            StartQrFlow();
        }

        private async void BtnWxUnbind_Click(object sender, RoutedEventArgs e)
        {
            var r = System.Windows.MessageBox.Show(
                "解绑仅断开微信通道，记忆与文档不受影响。继续？",
                "解绑微信", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (r != MessageBoxResult.Yes) return;
            BtnWxBind.IsEnabled = false;
            BtnWxUnbind.IsEnabled = false;
            WxBindStatus.Text = "正在解绑……";
            var wasRunning = await Task.Run(HermesCtl.State) == "running";
            await Task.Run(() =>
            {
                try { HermesCtl.Run("gateway stop", 60); } catch { }
                CleanWeixinCredentials(HermesHome);
                // 只在原本运行时才恢复：解绑不该把用户主动停掉的 Gateway 拉起来
                if (wasRunning) { try { HermesCtl.Run("gateway start", 60); } catch { } }
            });
            BtnWxBind.IsEnabled = true;
            UpdateWeixinStatus();
        }

        private void FocusCfg()
        {
            Dispatcher.InvokeAsync(() =>
            {
                CfgUrl.Focus();
                CfgUrl.CaretIndex = CfgUrl.Text.Length;
            }, System.Windows.Threading.DispatcherPriority.Background);
        }

        private void BtnBack_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageHome");
            HomeStatus.Text = _lastState switch
            {
                "running" => "Gateway 运行中，AI 在线",
                _ => "Gateway 已停止，AI 离线",
            };
        }

        private void BtnVault_Click(object sender, RoutedEventArgs e)
        {
            if (Directory.Exists(VaultDir))
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{VaultDir}\"") { UseShellExecute = true });
        }

        private void BtnTheme_Click(object sender, RoutedEventArgs e)
        {
            Theme.SetDark(!Theme.IsDark);
            ThemeGlyph.Text = Theme.IsDark ? "☾" : "☀";
            ApplyGirlIcon();
        }

        // —— 女孩图标（右上角）：全透明底（窗口背景透出=与软件背景同色），深=白线稿/浅=黑线稿；logo 嵌入色两版一致 ——
        // 从嵌入资源加载（单文件分发）；Theme.SetDark 只换资源字典，图标需手动重载。
        private void ApplyGirlIcon()
        {
            try
            {
                var asm = System.Reflection.Assembly.GetExecutingAssembly();
                var name = Theme.IsDark ? "girl-dark.png" : "girl-light.png";
                using var s = asm.GetManifestResourceStream(name);
                if (s == null) return;
                var bmp = new System.Windows.Media.Imaging.BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
                bmp.StreamSource = s;
                bmp.EndInit();
                bmp.Freeze();
                GirlIcon.Source = bmp;
            }
            catch { }
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
                Background = System.Windows.Application.Current.Resources["WindowBg"] as System.Windows.Media.Brush
                    ?? new System.Windows.Media.SolidColorBrush(
                        (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FAFBFC")),
            };
            var rememberBox = new System.Windows.Controls.CheckBox
            {
                Content = "记住此选择，以后不再询问",
                FontSize = 12.5,
                Foreground = System.Windows.Application.Current.Resources["Ink"] as System.Windows.Media.Brush
                    ?? System.Windows.Media.Brushes.DimGray,
                Margin = new Thickness(0, 16, 0, 0),
            };
            string? result = null;
            var stack = new System.Windows.Controls.StackPanel { Margin = new Thickness(28, 24, 28, 20) };
            stack.Children.Add(new TextBlock
            {
                Text = "要退出 HerMemory，还是最小化到系统托盘？",
                FontSize = 14.5,
                TextWrapping = TextWrapping.Wrap,
                Foreground = System.Windows.Application.Current.Resources["Ink"] as System.Windows.Media.Brush
                    ?? System.Windows.Media.Brushes.Black,
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

        // ================= 页 1：预检 =================

        /// <summary>本轮启动是否已经尝试过自提权（由命令行标记传入）。
        /// 防止用户拒绝 UAC 后无限重启：提权实例带该标记启动，不再重复尝试。</summary>
        private static bool ElevationAttempted =>
            Environment.GetCommandLineArgs().Any(a =>
                string.Equals(a, "--elevated-attempted", StringComparison.OrdinalIgnoreCase));

        /// <summary>当前进程是否持有管理员令牌。</summary>
        private static bool IsElevated()
        {
            try
            {
                using var id = System.Security.Principal.WindowsIdentity.GetCurrent();
                return new System.Security.Principal.WindowsPrincipal(id)
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        /// <summary>开发者模式是否开启（开启后非管理员也能创建符号链接）。</summary>
        private static bool IsDeveloperModeOn()
        {
            try
            {
                using var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock");
                return Convert.ToInt32(k?.GetValue("AllowDevelopmentWithoutDevLicense") ?? 0) == 1;
            }
            catch { return false; }
        }

        /// <summary>两个注入槽位（符号链接）是否已就位。
        /// 已就位时 install.ps1 的 LinkOne 幂等直接返回，不再需要提权——避免重跑向导也弹 UAC。</summary>
        private static bool InjectionLinksReady()
        {
            return IsSymbolicLink(Path.Combine(HermesCtl.HermesHome, "SOUL.md"))
                && IsSymbolicLink(Path.Combine(
                       Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".hermes.md"));
        }

        private static bool IsSymbolicLink(string path)
        {
            try { var fi = new FileInfo(path); return fi.Exists && fi.LinkTarget != null; }
            catch { return false; }
        }

        /// <summary>以管理员身份重启自身（触发一次 UAC）。返回 true 表示已成功派发，本实例应退出。
        /// 失败（用户拒绝 UAC / runas 不可用）返回 false，流程继续走非提权安装——
        /// install.ps1 第 5 段会给出明确提示，不会静默。</summary>
        private static bool TryRelaunchElevated()
        {
            try
            {
                var self = SelfPath;
                if (string.IsNullOrEmpty(self) || !File.Exists(self)) return false;
                // 必须先释放单实例锁：提权实例启动后会抢同一把锁
                App.ReleaseSingleInstance();
                var psi = new ProcessStartInfo(self, "--elevated-attempted")
                {
                    UseShellExecute = true,     // runas 动词要求 ShellExecute
                    Verb = "runas",             // 弹 UAC
                    WorkingDirectory = Path.GetDirectoryName(self) ?? "",
                };
                Process.Start(psi);
                App.RequestExit();
                return true;
            }
            catch { return false; }
        }

        private async Task RunPrecheckAsync()
        {
            var notes = new List<string>();

            // 权限前置（2026-09-10）：install.ps1 第 5 段用**文件符号链接**把 vault 里的
            // SOUL.md / AGENTS.md 注入到 HERMES_HOME 与 $HOME。文件符号链接需要
            // SeCreateSymbolicLinkPrivilege，只有「管理员令牌」或「开发者模式」二者之一满足才可免提权。
            // 都不满足时该段直接 Die → 安装在符号链接处硬停（且用户此前已白填 API 参数）。
            // 故在此先判定并自提权重启。槽位已就位 / 已尝试过 / 用户拒绝 → 不打扰，继续原流程。
            if (!ElevationAttempted && !IsElevated() && !IsDeveloperModeOn() && !InjectionLinksReady())
            {
                if (TryRelaunchElevated()) return;   // 本实例已请求退出，提权实例接管
            }

            // payload 新鲜度由 .hm-payload-stamp 机制保证
            // 仓库定位：从 exe 所在目录逐级向上找 install.ps1；找不到则解压内嵌发行包（裸 exe 分发，无需仓库文件随行）
            _repoRoot = FindRepoRoot();
            if (_repoRoot == null)
            {
                var pd = PayloadDir;
                if (ExtractPayload(pd)) _repoRoot = pd;
            }
            notes.Add(_repoRoot != null
                ? "安装源已就位"
                : "安装源缺失（请检查磁盘空间与权限）");

            // git 不再预检：上游官方安装器自带 Stage-Git，自动便携化安装 PortableGit（pin 版上游源码实证），
            // 装后 export.sh / memory-size.sh 等 bash 脚本所需的 Git Bash 亦由其提供。

            // 网络探测已移除（2026-09-10 定案：只发行离线版，全部资源内嵌，无需网络）。
            // 离线版预检改为「离线资源包在场」：payload 解压后 assets-offline.zip 应与 install.ps1 同目录。
            bool offlinePack = File.Exists(Path.Combine(PayloadDir, "assets-offline.zip"));
            notes.Add(offlinePack
                ? "离线资源包已就位"
                : "未发现离线资源包，将走在线镜像安装（需网络）");

            // 权限状态如实回显（不提权也能装，但符号链接那一步会失败——用户要能提前看到）
            bool linksReady = InjectionLinksReady();
            notes.Add(linksReady ? "注入槽位已就位"
                : IsElevated() ? "管理员权限：已具备"
                : IsDeveloperModeOn() ? "开发者模式：已开启"
                : "管理员权限：未具备（注入槽位可能创建失败）");

            bool allOk = _repoRoot != null;
            PrecheckStatus.Text = string.Join(Environment.NewLine, notes);
            PrecheckStatus.Foreground = new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(
                    allOk ? (offlinePack ? "#2E7D32" : "#EF6C00") : "#C62828"));
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

        /// <summary>定位微信登录脚本：优先发行仓库目录文件；缺失（从旧的发行目录拷贝/残缺仓库启动）
        /// 时回落本 exe 内嵌 payload（构建戳保证新鲜）——QR 流对启动位置免疫。</summary>
        private string? ResolveQrScript()
        {
            try
            {
                var inRepo = _repoRoot == null ? null : Path.Combine(_repoRoot, "scripts", "weixin_qr_login.py");
                if (inRepo != null && File.Exists(inRepo)) return inRepo;
            }
            catch { }
            var pd = PayloadDir;
            if (ExtractPayload(pd))
            {
                var s = Path.Combine(pd, "scripts", "weixin_qr_login.py");
                if (File.Exists(s)) return s;
            }
            return null;
        }

        /// <summary>内嵌发行包解压目录（按版本隔离，exe 升级后旧解压不残留使用）。</summary>
        private static string PayloadDir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HerMemory", "payload",
            (System.Reflection.Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 1)).ToString(3));

        /// <summary>把构建期嵌入的仓库 payload（payload/… 资源，对应 memory/docs/skins/scripts + 根部脚本）
        /// 逐字节解压到 dir——BOM/编码与仓库文件一致（install.ps1 的 UTF-8 BOM 得以保留）。
        /// 新鲜度以 exe 构建时间戳为准（.hm-payload-stamp）：同版本号目录换新版 exe 也整包重刷，杜绝陈旧快照复用。</summary>
        private static bool ExtractPayload(string dir)
        {
            try
            {
                long stamp = 0;
                try { var self = SelfPath; stamp = self.Length > 0 ? File.GetLastWriteTimeUtc(self).Ticks : 0; } catch { }
                var stampFile = Path.Combine(dir, ".hm-payload-stamp");
                try
                {
                    // stamp=0 表示取不到自身路径：不认缓存，整包重解，避免误判为"已是最新"
                    if (stamp != 0 && File.Exists(Path.Combine(dir, "install.ps1")) && File.Exists(stampFile)
                        && long.TryParse(File.ReadAllText(stampFile), out var s) && s == stamp)
                        return true; // 构建戳一致 = 目录内容与本 exe 完全同步
                }
                catch { }
                var asm = System.Reflection.Assembly.GetExecutingAssembly();
                foreach (var name in asm.GetManifestResourceNames())
                {
                    if (!name.StartsWith("payload/", StringComparison.Ordinal)) continue;
                    var dst = Path.Combine(dir, name["payload/".Length..].Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                    using var rs = asm.GetManifestResourceStream(name);
                    if (rs == null) continue;
                    using var fs = File.Create(dst);
                    rs.CopyTo(fs);
                }
                try { File.WriteAllText(stampFile, stamp.ToString()); } catch { }
                return File.Exists(Path.Combine(dir, "install.ps1"));
            }
            catch { return false; }
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
            // 档位：三选一，或自定义（确定时校验两个 100-9999999 整数）
            string tier; int customMem = 0, customUser = 0;
            if (Tier4.IsChecked == true)
            {
                if (!int.TryParse(CustomMem.Text.Trim(), out customMem) || !int.TryParse(CustomUser.Text.Trim(), out customUser)
                    || customMem < 100 || customMem > 9999999 || customUser < 100 || customUser > 9999999)
                {
                    ParamStatus.Text = "自定义档位：MEMORY 与 USER 需分别填 100-9999999 的整数。";
                    ParamStatus.Foreground = Brush("#C62828");
                    return;
                }
                tier = "custom";
            }
            else tier = Tier1.IsChecked == true ? "1" : Tier2.IsChecked == true ? "2" : "3";
            _provBase = url;
            _provModel = model;
            StartInstall(tier, url, key, model, customMem, customUser);
        }

        /// <summary>档位单选切换：仅「自定义」时启用两个自由输入框。解析期 Tier1 默认选中会先于输入框创建触发，需判空。</summary>
        private void Tier_Checked(object sender, RoutedEventArgs e)
        {
            if (CustomMem == null || CustomUser == null) return;
            var on = Tier4 != null && Tier4.IsChecked == true;
            CustomMem.IsEnabled = on;
            CustomUser.IsEnabled = on;
            if (on) CustomMem.Focus();
        }

        /// <summary>URL 检测：与「获取模型列表」完全同通道（curl GET {url}/models，先直连、失败走代理兜底，填了 Key 则带认证）。</summary>
        private async void BtnCheckUrl_Click(object sender, RoutedEventArgs e)
        {
            var url = CleanAscii(UrlBox.Text).TrimEnd('/');
            if (url.Length == 0)
            {
                ParamStatus.Text = "请先填写 API 地址。";
                ParamStatus.Foreground = Brush("#C62828");
                return;
            }
            var key = CleanAscii(KeyBox.Text);
            BtnCheckUrl.IsEnabled = false;
            ParamStatus.Text = "正在检测地址……";
            ParamStatus.Foreground = Brush("#78909C");
            var (level, msg) = await Task.Run(() => ProbeUrl(url, key));
            ParamStatus.Text = msg;
            ParamStatus.Foreground = Brush(level == 2 ? "#2E7D32" : level == 1 ? "#EF6C00" : "#C62828");
            BtnCheckUrl.IsEnabled = true;
        }

        /// <summary>探活 {url}/models：任何 HTTP 应答即可达（level 2 绿 / 1 橙 / 0 红）；curl 000 时按退出码给出失败原因。</summary>
        private static (int level, string msg) ProbeUrl(string url, string key)
        {
            var tmp = Path.Combine(Path.GetTempPath(), $"hm-probe-{Guid.NewGuid():N}.json");
            (string code, int exit) Run(string extra)
            {
                try
                {
                    var auth = key.Length > 0 ? $" -H \"Authorization: Bearer {key}\"" : "";
                    var psi = new ProcessStartInfo
                    {
                        FileName = "curl.exe",
                        Arguments = $"-sL {extra} --max-time 10 -o \"{tmp}\" -w \"%{{http_code}}\" \"{url}/models\"{auth}",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        CreateNoWindow = true,
                    };
                    using var p = Process.Start(psi)!;
                    var code = p.StandardOutput.ReadToEnd().Trim();
                    p.WaitForExit(20000);
                    return (code, p.ExitCode);
                }
                catch { return ("", -1); }
            }
            try
            {
                var (code, exit) = Run("--noproxy \"*\"");
                if (code == "000" || code.Length == 0) (code, exit) = Run("");
                if (code.Length > 0 && code != "000")
                {
                    if (code == "200") return (2, "地址有效（HTTP 200）。");
                    if (code == "401" || code == "403") return (1, $"地址可达（HTTP {code}），认证未通过，请检查 Key。");
                    return (2, $"地址可达（HTTP {code}）。");
                }
                return (0, exit switch
                {
                    6 => "无法连接：域名解析失败。",
                    7 => "无法连接：服务器拒绝连接。",
                    28 => "无法连接：连接超时。",
                    35 => "无法连接：TLS 握手失败。",
                    _ => $"无法连接：网络错误（代码 {exit}）。",
                });
            }
            finally { try { File.Delete(tmp); } catch { } }
        }

        // ================= 页 3：安装 =================
        private static readonly Dictionary<string, int> ProgressMap = new()
        {
            ["precheck"] = 5, ["upstream"] = 45, ["files"] = 55, ["memory-tier"] = 62,
            ["config-ai"] = 78, ["wechat"] = 82, ["gateway"] = 92, ["done"] = 100
        };

        private readonly List<string> _installTail = new();   // 安装输出环形尾部（≤400 行，失败红字取材）
        private string? _mirrorInfo;                          // ##HM-MIRROR## 标记：本次安装链路模式（失败红字头部展示，远程定位用）

        private void StartInstall(string tier, string url, string key, string model, int customMem = 0, int customUser = 0)
        {
            ShowPage("PageInstall");
            InstallBar.Value = 2;
            InstallTitle.Text = "正在安装 HerMemory……";
            InstallDetail.Text = "";
            InstallFail.Text = "";
            InstallFail.Visibility = Visibility.Collapsed;
            lock (_installTail) _installTail.Clear();
            _mirrorInfo = null;
            StartTips();

            void Record(string? l)
            {
                if (string.IsNullOrWhiteSpace(l)) return;
                lock (_installTail) { _installTail.Add(l); if (_installTail.Count > 400) _installTail.RemoveAt(0); }
                Dispatcher.Invoke(() => InstallDetail.Text = l);
            }

            Task.Run(async () =>
            {
                try
                {
                    // 1. 答案文件（key 明文短暂落盘，成功后即删）
                    _answersPath = Path.Combine(Path.GetTempPath(), $"hermemory-answers-{Guid.NewGuid():N}.json");
                    var answers = new Dictionary<string, string>
                    {
                        ["memoryTier"] = tier, ["baseUrl"] = url, ["apiKey"] = key, ["model"] = model
                    };
                    if (tier == "custom")
                    {
                        answers["customMem"] = customMem.ToString();
                        answers["customUser"] = customUser.ToString();
                    }
                    var payload = JsonSerializer.Serialize(answers);
                    await File.WriteAllTextAsync(_answersPath, payload, new UTF8Encoding(false));

                    // 2. 静默安装
                    // RedirectStandardInput：CreateNoWindow 下子进程会拿到一个"无窗口但真实存在"的控制台，
                    // 其 stdin 是有效输入缓冲区——上游任何 input() 都会永久阻塞等待敲不进来的按键
                    //（2026-09-10 实录：gateway install 死锁，进程树里可见 powershell 的 conhost）。
                    // 重定向后在下面立即关闭写端 → 子进程读到 EOF → prompt 走其默认值，不再挂死。
                    var psi = new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{Path.Combine(_repoRoot!, "install.ps1")}\" -AnswersFile \"{_answersPath}\"",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        RedirectStandardInput = true,
                        CreateNoWindow = true,
                        // 不设 StandardOutputEncoding：手工字节级读取 + 逐行自适应解码（见下）
                    };

                    // 自适应解码：install.ps1 默认 GBK（chcp 936 自愈），上游脚本中途把会话切成 UTF-8（其 L101），
                    // 归位调用在重定向下不可靠（实测）——流内编码会中途切换，任何单一编码解码必乱一段（VM 两轮实测踩中）。
                    // 按行字节解码：严格 UTF-8 优先，解码失败退 GBK——GBK 中文序列几乎必然非法 UTF-8，UTF-8 中文必然合法，ASCII 两者共通。
                    var utf8Strict = new UTF8Encoding(false, true);
                    var gbk = Encoding.GetEncoding(936);
                    string Decode(byte[] arr)
                    {
                        try { return utf8Strict.GetString(arr); }
                        catch { return gbk.GetString(arr); }
                    }

                    int exit;
                    using (var p = Process.Start(psi)!)
                    {
                        // 立即关闭 stdin 写端：子进程侧立刻 EOF，任何 prompt 都不会阻塞（配合上面的重定向）
                        try { p.StandardInput.Close(); } catch { }
                        void HandleLine(string raw)
                        {
                            var line = raw.EndsWith("\r") ? raw[..^1] : raw;
                            if (line.StartsWith("##HM-MIRROR## "))
                            {
                                _mirrorInfo = line["##HM-MIRROR## ".Length..].Trim();
                                lock (_installTail) { _installTail.Add(line); if (_installTail.Count > 400) _installTail.RemoveAt(0); }
                                return;
                            }
                            if (line.StartsWith("##HM-PROGRESS## "))
                            {
                                var step = line["##HM-PROGRESS## ".Length..].Trim();
                                if (ProgressMap.TryGetValue(step, out var pct))
                                    Dispatcher.Invoke(() => InstallBar.Value = pct);
                                lock (_installTail) { _installTail.Add(line); if (_installTail.Count > 400) _installTail.RemoveAt(0); }
                            }
                            else Record(line);
                        }
                        void Pump(Stream stream)
                        {
                            using var bs = new BufferedStream(stream, 4096);
                            var buf = new List<byte>(512);
                            var one = new byte[1];
                            int n;
                            while ((n = bs.Read(one, 0, 1)) > 0)
                            {
                                if (one[0] == (byte)'\n') { HandleLine(Decode(buf.ToArray())); buf.Clear(); }
                                else buf.Add(one[0]);
                            }
                            if (buf.Count > 0) HandleLine(Decode(buf.ToArray()));
                        }
                        var errTask = Task.Run(() => Pump(p.StandardError.BaseStream));
                        await Task.Run(() => Pump(p.StandardOutput.BaseStream));
                        await errTask;
                        await p.WaitForExitAsync();
                        exit = p.ExitCode;
                    }

                    if (exit != 0)
                    {
                        // 答案文件保留：续装还要用（成功才删）
                        string tailText;
                        lock (_installTail)
                            tailText = string.Join(Environment.NewLine,
                                _installTail.Where(l => !string.IsNullOrWhiteSpace(l) && !l.StartsWith("##HM-PROGRESS##") && !l.StartsWith("##HM-MIRROR##"))
                                            .Select(l => l.Trim()).TakeLast(16));
                        Dispatcher.Invoke(() =>
                        {
                            InstallTitle.Text = "安装未成功";
                            InstallFail.Text = $"失败原因（退出码 {exit}，输出末尾 16 行）："
                                + (_mirrorInfo != null ? Environment.NewLine + "[链路] " + _mirrorInfo : "")
                                + Environment.NewLine + tailText
                                + Environment.NewLine + Environment.NewLine
                                + "已完成步骤将自动跳过；排除问题后点击「重新安装」继续。";
                            InstallFail.Visibility = Visibility.Visible;
                            AddRetryButton();
                        });
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
                        InstallFail.Text = "失败原因：" + ex;
                        InstallFail.Visibility = Visibility.Visible;
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
            InstallTip.Text = lines[0];
            _tipTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            _tipTimer.Tick += (_, _) => { i = (i + 1) % lines.Count; InstallTip.Text = lines[i]; };
            _tipTimer.Start();
        }

        private void StopTips() => _tipTimer?.Stop();

        private void AddRetryButton()
        {
            StopTips();

            if (InstallTitle.Text != "安装未成功" && InstallTitle.Text != "安装出错") return;
            // 重试按钮：回到参数页重配（样式从 App.Resources 取——Window.Resources 里是 null）
            var btn = new System.Windows.Controls.Button
            {
                Content = "重新安装",
                Style = System.Windows.Application.Current.Resources["AccentButton"] as Style,
                Margin = new Thickness(0, 18, 0, 0),
            };
            btn.Click += (_, _) =>
            {
                ((StackPanel)InstallTitle.Parent).Children.Remove(btn);
                ShowPage("PageParams");
            };
            ((StackPanel)InstallTitle.Parent).Children.Add(btn);
        }

        // ================= 页 4：微信扫码 =================
        // 不要 .Wait()：那会白白占住一个线程池线程长达 9 分钟；Task.Run 直接跑异步流即可
        //
        // CTS 必须在**派发之前**于 UI 线程同步建立并登记：否则快速连点「重新扫码」时，
        // 上一轮任务可能还没执行到 _qrCts 赋值，Cancel() 打空 → 两轮并存（两个 python 进程、
        // 两个浏览器标签）。登记在前则第二次点击必定取消第一轮的 token。
        private void StartQrFlow()
        {
            try { _qrCts?.Cancel(); } catch { }
            var cts = new CancellationTokenSource(TimeSpan.FromMinutes(9));   // 9 分钟上限 = 上游 qr_login 内部 8 分钟 + 收尾余量
            _qrCts = cts;
            var ct = cts.Token;
            _ = Task.Run(() => WeChatFlowAsync(ct));
        }

        private async Task WeChatFlowAsync(CancellationToken ct)
        {
            // 连点竞态下本轮的 token 可能已被取消：立即退出，绝不触碰页面、也不起 python 进程
            if (ct.IsCancellationRequested) return;

            SetQr("正在检查微信接入状态……");
            if (EnvHasWeixin()) { await AfterWechatAsync(); return; }

            // Headless 二维码登录：venv python 直调发行脚本 scripts\weixin_qr_login.py（内部走上游 qr_login 并落 .env）。
            // 不再用 gateway setup——其 curses 菜单在非 TTY stdin 下直接返回取消值、完全不读管道输入
            //（上游 curses_ui._run_curses_menu isatty 守卫实证），旧答题卡自动化在结构上无法通过；install.ps1 交互路径不受影响（真 TTY 由人应答）。
            SetQr("正在启动微信接入，浏览器将打开二维码页面。");
            try
            {
                var pyExe = Path.Combine(HermesHome, "hermes-agent", "venv", "Scripts", "python.exe");
                var script = ResolveQrScript();
                if (!File.Exists(pyExe) || script == null)
                {
                    SetQr(!File.Exists(pyExe)
                        ? "微信接入组件缺失（Python 环境未就绪）：" + pyExe
                        : $"微信接入组件缺失（登录脚本，安装源={_repoRoot ?? "未定位"}，内嵌包解压也失败，请检查磁盘空间与权限）");
                    return;
                }
                bool urlOpened = false;
                var psi = new ProcessStartInfo
                {
                    FileName = pyExe,
                    Arguments = $"\"{script}\" \"{Path.Combine(HermesHome, "hermes-agent")}\" \"{HermesHome}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                };
                psi.EnvironmentVariables["NO_COLOR"] = "1";
                psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
                psi.EnvironmentVariables["PYTHONUTF8"] = "1";
                using var p = Process.Start(psi)!;
                var readerTask = Task.Run(() =>
                {
                    try
                    {
                        while (!p.StandardOutput.EndOfStream)
                        {
                            var line = p.StandardOutput.ReadLine();
                            if (line == null) break;
                            // 二维码链接裸行（过期刷新后重打，仅首次拉起浏览器）
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
                        }
                    }
                    catch { }
                });
                _ = Task.Run(() => { try { p.StandardError.ReadToEnd(); } catch { } });

                // 轮询 .env 等凭据落盘（登录脚本成功后最后一步写 WEIXIN_ACCOUNT_ID）；脚本自行退出（超时/失败）即停止等待。
                // Delay 必须吃 ct：否则点了「跳过」后旧流程仍会在下一次扫码成功时切走页面。
                while (!ct.IsCancellationRequested)
                {
                    if (EnvHasWeixin()) break;
                    if (p.HasExited) break;
                    try { await Task.Delay(2000, ct); }
                    catch (OperationCanceledException) { break; }
                }
                try { if (!p.HasExited) p.Kill(true); } catch { }
                try { await readerTask; } catch { }

                // 已取消（用户点跳过 / 离开本页）：到此为止，绝不触碰页面
                if (ct.IsCancellationRequested) return;

                if (!EnvHasWeixin())
                {
                    SetQr("二维码已超时或未完成扫码，可重试。");
                    return;
                }

                ApplyAllowlist();
                await AfterWechatAsync();
            }
            catch (Exception ex)
            {
                if (ct.IsCancellationRequested) return;
                SetQr("微信接入异常：" + ex.Message);
            }
        }

        private void SetQr(string text) => Dispatcher.Invoke(() => QrStatus.Text = text);

        private bool EnvHasWeixin()
        {
            try
            {
                var env = Path.Combine(HermesHome, ".env");
                // 必须有非空值：登录脚本异常时可能写入空值，空值不得判定为已绑定
                return File.Exists(env) && File.ReadAllLines(env)
                    .Any(l => l.StartsWith("WEIXIN_ACCOUNT_ID=", StringComparison.Ordinal)
                              && l.Length > "WEIXIN_ACCOUNT_ID=".Length);
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
            // 取消闸门：用户已跳过或已离开二维码页时，不得再改页面（旧流程可能晚于取消完成）
            if (_qrCts?.IsCancellationRequested == true) return;

            if (_wxRebind)
            {
                // 换绑/重绑成功：重启 gateway 加载新凭据（allowlist 已由 ApplyAllowlist 跟随新微信 ID），回绑定页
                SetQr("绑定成功，正在重启 Gateway……");
                await Task.Run(() => { try { HermesCtl.Run("gateway start", 60); } catch { } });
                _wxRebind = false;
                Dispatcher.Invoke(() => { ShowPage("PageWeixin"); UpdateWeixinStatus(); });
                return;
            }
            // gateway 服务（计划任务）缺则补装；失败不阻塞完成
            SetQr("检查 gateway 服务……");
            bool taskExists = await Task.Run(() =>
            {
                var r = RunCapture("schtasks", "/Query /FO LIST");
                return r != null && r.Contains("hermes", StringComparison.OrdinalIgnoreCase);
            });
            if (!taskExists)
            {
                SetQr("正在安装 gateway 服务……");
                await Task.Run(() => HermesCtl.Run("gateway install", 600));
            }
            // 凭据已落 .env——重启 gateway 加载 weixin 通道（install.ps1 第 10 段起的服务不含微信凭据）
            SetQr("正在重启 Gateway 加载微信通道……");
            await Task.Run(() => { try { HermesCtl.Run("gateway restart", 120); } catch { } });

            var warn = taskExists ? "" : "gateway 计划任务未注册，不影响微信使用，可稍后补装。";
            Dispatcher.Invoke(() =>
            {
                DoneText.Text = "HerMemory 已就绪。" + warn + Environment.NewLine +
                    "在微信发送首条消息，AI 将完成剩余部署。" + Environment.NewLine +
                    "记忆为纯文本，位于 vault\\HerMemory\\memory\\，修改后开启新对话生效。" + Environment.NewLine +
                    "系统托盘已常驻，可随时启停 Gateway。";
                ShowPage("PageDone");
                App.Inst?.EnterHomeMode(this);   // 装完当次会话即有托盘，无需重开本程序
            });
        }

        private void BtnQrRetry_Click(object sender, RoutedEventArgs e)
        {
            // 按钮常驻（不再只在失败后才出现）：任何时刻都可重新生成二维码并在浏览器打开。
            // 取消与新建 CTS 都在 StartQrFlow 内于 UI 线程同步完成——见该处关于连点竞态的注释。
            StartQrFlow();
        }

        private void BtnQrSkip_Click(object sender, RoutedEventArgs e)
        {
            _qrCts?.Cancel();
            if (_wxRebind)
            {
                // 重绑中途取消：恢复解绑前的运行态（原来是停的就保持停），回绑定页如实回显状态
                _wxRebind = false;
                var prev = _wxPrevRunning;
                _ = Task.Run(() => { if (prev) { try { HermesCtl.Run("gateway start", 60); } catch { } } });
                Dispatcher.Invoke(() => { ShowPage("PageWeixin"); UpdateWeixinStatus(); });
                return;
            }
            Dispatcher.Invoke(() =>
            {
                DoneText.Text = "安装完成，微信暂未接入。" + Environment.NewLine +
                    "可随时重新接入：主界面「微信绑定」，或重新运行安装向导。" + Environment.NewLine +
                    "系统托盘已常驻，可随时启停 Gateway。";
                ShowPage("PageDone");
                App.Inst?.EnterHomeMode(this);
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

        private void BtnFinish_Click(object sender, RoutedEventArgs e)
        {
            // 全新安装完成时已置为日常态（托盘已建）：进主界面而不是关窗口
            if (HomeMode) GoHome();
            else Close();
        }

        // ================= 卸载 =================
        private static string VaultDir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "vault");

        private void BtnUninstall_Click(object sender, RoutedEventArgs e)
        {
            ShowPage("PageUninstall");
        }

        private void BtnUninsCancel_Click(object sender, RoutedEventArgs e)
        {
            UninsBar.Visibility = Visibility.Collapsed;
            ShowPage(HomeMode ? "PageHome" : "PageWelcome");
            if (HomeMode) _ = Task.Run(async () =>
            {
                var s = await Task.Run(HermesCtl.State);
                await Dispatcher.InvokeAsync(() => UpdateHomeStatus(s));
            });
        }

        private void BtnUninsRun_Click(object sender, RoutedEventArgs e)
        {
            var delVault = UninsVault.IsChecked == true;
            if (delVault)
            {
                var r = System.Windows.MessageBox.Show(this,
                    "删除整个 vault？其中为全部文档与 AI 记忆，删除后不可恢复。",
                    "删除 vault", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
                if (r != MessageBoxResult.Yes) { UninsVault.IsChecked = false; return; }
            }
            BtnUninsRun.IsEnabled = false;
            BtnUninsBack.IsEnabled = false;
            UninsVault.IsEnabled = false;
            UninsBar.Visibility = Visibility.Visible;
            UninsBar.Value = 2;
            _ = Task.Run(() => DoUninstall(delVault));
        }

        private void SetUnins(string text, int? pct = null) => Dispatcher.Invoke(() =>
        {
            UninsStatus.Text = text;
            if (pct.HasValue) UninsBar.Value = pct.Value;
        });

        /// <summary>卸载：清软件本体与配置。vault 默认保留。
        /// 不删 exe 自身（用户自行删除本程序文件）——卸载功能只负责把 HerMemory 装进去的东西清干净。</summary>
        private void DoUninstall(bool delVault)
        {
            SetUnins("停止网关……", 5);
            HermesCtl.Run("gateway stop", 60);

            SetUnins("移除登录项与计划任务……", 12);
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

            SetUnins("移除自启项与偏好设置……", 20);
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                    k?.DeleteValue("HerMemory", false);
                Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(@"Software\HerMemory", false);
            }
            catch { }

            // 只删内嵌发行包缓存，不删 HerMemory 目录本身——用户可能把本程序放在该目录下
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var payloadCache = Path.Combine(localAppData, "HerMemory", "payload");
            SetUnins("移除内嵌发行包缓存……", 26);
            try
            {
                if (Directory.Exists(payloadCache)) Directory.Delete(payloadCache, true);
            }
            catch { }

            SetUnins("移除注入槽位……", 32);
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
                    SetUnins("正在移除内核与配置……", 35 + (int)(45.0 * (i + 1) / tops.Length));
                    try
                    {
                        if (Directory.Exists(tops[i])) Directory.Delete(tops[i], true);
                        else File.Delete(tops[i]);
                    }
                    catch { }
                }
                try { Directory.Delete(hh, true); } catch { }
            }

            if (delVault)
            {
                SetUnins("删除 vault……", 80);
                try { if (Directory.Exists(VaultDir)) Directory.Delete(VaultDir, true); } catch { }
            }

            // 残留核对：删除可能因文件占用失败（残留 venv/python 进程、资源管理器句柄等）。
            // 旧实现一律报"已移除全部软件痕迹"——静默失败比失败本身更糟，此处如实列出。
            var left = new List<string>();
            if (Directory.Exists(hh)) left.Add(hh);
            if (Directory.Exists(payloadCache)) left.Add(payloadCache);
            if (delVault && Directory.Exists(VaultDir)) left.Add(VaultDir);

            SetUnins(left.Count == 0 ? "卸载完成。" : "卸载已完成，存在残留。", 100);
            Dispatcher.Invoke(() =>
            {
                // 内核已删：撤掉托盘并退回向导态，否则托盘会继续指向一个不存在的安装，关窗只留幽灵进程
                App.Inst?.LeaveHomeMode(this);
                UninsStatus.Text = left.Count == 0
                    ? "卸载完成，已移除全部软件痕迹" + (delVault ? "（含 vault）。" : "；vault 已保留。")
                      + Environment.NewLine + "本程序文件请自行删除。"
                    : "卸载已完成，以下目录未能完全删除（多为文件被占用）：" + Environment.NewLine
                      + string.Join(Environment.NewLine, left) + Environment.NewLine
                      + "关闭占用程序后可手动删除。" + (delVault ? "" : " vault 已保留。");
                BtnUninsClose.Visibility = Visibility.Visible;
            });
        }

        private void BtnUninsDone_Click(object sender, RoutedEventArgs e) => App.RequestExit();

        public void ShowUninstall()
        {
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
            var tmp = Path.Combine(Path.GetTempPath(), $"hm-models-{Guid.NewGuid():N}.json");
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
            try { File.Delete(tmp); } catch { }
            return (code, body);
        }
    }
}
