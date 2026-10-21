using System.IO;

namespace HerMemory
{
    /// <summary>
    /// 主题：单 exe 内浅色/深色动态切换（DynamicResource 元素实时跟随）。
    /// 黑白反转（背景/墨色），灰、蓝青、红绿等语义色随明度重配——深色下若沿用浅色的
    /// #546E7A 这类灰，对比度只有 3:1 左右，正文会糊成一片。
    /// 键名与 App.xaml 里的默认值一一对应，两处必须同时增删。
    /// </summary>
    public static class Theme
    {
        private const string Key = @"Software\HerMemory";

        public static bool IsDark
        {
            get
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key);
                return k?.GetValue("DarkMode") as string == "1";
            }
        }

        public static void Apply() => Apply(IsDark);

        /// <summary>切换主题并实时生效（DynamicResource 消费者自动跟随）。</summary>
        public static void SetDark(bool dark)
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key);
            k.SetValue("DarkMode", dark ? "1" : "0");
            Apply(dark);
        }

        /// <summary>深色标题栏：Win10 1809+ 用属性 20，更早的用 19。失败就算了，不影响功能。</summary>
        public static void ApplyTitleBar(System.Windows.Window w)
        {
            try
            {
                var h = new System.Windows.Interop.WindowInteropHelper(w).Handle;
                if (h == IntPtr.Zero) return;
                var flag = IsDark ? 1 : 0;
                if (DwmSetWindowAttribute(h, 20, ref flag, sizeof(int)) != 0)
                    DwmSetWindowAttribute(h, 19, ref flag, sizeof(int));
            }
            catch { }
        }

        [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        private static void Apply(bool dark)
        {
            var res = System.Windows.Application.Current.Resources;
            void Set(string key, string hex)
            {
                res[key] = new System.Windows.Media.SolidColorBrush(
                    (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
            }

            if (dark)
            {
                Set("WindowBg", "#0F141A");
                Set("Ink", "#E9EFF5");
                Set("FieldBg", "#171E26");
                Set("Accent", "#22D3EE");
                Set("AccentHover", "#38BDF8");
                Set("CardBg", "#161E27");
                Set("CardBorder", "#2A3742");
                Set("Muted", "#9AAABA");
                Set("Subtle", "#6E7F8F");
                Set("AccentSoft", "#10313A");
                Set("Hairline", "#1C242D");
                Set("ScrollThumb", "#3A4854");
                Set("OnAccent", "#08151C");
                Set("Danger", "#F87171");
                Set("Success", "#4ADE80");
                Set("Warn", "#FBBF24");
            }
            else
            {
                Set("WindowBg", "#F6F8FA");
                Set("Ink", "#0F172A");
                Set("FieldBg", "#FFFFFF");
                Set("Accent", "#0891B2");
                Set("AccentHover", "#0EA5E9");
                Set("CardBg", "#FFFFFF");
                Set("CardBorder", "#E3EAF1");
                Set("Muted", "#55677A");
                Set("Subtle", "#8C9CAC");
                Set("AccentSoft", "#E7F6FA");
                Set("Hairline", "#EDF1F5");
                Set("ScrollThumb", "#C8D3DD");
                Set("OnAccent", "#FFFFFF");
                Set("Danger", "#C62828");
                Set("Success", "#2E7D32");
                Set("Warn", "#EF6C00");
            }
        }
    }
}
