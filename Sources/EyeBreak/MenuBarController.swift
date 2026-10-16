import AppKit
import Combine

/// 菜单栏：纯文字日期（10月16日 周五），单击弹出 / 收起主面板（月历 + 日程 + 护眼 / 喝水 / Wi-Fi）。
/// 2026-10-14 起不再挂下拉菜单，原菜单里的信息和操作都搬进了主面板，设置收进面板里的齿轮。
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem
    private let timerManager: TimerManager
    private let waterCounter: WaterCounter
    private let wifiMonitor: WifiMonitor
    private let mainPanel: MainPanelController
    private var cancellables = Set<AnyCancellable>()

    /// 巡测时给标题换等宽数字字体，否则数字每秒变化会让标题宽度来回摆动
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    private lazy var monoTitleFont: NSFont = {
        let size = statusItem.button?.font?.pointSize ?? NSFont.systemFontSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }()

    init(timerManager: TimerManager, waterCounter: WaterCounter, wifiMonitor: WifiMonitor, feishuCalendar: FeishuCalendar) {
        self.timerManager = timerManager
        self.waterCounter = waterCounter
        self.wifiMonitor = wifiMonitor
        self.mainPanel = MainPanelController(
            timer: timerManager, water: waterCounter, wifi: wifiMonitor, calendar: feishuCalendar,
            newEventPanel: NewEventPanelController(calendar: feishuCalendar))
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
        }
        bindUpdates()
        updateDisplay()
    }

    private func bindUpdates() {
        timerManager.$remainingWork.map { _ in () }
            .merge(with: timerManager.$remainingBreak.map { _ in () },
                   timerManager.$state.map { _ in () },
                   waterCounter.$cupsToday.map { _ in () },
                   wifiMonitor.$reading.map { _ in () },
                   wifiMonitor.$surveying.map { _ in () },
                   // 暂停时倒计时不跳、上面几路都不触发，日期得自己刷：每 30 秒一次 + 系统跨天通知
                   Timer.publish(every: 30, on: .main, in: .common).autoconnect().map { _ in () },
                   NotificationCenter.default.publisher(for: .NSCalendarDayChanged).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateDisplay() }
            .store(in: &cancellables)
    }

    private func updateDisplay() {
        // 每秒跟着倒计时跑一次：进程常驻多日，跨天清零不能只在启动时判断
        waterCounter.refreshIfNeeded()

        var surveySuffix = ""
        if wifiMonitor.surveying {
            if case .connected(let rssi, _, _) = wifiMonitor.reading {
                surveySuffix = " · \(rssi)"
            } else {
                surveySuffix = " · --"
            }
        }

        guard let button = statusItem.button else { return }
        button.image = nil
        // 菜单栏只显示今天日期（月日 + 周几），倒计时 / 喝水在主面板里看；每秒刷新，跨零点自动换
        let text = Self.dateFormatter.string(from: Date()) + surveySuffix
        // 巡测期间换等宽数字，其余时候留空属性、沿用按钮默认外观
        button.attributedTitle = wifiMonitor.surveying
            ? NSAttributedString(string: text, attributes: [.font: monoTitleFont])
            : NSAttributedString(string: text)
    }

    @objc private func togglePanel() {
        mainPanel.toggle(below: statusItem.button)
    }
}
