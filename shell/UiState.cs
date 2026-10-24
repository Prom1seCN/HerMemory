using System;
using System.IO;
using System.Text.Json;

namespace HerMemory
{
    /// <summary>界面侧的小状态，与内核配置分开存（换内核、重装内核都不该丢"引导做完了"这件事）。
    /// 目前只有一项：首次启动的三步配置是否走完。</summary>
    internal static class UiState
    {
        private static string FilePath
        {
            get
            {
                try
                {
                    return System.IO.Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "HerMemory", "ui-state.json");
                }
                catch { return ""; }
            }
        }

        private static bool _loaded;
        private static bool _setupDone;

        private static void Load()
        {
            if (_loaded) return;
            _loaded = true;
            try
            {
                var p = FilePath;
                if (p.Length == 0 || !File.Exists(p)) return;
                using var doc = JsonDocument.Parse(File.ReadAllText(p));
                if (doc.RootElement.TryGetProperty("setup_done", out var v) && v.ValueKind == JsonValueKind.True)
                    _setupDone = true;
            }
            catch { }
        }

        /// <summary>首次启动的三步配置是否已完成。读失败一律当作"没做过"，宁可多问一次。</summary>
        public static bool SetupDone
        {
            get { Load(); return _setupDone; }
            set
            {
                Load();
                _setupDone = value;
                try
                {
                    var p = FilePath;
                    if (p.Length == 0) return;
                    Directory.CreateDirectory(System.IO.Path.GetDirectoryName(p)!);
                    HermesCtl.WriteTextAtomic(p, new[] { JsonSerializer.Serialize(new { setup_done = value }) });
                }
                catch { }
            }
        }
    }
}
