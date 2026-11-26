using System;
using System.Windows;
using System.Windows.Media;
// 本项目同时引用 WinForms（托盘/剪贴板），Brush/Application 会与 System.Drawing /
// System.Windows.Forms 撞名。这里统一钉死到 WPF 的类型，下面的代码就不用逐个写全名。
using Application = System.Windows.Application;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;

namespace HerMemory
{
    /// <summary>
    /// 应用自己的对话框，替换系统 MessageBox。
    ///
    /// 为什么不用 MessageBox：它是 Win32 原生控件，方角灰底、字体不跟主题、按钮是英文系统的
    /// "OK/Cancel" 排版习惯，夹在 HerMemory 这套界面里像从别的程序弹出来的。这里保持同一套
    /// 令牌（WindowBg / Ink / Muted / Accent）、同一套按钮样式，深浅色自动跟随。
    /// </summary>
    public partial class AppDialog : Window
    {
        public enum Kind { Info, Warn, Error }

        /// <summary>三态结果，语义与 MessageBox 的 Yes/No/Cancel 一致。</summary>
        public enum Choice { Yes, No, Cancel }

        private bool _ok;
        private bool _no;

        private AppDialog()
        {
            InitializeComponent();
            PreviewKeyDown += (_, e) =>
            {
                if (e.Key == System.Windows.Input.Key.Escape) { _ok = false; Close(); }
                else if (e.Key == System.Windows.Input.Key.Enter) { _ok = true; Close(); }
            };
        }

        public static void Info(Window? owner, string message, string title = "提示")
            => Show(owner, title, message, Kind.Info, confirm: false);

        public static void Warn(Window? owner, string message, string title = "注意")
            => Show(owner, title, message, Kind.Warn, confirm: false);

        public static void Error(Window? owner, string message, string title = "出错了")
            => Show(owner, title, message, Kind.Error, confirm: false);

        /// <summary>确认框：返回 true 表示用户点了确定。</summary>
        public static bool Confirm(Window? owner, string message, string title = "确认")
            => Show(owner, title, message, Kind.Warn, confirm: true);

        /// <summary>三态询问：保存/不保存/取消 这类"必须先表态才能继续"的场景。</summary>
        public static Choice Ask3(Window? owner, string message, string title,
            string yes = "保存", string no = "不保存", string cancel = "取消")
        {
            var dlg = Build(owner, title, message, Kind.Warn);
            dlg._tri = true;
            dlg.BtnOk.Content = yes;
            dlg.BtnNo.Content = no;
            dlg.BtnNo.Visibility = Visibility.Visible;
            dlg.BtnCancel.Content = cancel;
            dlg.BtnCancel.Visibility = Visibility.Visible;
            dlg.ShowDialog();
            if (dlg._ok) return Choice.Yes;
            return dlg._no ? Choice.No : Choice.Cancel;
        }

        private bool _tri;

        private static AppDialog Build(Window? owner, string title, string message, Kind kind)
        {
            var dlg = new AppDialog();
            dlg.Title = title;
            dlg.HeadText.Text = title;
            dlg.BodyText.Text = message;
            dlg.Accent.Background = kind switch
            {
                Kind.Error => BrushOf("#C62828"),
                Kind.Warn => BrushOf("#EF6C00"),
                _ => (System.Windows.Media.Brush)Application.Current.Resources["Accent"],
            };
            try
            {
                var win = owner;
                if (win == null || !win.IsVisible)
                {
                    foreach (Window w in Application.Current.Windows)
                        if (w != dlg && w.IsVisible) { win = w; break; }
                }
                if (win != null && win != dlg) dlg.Owner = win;
            }
            catch { }
            return dlg;
        }

        private static bool Show(Window? owner, string title, string message, Kind kind, bool confirm)
        {
            var dlg = Build(owner, title, message, kind);
            dlg.BtnCancel.Visibility = confirm ? Visibility.Visible : Visibility.Collapsed;
            dlg.BtnOk.Content = confirm ? "确定" : "知道了";
            dlg.ShowDialog();
            return dlg._ok;
        }

        private static System.Windows.Media.Brush BrushOf(string hex)
        {
            try { return (System.Windows.Media.Brush)new BrushConverter().ConvertFromString(hex)!; }
            catch { return System.Windows.Media.Brushes.Gray; }
        }

        private void BtnOk_Click(object sender, RoutedEventArgs e) { _ok = true; Close(); }
        private void BtnNo_Click(object sender, RoutedEventArgs e) { _no = true; Close(); }
        private void BtnCancel_Click(object sender, RoutedEventArgs e) { _ok = false; _no = false; Close(); }
    }
}
