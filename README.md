# EyeBreak

macOS 菜单栏护眼提醒。每 20 分钟在所有屏幕弹一次半透明浮窗，提醒看远处休息 20 秒（20-20-20 原则），倒计时结束自动关闭。

- 菜单栏常驻一行纯文字日期（如 `10月16日 周五`，按北京时间，过零点自动换），没有 Dock 图标；单击弹出一页主面板
- 主面板左边是月历：农历、法定节假日休 / 班、二十四节气、ISO 周数
- 主面板右边：下次休息（可暂停）、今日喝水（+1）、Wi-Fi 信号质量，以及选中那天的日程
- 浮窗上带「顺便喝口水 +1」，顺手记当天喝水杯数，不另设提醒
- 可选：接飞书日历，看每天的日程、一键入会、新建日程

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

菜单栏右侧应出现 `10月16日 周五` 这样的日期。确认没问题后：

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

单击菜单栏日期弹出主面板；再点一次、按 Esc 或点到别处收起。

| 区域 | 说明 |
|---|---|
| 左：月历 | 农历、节假日休 / 班、节气、周数；滚轮 / 触控板上下滑或 ← → 翻月，T 回今天；有日程的日子下面有个点 |
| 右上：下次休息 | 倒计时 + 暂停 / 继续；休息中显示剩余秒数 |
| 右上：今日喝水 | 杯数 + 「+1」，两次休息之间也能补记 |
| 右上：Wi-Fi | 良好 / 一般 / 较差 + dBm，悬停看噪声、信噪比、速率 |
| 右：日程 | 选中那天的飞书日程；看今天时已结束的折叠，下一场高亮并带「入会」；右下「新建日程」 |
| 齿轮 | 工作间隔 15 / 20 / 25 / 30 分钟、休息时长 10 / 15 / 20 / 30 秒、重置、信号巡测、退出 |

信号巡测：菜单栏临时显示实时信号强度（dBm），10 分钟后自动关闭。

浮窗上点「顺便喝口水 +1」记一杯，不会关闭浮窗。多屏时任一块屏上点一次即可，其余屏同步，不会重复计数。

设置和杯数存在 UserDefaults（domain `io.github.tinkqw.eyebreak`），重启保留。杯数按北京时间跨天自动清零，不存历史。

### Wi-Fi 信号

显示的是最近 2 秒样本的中位数，不是瞬时值（原地不动 RSSI 也会在几 dBm 内高频跳动）。分档：≥ -67 dBm 良好，≥ -80 dBm 一般，其余较差；信噪比低于 20 dB 时降一档。

采样聚合后按月写 CSV 到 `~/Library/Application Support/EyeBreak/wifi-YYYY-MM.csv`（平时 1 分钟一行，巡测时 1 秒一行），方便事后看信号变化。目录可改：

```bash
defaults write io.github.tinkqw.eyebreak WifiLogDirectory /path/to/dir
```

### 月历

- 农历用系统 `Calendar(identifier: .chinese)`，时区固定北京时间
- 节气按太阳视黄经每 15° 计算（Meeus《天文算法》低精度公式），与香港天文台 2020–2035 年间可查的 216 个节气日期全部一致，交节时刻误差在 15 分钟内
- 法定节假日与调休数据来自 [holiday-cn](https://github.com/NateScarlet/holiday-cn)（MIT），编译进程序、不联网。每年 11 月前后国务院公布下一年安排、holiday-cn 更新后，重新生成并编译：

```bash
python3 scripts/gen-holidays.py 2025 2026 2027
swift build -c release
```

### 飞书日程（可选）

放一个凭证文件即启用，没有就只显示月历和状态：

```json
{"access_token": "<飞书 user_access_token>", "expires_at": 1767225600}
```

默认路径 `~/.config/eyebreak/feishu_token.json`，可改：

```bash
defaults write io.github.tinkqw.eyebreak FeishuTokenPath /path/to/token.json
```

token 需要飞书日历的读写权限；本程序只读不续期，过期前请用你自己的脚本刷新这个文件。主面板打开、翻月、新建日程后拉取，没有后台定时请求。

## 想改哪里改哪个文件

| 改什么 | 文件 |
|---|---|
| 浮窗文案、配色、尺寸、按钮 | `OverlayWindow.swift` |
| 菜单栏显示格式 | `MenuBarController.swift` |
| 主面板（月历、状态卡、日程、齿轮设置） | `MainPanel.swift` |
| 农历、节日、节气 | `ChineseDay.swift`（节假日数据 `HolidayData.swift` 由脚本生成，勿手改） |
| 计时逻辑、预设时长 | `TimerManager.swift` |
| 喝水计数 | `WaterCounter.swift` |
| Wi-Fi 分档阈值、采样频率 | `WifiMonitor.swift` |
| 飞书日程 | `FeishuCalendar.swift`、`NewEventPanel.swift` |

改完重新构建并重启：

```bash
swift build -c release
launchctl bootout gui/$UID/io.github.tinkqw.eyebreak
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.github.tinkqw.eyebreak.plist
```

换了二进制要 bootout + bootstrap，**`kickstart -k` 不行**：本地编译是 ad-hoc 签名，每次构建签名都变，launchd 缓存了旧签名要求，kickstart 会被签名校验拒掉，进程起不来且日志是空的。

## 踩过的坑

- **plist 里任何路径都不能指向 Desktop / Documents / Downloads**，包括程序路径、日志路径、`WorkingDirectory`。
- **主面板「点到外面就收起」用全局鼠标监听，不用 `didResignActive`**：面板关闭后系统会延迟补发一次失焦，会把紧接着重新打开的面板立刻关掉。
- **飞书日程接口 `instance_view` 单次最多查 40 天**，月历一屏 42 天要分两段查。
- **浮窗按弹出瞬间接入的屏幕数建面板**，休息中间插拔显示器不会补面板或回收。
- **喝水杯数单日封顶 99**，防手改 plist 出脏值导致整数溢出崩溃。
- **飞书新建日程后要把自己加为参与人**，否则飞书客户端不显示这条日程。

## 已知限制

- 只在 Apple Silicon 上跑过，Intel 只保证能编译
- 睡眠期间计时等于暂停（`Timer` 不追赶）

## 许可证

MIT，见 `LICENSE`。
