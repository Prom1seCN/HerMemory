using System;
using System.Diagnostics;
using System.Net.Http;
using System.Threading;

namespace HerMemory
{
    /// <summary>打开 Web 管理面板（hermes dashboard）。
    /// 面板是**独立**于本控制界面的另一套东西：控制界面负责安装/记忆/体检/微信，
    /// 面板负责配置、会话、日志、cron、插件。这里只做「确保在跑 + 打开浏览器」。</summary>
    internal static class WebPanel
    {
        private const string Url = "http://127.0.0.1:9119/";

        public static void Open()
        {
            try
            {
                if (!Probe(1200))
                {
                    StartServer();
                    for (var i = 0; i < 24 && !Probe(800); i++) Thread.Sleep(500);
                }
            }
            catch { }
            try { Process.Start(new ProcessStartInfo(Url) { UseShellExecute = true }); } catch { }
        }

        private static bool Probe(int timeoutMs)
        {
            try
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(timeoutMs) };
                using var _ = http.GetAsync(Url).GetAwaiter().GetResult();
                return true;
            }
            catch { return false; }
        }

        private static void StartServer()
        {
            try
            {
                var cli = HermesCtl.WorkingCli();
                if (string.IsNullOrEmpty(cli)) return;
                Process.Start(new ProcessStartInfo
                {
                    FileName = cli,
                    Arguments = "dashboard --no-open --port 9119",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                });
            }
            catch { }
        }
    }
}
