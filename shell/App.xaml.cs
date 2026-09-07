using System.Windows;

namespace HerMemory
{
    public partial class App : System.Windows.Application
    {
        private TrayService? _tray;
        private MainWindow? _wizard;
        private static Mutex? _single;

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

            if (TrayService.IsInstalled())
            {
                // 托盘模式（已安装）：常驻后台，无窗口
                _tray = new TrayService();
                _tray.OpenWizard += () => Dispatcher.Invoke(ShowWizard);
            }
            else
            {
                ShowWizard();
            }
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
                _wizard.WindowState = WindowState.Normal;
                _wizard.Activate();
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
