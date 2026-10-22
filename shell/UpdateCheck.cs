using System.Net.Http;
using System.Text.Json;

namespace HerMemory
{
    /// <summary>
    /// 更新检查：只问 GitHub 的「最新 release」，拿到 tag 就跟当前程序集版本比。
    /// 不下载、不安装、不驻留——有新版只在顶栏挂一个可点的胶囊。
    /// 断网 / 仓库还没发版（404）/ 限流（403）都返回 null，调用方静默忽略。
    /// </summary>
    public static class UpdateCheck
    {
        public const string Repo = "Prom1seCN/HerMemory";
        public static string ReleasesPage => "https://github.com/" + Repo + "/releases/latest";

        public static async Task<(string Tag, string Url)?> LatestAsync()
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(7) };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("HerMemory-UpdateCheck");
                var json = await http.GetStringAsync("https://api.github.com/repos/" + Repo + "/releases/latest");
                using var doc = JsonDocument.Parse(json);
                if (!doc.RootElement.TryGetProperty("tag_name", out var tagEl)) return null;
                var tag = tagEl.GetString() ?? "";
                var url = doc.RootElement.TryGetProperty("html_url", out var urlEl)
                    ? urlEl.GetString() ?? ReleasesPage : ReleasesPage;
                return string.IsNullOrWhiteSpace(tag) ? null : (tag, url);
            }
            catch { return null; }
        }

        /// <summary>tag 允许带 v 前缀；语义化版本用 System.Version 比较（0.2.0 / 0.2.0.1 都认）。</summary>
        public static bool IsNewer(string tag, Version current)
        {
            var t = tag.Trim().TrimStart('v', 'V');
            return Version.TryParse(t, out var v) && v > current;
        }
    }
}
