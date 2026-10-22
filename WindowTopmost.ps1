<#
Start:  .\WindowTopmost.ps1
Status: .\WindowTopmost.ps1 -Mode Status
Stop:   .\WindowTopmost.ps1 -Mode Stop
Click a window, then press Ctrl+Alt+T to toggle its always-on-top state.
#>
[CmdletBinding()]
param([ValidateSet('Start', 'Stop', 'Status')][string]$Mode = 'Start')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

try {
    if (-not ('WindowPin.Tool' -as [type])) {
        Add-Type -ReferencedAssemblies System.dll, System.Core.dll, System.Windows.Forms.dll, System.Drawing.dll -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using Microsoft.Win32;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace WindowPin
{
    internal static class Api
    {
        internal const string HostTitle = "WindowPin.HotkeyHost.738123b9";
        internal const string OwnerProperty = "WindowPin.Owner.738123b9";
        internal const int HotkeyMessage = 0x0312;
        internal const int StopMessage = 0x8001;
        internal const int HelpMessage = 0x8002;
        internal const int HotkeyId = 1;
        internal const int SW_RESTORE = 9;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        internal static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        internal static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")]
        internal static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")]
        internal static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")]
        internal static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern int GetClassName(IntPtr window, StringBuilder text, int length);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        internal static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter,
            int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool SetProp(IntPtr window, string name, IntPtr value);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr GetProp(IntPtr window, string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr RemoveProp(IntPtr window, string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr FindWindow(string className, string title);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")]
        internal static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")]
        internal static extern bool BringWindowToTop(IntPtr window);
        [DllImport("user32.dll")]
        internal static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")]
        internal static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")]
        internal static extern bool AttachThreadInput(uint attach, uint attachTo, bool attachInput);
        [DllImport("kernel32.dll")]
        internal static extern uint GetCurrentThreadId();

        internal static bool IsTopmost(IntPtr window)
        {
            return (GetWindowLong(window, -20) & 0x00000008) != 0;
        }

        internal static void SetTopmost(IntPtr window, bool enabled)
        {
            // NOSIZE | NOMOVE | NOACTIVATE: preserve the target's geometry and focus.
            if (!SetWindowPos(window, new IntPtr(enabled ? -1 : -2), 0, 0, 0, 0, 0x0013))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (IsTopmost(window) != enabled)
                throw new InvalidOperationException("Windows 未应用置顶设置。目标窗口若以管理员身份运行，请用相同权限启动本工具。");
        }
    }

    internal static class AutoStart
    {
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "WindowTopmost";

        internal static bool IsEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                    return key != null && key.GetValue(ValueName) != null;
            }
            catch { return false; }
        }

        internal static void Enable(string launcherPath)
        {
            if (string.IsNullOrEmpty(launcherPath) || !File.Exists(launcherPath))
                throw new FileNotFoundException("找不到启动器，无法设置开机自启动：" + launcherPath);
            string command = "\"" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wscript.exe")
                + "\" \"" + launcherPath + "\"";
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
            {
                if (key == null) throw new InvalidOperationException("无法打开当前用户的启动项。");
                key.SetValue(ValueName, command, RegistryValueKind.String);
            }
        }

        internal static void Disable()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true))
            {
                if (key != null) key.DeleteValue(ValueName, false);
            }
        }
    }

    internal sealed class MessageWindow : NativeWindow, IDisposable
    {
        internal Action Toggle;
        internal Action Stop;
        internal Action Help;

        internal MessageWindow()
        {
            CreateHandle(new CreateParams { Caption = Api.HostTitle });
            // MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, virtual key T.
            if (!Api.RegisterHotKey(Handle, Api.HotkeyId, 0x4003, 0x54))
            {
                int error = Marshal.GetLastWin32Error();
                DestroyHandle();
                throw new InvalidOperationException("无法注册 Ctrl+Alt+T，可能已被其他程序占用。", new Win32Exception(error));
            }
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == Api.HotkeyMessage && message.WParam.ToInt32() == Api.HotkeyId)
            {
                if (Toggle != null) Toggle();
                return;
            }
            if (message.Msg == Api.StopMessage) { if (Stop != null) Stop(); return; }
            if (message.Msg == Api.HelpMessage) { if (Help != null) Help(); return; }
            base.WndProc(ref message);
        }

        public void Dispose()
        {
            if (Handle != IntPtr.Zero)
            {
                Api.UnregisterHotKey(Handle, Api.HotkeyId);
                DestroyHandle();
            }
        }
    }

    internal sealed class PinContext : ApplicationContext
    {
        private readonly HashSet<IntPtr> pinned = new HashSet<IntPtr>();
        private readonly IntPtr ownerToken = new IntPtr(Process.GetCurrentProcess().Id);
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem pinnedMenu;
        private readonly ToolStripMenuItem autoStartItem;
        private readonly MessageWindow host;

        internal PinContext()
        {
            host = new MessageWindow();
            menu = new ContextMenuStrip();
            menu.ShowItemToolTips = true;
            menu.Items.Add(new ToolStripMenuItem("选中窗口后按 Ctrl + Alt + T") { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            pinnedMenu = new ToolStripMenuItem("已置顶窗口 (0)") { Enabled = false };
            pinnedMenu.ToolTipText = "点击窗口标题切换到该窗口";
            pinnedMenu.DropDownOpening += delegate { RebuildPinnedMenu(); };
            pinnedMenu.DropDown.ShowItemToolTips = true;
            menu.Items.Add(pinnedMenu);
            autoStartItem = new ToolStripMenuItem("开机自启动") { Checked = AutoStart.IsEnabled() };
            autoStartItem.Click += delegate { ToggleAutoStart(); };
            menu.Items.Add(autoStartItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("取消本工具开启的全部置顶", null, delegate { RestoreAll(); });
            menu.Items.Add("退出并取消本工具开启的置顶", null, delegate { StopAndRestore(); });
            menu.Opening += delegate {
                autoStartItem.Checked = AutoStart.IsEnabled();
                RebuildPinnedMenu();
            };
            tray = new NotifyIcon {
                Icon = SystemIcons.Application,
                Text = "窗口置顶 | Ctrl + Alt + T",
                ContextMenuStrip = menu,
                Visible = true
            };
            tray.DoubleClick += delegate { ShowHelp(); };
            host.Toggle = ToggleForeground;
            host.Stop = StopAndRestore;
            host.Help = ShowHelp;
            ShowHelp();
        }

        private void Notify(string title, string text, bool error)
        {
            tray.ShowBalloonTip(2000, title, text, error ? ToolTipIcon.Warning : ToolTipIcon.Info);
        }

        private void ShowHelp()
        {
            Notify("窗口置顶已启动", "点击目标窗口，按 Ctrl+Alt+T 置顶；再按一次取消。右键托盘图标可查看已置顶窗口、取消全部或退出。", false);
        }

        private void RebuildPinnedMenu()
        {
            var entries = new List<KeyValuePair<IntPtr, string>>();
            foreach (IntPtr window in new List<IntPtr>(pinned))
            {
                if (!Api.IsWindow(window) || Api.GetProp(window, Api.OwnerProperty) != ownerToken)
                {
                    pinned.Remove(window);
                    continue;
                }
                entries.Add(new KeyValuePair<IntPtr, string>(window, WindowTitle(window)));
            }
            entries.Sort(delegate(KeyValuePair<IntPtr, string> left, KeyValuePair<IntPtr, string> right) {
                return string.Compare(left.Value, right.Value, StringComparison.CurrentCultureIgnoreCase);
            });

            pinnedMenu.DropDownItems.Clear();
            pinnedMenu.Text = "已置顶窗口 (" + entries.Count + ")";
            pinnedMenu.Enabled = entries.Count != 0;
            foreach (KeyValuePair<IntPtr, string> entry in entries)
            {
                var item = new ToolStripMenuItem(MenuTitle(entry.Value));
                item.ToolTipText = entry.Value.Length == 0 ? "无标题窗口" : entry.Value;
                IntPtr target = entry.Key;
                item.Click += delegate { FocusPinnedWindow(target); };
                pinnedMenu.DropDownItems.Add(item);
            }
        }

        private static string WindowTitle(IntPtr window)
        {
            var title = new StringBuilder(512);
            Api.GetWindowText(window, title, title.Capacity);
            return title.ToString();
        }

        private static string MenuTitle(string title)
        {
            string text = title.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ").Trim();
            if (text.Length == 0) text = "（无标题窗口）";
            if (text.Length > 60) text = text.Substring(0, 57) + "...";
            return text.Replace("&", "&&");
        }

        private void FocusPinnedWindow(IntPtr window)
        {
            try
            {
                if (!Api.IsWindow(window) || Api.GetProp(window, Api.OwnerProperty) != ownerToken)
                {
                    pinned.Remove(window);
                    Notify("窗口不可用", "该窗口已关闭或已取消置顶。", true);
                    return;
                }
                if (Api.IsIconic(window)) Api.ShowWindow(window, Api.SW_RESTORE);
                if (!Api.SetForegroundWindow(window) && !ActivateWindow(window))
                    Notify("切换窗口失败", "Windows 拒绝了焦点切换，请手动点击目标窗口。", true);
            }
            catch (Exception error)
            {
                Notify("切换窗口失败", error.GetBaseException().Message, true);
            }
        }

        private static bool ActivateWindow(IntPtr window)
        {
            IntPtr foreground = Api.GetForegroundWindow();
            uint processId;
            uint foregroundThread = Api.GetWindowThreadProcessId(foreground, out processId);
            uint currentThread = Api.GetCurrentThreadId();
            bool attached = false;
            try
            {
                if (foregroundThread != 0 && foregroundThread != currentThread)
                    attached = Api.AttachThreadInput(currentThread, foregroundThread, true);
                Api.BringWindowToTop(window);
                return Api.SetForegroundWindow(window);
            }
            finally
            {
                if (attached) Api.AttachThreadInput(currentThread, foregroundThread, false);
            }
        }

        private void ToggleAutoStart()
        {
            bool enable = !autoStartItem.Checked;
            try
            {
                if (enable) AutoStart.Enable(Tool.LauncherPath);
                else AutoStart.Disable();
                autoStartItem.Checked = enable;
                Notify(enable ? "已开启开机自启动" : "已关闭开机自启动",
                    enable ? "登录 Windows 后会自动在托盘运行本工具。" : "下次登录 Windows 时将不再自动运行本工具。", false);
            }
            catch (Exception error)
            {
                Notify("操作失败", "无法修改开机自启动：" + error.GetBaseException().Message, true);
            }
        }

        private void ToggleForeground()
        {
            try
            {
                IntPtr window = Api.GetForegroundWindow();
                if (window == IntPtr.Zero || window == host.Handle || !Api.IsWindowVisible(window)
                    || window == Api.GetDesktopWindow() || window == Api.GetShellWindow())
                    return;
                var className = new StringBuilder(256);
                Api.GetClassName(window, className, className.Capacity);
                string name = className.ToString();
                if (name == "Shell_TrayWnd" || name == "Shell_SecondaryTrayWnd" || name == "Progman" || name == "WorkerW")
                    return;

                bool enable = !Api.IsTopmost(window);
                if (enable)
                {
                    // Window properties disappear on destruction, avoiding stale HWND reuse.
                    if (!Api.SetProp(window, Api.OwnerProperty, ownerToken))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "无法设置窗口标记。目标窗口若以管理员身份运行，请用相同权限启动本工具。");
                    try { Api.SetTopmost(window, true); }
                    catch { Api.RemoveProp(window, Api.OwnerProperty); throw; }
                    pinned.Add(window);
                }
                else
                {
                    Api.SetTopmost(window, false);
                    if (Api.GetProp(window, Api.OwnerProperty) == ownerToken)
                        Api.RemoveProp(window, Api.OwnerProperty);
                    pinned.Remove(window);
                }

                string title = WindowTitle(window);
                Notify(enable ? "已置顶" : "已取消置顶", title.Length == 0 ? "当前窗口" : title, false);
            }
            catch (Exception error) { Notify("操作失败", error.Message, true); }
        }

        private bool RestoreAll()
        {
            int failed = 0;
            foreach (IntPtr window in new List<IntPtr>(pinned))
            {
                if (!Api.IsWindow(window) || Api.GetProp(window, Api.OwnerProperty) != ownerToken)
                {
                    pinned.Remove(window);
                    continue;
                }
                try
                {
                    Api.SetTopmost(window, false);
                    Api.RemoveProp(window, Api.OwnerProperty);
                    pinned.Remove(window);
                }
                catch { failed++; }
            }
            if (failed != 0)
                Notify("部分窗口未能取消置顶", "仍有 " + failed + " 个窗口未能恢复，请选中窗口后重试 Ctrl+Alt+T。", true);
            else
                Notify("已取消全部", "本工具开启的置顶已全部取消。", false);
            return failed == 0;
        }

        private void StopAndRestore()
        {
            if (RestoreAll()) ExitThread();
        }

        protected override void ExitThreadCore()
        {
            host.Dispose();
            tray.Visible = false;
            tray.Dispose();
            menu.Dispose();
            base.ExitThreadCore();
        }
    }

    public static class Tool
    {
        public static string LauncherPath { get; set; }

        public static long HostHandle()
        {
            return Api.FindWindow(null, Api.HostTitle).ToInt64();
        }

        public static int HostProcessId()
        {
            uint processId;
            Api.GetWindowThreadProcessId(new IntPtr(HostHandle()), out processId);
            return (int)processId;
        }

        public static bool Stop()
        {
            IntPtr host = new IntPtr(HostHandle());
            return host != IntPtr.Zero && Api.PostMessage(host, Api.StopMessage, IntPtr.Zero, IntPtr.Zero);
        }

        public static void Run()
        {
            bool created;
            using (var singleton = new Mutex(true, "Local\\WindowPin.Utility.738123b9", out created))
            {
                if (!created)
                {
                    IntPtr host = new IntPtr(HostHandle());
                    if (host != IntPtr.Zero) Api.PostMessage(host, Api.HelpMessage, IntPtr.Zero, IntPtr.Zero);
                    return;
                }
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    using (var context = new PinContext()) Application.Run(context);
                }
                finally { singleton.ReleaseMutex(); }
            }
        }
    }
}
'@
    }

    switch ($Mode) {
        'Status' {
            [pscustomobject]@{
                Running = [WindowPin.Tool]::HostHandle() -ne 0
                ProcessId = [WindowPin.Tool]::HostProcessId()
                HostHandle = [WindowPin.Tool]::HostHandle()
                Hotkey = 'Ctrl+Alt+T'
            }
        }
        'Stop' { [WindowPin.Tool]::Stop() }
        'Start' {
            [WindowPin.Tool]::LauncherPath = Join-Path $PSScriptRoot '启动通用置顶.vbs'
            [WindowPin.Tool]::Run()
        }
    }
}
catch {
    if ($Mode -eq 'Start') {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message, '窗口置顶启动失败')
    }
    throw
}
