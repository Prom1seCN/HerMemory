using System.IO;

namespace HerMemory
{
    /// <summary>
    /// 主题：浅色为默认；文件名以 _dark 结尾的 exe 自动切深色。
    /// 黑白反转（背景/墨色），灰、蓝青、红绿等语义色不变。
    /// </summary>
    public static class Theme
    {
        public static void Apply()
        {
            bool dark = Path.GetFileNameWithoutExtension(Environment.ProcessPath ?? "")
                .EndsWith("_dark", StringComparison.OrdinalIgnoreCase);

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
            }
            else
            {
                Set("WindowBg", "#FAFBFC");
                Set("Ink", "#0F172A");
                Set("FieldBg", "#FFFFFF");
            }
        }
    }
}
