using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace HerMemory
{
    /// <summary>
    /// 记忆时光机：用 PortableGit（随内核落位）给 vault 里的记忆目录做本地版本历史。
    ///
    /// 几个刻意的选择：
    ///  · 仓库放在 **%LOCALAPPDATA%\HerMemory\history**，不放进 vault——否则会跟用户文档一起被同步/备份工具
    ///    到手机、还会和 Obsidian 的 .git 插件抢同一个目录。
    ///  · 用 `--git-dir/--work-tree` 指向 vault，只跟踪 `HerMemory/memory/`，不碰用户文档。
    ///  · 每次编辑器保存后自动提交一条；手动「立即快照」也走同一条路。
    ///  · 没有 git 就整体降级为不可用（返回 false），不抛异常、不挡保存。
    /// </summary>
    internal static class MemoryHistory
    {
        private const string RelDir = "HerMemory/memory";

        public static string RepoDir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HerMemory", "history");

        private static string VaultDir => AppPaths.VaultDir;

        /// <summary>git 可执行文件：PATH 优先，其次 PM 托管的 PortableGit。</summary>
        public static string? GitExe
        {
            get
            {
                try
                {
                    var g = FindOnPath("git.exe");
                    if (g != null) return g;
                    var tools = Path.Combine(HermesCtl.HermesHome, "tools");
                    if (Directory.Exists(tools))
                    {
                        // 槽位名形如 git-2.53.0+3-win32-x64
                        foreach (var d in Directory.GetDirectories(tools, "git-*"))
                        {
                            // PortableGit 两种布局都有：cmd\git.exe 是包装器，bin\git.exe 是真身
                            foreach (var sub in new[] { "cmd", "bin" })
                            {
                                var exe = Path.Combine(d, sub, "git.exe");
                                if (File.Exists(exe)) return exe;
                            }
                        }
                    }
                    foreach (var sub in new[] { "cmd", "bin" })
                    {
                        var legacy = Path.Combine(HermesCtl.HermesHome, "git", sub, "git.exe");
                        if (File.Exists(legacy)) return legacy;
                    }
                    return null;
                }
                catch { return null; }
            }
        }

        private static string? FindOnPath(string name)
        {
            try
            {
                foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
                {
                    if (string.IsNullOrWhiteSpace(dir)) continue;
                    try
                    {
                        var p = Path.Combine(dir.Trim(), name);
                        if (File.Exists(p)) return p;
                    }
                    catch { }
                }
            }
            catch { }
            return null;
        }

        private static (int code, string output) Run(string args, int timeoutSec = 30)
        {
            var git = GitExe;
            if (git == null) return (-1, "找不到 git");
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = git,
                    Arguments = args,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8,
                    WorkingDirectory = VaultDir,
                };
                psi.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0";
                using var p = Process.Start(psi);
                if (p == null) return (-1, "git 启动失败");
                try { p.StandardInput.Close(); } catch { }
                var so = p.StandardOutput.ReadToEndAsync();
                var se = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(timeoutSec * 1000)) { try { p.Kill(true); } catch { } return (-1, "git 超时"); }
                try { System.Threading.Tasks.Task.WaitAll(new[] { so, se }, 3000); } catch { }
                var text = (so.IsCompletedSuccessfully ? so.Result : "") + (se.IsCompletedSuccessfully ? se.Result : "");
                return (p.ExitCode, text);
            }
            catch (Exception ex) { return (-1, ex.Message); }
        }

        private static string BaseArgs =>
            $"--git-dir=\"{RepoDir}\" --work-tree=\"{VaultDir}\" " +
            "-c user.name=\"HerMemory\" -c user.email=\"noreply@hermemory.local\" -c commit.gpgsign=false ";

        /// <summary>确保仓库存在。返回 false 表示这台机器上用不了（没 git / vault 不可写）。</summary>
        public static bool EnsureRepo()
        {
            try
            {
                if (!Directory.Exists(Path.Combine(VaultDir, RelDir))) return false;
                if (Directory.Exists(RepoDir) && Directory.Exists(Path.Combine(RepoDir, "refs"))) return true;
                if (GitExe == null) return false;

                Directory.CreateDirectory(Path.GetDirectoryName(RepoDir) ?? RepoDir);
                if (Directory.Exists(RepoDir))
                {
                    // 仓库目录在、refs 不全（初始化中断/被搬动）时**不能递归删**：
                    // objects 里可能已经有用户的历史快照。改名留档，再建新仓。
                    var broken = RepoDir + ".broken-" + DateTime.Now.ToString("yyyyMMddHHmmss");
                    Directory.Move(RepoDir, broken);
                }
                var init = Run($"init --bare \"{RepoDir}\"");
                if (init.code != 0) return false;
                Run($"--git-dir=\"{RepoDir}\" config core.bare false");
                Run($"--git-dir=\"{RepoDir}\" config core.worktree \"{VaultDir}\"");
                Run($"--git-dir=\"{RepoDir}\" config core.autocrlf false");

                var add = Run(BaseArgs + $"add -A -- \"{RelDir}\"");
                if (add.code != 0) return false;
                Run(BaseArgs + "commit -m \"初始化记忆历史\" --quiet");
                return Directory.Exists(Path.Combine(RepoDir, "refs"));
            }
            catch { return false; }
        }

        /// <summary>提交一次快照（没有改动就什么都不做）。返回 (ok, 说明)。</summary>
        public static (bool ok, string message) Commit(string message)
        {
            try
            {
                if (!EnsureRepo()) return (false, "记忆历史不可用（找不到 git 或记忆库）");
                var add = Run(BaseArgs + $"add -A -- \"{RelDir}\"");
                if (add.code != 0) return (false, "git add 失败：" + Short(add.output));

                // 有没有改动：diff --cached --quiet 返回 1 表示有
                var diff = Run(BaseArgs + "diff --cached --quiet");
                if (diff.code == 0) return (true, "内容没变，无需快照");
                if (diff.code != 1) return (false, "git diff 失败：" + Short(diff.output));

                var msg = (message ?? "快照").Replace("\"", "'");
                var commit = Run(BaseArgs + $"commit -m \"{msg}\" --quiet");
                return commit.code == 0 ? (true, "已记录快照") : (false, "git commit 失败：" + Short(commit.output));
            }
            catch (Exception ex) { return (false, ex.Message); }
        }

        public sealed record Snapshot(string Sha, DateTime Time, string Subject)
        {
            public string Display => Time.ToString("yyyy-MM-dd HH:mm:ss") + "  ·  " + Subject;
        }

        public static List<Snapshot> Log(int max = 200)
        {
            var list = new List<Snapshot>();
            try
            {
                if (!EnsureRepo()) return list;
                var r = Run(BaseArgs + $"log --format=%H%x1f%ct%x1f%s -n {max} -- \"{RelDir}\"", 60);
                if (r.code != 0) return list;
                foreach (var line in r.output.Replace("\r\n", "\n").Split('\n'))
                {
                    if (line.Trim().Length == 0) continue;
                    var parts = line.Split('\x1f');
                    if (parts.Length < 3) continue;
                    if (!long.TryParse(parts[1], out var epoch)) continue;
                    list.Add(new Snapshot(parts[0], DateTimeOffset.FromUnixTimeSeconds(epoch).LocalDateTime, parts[2]));
                }
            }
            catch { }
            return list;
        }

        /// <summary>某个 commit 里某个记忆文件的内容；文件不存在返回 null。</summary>
        public static string? ShowFile(string sha, string fileName)
        {
            try
            {
                var r = Run(BaseArgs + $"show \"{sha}:{RelDir}/{fileName}\"", 30);
                return r.code == 0 ? r.output : null;
            }
            catch { return null; }
        }

        /// <summary>该 commit 与当前工作树的差异（只针对一个文件）。</summary>
        public static string Diff(string sha, string fileName)
        {
            try
            {
                var r = Run(BaseArgs + $"diff \"{sha}\" -- \"{RelDir}/{fileName}\"", 30);
                return r.code == 0 ? r.output : Short(r.output);
            }
            catch (Exception ex) { return ex.Message; }
        }

        /// <summary>把某个文件的旧版本写回去（不提交，交给编辑器/下次保存记录）。</summary>
        public static bool RestoreFile(string sha, string fileName)
        {
            try
            {
                var content = ShowFile(sha, fileName);
                if (content == null) return false;
                var target = Path.Combine(VaultDir, RelDir, fileName);
                var tmp = target + ".hm-restore-" + Guid.NewGuid().ToString("N").Substring(0, 6);
                File.WriteAllBytes(tmp, new UTF8Encoding(false).GetBytes(content));
                if (File.Exists(target))
                {
                    try { File.Replace(tmp, target, null, true); }
                    catch { File.Move(tmp, target, true); }
                }
                else File.Move(tmp, target);
                return true;
            }
            catch { return false; }
        }

        /// <summary>历史条数（用于设置页/体检页显示）。</summary>
        public static int Count()
        {
            try
            {
                if (!EnsureRepo()) return 0;
                var r = Run(BaseArgs + $"rev-list --count HEAD -- \"{RelDir}\"", 30);
                return r.code == 0 && int.TryParse(r.output.Trim(), out var n) ? n : 0;
            }
            catch { return 0; }
        }

        private static string Short(string s)
        {
            s = (s ?? "").Trim();
            return s.Length <= 200 ? s : s.Substring(0, 200) + "…";
        }
    }
}
