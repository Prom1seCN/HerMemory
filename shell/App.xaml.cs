using System.IO;
using System.Windows;

namespace HerMemory
{
    public partial class App : System.Windows.Application
    {
        private TrayService? _tray;
        private MainWindow? _wizard;
        private static Mutex? _single;

        public static void RequestExit()
        {
            global::HerMemory.MainWindow.ReallyExit = true;
            Current?.Shutdown();
        }

        /// <summary>自提权重启前调用：释放单实例互斥量。
        /// 否则提权实例启动时抢同一把锁会失败（first=false），弹"已在运行"后立即退出，
        /// 表现为"点了确定但窗口再也没起来"。</summary>
        public static void ReleaseSingleInstance()
        {
            try { _single?.ReleaseMutex(); } catch { }
            try { _single?.Dispose(); } catch { }
            _single = null;
        }

        /// <summary>供窗口侧访问 App 实例（安装完成建托盘、卸载完成撤托盘）。</summary>
        public static App? Inst => Current as App;

        /// <summary>托盘是"安装后日常态"的产物：只在需要时创建，且全程只创建一次。</summary>
        private void EnsureTray()
        {
            if (_tray != null) return;
            try
            {
                _tray = new TrayService();
            }
            catch (Exception ex)
            {
                // 托盘建不起来（图标资源缺失 / NotifyIcon 被策略拦）不该让整个程序崩掉：
                // 主界面仍然可用，只是没有常驻入口。
                LogCrash(ex, "tray-init");
                _tray = null;
                return;
            }
            _tray.OpenWizard += () => SafeDispatch(ShowWizard);
            _tray.OpenMain += () => SafeDispatch(ShowMain);
            _tray.OpenUninstall += () => SafeDispatch(ShowUninstall);
            _tray.OpenWeixin += () => SafeDispatch(ShowWeixinFromTray);
            _tray.StatusChanged += (state, _) => SafeDispatch(() => _wizard?.UpdateHomeStatus(state));
        }

        /// <summary>跨线程回 UI 的安全派发：程序正在退出时 Dispatcher 会拒绝（抛 TaskCanceled/
        /// InvalidOperation）——托盘事件与后台轮询晚到一步就会踩到，此处直接丢弃。</summary>
        private static void SafeDispatch(Action act)
        {
            var app = Current;
            if (app == null || app.Dispatcher.HasShutdownStarted || app.Dispatcher.HasShutdownFinished) return;
            try { app.Dispatcher.Invoke(act); } catch { }
        }

        // —— 全局异常兜底 ——
        // 托盘常驻程序最怕"静默死亡"：UI 事件里一个未处理异常就整进程消失，
        // 托盘没了、用户毫不知情，而 gateway 还在后台跑。这里记日志 + 一次性提示，尽量让进程活着。
        private static int _crashWarned;

        private static void InstallCrashHandlers()
        {
            Current!.DispatcherUnhandledException += (_, args) =>
            {
                LogCrash(args.Exception, "dispatcher");
                args.Handled = true;   // 不掀掉整个进程
                if (System.Threading.Interlocked.Exchange(ref _crashWarned, 1) == 0)
                {
                    try
                    {
                        System.Windows.MessageBox.Show(
                            "HerMemory 遇到一个内部错误，已记录日志。\n"
                            + "功能可能受影响，必要时请从托盘退出并重新打开。\n\n"
                            + "日志：%LOCALAPPDATA%\\hermes\\logs\\hermemory-crash.log",
                            "HerMemory", MessageBoxButton.OK, MessageBoxImage.Warning);
                    }
                    catch { }
                }
            };
            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
                LogCrash(args.ExceptionObject as Exception, "appdomain");
            TaskScheduler.UnobservedTaskException += (_, args) =>
            {
                LogCrash(args.Exception, "task");
                args.SetObserved();    // 后台任务里被丢弃的异常不该在 GC 时掀翻进程
            };
        }

        /// <summary>崩溃日志：追加到 hermes\logs\hermemory-crash.log，单文件上限约 1MB（超了轮换）。
        /// 记录本身绝不能再抛异常——那会在异常处理器里二次崩溃。</summary>
        private static void LogCrash(Exception? ex, string kind)
        {
            try
            {
                if (ex == null) return;
                var dir = Path.Combine(HermesCtl.HermesHome, "logs");
                Directory.CreateDirectory(dir);
                var f = Path.Combine(dir, "hermemory-crash.log");
                try { if (File.Exists(f) && new FileInfo(f).Length > 1_000_000) File.Delete(f); } catch { }
                File.AppendAllText(f,
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{kind}] {ex}{Environment.NewLine}{Environment.NewLine}",
                    new System.Text.UTF8Encoding(false));
            }
            catch { }
        }

        /// <summary>安装成功：补建托盘并把窗口置为日常态，使全新安装的当次会话即可常驻托盘，
        /// 不必重开本程序。只建托盘、不切页——完成页仍要给用户看。</summary>
        public void EnterHomeMode(MainWindow w)
        {
            EnsureTray();
            _wizard = w;
            w.PrepareHome();
        }

        /// <summary>卸载完成：撤销托盘并退回向导态，避免托盘继续指向已被删除的 hermes。
        /// HomeMode 置回 false 后，关窗口即直接退出，不会再弹"最小化到托盘"。</summary>
        public void LeaveHomeMode(MainWindow w)
        {
            try { _tray?.Dispose(); } catch { }
            _tray = null;
            w.HomeMode = false;
        }

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            InstallCrashHandlers();
            // .NET 8 缺代码页数据：注册后 Encoding.GetEncoding(936) 才可用（安装器输出按 GBK 解码，见 StartInstall）
            System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
            // 清掉上次失败留下的安装答案文件（含明文 API Key，失败时被刻意保留以支持续装）
            // 注意必须 global:: 限定：Application.MainWindow 属性会遮蔽 MainWindow 类名
            global::HerMemory.MainWindow.PurgeStaleAnswerFiles();
            Theme.Apply();
            var elevateRestart = e.Args.Any(a =>
                string.Equals(a, "--elevated-attempted", StringComparison.OrdinalIgnoreCase));
            _single = new Mutex(true, "HerMemory-SingleInstance", out var first);
            if (!first)
            {
                // 自提权重启场景：本实例由「提权前的自己」派发，后者正在退出（会 ReleaseMutex）。
                // 给几秒等它让出锁——否则会被判"已在运行"直接退出，表现为点了 UAC 后再没窗口起来。
                bool took = false;
                if (elevateRestart)
                {
                    try { took = _single.WaitOne(TimeSpan.FromSeconds(8)); }
                    catch (AbandonedMutexException) { took = true; }   // 旧实例进程已终止，锁归本进程
                }
                if (!took)
                {
                    System.Windows.MessageBox.Show("HerMemory 已在运行，见系统托盘。", "HerMemory",
                        MessageBoxButton.OK, MessageBoxImage.Information);
                    Shutdown();
                    return;
                }
            }

            if (HermesCtl.Installed)
            {
                // 已安装：托盘 + 主界面双开（用户要求的默认形态）
                _wizard = new MainWindow { HomeMode = true };
                EnsureTray();
                _wizard.Closed += (_, _) => _wizard = null;
                _wizard.Show();
            }
            else
            {
                ShowWizard();
            }
        }

        private void ShowMain()
        {
            if (_wizard != null)
            {
                _wizard.ShowFromTray();
                // 从向导页（例如点了托盘「安装向导…」）回到主界面：只 Show 不切页会停在向导页上，
                // 表现为"再也回不到配置界面"。安装进行中则不抢页——那会打断进度显示与「中止安装」入口。
                if (!_wizard.InstallInProgress) _wizard.GoHome();
                return;
            }
            // 主界面被真正关闭过（罕见：窗口 Close 而非最小化到托盘）时按当前安装态重建。
            // 旧实现回落到 ShowWizard()：已安装状态下会开出预检页而非日常页，与"打开主界面"语义不符。
            _wizard = new MainWindow { HomeMode = true };
            _wizard.Closed += (_, _) => _wizard = null;
            _wizard.Show();
        }

        private void ShowUninstall()
        {
            if (_wizard == null)
            {
                _wizard = new MainWindow { HomeMode = true };
                _wizard.Closed += (_, _) => _wizard = null;
                _wizard.Show();
            }
            else _wizard.ShowFromTray();
            _wizard.ShowUninstall();
        }

        private void ShowWeixinFromTray()
        {
            if (_wizard == null)
            {
                _wizard = new MainWindow { HomeMode = true };
                _wizard.Closed += (_, _) => _wizard = null;
                _wizard.Show();
            }
            else _wizard.ShowFromTray();
            _wizard.ShowWeixin();
        }

        private void ShowWizard()
        {
            if (_wizard == null)
            {
                _wizard = new MainWindow();
                _wizard.Closed += (_, _) => _wizard = null;
                _wizard.Show();
            }
            else if (_wizard.HomeMode) _wizard.GoWelcome();
            else _wizard.ShowFromTray();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _tray?.Dispose();
            _single?.Dispose();
            base.OnExit(e);
        }
    }
}
