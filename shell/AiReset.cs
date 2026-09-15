using System.IO;

namespace HerMemory
{
    /// <summary>「重置 AI」：不重装软件，把 AI 的记忆清空到首次使用的状态。
    ///
    /// 清理面（2026-09-15 按本机实测布局逐个确认，分组见 <see cref="Describe"/>）：
    ///   ① 记忆与身份 —— vault 里 MEMORY.md / USER.md 置空，SOUL.md / AGENTS.md 恢复出厂
    ///   ② 对话记录   —— state.db 一族（对话内容都在这里）与 sessions\
    ///   ③ 运行痕迹   —— logs\、kanban.db、cron 执行记录、cache\、channel_directory.json、pending_messages\
    ///   ④ 历史备份   —— `*.pre-hermemory.*`（install.ps1 第 5 段换链接时留下的旧身份副本）
    ///
    /// **不碰**：`.env`（API Key 与微信凭据）、`config.yaml`、`skills\`（见下）、
    /// 内核与运行时（bin/ hermes-agent/ node/ uv-python/ git/）、vault 里的用户文档。
    ///
    /// 两个刻意的取舍：
    ///   · **不用 `hermes memory reset`**：该命令（hermes_cli/subcommands/memory.py）只删
    ///     memories\MEMORY.md 与 USER.md —— 不含 SOUL / AGENTS / state.db；而且它是 unlink（删文件）
    ///     而非置空，会让注入槽位消失。覆盖面比这里小，用它反而要再补一遍。另外它的 `--target`
    ///     只接受 all / memory / user（`everything` 会直接被 argparse 拒掉）。
    ///   · **不动 `skills\`**：`.bundled_manifest` 里登记的是**单个技能名**（airtable、apple-notes…），
    ///     而 skills\ 下是**分类目录**（apple、creative…）——两者对不上，任何"按 manifest 求差"的实现
    ///     都会把整批内置技能误判成自建技能删掉。用户自建的技能属于用户资产，清不清该由用户决定。
    ///     现状：本机 15 个条目全部有 manifest 记录，即当前没有 AI 自建技能。</summary>
    internal static class AiReset
    {
        public sealed record ClearedItem(string Group, string Label);

        public sealed record FailedItem(string Group, string Label, string Error);

        /// <summary>执行结果。Ok 只表示"没有失败项"；Notes 里是"做成了但有话要说"的情况。</summary>
        public sealed class Report
        {
            public bool GatewayWasRunning;
            public bool Stopped;
            public bool Restarted;
            public string? BackupDir;
            public readonly List<ClearedItem> Cleared = new();
            public readonly List<FailedItem> Failed = new();
            public readonly List<string> Notes = new();
            public bool Ok => Failed.Count == 0;
        }

        private static string HomeDir =>
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        // ================= 执行计划 =================
        // 一处定义，三处共用：确认框（Describe）、执行（Run）、结果（Report）。
        // 这样"界面说的"与"实际做的"不可能不一致——本项目最贵的一类 bug 就是二者脱节。

        private sealed record Step(string Group, string Label, Func<bool> Run);

        private static List<Step> BuildPlan(string memoryDir, string factoryDir, string hh, string home) => new()
        {
            // —— ① 记忆与身份 ——
            new("记忆与身份", "MEMORY.md 置空",
                () => Write(memoryDir, "MEMORY.md", Array.Empty<byte>())),
            new("记忆与身份", "USER.md 置空",
                () => Write(memoryDir, "USER.md", Array.Empty<byte>())),
            new("记忆与身份", "SOUL.md 恢复出厂",
                () => Copy(Path.Combine(factoryDir, "SOUL.md"), Path.Combine(memoryDir, "SOUL.md"))),
            new("记忆与身份", "AGENTS.md 恢复出厂",
                () => Copy(Path.Combine(factoryDir, "AGENTS.md"), Path.Combine(memoryDir, "AGENTS.md"))),

            // —— ② 对话记录 ——
            new("对话记录", "state.db（含 WAL/SHM）",
                () => DeleteFileFamily(Path.Combine(hh, "state.db"))),
            new("对话记录", "sessions\\（会话索引）",
                () => DeleteTree(Path.Combine(hh, "sessions"))),

            // —— ③ 运行痕迹 ——
            new("运行痕迹", "logs\\（网关与 Agent 日志）",
                () => DeleteTree(Path.Combine(hh, "logs"))),
            new("运行痕迹", "kanban.db（任务板，含 WAL/SHM）",
                () => DeleteFileFamily(Path.Combine(hh, "kanban.db"))),
            new("运行痕迹", "cron\\executions.db（定时任务记录）",
                () => DeleteFileFamily(Path.Combine(hh, "cron", "executions.db"))),
            new("运行痕迹", "cron\\output\\（定时任务输出）",
                () => DeleteTree(Path.Combine(hh, "cron", "output"))),
            new("运行痕迹", "cache\\（工具与网页缓存）",
                () => DeleteTree(Path.Combine(hh, "cache"))),
            new("运行痕迹", "audio_cache\\",
                () => DeleteTree(Path.Combine(hh, "audio_cache"))),
            new("运行痕迹", "image_cache\\",
                () => DeleteTree(Path.Combine(hh, "image_cache"))),
            new("运行痕迹", "channel_directory.json（微信联系人目录）",
                () => DeleteFileFamily(Path.Combine(hh, "channel_directory.json"))),
            new("运行痕迹", "pending_messages\\（待投递消息）",
                () => DeleteTree(Path.Combine(hh, "pending_messages"))),

            // —— ④ 历史备份 ——
            // 只按 LinkOne 自己那两个命名去命中（`$dst.pre-hermemory.<时间戳>`，dst 只可能是这两处）；
            // **不在 HOME 下做通配扫描**——那是拿一个模式去翻用户的整个主目录，没必要也不该。
            new("历史备份", "SOUL.md / AGENTS.md 的 .pre-hermemory 旧副本",
                () => DeleteByPattern(hh, "SOUL.md.pre-hermemory.*")
                    | DeleteByPattern(home, ".hermes.md.pre-hermemory.*")),
        };

        /// <summary>确认框要展示的"将清除什么"。与 <see cref="Run"/> 同源。</summary>
        public static List<(string Group, string Label)> Describe(string memoryDir, string factoryDir)
        {
            var plan = BuildPlan(memoryDir, factoryDir, HermesCtl.HermesHome, HomeDir);
            return plan.Select(s => (s.Group, s.Label)).ToList();
        }

        // ================= 主流程 =================

        /// <param name="memoryDir">vault 里的记忆目录（AI 最终读到的就是这里，经 junction/符号链接注入）</param>
        /// <param name="factoryDir">出厂模板目录（仓库 memory\ 或解压后的 payload\memory\）</param>
        /// <param name="progress">进度回调，用于把当前步骤回显到界面</param>
        public static Report Run(string memoryDir, string factoryDir, Action<string>? progress = null)
        {
            var r = new Report();

            // 出厂模板必须先在：缺了就只能"写空"，那会把 SOUL/AGENTS 也一起清掉——
            // 用户要的是恢复出厂，不是把人格删掉。宁可中止。
            foreach (var f in new[] { "SOUL.md", "AGENTS.md" })
            {
                var src = Path.Combine(factoryDir, f);
                if (!File.Exists(src)) r.Failed.Add(new("记忆与身份", f, "出厂模板缺失：" + src));
            }
            if (r.Failed.Count > 0) { r.Notes.Add("已中止，未修改任何文件。"); return r; }
            if (!Directory.Exists(memoryDir)) { r.Failed.Add(new("记忆与身份", "记忆目录", "不存在：" + memoryDir)); return r; }

            var hh = HermesCtl.HermesHome;
            var home = HomeDir;

            // ---------- ① 停 Gateway ----------
            // 两个理由，都不是小事：
            //   a) 会话库（state.db）被运行中的 gateway 持有，此刻删除等于在别人写字时抽走纸；
            //   b) 更要命的是——gateway 会把它的学习记忆**写回** memories\，重置完它再写一次，
            //      等于白清。所以必须确认进程真的退出了才继续。
            // 判据取 gateway.pid 的进程存活，而不是解析 `gateway status`：CLI 读不到时会返回
            // "stopped"，那种误判正好会让我们带着一个活着的 gateway 去删文件。
            progress?.Invoke("正在停止 Gateway……");
            try
            {
                r.GatewayWasRunning = HermesCtl.GatewayProcessAlive();
                HermesCtl.Run("gateway stop", 120);
                for (int i = 0; i < 25 && HermesCtl.GatewayProcessAlive(); i++) Thread.Sleep(400);
                // 稳压：确认不是"停了一瞬又被拉起来"（登录触发的计划任务通常不会，
                // 但这里赌错的代价是删掉一个活着的进程正持有的会话库，不值得赌）
                if (!HermesCtl.GatewayProcessAlive()) Thread.Sleep(1200);
                r.Stopped = !HermesCtl.GatewayProcessAlive();
            }
            catch { r.Stopped = false; }

            if (!r.Stopped)
            {
                r.Failed.Add(new("对话记录", "Gateway", "未能停止，已中止。会话库可能正被占用，此时删除会损坏它。"));
                r.Notes.Add("已中止，未修改任何文件。");
                return r;
            }

            // ---------- ② 备份 ----------
            // 放在 %LOCALAPPDATA%\HerMemory 下：不在同步范围内，AI 也不会读它。
            // 只备"小而不可再生"的那几样；logs\ 与 cache\ 是有体积的诊断/派生数据，不备（确认框里写明）。
            progress?.Invoke("正在备份当前记忆……");
            try
            {
                var backup = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "HerMemory", "reset-backup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
                Directory.CreateDirectory(backup);

                foreach (var f in new[] { "SOUL.md", "AGENTS.md", "MEMORY.md", "USER.md" })
                {
                    var src = Path.Combine(memoryDir, f);
                    if (File.Exists(src)) File.Copy(src, Path.Combine(backup, f), true);
                }
                foreach (var f in new[]
                {
                    Path.Combine(hh, "sessions", "sessions.json"),
                    Path.Combine(hh, "state.db"),
                    Path.Combine(hh, "kanban.db"),
                    Path.Combine(hh, "channel_directory.json"),
                })
                {
                    if (!File.Exists(f)) continue;
                    if (new FileInfo(f).Length > 64L * 1024 * 1024) continue;   // 异常大的库不备，避免拖住界面
                    File.Copy(f, Path.Combine(backup, Path.GetFileName(f)), true);
                }
                r.BackupDir = backup;
            }
            catch (Exception ex) { r.Notes.Add("备份未完成：" + ex.Message); }

            // ---------- ③ 按计划执行 ----------
            foreach (var step in BuildPlan(memoryDir, factoryDir, hh, home))
            {
                progress?.Invoke("正在清除：" + step.Label);
                try
                {
                    if (step.Run()) r.Cleared.Add(new(step.Group, step.Label));
                }
                catch (Exception ex) { r.Failed.Add(new(step.Group, step.Label, ex.Message)); }
            }

            // ---------- ④ 校验：写进 vault ≠ AI 读得到 ----------
            // 四个文件都是经符号链接/junction 注入的（SOUL → HERMES_HOME\SOUL.md，
            // AGENTS → ~\.hermes.md，MEMORY/USER → HERMES_HOME\memories\）。链接一旦断掉，
            // 我们写 vault 会"成功"，而 AI 仍读旧内容。所以按 AI 的读取位置回头验一次。
            progress?.Invoke("正在校验注入槽位……");
            var slots = new (string Label, string Path, bool MustBeEmpty)[]
            {
                ("SOUL.md",   Path.Combine(hh, "SOUL.md"),               false),
                ("AGENTS.md", Path.Combine(home, ".hermes.md"),          false),
                ("MEMORY.md", Path.Combine(hh, "memories", "MEMORY.md"), true),
                ("USER.md",   Path.Combine(hh, "memories", "USER.md"),   true),
            };
            foreach (var s in slots)
            {
                if (!File.Exists(s.Path)) { r.Notes.Add($"AI 读取位置不可用：{s.Path}（重跑安装向导可修复）"); continue; }
                try
                {
                    if (s.MustBeEmpty)
                    {
                        if (new FileInfo(s.Path).Length != 0) r.Notes.Add("未同步到 AI 读取位置：" + s.Path);
                    }
                    else
                    {
                        var src = Path.Combine(factoryDir, s.Label);
                        if (!File.ReadAllBytes(s.Path).SequenceEqual(File.ReadAllBytes(src)))
                            r.Notes.Add("未同步到 AI 读取位置：" + s.Path);
                    }
                }
                catch { }
            }

            // ---------- ⑤ 回到用户原来看到的状态 ----------
            // 原本在运行 → 重启。不重启的话，用户看到的是"AI 掉线了"，而重置的语义是
            // "从头开始使用"——那必须让 AI 重新读一遍刚恢复出厂的身份与空记忆。
            // 原本就是停的 → 保持停止，不擅自把用户的机器状态改掉。
            if (r.GatewayWasRunning)
            {
                progress?.Invoke("正在重新启动 Gateway……");
                try
                {
                    HermesCtl.Run("gateway start", 120);
                    // 启动是异步的（gateway 自己写 pid 文件），单次判定会误报"没起来"
                    for (int i = 0; i < 25 && !HermesCtl.GatewayProcessAlive(); i++) Thread.Sleep(400);
                    r.Restarted = HermesCtl.GatewayProcessAlive() || HermesCtl.State() == "running";
                }
                catch { r.Restarted = false; }
            }
            return r;
        }

        // ================= 文件操作 =================

        private static bool Write(string dir, string name, byte[] bytes)
        {
            File.WriteAllBytes(Path.Combine(dir, name), bytes);
            return true;
        }

        private static bool Copy(string src, string dst)
        {
            File.Copy(src, dst, true);
            return true;
        }

        /// <summary>删一个文件及其全部同名 sidecar（`state.db` → `state.db*`，即 -wal/-shm/-journal/
        /// 锁文件/修复快照一并带走）。口径对齐上游 `hermes_state._unlink_db_triple`：它同样是
        /// "主库 + 全部 sidecar"，且 Windows 下带重试——刚关闭的 SQLite 句柄可能被系统多留几百毫秒。
        /// 只删主库会把数据留在 WAL 里，下次打开时连带恢复："删了但没删掉"，且不报任何错。</summary>
        private static bool DeleteFileFamily(string path)
        {
            var dir = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return false;

            var any = false;
            foreach (var v in Directory.GetFiles(dir, Path.GetFileName(path) + "*"))
            {
                DeleteOne(v);
                any = true;
            }
            return any;
        }

        private static bool DeleteByPattern(string dir, string pattern)
        {
            if (!Directory.Exists(dir)) return false;
            var any = false;
            foreach (var v in Directory.GetFiles(dir, pattern))
            {
                DeleteOne(v);
                any = true;
            }
            return any;
        }

        private static void DeleteOne(string file)
        {
            for (int attempt = 0; ; attempt++)
            {
                try { File.Delete(file); return; }
                catch (Exception) when (attempt < 9) { Thread.Sleep(60); }   // 句柄尚未释放 → 重试
            }
        }

        private static bool DeleteTree(string path)
        {
            for (int attempt = 0; ; attempt++)
            {
                try { Directory.Delete(path, true); return true; }
                catch (DirectoryNotFoundException) { return false; }         // 本来就没有 → 不算清除过
                catch (Exception) when (attempt < 4) { Thread.Sleep(120); }
            }
        }
    }
}
