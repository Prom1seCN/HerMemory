using System;
using Microsoft.Win32;

namespace HerMemory
{
    /// <summary>「开机自动启动」——注册当前用户的登录启动项（HKCU\...\Run）。
    ///
    /// 写 HKCU 而不是机器级：提权安装用的是同一个用户令牌，HKCU 仍是该用户；
    /// 且登录启动本来就是「谁登录、谁启动」的语义，装到公共位置反而会让每个用户都被拉起。
    ///
    /// 这里是「托盘常驻」的自启项。它与 gateway 的计划任务（Hermes_Gateway）是两件事：
    ///   计划任务 = AI/微信通道在后台跑（由 install.ps1 第 11 段按安装时的选择注册）
    ///   本项     = 托盘程序随登录启动，让用户一眼看到状态
    ///
    /// **不含自我修复**：本项在每次启动时**不**重写（否则用户手动关掉自启后会被静默改回来）。</summary>
    internal static class AutoStart
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "HerMemory";

        /// <summary>启用/停用开机启动。</summary>
        public static void Set(bool on, string exePath)
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(RunKey, true);
                if (k == null) return;
                if (on && !string.IsNullOrEmpty(exePath))
                    k.SetValue(ValueName, "\"" + exePath + "\"", RegistryValueKind.String);
                else
                    k.DeleteValue(ValueName, false);
            }
            catch { }
        }

        public static bool IsOn
        {
            get
            {
                try
                {
                    using var k = Registry.CurrentUser.OpenSubKey(RunKey, false);
                    return k?.GetValue(ValueName) != null;
                }
                catch { return false; }
            }
        }
    }
}
