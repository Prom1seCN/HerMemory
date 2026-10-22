using System.IO;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using LinearGradientBrush = System.Windows.Media.LinearGradientBrush;
using SolidColorBrush = System.Windows.Media.SolidColorBrush;
using DropShadowEffect = System.Windows.Media.Effects.DropShadowEffect;

namespace HerMemory
{
    /// <summary>
    /// 主题：单 exe 内浅色/深色动态切换（DynamicResource 元素实时跟随）。
    /// 黑白反转（背景/墨色），灰、蓝青、红绿等语义色随明度重配——深色下若沿用浅色的
    /// #5A6B7C 这类灰，对比度只有 3:1 左右，正文会糊成一片。
    /// 键名与 App.xaml 里的默认值一一对应，两处必须同时增删。
    /// 除了纯色，还整体替换三样"有质感"的资源：主按钮渐变 AccentGradient、
    /// 首页状态卡水洗底 HeroWash、卡片投影 CardShadow（深色下阴影要更黑、更远）。
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
                res[key] = new SolidColorBrush(
                    (Color)ColorConverter.ConvertFromString(hex));
            }
            void Grad(string key, string a, string b)
            {
                var g = new LinearGradientBrush(
                    (Color)ColorConverter.ConvertFromString(a),
                    (Color)ColorConverter.ConvertFromString(b), 90);
                g.Freeze();
                res[key] = g;
            }

            if (dark)
            {
                Set("WindowBg", "#0C1117");
                Set("Ink", "#E9EFF5");
                Set("FieldBg", "#131A22");
                Set("Accent", "#22D3EE");
                Set("AccentHover", "#67E8F9");
                Set("CardBg", "#151C24");
                Set("CardBorder", "#26313B");
                Set("Muted", "#9DACBB");
                Set("Subtle", "#6C7C8C");
                Set("AccentSoft", "#0F2C35");
                Set("Hairline", "#1D262F");
                Set("ScrollThumb", "#3A4854");
                Set("OnAccent", "#06141A");
                Set("Danger", "#F87171");
                Set("Success", "#4ADE80");
                Set("Warn", "#FBBF24");
                Grad("AccentGradient", "#22D3EE", "#0FB5D6");
                Grad("HeroWash", "#17202A", "#102B33");
                res["CardShadow"] = new DropShadowEffect
                {
                    Color = (Color)ColorConverter.ConvertFromString("#000000"),
                    BlurRadius = 22, ShadowDepth = 3, Direction = 270, Opacity = 0.45,
                    RenderingBias = RenderingBias.Performance,
                };
            }
            else
            {
                Set("WindowBg", "#F5F7FA");
                Set("Ink", "#101828");
                Set("FieldBg", "#FFFFFF");
                Set("Accent", "#0891B2");
                Set("AccentHover", "#0EA5E9");
                Set("CardBg", "#FFFFFF");
                Set("CardBorder", "#E4EAF1");
                Set("Muted", "#5A6B7C");
                Set("Subtle", "#8B9AAA");
                Set("AccentSoft", "#E8F6FA");
                Set("Hairline", "#EEF2F6");
                Set("ScrollThumb", "#C9D4DF");
                Set("OnAccent", "#FFFFFF");
                Set("Danger", "#C62828");
                Set("Success", "#2E7D32");
                Set("Warn", "#EF6C00");
                Grad("AccentGradient", "#0AA0C2", "#0891B2");
                Grad("HeroWash", "#FFFFFF", "#F0FAFD");
                res["CardShadow"] = new DropShadowEffect
                {
                    Color = (Color)ColorConverter.ConvertFromString("#10243A"),
                    BlurRadius = 18, ShadowDepth = 2, Direction = 270, Opacity = 0.055,
                    RenderingBias = RenderingBias.Performance,
                };
            }
        }
    }
}
