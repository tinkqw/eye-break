import AppKit
import Combine

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private let timerManager: TimerManager
    private let waterCounter: WaterCounter
    private let wifiMonitor: WifiMonitor
    private let feishuCalendar: FeishuCalendar
    private let newEventPanel: NewEventPanelController
    /// 菜单顶部的日程区（标题行 + 日程行 + 新建 + 分隔线），每次刷新整段重建
    private var calendarItems: [NSMenuItem] = []
    private var cancellables = Set<AnyCancellable>()
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem()
    private let waterMenuItem = NSMenuItem()
    private let wifiMenuItem = NSMenuItem()
    private let wifiDetailMenuItem = NSMenuItem()
    private let surveyMenuItem = NSMenuItem()

    /// 巡测时给标题换等宽数字字体，否则数字每秒变化会让标题宽度来回摆动
    private lazy var monoTitleFont: NSFont = {
        let size = statusItem.button?.font?.pointSize ?? NSFont.systemFontSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }()

    init(timerManager: TimerManager, waterCounter: WaterCounter, wifiMonitor: WifiMonitor, feishuCalendar: FeishuCalendar) {
        self.timerManager = timerManager
        self.waterCounter = waterCounter
        self.wifiMonitor = wifiMonitor
        self.feishuCalendar = feishuCalendar
        self.newEventPanel = NewEventPanelController(calendar: feishuCalendar)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        setupMenu()
        bindUpdates()
        updateDisplay()
    }

    private func setupMenu() {
        // NSMenu 默认 autoenablesItems=true，会按 target/action 自动算可用性、
        // 覆盖手写的 isEnabled。关掉才能让「休息中暂停项置灰」真正生效。
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false

        // 信息行与 statusMenuItem / waterMenuItem 一致置灰。置灰会冲淡 attributedTitle
        // 的颜色，但「良好/一般/较差」这几个字本身已带全信息——颜色只做冗余，不做载体。
        // 主行不置灰：置灰是系统降透明度，任何颜色叠在上面都会被冲淡。
        // 打开这个菜单主要就是为了读这一行，它需要全对比度。
        // 代价是鼠标划过会高亮（action = nil，点了只是关菜单，不做事）。
        // 详情行继续置灰——它确实是次要信息，全都拉到同一重量就没法扫读了。
        wifiMenuItem.isEnabled = true
        wifiDetailMenuItem.isEnabled = false

        surveyMenuItem.title = "信号巡测"
        surveyMenuItem.target = self
        surveyMenuItem.action = #selector(toggleSurvey)
        surveyMenuItem.toolTip = "临时在菜单栏显示实时信号强度，用于走动找位置；10 分钟后自动关闭"

        toggleMenuItem.title = "暂停"
        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(togglePause)

        let resetItem = NSMenuItem(title: "重置", action: #selector(reset), keyEquivalent: "r")
        resetItem.target = self

        // Work interval submenu
        let workItem = NSMenuItem(title: "工作间隔", action: nil, keyEquivalent: "")
        let workSubmenu = NSMenu()
        for option in TimerManager.workOptions {
            let item = NSMenuItem(title: option.label, action: #selector(selectWorkDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.seconds
            workSubmenu.addItem(item)
        }
        workItem.submenu = workSubmenu

        // Break duration submenu
        let breakItem = NSMenuItem(title: "休息时长", action: nil, keyEquivalent: "")
        let breakSubmenu = NSMenu()
        for option in TimerManager.breakOptions {
            let item = NSMenuItem(title: option.label, action: #selector(selectBreakDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.seconds
            breakSubmenu.addItem(item)
        }
        breakItem.submenu = breakSubmenu

        waterMenuItem.isEnabled = false

        let logWaterItem = NSMenuItem(title: "记一杯 +1", action: #selector(logWater), keyEquivalent: "w")
        logWaterItem.target = self

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(wifiMenuItem)
        menu.addItem(wifiDetailMenuItem)
        menu.addItem(.separator())
        menu.addItem(toggleMenuItem)
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(workItem)
        menu.addItem(breakItem)
        menu.addItem(.separator())
        menu.addItem(waterMenuItem)
        menu.addItem(logWaterItem)
        menu.addItem(.separator())
        menu.addItem(surveyMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func bindUpdates() {
        timerManager.$remainingWork
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &cancellables)

        timerManager.$remainingBreak
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &cancellables)

        timerManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &cancellables)

        waterCounter.$cupsToday
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &cancellables)

        wifiMonitor.$reading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &cancellables)

        wifiMonitor.$surveying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &cancellables)

        feishuCalendar.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.rebuildCalendarItems(status) }
            .store(in: &cancellables)
    }

    private func updateDisplay() {
        waterCounter.refreshIfNeeded()

        // 第一杯之前不显示杯数，避免菜单栏常挂一个「0 杯」
        let waterSuffix = waterCounter.cupsToday > 0 ? " · \(waterCounter.cupsToday) 杯" : ""

        var surveySuffix = ""
        if wifiMonitor.surveying {
            if case .connected(let rssi, _, _) = wifiMonitor.reading {
                surveySuffix = " · \(rssi)"
            } else {
                surveySuffix = " · --"
            }
        }

        if let button = statusItem.button {
            button.image = nil
            let base: String
            switch timerManager.state {
            case .counting: base = timerManager.remainingMinutes
            case .paused:   base = "⏸"
            case .breaking: base = "休息"
            }
            let text = base + waterSuffix + surveySuffix
            // 巡测期间换等宽数字，其余时候留空属性、沿用按钮默认外观
            button.attributedTitle = wifiMonitor.surveying
                ? NSAttributedString(string: text, attributes: [.font: monoTitleFont])
                : NSAttributedString(string: text)
        }

        updateWifiItems()

        statusMenuItem.title = timerManager.statusText
        waterMenuItem.title = "今日喝水：\(waterCounter.cupsToday) 杯"

        switch timerManager.state {
        case .counting:
            toggleMenuItem.title = "暂停"
            toggleMenuItem.isEnabled = true
        case .paused:
            toggleMenuItem.title = "恢复"
            toggleMenuItem.isEnabled = true
        case .breaking:
            toggleMenuItem.title = "暂停"
            toggleMenuItem.isEnabled = false
        }

        // Update checkmarks in submenus
        updateSubmenuChecks()
    }

    private func updateSubmenuChecks() {
        // Work interval checkmarks
        if let workSubmenu = menu.item(withTitle: "工作间隔")?.submenu {
            for item in workSubmenu.items {
                item.state = item.tag == timerManager.workDuration ? .on : .off
            }
        }
        // Break duration checkmarks
        if let breakSubmenu = menu.item(withTitle: "休息时长")?.submenu {
            for item in breakSubmenu.items {
                item.state = item.tag == timerManager.breakDuration ? .on : .off
            }
        }
    }

    /// Wi-Fi 两行：第一行「结论 + 数值」，第二行噪声/信噪比/速率。
    /// 结论词在前、dBm 在后——dBm 是要查表才看得懂的单位，不该占第一个词的位置。
    private func updateWifiItems() {
        surveyMenuItem.state = wifiMonitor.surveying ? .on : .off

        switch wifiMonitor.reading {
        case .connected(let rssi, let noise, let rate):
            let q = WifiMonitor.quality(rssi: rssi, noise: noise)
            // 颜色只上在前导圆点上，文字本身不着色。
            // 信息行是 isEnabled = false，系统已经在降透明度；再叠一个
            // 白底约 2:1 的 systemGreen（规范要求正文 ≥ 4.5）就看不清了。
            // 圆点是实心色块、且按设计只做冗余，被冲淡也不丢信息。
            let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: q.color])
            // labelColor 而不是写死黑色：深色模式下菜单背景变深，黑字就没了
            title.append(NSAttributedString(
                string: "Wi-Fi \(q.label) · \(rssi) dBm",
                attributes: [.foregroundColor: NSColor.labelColor]
            ))
            wifiMenuItem.attributedTitle = title

            var parts: [String] = []
            if noise < 0 {
                parts.append("噪声 \(noise)")
                parts.append("信噪比 \(rssi - noise) dB")
            }
            if rate > 0 { parts.append("\(rate) Mbps") }
            wifiDetailMenuItem.isHidden = parts.isEmpty
            // 不设字号和颜色：置灰本身已经提供了层级，再叠小字号 + secondaryLabelColor
            // 就是第三层减弱。与「下次休息」同样处理，那行实测是看得清的。
            wifiDetailMenuItem.attributedTitle = NSAttributedString(string: parts.joined(separator: " · "))

        case .disconnected:
            wifiMenuItem.attributedTitle = NSAttributedString(
                string: "Wi-Fi 未连接", attributes: [.foregroundColor: NSColor.labelColor])
            wifiDetailMenuItem.isHidden = true

        case .off:
            wifiMenuItem.attributedTitle = NSAttributedString(
                string: "Wi-Fi 已关闭", attributes: [.foregroundColor: NSColor.labelColor])
            wifiDetailMenuItem.isHidden = true

        case .unavailable:
            wifiMenuItem.isHidden = true
            wifiDetailMenuItem.isHidden = true
            surveyMenuItem.isHidden = true
        }
    }

    // MARK: - 飞书日程

    func menuWillOpen(_ menu: NSMenu) {
        feishuCalendar.refresh()
    }

    /// 日程区插在菜单最顶上。没有凭证（unavailable）时整段不出现。
    private func rebuildCalendarItems(_ status: FeishuCalendar.Status) {
        calendarItems.forEach { menu.removeItem($0) }
        calendarItems = []
        if case .unavailable = status { return }

        var items: [NSMenuItem] = []
        let header = NSMenuItem(title: Self.dayHeader(Date()), action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)

        switch status {
        case .loading:
            items.append(Self.infoItem("读取中…"))
        case .failed(let msg):
            items.append(Self.infoItem("飞书日程读取失败：\(msg)"))
        case .loaded(let events) where events.isEmpty:
            items.append(Self.infoItem("今天没有日程"))
        case .loaded(let events):
            let now = Date()
            for e in events {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                // 已结束的置灰；未结束的全对比度（同 Wi-Fi 主行：isEnabled + labelColor，点了只关菜单）
                let past = e.end <= now
                item.isEnabled = !past
                let attrs: [NSAttributedString.Key: Any] = past ? [:] : [.foregroundColor: NSColor.labelColor]
                item.attributedTitle = NSAttributedString(string: Self.eventLine(e), attributes: attrs)
                item.toolTip = e.title
                items.append(item)
            }
        case .unavailable:
            break
        }

        let newItem = NSMenuItem(title: "＋ 新建日程…", action: #selector(newEvent), keyEquivalent: "n")
        newItem.target = self
        items.append(newItem)
        items.append(.separator())

        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        calendarItems = items
    }

    private static func infoItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func dayHeader(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = FeishuCalendar.timeZone
        f.dateFormat = "今天 M/d EEE"
        return f.string(from: date)
    }

    static func eventLine(_ e: FeishuCalendar.Event) -> String {
        let title = e.title.count > 28 ? String(e.title.prefix(27)) + "…" : e.title
        if e.isAllDay { return "全天  \(title)" }
        let f = DateFormatter()
        f.timeZone = FeishuCalendar.timeZone
        f.dateFormat = "HH:mm"
        return "\(f.string(from: e.start))–\(f.string(from: e.end))  \(title)"
    }

    @objc private func newEvent() {
        newEventPanel.show()
    }

    @objc private func toggleSurvey() {
        wifiMonitor.toggleSurvey()
    }

    @objc private func togglePause() {
        switch timerManager.state {
        case .counting:
            timerManager.pause()
        case .paused:
            timerManager.resume()
        case .breaking:
            break
        }
    }

    @objc private func reset() {
        timerManager.reset()
    }

    @objc private func logWater() {
        waterCounter.add()
    }

    @objc private func selectWorkDuration(_ sender: NSMenuItem) {
        timerManager.setWorkDuration(sender.tag)
    }

    @objc private func selectBreakDuration(_ sender: NSMenuItem) {
        timerManager.setBreakDuration(sender.tag)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
