using System.IO;

namespace HerMemory
{
    /// <summary>
    /// 主题：单 exe 内浅色/深色动态切换（DynamicResource 元素实时跟随）。
    /// 黑白反转（背景/墨色），灰、蓝青、红绿等语义色不变。偏好存注册表。
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
                Set("WindowBg", "#14181D");
                Set("Ink", "#F2F5F7");
                Set("FieldBg", "#1B2127");
                Set("Accent", "#22D3EE");
                Set("AccentHover", "#38BDF8");
            }
            else
            {
                Set("WindowBg", "#FAFBFC");
                Set("Ink", "#0F172A");
                Set("FieldBg", "#FFFFFF");
                Set("Accent", "#0891B2");
                Set("AccentHover", "#0EA5E9");
            }
        }
    }
}
