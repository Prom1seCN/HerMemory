using System;
using System.IO;
using System.Reflection;

namespace HerMemory
{
    /// <summary>发行形态与关键路径的唯一来源。
    ///
    /// 拆包后的两种形态（同一份代码、两个构建产物，见 csproj 的 SetupMode）：
    ///   安装器 Setup  —— 内嵌 app/HerMemory.exe（程序本体）与 payload/assets-offline.zip（离线素材）
    ///   程序本体 App  —— 只有 exe 自己 + 小 payload，不含离线素材
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

        /// <summary>内嵌资源里是否带离线素材（安装器带、程序本体不带）。</summary>
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

        public static string DesktopLnk =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "HerMemory.lnk");

        /// <summary>开始菜单里的快捷方式（当前用户）。</summary>
        public static string StartMenuLnk =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "HerMemory.lnk");
    }
}
