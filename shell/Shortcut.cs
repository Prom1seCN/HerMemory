using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace HerMemory
{
    /// <summary>快捷方式（.lnk）的创建与删除。
    ///
    /// 直接声明 IShellLinkW / IPersistFile 这两个 shell 的稳定 COM 契约，而不是走
    /// `WScript.Shell` 的 late binding：后者依赖 dynamic + IDispatch 运行时绑定，
    /// 在 self-contained 单文件进程里多一层不必要的不确定性（且没有编译期检查）。
    ///
    /// 接口方法顺序必须与 shell32 的 vtable 严格一致——顺序错会静默写坏 .lnk 或直接崩。
    /// 另注意：C# 的 [ComImport] 接口**不会**自动拼上基接口的方法，所以 IPersistFile
    /// 必须把继承自 IPersist 的 GetClassID 显式写在最前面。</summary>
    internal static class Shortcut
    {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLinkComObject { }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
         Guid("000214F9-0000-0000-C000-000000000046")]
        private interface IShellLinkW
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
            void GetIDList(out IntPtr ppidl);
            void SetIDList(IntPtr pidl);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
            void GetHotkey(out short pwHotkey);
            void SetHotkey(short wHotkey);
            void GetShowCmd(out int piShowCmd);
            void SetShowCmd(int iShowCmd);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
            void Resolve(IntPtr hwnd, uint fFlags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
        }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown),
         Guid("0000010b-0000-0000-C000-000000000046")]
        private interface IPersistFile
        {
            void GetClassID(out Guid pClassID);
            [PreserveSig] int IsDirty();
            void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
            void Save([MarshalAs(UnmanagedType.LPWStr)] string? pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
            void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
            void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
        }

        /// <summary>创建（或覆盖）一个指向 targetExe 的快捷方式。目标不存在时直接失败——
        /// 悬空快捷方式是比"没有快捷方式"更糟的状态。</summary>
        public static bool Create(string lnkPath, string targetExe, string workingDir, string description)
        {
            object? obj = null;
            try
            {
                if (string.IsNullOrEmpty(lnkPath) || string.IsNullOrEmpty(targetExe)) return false;
                if (!File.Exists(targetExe)) return false;
                Directory.CreateDirectory(Path.GetDirectoryName(lnkPath)!);

                obj = new ShellLinkComObject();
                var link = (IShellLinkW)obj;
                link.SetPath(targetExe);
                if (!string.IsNullOrEmpty(workingDir)) link.SetWorkingDirectory(workingDir);
                if (!string.IsNullOrEmpty(description)) link.SetDescription(description);
                link.SetIconLocation(targetExe, 0);   // 图标取 exe 自身（已含 app.ico）
                ((IPersistFile)link).Save(lnkPath, true);

                return File.Exists(lnkPath);
            }
            catch { return false; }
            finally { if (obj != null) { try { Marshal.ReleaseComObject(obj); } catch { } } }
        }

        public static void Delete(string lnkPath)
        {
            try { if (!string.IsNullOrEmpty(lnkPath) && File.Exists(lnkPath)) File.Delete(lnkPath); } catch { }
        }
    }
}
