using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.Win32;

namespace HerMemory
{
    /// <summary>「设置 → 应用」「控制面板 → 程序和功能」里的卸载项。
    ///
    /// 目的：让 HerMemory 在系统里表现为一个正常的已安装程序——能查看名称/版本/发布者/占用，
    /// 并可被 Windows 直接卸载，而不必先找到 exe。
    ///
    /// **写入 HKLM（不是 HKCU）**：拆包后程序本体落在 Program Files，属于机器级安装，
    /// 卸载项也应在机器级视图里——这样它出现在「程序和功能」的全局列表，任何用户都能看到并卸载。
    /// 代价是**需要提权**：安装期已提权（写 Program Files 本就需要），日常启动**不再重写**
    /// （启动多为普通权限，重写必然失败；且路径在 Program Files 里稳定，没有"exe 被移动"要修的场景）。
    ///
    /// `UninstallString` 指向稳定的 `Program Files\HerMemory\HerMemory.exe --uninstall`。
    /// 系统以调用者权限启动它，删 Program Files 需要管理员——由程序自身**自提权**补上
    /// （MainWindow 的 TryRelaunchElevated），所以这里不需要 RunAs 前缀。</summary>
    internal static class UninstallEntry
    {
        private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\HerMemory";
        private const string FallbackPublisher = "Prom1seCN";

        /// <summary>安装成功时写入（需要提权）。可重复调用（覆盖式，幂等）。
        /// appDir = 程序本体的落地目录；exe 取该目录下的 HerMemory.exe。</summary>
        public static void Register(string appDir)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(appDir)) return;
                var exe = Path.Combine(appDir, "HerMemory.exe");
                if (!File.Exists(exe)) return;

                var ver = (System.Reflection.Assembly.GetExecutingAssembly().GetName().Version
                           ?? new Version(0, 1, 0)).ToString(3);

                using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
                using var k = baseKey.CreateSubKey(KeyPath, true);
                if (k == null) return;

                k.SetValue("DisplayName", "HerMemory", RegistryValueKind.String);
                k.SetValue("DisplayVersion", ver, RegistryValueKind.String);
                k.SetValue("Publisher", Publisher(), RegistryValueKind.String);
                k.SetValue("DisplayIcon", $"\"{exe}\",0", RegistryValueKind.String);
                k.SetValue("UninstallString", $"\"{exe}\" --uninstall", RegistryValueKind.String);
                k.SetValue("InstallLocation", appDir, RegistryValueKind.String);
                k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"), RegistryValueKind.String);
                // 我们不通过系统界面提供"更改/修复"——避免 Windows 摆出做不到的入口
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);

                // 占用体积单独在后台算：hermes 树可达数 GB / 十万级文件，
                // 在 UI 线程上递归求和会把"完成页"冻住几秒。先写入其余项，体积稍后补。
                // 已有值时不再重算——否则每次安装（含修复）都要全盘统计一遍。
                var hasSize = k.GetValue("EstimatedSize") != null;
                if (!hasSize)
                {
                    _ = System.Threading.Tasks.Task.Run(() =>
                    {
                        try
                        {
                            long kb = SizeKb(HermesCtl.HermesHome) + SizeKb(appDir);
                            if (kb <= 0) return;
                            using var b2 = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
                            using var k2 = b2.CreateSubKey(KeyPath, true);
                            k2?.SetValue("EstimatedSize", (int)Math.Min(kb, int.MaxValue), RegistryValueKind.DWord);
                        }
                        catch { }
                    });
                }

                // 旧版把条目写在 HKCU——顺手清掉，否则同一个软件会在列表里出现两次
                try { Registry.CurrentUser.DeleteSubKeyTree(KeyPath, false); } catch { }
            }
            catch { }   // 未提权 / 策略限制 → 跳过（安装期已写过，日常启动不依赖它）
        }

        /// <summary>启动时的轻量同步：条目已存在就什么都不做（不重复尝试提权写入）；
        /// 缺失且程序在默认位置才补写。顺带清 HKCU 的旧版遗留。</summary>
        public static void Sync()
        {
            try
            {
                bool has = false;
                try
                {
                    using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
                    using var k = baseKey.OpenSubKey(KeyPath, false);
                    has = k != null;
                }
                catch { }

                if (!has)
                {
                    var dir = AppPaths.DefaultAppDir;
                    if (File.Exists(Path.Combine(dir, "HerMemory.exe"))) Register(dir);
                }
                else
                {
                    try { Registry.CurrentUser.DeleteSubKeyTree(KeyPath, false); } catch { }
                }
            }
            catch { }
        }

        /// <summary>卸载时删除（需要提权，卸载流程已自提权）。</summary>
        public static void Unregister()
        {
            try
            {
                using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
                baseKey.DeleteSubKeyTree(KeyPath, false);
            }
            catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(KeyPath, false); } catch { }
        }

        /// <summary>读取当前登记的安装目录（卸载时用来判断「能不能连程序文件一起删」——
        /// 只有登记的位置与本进程所在目录一致，才说明程序确实装在那儿）。</summary>
        public static string? GetInstallLocation()
        {
            try
            {
                using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
                using var k = baseKey.OpenSubKey(KeyPath, false);
                return k?.GetValue("InstallLocation") as string;
            }
            catch { return null; }
        }

        private static string Publisher()
        {
            try
            {
                var a = System.Reflection.Assembly.GetExecutingAssembly()
                    .GetCustomAttributes(typeof(System.Reflection.AssemblyCompanyAttribute), false);
                if (a.Length > 0 && a[0] is System.Reflection.AssemblyCompanyAttribute c
                    && !string.IsNullOrWhiteSpace(c.Company)) return c.Company;
            }
            catch { }
            return FallbackPublisher;
        }

        /// <summary>目录体积（KB）。**不跟随重解析点**——`memories` 是指向 vault 的 junction，
        /// 跟进去会把用户自己的资料重复计入软件占用。</summary>
        private static long SizeKb(string root)
        {
            if (string.IsNullOrEmpty(root) || !Directory.Exists(root)) return 0;
            long bytes = 0;
            var stack = new Stack<string>();
            stack.Push(root);
            while (stack.Count > 0)
            {
                var d = stack.Pop();
                try
                {
                    foreach (var f in Directory.EnumerateFiles(d))
                        try { bytes += new FileInfo(f).Length; } catch { }
                }
                catch { }
                try
                {
                    foreach (var s in Directory.EnumerateDirectories(d))
                    {
                        try
                        {
                            if ((new DirectoryInfo(s).Attributes & FileAttributes.ReparsePoint) != 0) continue;
                        }
                        catch { continue; }
                        stack.Push(s);
                    }
                }
                catch { }
            }
            return bytes / 1024;
        }
    }
}
