using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace HerMemory
{
    internal enum HealthFix
    {
        None,
        StartGateway,
        InstallGateway,
        Reinstall,
        OpenLogs,
    }

    internal sealed class HealthItem
    {
        public string Title = "";
        public string Status = "ok";     // ok / warn / fail
        public string Detail = "";
        public HealthFix Fix = HealthFix.None;
    }

    /// <summary>
    /// 本机体检：把「AI 不回话」这类问题拆成可判断的几条，全都用本地信息判，不调模型。
    ///
    /// 判据尽量贴近上游自己的口径：
    ///  · 内核 = hermes --version 能跑（文件在场不算，v0.22 起是 uv 启动器）
    ///  · 运行环境 = PM 记录的 venv（installs/<key>/facts.json）
    ///  · 注入槽位 = 三个符号链接/junction 是否还指向 vault
    /// 每一项都带一个「怎么修」的枚举，界面据此给按钮——诊断和修复不能只靠文字。
    /// </summary>
    internal static class HealthCheck
    {
        public static List<HealthItem> Run()
        {
            var items = new List<HealthItem>();
            items.Add(Kernel());
            items.Add(Runtime());
            items.Add(Gateway());
            items.Add(GatewayTask());
            items.Add(InjectionSlots());
            items.Add(VaultFiles());
            items.Add(Disk());
            items.Add(MemoryBudget());
            items.Add(Logs());
            return items;
        }

        private static HealthItem Kernel()
        {
            var item = new HealthItem { Title = "Hermes 内核", Fix = HealthFix.Reinstall };
            try
            {
                var cli = HermesCtl.WorkingCli();
                if (cli == null)
                {
                    item.Status = "fail";
                    item.Detail = "hermes 命令跑不起来。运行安装包可修复（已完成步骤会跳过）。";
                    return item;
                }
                var ver = HermesCtl.VersionOf(cli);
                var want = HermesCtl.PinnedKernelVersion;
                if (string.IsNullOrEmpty(ver))
                {
                    item.Status = "warn";
                    item.Detail = "命令可运行，但版本号读不出来：" + cli;
                }
                else if (!string.Equals(ver, want, StringComparison.Ordinal))
                {
                    // 能跑不等于跑对了：0.1.0 的 v0.21 也能跑，但 PM/记忆路径全不一样。
                    item.Status = "warn";
                    item.Detail = $"v{ver}（本发行版为 v{want}）。运行安装包可升级，记忆与配置保留。";
                }
                else
                {
                    item.Status = "ok";
                    item.Detail = "v" + ver + " · " + cli;
                }
            }
            catch (Exception ex) { item.Status = "fail"; item.Detail = ex.Message; }
            return item;
        }

        private static HealthItem Runtime()
        {
            var item = new HealthItem { Title = "运行环境（PM）", Fix = HealthFix.Reinstall };
            try
            {
                var venv = HermesCtl.PmVenvDir;
                if (venv == null)
                {
                    item.Status = "fail";
                    item.Detail = "找不到 PM 托管的 Python 环境（installs/*/facts.json）。";
                }
                else
                {
                    item.Status = "ok";
                    item.Detail = venv;
                }
            }
            catch (Exception ex) { item.Status = "fail"; item.Detail = ex.Message; }
            return item;
        }

        private static HealthItem Gateway()
        {
            var item = new HealthItem { Title = "网关（微信通道）", Fix = HealthFix.StartGateway };
            try
            {
                var state = HermesCtl.State();
                item.Status = state == "running" ? "ok" : "fail";
                item.Detail = state == "running" ? "运行中" : "已停止 —— 停着就收不到微信消息";
            }
            catch (Exception ex) { item.Status = "fail"; item.Detail = ex.Message; }
            return item;
        }

        private static HealthItem GatewayTask()
        {
            var item = new HealthItem { Title = "开机自启任务", Fix = HealthFix.InstallGateway };
            try
            {
                if (HermesCtl.GatewayTaskUsable())
                {
                    item.Status = "ok";
                    item.Detail = "计划任务 Hermes_Gateway 与启动脚本都在";
                }
                else
                {
                    item.Status = "warn";
                    item.Detail = "计划任务缺失或启动脚本已被删 —— 重启电脑后网关不会自动起来";
                }
            }
            catch (Exception ex) { item.Status = "warn"; item.Detail = ex.Message; }
            return item;
        }

        private static HealthItem InjectionSlots()
        {
            var item = new HealthItem { Title = "记忆注入槽位", Fix = HealthFix.Reinstall };
            try
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                var soul = Path.Combine(HermesCtl.HermesHome, "SOUL.md");
                var agents = Path.Combine(home, ".hermes.md");
                var memories = Path.Combine(HermesCtl.HermesHome, "memories");

                var soulOk = IsLink(soul);
                var agentsOk = IsLinkOrFile(agents);
                var memOk = IsLink(memories);

                var bad = new List<string>();
                if (!soulOk) bad.Add("SOUL.md");
                if (!agentsOk) bad.Add(".hermes.md");
                if (!memOk) bad.Add("memories\\");

                if (bad.Count == 0)
                {
                    item.Status = "ok";
                    item.Detail = "三个槽位都指向记忆库";
                }
                else
                {
                    item.Status = "fail";
                    item.Detail = "断了：" + string.Join("、", bad) + "（改了记忆 AI 也读不到）";
                }
            }
            catch (Exception ex) { item.Status = "fail"; item.Detail = ex.Message; }
            return item;
        }

        private static bool IsLink(string path)
        {
            try
            {
                if (!Directory.Exists(path) && !File.Exists(path)) return false;
                var attrs = File.GetAttributes(path);
                return (attrs & FileAttributes.ReparsePoint) != 0;
            }
            catch { return false; }
        }

        private static bool IsLinkOrFile(string path)
        {
            try
            {
                if (!File.Exists(path)) return false;
                return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
            }
            catch { return false; }
        }

        private static HealthItem VaultFiles()
        {
            var item = new HealthItem { Title = "记忆库文件", Fix = HealthFix.Reinstall };
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    "vault", "HerMemory", "memory");
                if (!Directory.Exists(dir))
                {
                    item.Status = "fail";
                    item.Detail = "记忆库不存在：" + dir;
                    return item;
                }
                var missing = new[] { "MEMORY.md", "USER.md", "SOUL.md", "AGENTS.md", "AUTOMATION.md" }
                    .Where(f => !File.Exists(Path.Combine(dir, f))).ToList();
                item.Status = missing.Count == 0 ? "ok" : "fail";
                item.Detail = missing.Count == 0
                    ? "五个记忆文件齐全"
                    : "缺：" + string.Join("、", missing);
            }
            catch (Exception ex) { item.Status = "fail"; item.Detail = ex.Message; }
            return item;
        }

        private static HealthItem Disk()
        {
            var item = new HealthItem { Title = "磁盘空间", Fix = HealthFix.None };
            try
            {
                var root = Path.GetPathRoot(HermesCtl.HermesHome) ?? "C:\\";
                var di = new DriveInfo(root);
                var gb = di.AvailableFreeSpace / 1024.0 / 1024 / 1024;
                item.Status = gb < 1 ? "fail" : gb < 3 ? "warn" : "ok";
                item.Detail = $"{root} 剩余 {gb:F1} GB";
            }
            catch (Exception ex) { item.Status = "warn"; item.Detail = ex.Message; }
            return item;
        }

        private static HealthItem MemoryBudget()
        {
            var item = new HealthItem { Title = "记忆预算", Fix = HealthFix.None };
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    "vault", "HerMemory", "memory");
                var memFile = Path.Combine(dir, "MEMORY.md");
                if (!File.Exists(memFile)) { item.Status = "warn"; item.Detail = "找不到 MEMORY.md"; return item; }
                var chars = File.ReadAllText(memFile).Length;
                var limit = Parse(HermesCtl.Run("config get memory.memory_char_limit", 20));
                if (limit <= 0)
                {
                    item.Status = "ok";
                    item.Detail = $"MEMORY.md {chars} 字";
                }
                else if (chars > limit)
                {
                    item.Status = "warn";
                    item.Detail = $"MEMORY.md {chars} 字，超过预算 {limit}（不丢内容，但 AI 下次写记忆前会先要求自己整合）";
                }
                else
                {
                    item.Status = "ok";
                    item.Detail = $"MEMORY.md {chars} / {limit} 字";
                }
            }
            catch (Exception ex) { item.Status = "warn"; item.Detail = ex.Message; }
            return item;
        }

        private static int Parse(string s)
        {
            var m = System.Text.RegularExpressions.Regex.Match(s ?? "", @"(\d{2,7})");
            return m.Success ? int.Parse(m.Groups[1].Value) : 0;
        }

        private static HealthItem Logs()
        {
            var item = new HealthItem { Title = "最近日志", Fix = HealthFix.OpenLogs };
            try
            {
                var dir = HermesCtl.LogsDir;
                if (!Directory.Exists(dir)) { item.Status = "ok"; item.Detail = "还没有日志目录"; return item; }
                var newest = new DirectoryInfo(dir).GetFiles("*.log", SearchOption.AllDirectories)
                    .OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault();
                if (newest == null) { item.Status = "ok"; item.Detail = "还没有日志文件"; return item; }

                var lines = File.ReadAllLines(newest.FullName).TakeLast(400).ToList();
                int errs = lines.Count(l => l.Contains("ERROR", StringComparison.OrdinalIgnoreCase)
                                            || l.Contains("Traceback", StringComparison.Ordinal));
                item.Status = errs == 0 ? "ok" : "warn";
                item.Detail = errs == 0
                    ? $"{newest.Name}：最近 400 行没有错误"
                    : $"{newest.Name}：最近 400 行里有 {errs} 行错误";
            }
            catch (Exception ex) { item.Status = "warn"; item.Detail = ex.Message; }
            return item;
        }
    }
}
