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

        /// <summary>供窗口侧访问 App 实例（安装完成建托盘、卸载完成撤托盘）。</summary>
        public static App? Inst => Current as App;

        /// <summary>托盘是"安装后日常态"的产物：只在需要时创建，且全程只创建一次。</summary>
        private void EnsureTray()
        {
            if (_tray != null) return;
            _tray = new TrayService();
            _tray.OpenWizard += () => Dispatcher.Invoke(ShowWizard);
            _tray.OpenMain += () => Dispatcher.Invoke(ShowMain);
            _tray.OpenUninstall += () => Dispatcher.Invoke(ShowUninstall);
            _tray.OpenWeixin += () => Dispatcher.Invoke(ShowWeixinFromTray);
            _tray.StatusChanged += (state, _) => Dispatcher.Invoke(() => _wizard?.UpdateHomeStatus(state));
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
            // .NET 8 缺代码页数据：注册后 Encoding.GetEncoding(936) 才可用（安装器输出按 GBK 解码，见 StartInstall）
            System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
            Theme.Apply();
            _single = new Mutex(true, "HerMemory-SingleInstance", out var first);
            if (!first)
            {
                System.Windows.MessageBox.Show("HerMemory 已在运行，见系统托盘。", "HerMemory",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
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
            if (_wizard != null) { _wizard.ShowFromTray(); return; }
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
