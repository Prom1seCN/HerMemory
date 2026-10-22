using System;
using System.IO;
using System.Reflection;
using Microsoft.Win32;

namespace HerMemory
{
    /// <summary>发行形态与关键路径的唯一来源。
    ///
    /// 拆包后的两种形态（同一份代码、两个构建产物，见 csproj 的 SetupMode）：
    ///   安装器 Setup  —— 内嵌 app/HerMemory.exe（程序本体）与 payload/ 最小随包素材
    ///                    （内核源码快照 hermes-agent.zip / uv.exe / rg.exe）
    ///   程序本体 App  —— 只有 exe 自己 + 小 payload，不含随包素材
    ///
    /// 目录约定（2026-09-15 定案，「程序与运行时分离」）：
    ///   程序目录  AppDir     默认 C:\Program Files\HerMemory，只读、放 exe（几十 MB）
    ///   运行时    HERMES_HOME 默认 %LOCALAPPDATA%\hermes，venv/node_modules/state.db 都在这里（数 GB）
    /// 这样分离的依据：日常运行**不提权**，而运行时要写 state.db / sessions / logs / venv 缓存——
    /// 放进 Program Files 会让「装了但跑不起来」变成必然，而不是权限提示。</summary>
    internal static class AppPaths
    {
        /// <summary>本进程 exe 的完整路径。单文件发布下 Assembly.Location 恒空（IL3000），只能走 ProcessPath。</summary>
        public static string ExePath
        {
            get { try { return Environment.ProcessPath ?? ""; } catch { return ""; } }
        }

        /// <summary>本进程 exe 所在目录。安装器下是「下载目录/临时目录」，程序本体下才是 Program Files\HerMemory。</summary>
        public static string ExeDir
        {
            get { try { return Path.GetDirectoryName(ExePath) ?? ""; } catch { return ""; } }
        }

        /// <summary>程序本体的落地位置（默认 Program Files\HerMemory）。</summary>
        public static string DefaultAppDir =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "HerMemory");

        private static readonly bool _isSetup = DetectSetup();

        /// <summary>true = 当前进程是安装器。
        /// 判定依据是「内嵌了 app/HerMemory.exe」——这是安装器独有的资源，不依赖文件名，
        /// 所以即使用户把 exe 改名也不影响行为。</summary>
        public static bool IsSetup => _isSetup;

        private static bool DetectSetup()
        {
            try
            {
                foreach (var n in Assembly.GetExecutingAssembly().GetManifestResourceNames())
                    if (n.StartsWith("app/", StringComparison.Ordinal)) return true;
            }
            catch { }
            return false;
        }

        /// <summary>内嵌资源里是否带离线素材（安装器带、程序本体不带）。
        /// 2026-09-16 瘦身后 assets-offline.zip 不再随包，本值恒为 false、当前也无人调用；
        /// 保留它是为将来若再发行「完整离线包」形态时可直接使用。</summary>
        public static bool HasOfflineAssets
        {
            get
            {
                try
                {
                    foreach (var n in Assembly.GetExecutingAssembly().GetManifestResourceNames())
                        if (n == "payload/assets-offline.zip") return true;
                }
                catch { }
                return false;
            }
        }

        // ================= 记忆库（vault）=================
        // 记忆库是**第三个**位置，与程序目录、运行时目录分开：
        //   程序目录  Program Files\HerMemory   只放 exe
        //   运行时    %LOCALAPPDATA%\hermes    内核、venv、state.db、config、凭据
        //   记忆库    vault                     用户的文档 + AI 的五个记忆文件（明文）
        // 前两个装完就固定；记忆库在首次安装时可选（可以放到 D 盘或已有的文档目录），
        // 选择结果记在 HKCU，这样程序、编辑器、体检、导出、卸载读到的都是同一个值。

        private const string RegKey = @"Software\HerMemory";
        private const string VaultValue = "VaultDir";

        public static string DefaultVaultDir =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "vault");

        /// <summary>记忆库根目录。未配置过（0.1.0 升级上来、或还没装）时回落默认位置。</summary>
        public static string VaultDir
        {
            get
            {
                try
                {
                    using var k = Registry.CurrentUser.OpenSubKey(RegKey, false);
                    if (k?.GetValue(VaultValue) as string is { Length: > 0 } v)
                    {
                        var clean = v.Trim().Trim('"').TrimEnd('\\');
                        if (clean.Length > 0) return clean;
                    }
                }
                catch { }
                return DefaultVaultDir;
            }
        }

        /// <summary>记住用户选的记忆库位置。传空 = 恢复默认。</summary>
        public static void SetVaultDir(string? dir)
        {
            try
            {
                using var k = Registry.CurrentUser.CreateSubKey(RegKey);
                var clean = (dir ?? "").Trim().Trim('"').TrimEnd('\\');
                if (clean.Length == 0) k.DeleteValue(VaultValue, false);
                else k.SetValue(VaultValue, clean, RegistryValueKind.String);
            }
            catch { }
        }

        /// <summary>AI 记忆文件所在目录（记忆库\HerMemory\memory）。</summary>
        public static string VaultMemoryDir => Path.Combine(VaultDir, "HerMemory", "memory");

        /// <summary>AI 与人共用的文档目录（记忆库\HerMemory\docs）。</summary>
        public static string VaultDocsDir => Path.Combine(VaultDir, "HerMemory", "docs");

        public static string DesktopLnk =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "HerMemory.lnk");

        /// <summary>开始菜单里的快捷方式（当前用户）。</summary>
        public static string StartMenuLnk =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "HerMemory.lnk");
    }
}
