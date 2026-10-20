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
        private readonly MessageWindow host;

        internal PinContext()
        {
            host = new MessageWindow();
            menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("选中窗口后按 Ctrl + Alt + T") { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("取消本工具开启的全部置顶", null, delegate { RestoreAll(); });
            menu.Items.Add("退出并取消本工具开启的置顶", null, delegate { StopAndRestore(); });
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
            Notify("窗口置顶已启动", "点击目标窗口，按 Ctrl+Alt+T 置顶；再按一次取消。右键托盘图标可取消全部或退出。", false);
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

                var title = new StringBuilder(512);
                Api.GetWindowText(window, title, title.Capacity);
                Notify(enable ? "已置顶" : "已取消置顶", title.Length == 0 ? "当前窗口" : title.ToString(), false);
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
        'Start' { [WindowPin.Tool]::Run() }
    }
}
catch {
    if ($Mode -eq 'Start') {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message, '窗口置顶启动失败')
    }
    throw
}
