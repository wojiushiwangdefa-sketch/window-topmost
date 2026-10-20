# 窗口置顶（WindowTopmost）

一个轻量的 Windows 10/11 窗口置顶工具。点击任意普通桌面窗口后按 `Ctrl + Alt + T`，即可将该窗口置顶；再按一次取消。程序常驻系统托盘，无需安装，不联网。

## 功能特点

- **一键置顶**：`Ctrl + Alt + T` 切换当前前台窗口的置顶状态。
- **多窗口独立管理**：不同窗口可以分别置顶或取消。
- **托盘运行**：由 VBS 启动，无命令行窗口。
- **干净退出**：正常退出时自动取消本工具开启的全部置顶。
- **单实例**：重复启动不会产生多个常驻进程。
- **可选自启动**：托盘右键勾选“开机自启动”，登录 Windows 后自动在托盘运行；再次点击取消，默认关闭。
- **纯本地**：不联网、不收集数据，无需管理员权限（除非目标窗口本身以管理员身份运行）。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `WindowTopmost.ps1` | 主程序，负责快捷键、托盘和置顶逻辑 |
| `启动通用置顶.vbs` | 隐藏窗口启动器，双击即运行 |
| `使用说明.txt` | 简明使用说明 |

## 系统要求

- Windows 10 或 Windows 11（主要在 Windows 11 上测试）
- Windows PowerShell 5.1（系统自带）
- .NET Framework 4.x（系统自带）

## 快速开始

### 下载便携包

1. 从 [Releases](https://github.com/wojiushiwangdefa-sketch/window-topmost/releases) 下载 `WindowTopmost-v1.1.0-Win11.zip`。
2. 解压到任意位置。压缩包来自网络时，建议先右键 zip → 属性 → 勾选“解除锁定”，再解压。
3. 双击 `启动通用置顶.vbs`，托盘会出现图标。
4. 点击目标窗口，按 `Ctrl + Alt + T`。

### 从源码运行

```powershell
git clone https://github.com/wojiushiwangdefa-sketch/window-topmost.git
cd window-topmost
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\WindowTopmost.ps1
```

## 使用方式

| 操作 | 效果 |
| --- | --- |
| `Ctrl + Alt + T` | 置顶/取消置顶当前前台窗口 |
| 托盘右键 → 开机自启动 | 勾选后登录 Windows 自动运行；取消勾选即关闭 |
| 托盘右键 → 取消本工具开启的全部置顶 | 只恢复由本工具置顶的窗口 |
| 托盘右键 → 退出并取消本工具开启的置顶 | 恢复全部置顶后退出程序 |
| 双击托盘图标 | 显示操作提示 |

查看运行状态或退出：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WindowTopmost.ps1 -Mode Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\WindowTopmost.ps1 -Mode Stop
```

`Status` 会显示是否运行、进程 ID 和当前快捷键。

## 注意事项与限制

- 置顶状态不持久化，只在工具运行期间有效。正常退出会恢复本工具开启的置顶；如果进程被强制结束，已置顶的窗口会保持置顶，直到窗口关闭或手动取消。
- 目标窗口若以管理员身份运行，Windows 会阻止普通权限进程修改它。此时请先退出本工具，再以管理员身份打开 PowerShell 并运行：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\WindowTopmost.ps1
  ```

- 少数使用特殊窗口管理的程序（如独占全屏游戏）可能无法置顶。
- 如果 `Ctrl + Alt + T` 已被其它程序占用，启动时会提示快捷键注册失败。
- 开机自启动是可选功能，默认关闭。开启后会写入当前用户的 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，命令指向当前文件夹中的 `启动通用置顶.vbs`；取消勾选即删除。如果移动了文件夹，请重新勾选一次以更新路径。
- Windows 11 已开始弃用 VBScript。如果系统禁用了 Windows Script Host，VBS 启动器不会工作，可改用上面的 PowerShell 命令启动。

## 常见问题

**双击后没有反应？**
可能已经有一个实例在运行（重复启动只会弹出提示，不会再开一个），或系统禁用了 Windows Script Host。可在 PowerShell 中直接运行主程序确认。

**提示“无法加载脚本，因为在此系统上禁止运行脚本”？**
启动器已使用进程级 `-ExecutionPolicy Bypass`，不会修改系统执行策略。手动运行 `.ps1` 时请保留 `-ExecutionPolicy Bypass` 参数。

**杀毒软件或 SmartScreen 报警？**
这是未签名的 PowerShell/VBS 脚本，属于常见误报。全部代码都在本仓库中，可自行审阅。下载后先解除锁定再解压，通常能避免 SmartScreen 提示。

**如何卸载？**
如果开启过开机自启动，先在托盘右键取消勾选；然后退出程序并删除整个文件夹即可。不安装服务，也不会留下后台进程。

## 实现原理

- `RegisterHotKey` 注册全局快捷键 `Ctrl + Alt + T`。
- `GetForegroundWindow` 获取当前前台窗口。
- `SetWindowPos(HWND_TOPMOST / HWND_NOTOPMOST)` 切换置顶状态。
- `SetProp` 给窗口打上所有者标记，退出时只恢复本工具修改过的窗口。
- 命名 Mutex + 隐藏消息窗口实现单实例和状态查询。
- 可选开机自启动通过当前用户的 `Run` 注册表项实现，取消勾选时删除该值。
- 全程只调用 Win32 API 和 Windows Forms，无网络请求。

## 隐私

本工具不发起任何网络请求，不收集、不发送任何数据。

## 参与贡献

欢迎提交 Issue 或 Pull Request。

## 许可证

[MIT](LICENSE)

---

## English

A lightweight always-on-top utility for Windows 10/11. Extract the release zip, double-click `启动通用置顶.vbs` (the launcher), click a window, and press `Ctrl + Alt + T` to toggle its topmost state. The app lives in the system tray and makes no network requests. An optional checked “Start with Windows” item in the tray menu enables or disables auto-start for the current user; it is off by default and stored in the current user's Run registry key. Requires Windows PowerShell 5.1 and .NET Framework 4.x, both included with Windows. Licensed under MIT.
