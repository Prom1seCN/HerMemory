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

        public MainWindow()
        {
            InitializeComponent();
            Loaded += async (_, _) => await RunPrecheckAsync();
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
                ParamStatus.Text = "请先填写 API 地址与 API Key。";
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
                ParamStatus.Text = $"获取成功：{ids.Count} 个可用模型，请选择默认模型。";
                ParamStatus.Foreground = Brush("#2E7D32");
            }
            else if (code == "401" || code == "403")
            {
                ParamStatus.Text = $"[{code}] 认证未通过——请检查 API Key。";
                ParamStatus.Foreground = Brush("#C62828");
            }
            else if (code == "000" || code.Length == 0)
            {
                ParamStatus.Text = "[连接超时] 无法连接该地址——检查网络，或关闭代理后重试。";
                ParamStatus.Foreground = Brush("#C62828");
            }
            else
            {
                ParamStatus.Text = $"[{code}] 获取失败——请核对地址与 Key。";
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
                ParamStatus.Text = "地址、Key、模型三项都填好才能继续。";
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
            InstallTitle.Text = "正在安装……（首次约 5-10 分钟）";
            InstallDetail.Text = "";

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
                            InstallDetail.Text += Environment.NewLine + "已完成的步骤会自动跳过——修正后点“重新安装”即可续装。";
                        });
                        // 答案文件保留：续装还要用（成功才删）
                        Dispatcher.Invoke(() => AddRetryButton());
                        return;
                    }

                    // 成功：用完即删
                    try { File.Delete(_answersPath); } catch { }
                    _answersPath = null;

                    // 3. 微信扫码
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

        private void AddRetryButton()
        {
            if (InstallTitle.Text != "安装未成功" && InstallTitle.Text != "安装出错") return;
            // 复用扫码页的重试思路：这里直接放一个"重新安装"按钮
            var btn = new Button { Content = "重新安装", Style = (Style)Resources["AccentButton"], Margin = new Thickness(0, 18, 0, 0) };
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

            SetQr("正在拉起微信接入向导……浏览器将自动打开二维码页面。");
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
                using var p = Process.Start(psi)!;
                StdinWriter = p.StandardInput;
                StdinWriter.AutoFlush = true;
                var readerTask = Task.Run(() =>
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
                            var end = url.IndexOfAny(new[] { ' ', '\t', ')' });
                            if (end > 0) url = url[..end];
                            try
                            {
                                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                                urlOpened = true;
                                SetQr("二维码已在浏览器打开——请用微信扫码并确认（约 8 分钟内有效）。");
                            }
                            catch { }
                        }
                        FeedWizardAnswer(line);
                    }
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
                SetQr("微信接入出错：" + ex.Message);
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
                SetQr("微信已连接：仅允许你的微信 ID（首条消息直达）。");
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
                SetQr("安装 gateway 服务（约一两分钟）……");
                await Task.Run(() => RunCapture(HermsExe, "gateway install", 600));
            }

            var warn = taskExists ? "" : "（gateway 计划任务未注册成功——不影响微信使用，可在托盘功能里补装）";
            Dispatcher.Invoke(() =>
            {
                DoneText.Text = "你的 HerMemory 已就绪。" + warn + Environment.NewLine +
                    "① 打开微信，给它发第一句话——它会自我介绍并引导完成剩余部署。" + Environment.NewLine +
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
                DoneText.Text = "安装完成（微信暂未接入）。" + Environment.NewLine +
                    "随时可重新接入：双击桌面的 gateway-run.bat，或在向导里重跑。";
                ShowPage("PageDone");
            });
        }

        // ================= 页 5：完成 =================
        private void BtnGuide_Click(object sender, RoutedEventArgs e)
        {
            var guide = Path.Combine(VaultDocs, "GUIDE.md");
            if (File.Exists(guide))
                Process.Start(new ProcessStartInfo(guide) { UseShellExecute = true });
            else if (Directory.Exists(VaultDocs))
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{VaultDocs}\"") { UseShellExecute = true });
        }

        private void BtnFinish_Click(object sender, RoutedEventArgs e) => Close();

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
