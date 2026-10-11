# EyeBreak

macOS 菜单栏护眼提醒。每 20 分钟在所有屏幕弹一次半透明浮窗，提醒看远处休息 20 秒（20-20-20 原则），倒计时结束自动关闭。

- 菜单栏常驻一行纯文字倒计时，没有 Dock 图标
- 浮窗上带「顺便喝口水 +1」，顺手记当天喝水杯数，不另设提醒
- 菜单里看当前 Wi-Fi 信号质量（良好 / 一般 / 较差），可开「信号巡测」走动找信号好的位置
- 可选：菜单顶部显示今天的飞书日程，并能新建日程

技术栈：Swift + SwiftUI + Combine，Swift Package Manager 构建，macOS 14+。

> 这份说明也可以直接交给 AI agent（Claude Code 等）执行，命令都可直接跑。

## 前提

- macOS 14 或更高
- Xcode Command Line Tools：`xcode-select -p` 有输出即可；没有则 `xcode-select --install`
- 不需要 Apple 开发者账号、不需要代码签名。本地编译出来的二进制没有 quarantine 标记，不会触发 Gatekeeper 拦截

## 安装

### 1. 放对位置

把仓库放到 **不是** Desktop / Documents / Downloads 的地方，例如 `~/Apps/eye-break/`。

launchd 启动的进程在这三个 TCC 保护目录下拿不到文件权限，表现为 `Operation not permitted` 或 exit 78，而且日志往往也写不出来，极难排查。

### 2. 编译

```bash
cd ~/Apps/eye-break
swift build -c release
```

产物：`.build/release/EyeBreak`。

### 3. 先手动验一次

```bash
.build/release/EyeBreak &
```

菜单栏右侧应出现 `20m` 字样的倒计时。确认没问题后：

```bash
pkill -f '.build/release/EyeBreak'
```

### 4. 开机自启动

写 `~/Library/LaunchAgents/io.github.tinkqw.eyebreak.plist`，**路径必须是真实绝对路径，不能用 `~`**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.tinkqw.eyebreak</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/你的用户名/Apps/eye-break/.build/release/EyeBreak</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/你的用户名/Library/Logs/eyebreak.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/你的用户名/Library/Logs/eyebreak.err</string>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.github.tinkqw.eyebreak.plist
launchctl list | grep eyebreak      # 第二列是 0 或 - 即正常，非 0 是退出码
```

## 使用

| 菜单项 | 说明 |
|---|---|
| 暂停 / 恢复 | 休息中该项置灰 |
| 重置（⌘R） | 工作计时归零重新开始 |
| 工作间隔 | 15 / 20 / 25 / 30 分钟 |
| 休息时长 | 10 / 15 / 20 / 30 秒 |
| 今日喝水：N 杯 | 只读统计 |
| 记一杯 +1（⌘W） | 两次休息之间也能补记 |
| 信号巡测 | 菜单栏临时显示实时信号强度（dBm），10 分钟后自动关闭 |

浮窗上点「顺便喝口水 +1」记一杯，不会关闭浮窗。多屏时任一块屏上点一次即可，其余屏同步，不会重复计数。

设置和杯数存在 UserDefaults（domain `io.github.tinkqw.eyebreak`），重启保留。杯数按北京时间跨天自动清零，不存历史。

### Wi-Fi 信号

显示的是最近 2 秒样本的中位数，不是瞬时值（原地不动 RSSI 也会在几 dBm 内高频跳动）。分档：≥ -67 dBm 良好，≥ -80 dBm 一般，其余较差；信噪比低于 20 dB 时降一档。

采样聚合后按月写 CSV 到 `~/Library/Application Support/EyeBreak/wifi-YYYY-MM.csv`（平时 1 分钟一行，巡测时 1 秒一行），方便事后看信号变化。

### 飞书日程（可选）

放一个凭证文件即启用，没有就整段隐藏：

```json
{"access_token": "<飞书 user_access_token>", "expires_at": 1767225600}
```

默认路径 `~/.config/eyebreak/feishu_token.json`，可改：

```bash
defaults write io.github.tinkqw.eyebreak FeishuTokenPath /path/to/token.json
```

token 需要飞书日历的读写权限；本程序只读不续期，过期前请用你自己的脚本刷新这个文件。菜单打开时和每 5 分钟刷新一次。

## 想改哪里改哪个文件

| 改什么 | 文件 |
|---|---|
| 浮窗文案、配色、尺寸、按钮 | `OverlayWindow.swift` |
| 菜单结构、菜单栏显示格式 | `MenuBarController.swift` |
| 计时逻辑、预设时长 | `TimerManager.swift` |
| 喝水计数 | `WaterCounter.swift` |
| Wi-Fi 分档阈值、采样频率 | `WifiMonitor.swift` |
| 飞书日程 | `FeishuCalendar.swift`、`NewEventPanel.swift` |

改完重新构建并重启：

```bash
swift build -c release && launchctl kickstart -k gui/$UID/io.github.tinkqw.eyebreak
```

改了 plist 本身要 `launchctl bootout` 再 `bootstrap`，kickstart 不会重读 plist。

## 踩过的坑

- **plist 里任何路径都不能指向 Desktop / Documents / Downloads**，包括程序路径、日志路径、`WorkingDirectory`。
- **`NSMenu.autoenablesItems` 默认是 true**，会覆盖手写的 `isEnabled`。代码里 `menu.autoenablesItems = false` 那行不能删，否则「休息中暂停项置灰」失效。
- **浮窗按弹出瞬间接入的屏幕数建面板**，休息中间插拔显示器不会补面板或回收。
- **喝水杯数单日封顶 99**，防手改 plist 出脏值导致整数溢出崩溃。
- **飞书新建日程后要把自己加为参与人**，否则飞书客户端不显示这条日程。

## 已知限制

- 只在 Apple Silicon 上跑过，Intel 只保证能编译
- 睡眠期间计时等于暂停（`Timer` 不追赶）

## 许可证

MIT，见 `LICENSE`。
