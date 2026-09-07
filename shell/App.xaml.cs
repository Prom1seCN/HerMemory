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

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            _single = new Mutex(true, "HerMemory-SingleInstance", out var first);
            if (!first)
            {
                System.Windows.MessageBox.Show("HerMemory 已在运行（看系统托盘）。", "HerMemory",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }

            if (HermesCtl.Installed)
            {
                // 已安装：托盘 + 主界面双开（用户要求的默认形态）
                _tray = new TrayService();
                _tray.OpenWizard += () => Dispatcher.Invoke(ShowWizard);
                _tray.OpenMain += () => Dispatcher.Invoke(ShowMain);
                _tray.OpenUninstall += () => Dispatcher.Invoke(ShowUninstall);
                _wizard = new MainWindow { HomeMode = true };
                _wizard.Closed += (_, _) => _wizard = null;
                _tray.StatusChanged += (state, _) => Dispatcher.Invoke(() => _wizard?.UpdateHomeStatus(state));
                _wizard.Show();
            }
            else
            {
                ShowWizard();
            }
        }

        private void ShowMain()
        {
            if (_wizard != null) _wizard.ShowFromTray();
            else ShowWizard();
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

        private void ShowWizard()
        {
            if (_wizard == null)
            {
                _wizard = new MainWindow();
                _wizard.Closed += (_, _) => _wizard = null;
                _wizard.Show();
            }
            else
            {
                _wizard.ShowFromTray();
            }
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _tray?.Dispose();
            _single?.Dispose();
            base.OnExit(e);
        }
    }
}
