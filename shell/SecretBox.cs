using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Brushes = System.Windows.Media.Brushes;

namespace HerMemory
{
    /// <summary>
    /// 密码样式的输入框：默认遮挡（●），右侧「显示/隐藏」可临时查看。
    /// 用在 API Key 这类会被旁人/录屏看到的字段上。
    ///
    /// 为什么不用 PasswordBox 直接替换 TextBox：PasswordBox.Password 不是依赖属性、
    /// 也不能绑定，调用方全都在读 .Text；这里用一个组合控件把两者包起来，对外仍是 Text。
    /// </summary>
    public sealed class SecretBox : Grid
    {
        private readonly PasswordBox _pwd = new();
        private readonly System.Windows.Controls.TextBox _txt = new();
        private readonly System.Windows.Controls.Button _eye = new();
        private bool _sync;

        public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
            nameof(Text), typeof(string), typeof(SecretBox),
            new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, OnTextChanged));

        public string Text
        {
            get => GetValue(TextProperty) as string ?? "";
            set => SetValue(TextProperty, value ?? "");
        }

        public SecretBox()
        {
            Height = 38;
            var border = new Border
            {
                CornerRadius = new CornerRadius(9),
                BorderThickness = new Thickness(1),
            };
            border.SetResourceReference(Border.BackgroundProperty, "FieldBg");
            border.SetResourceReference(Border.BorderBrushProperty, "CardBorder");

            _pwd.PasswordChar = '●';
            _pwd.BorderThickness = new Thickness(0);
            _pwd.Background = Brushes.Transparent;
            _pwd.Padding = new Thickness(11, 0, 4, 0);
            _pwd.FontSize = 13;
            _pwd.VerticalContentAlignment = VerticalAlignment.Center;
            _pwd.PasswordChanged += (_, _) =>
            {
                if (_sync) return;
                SetCurrentValue(TextProperty, _pwd.Password);
            };

            _txt.BorderThickness = new Thickness(0);
            _txt.Background = Brushes.Transparent;
            _txt.Padding = new Thickness(11, 0, 4, 0);
            _txt.FontSize = 13;
            _txt.VerticalContentAlignment = VerticalAlignment.Center;
            _txt.Visibility = Visibility.Collapsed;
            _txt.TextChanged += (_, _) =>
            {
                if (_sync) return;
                SetCurrentValue(TextProperty, _txt.Text);
            };

            _eye.Content = "显示";
            _eye.Width = 48;
            _eye.FontSize = 11.5;
            _eye.Cursor = System.Windows.Input.Cursors.Hand;
            _eye.Focusable = false;
            if (System.Windows.Application.Current?.Resources["LinkButton"] is Style link) _eye.Style = link;
            _eye.Click += (_, _) => Toggle();

            var host = new Grid();
            host.Children.Add(_pwd);
            host.Children.Add(_txt);

            var dock = new DockPanel();
            DockPanel.SetDock(_eye, Dock.Right);
            dock.Children.Add(_eye);
            dock.Children.Add(host);
            border.Child = dock;
            Children.Add(border);
        }

        private static void OnTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            var box = (SecretBox)d;
            if (box._sync) return;
            var value = e.NewValue as string ?? "";
            box._sync = true;
            try
            {
                if (box._pwd.Password != value) box._pwd.Password = value;
                if (box._txt.Text != value) box._txt.Text = value;
            }
            finally { box._sync = false; }
        }

        private void Toggle()
        {
            var show = _txt.Visibility != Visibility.Visible;
            _sync = true;
            try
            {
                if (show)
                {
                    _txt.Text = _pwd.Password;
                    _pwd.Visibility = Visibility.Collapsed;
                    _txt.Visibility = Visibility.Visible;
                    _eye.Content = "隐藏";
                    _txt.Focus();
                    _txt.CaretIndex = _txt.Text.Length;
                }
                else
                {
                    _pwd.Password = _txt.Text;
                    _txt.Visibility = Visibility.Collapsed;
                    _pwd.Visibility = Visibility.Visible;
                    _eye.Content = "显示";
                    _pwd.Focus();
                }
            }
            finally { _sync = false; }
        }
    }
}
