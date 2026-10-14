import AppKit
import SwiftUI
import Combine

/// 主面板：单击菜单栏倒计时弹出，一页放下全部。
/// 左 = 月历（周数列、农历 / 节日 / 节气、休班角标、固定 6 周）；
/// 右 = 三个状态（下次休息 / 今日喝水 / Wi-Fi）+ 选中那天的飞书日程。
/// 设置（工作间隔、休息时长、重置、信号巡测、退出）收在日程标题右边的齿轮里。
final class MainPanelController {
    private var panel: MainNSPanel?
    private let board: CalendarBoard
    private let timer: TimerManager
    private let water: WaterCounter
    private let wifi: WifiMonitor
    private let newEventPanel: NewEventPanelController
    private var scrollMonitor: Any?
    private var outsideClickMonitor: Any?
    private var wheelAccum: CGFloat = 0
    private var wheelLocked = false
    private var lastWheelStep = Date.distantPast

    static let leftWidth: CGFloat = 572
    static let rightWidth: CGFloat = 320
    static let height: CGFloat = 560
    static var width: CGFloat { leftWidth + rightWidth + 1 }

    init(timer: TimerManager, water: WaterCounter, wifi: WifiMonitor, calendar: FeishuCalendar,
         newEventPanel: NewEventPanelController) {
        self.board = CalendarBoard(feishu: calendar)
        self.timer = timer
        self.water = water
        self.wifi = wifi
        self.newEventPanel = newEventPanel
    }

    func toggle(below button: NSStatusBarButton?) {
        if panel?.isVisible == true { close() } else { show(below: button) }
    }

    func show(below button: NSStatusBarButton?) {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        board.goToday()
        let view = MainPanelView(
            board: board, timer: timer, water: water, wifi: wifi,
            onNewEvent: { [weak self] day in
                self?.newEventPanel.show(start: NewEventPanelController.defaultStart(on: day))
            })
        let panel = MainNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            panel.standardWindowButton($0)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false   // 收起由下面的「点到外面」统一处理
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.onClose = { [weak self] in self?.didClose() }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: view)
        // 不让 SwiftUI 反推窗口尺寸：它按「内容 560 + 标题栏 32」撑窗，底部多出一截空白（实测 592）。尺寸由下面 setFrame 定
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        panel.setFrame(Self.frame(below: button), display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installScrollMonitor()
        // 鼠标点到本程序以外 = 收起，同系统菜单栏弹窗。全局监听只收得到发往别的 app 的点击，
        // 所以点菜单栏按钮（走 toggle）、点新建日程小窗都不会误触发。
        // 不用 didResignActive：面板关闭后系统会延迟补发一次失焦，正好把紧接着重新打开的面板关掉
        // （实测：开 → 关 → 再开，第三次弹出即消失）
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.close()
        }
    }

    func close() {
        panel?.close()
    }

    private func didClose() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
        outsideClickMonitor = nil
        panel = nil
    }

    /// 挂在菜单栏按钮正下方、水平居中，越出屏幕就往里收
    static func frame(below button: NSStatusBarButton?) -> NSRect {
        let size = NSSize(width: width, height: height)
        guard let win = button?.window, let screen = win.screen ?? NSScreen.main else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height)
        }
        let anchor = win.frame
        let vis = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, vis.minX + 8), vis.maxX - 8 - size.width)
        let y = min(anchor.minY, vis.maxY) - 6 - size.height
        return NSRect(x: x, y: max(y, vis.minY + 8), width: size.width, height: size.height)
    }

    /// 滚轮 / 触控板在月历上上下滑 = 翻月。
    /// 触控板一次手势只翻一个月：累计过阈值翻一次，然后锁到手势结束；惯性滚动整段忽略。
    /// 普通鼠标滚轮没有手势阶段，按格子来、两次至少隔 0.15 秒。右栏的滚动留给日程列表。
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel,
                  event.locationInWindow.x < Self.leftWidth else { return event }
            if !event.momentumPhase.isEmpty { return nil }
            if event.hasPreciseScrollingDeltas {
                if event.phase.contains(.began) { self.wheelAccum = 0; self.wheelLocked = false }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.wheelAccum = 0; self.wheelLocked = false; return nil
                }
                guard !self.wheelLocked else { return nil }
                self.wheelAccum += event.scrollingDeltaY
                if abs(self.wheelAccum) > 24 {
                    self.board.step(self.wheelAccum > 0 ? -1 : 1)
                    self.wheelLocked = true
                }
            } else if event.scrollingDeltaY != 0, Date().timeIntervalSince(self.lastWheelStep) > 0.15 {
                self.board.step(event.scrollingDeltaY > 0 ? -1 : 1)
                self.lastWheelStep = Date()
            }
            return nil
        }
    }
}

final class MainNSPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    /// Esc 收起
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }
}

// MARK: - 数据

final class CalendarBoard: ObservableObject {
    typealias Event = FeishuCalendar.Event

    @Published private(set) var month: Date      // 当月 1 号 0 点
    @Published private(set) var selected: Date   // 选中那天 0 点
    @Published private(set) var byDay: [String: [Event]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?

    let feishu: FeishuCalendar
    private var cache: [String: [String: [Event]]] = [:]
    private var loadSeq = 0
    private var bag = Set<AnyCancellable>()
    private var cal: Calendar { ChineseDay.gregorian }

    init(feishu: FeishuCalendar) {
        self.feishu = feishu
        let today = ChineseDay.gregorian.startOfDay(for: Date())
        selected = today
        month = ChineseDay.gregorian.dateInterval(of: .month, for: today)!.start
        // 新建了日程：缓存全作废，重拉当前月
        feishu.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.cache.removeAll()
            self?.load()
        }.store(in: &bag)
    }

    var isAvailable: Bool { feishu.isAvailable }

    /// 固定 6 周 42 天，从当月 1 号所在周的周一开始（固定 6 行，月份切换时面板不跳高）
    var gridDays: [Date] { Self.gridDays(for: month) }

    static func gridDays(for month: Date) -> [Date] {
        let cal = ChineseDay.gregorian
        let weekday = cal.component(.weekday, from: month)       // 1 = 周日
        let offset = (weekday + 5) % 7                            // 周一 = 0
        let start = cal.date(byAdding: .day, value: -offset, to: month)!
        return (0..<42).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    func events(on day: Date) -> [Event]? { byDay[ChineseDay.key(day)] }

    func step(_ months: Int) {
        month = cal.date(byAdding: .month, value: months, to: month)!
        // 选中日跟着挪到新月份的同一天（没有那天就取月末），右栏不会停在看不见的日子上
        let d = min(cal.component(.day, from: selected), cal.range(of: .day, in: .month, for: month)!.count)
        selected = cal.date(byAdding: .day, value: d - 1, to: month)!
        load()
    }

    func goToday() {
        selected = cal.startOfDay(for: Date())
        month = cal.dateInterval(of: .month, for: selected)!.start
        load()
    }

    func select(_ day: Date) {
        selected = day
        let m = cal.dateInterval(of: .month, for: day)!.start
        if m != month { month = m; load() }
    }

    func load() {
        guard feishu.isAvailable else { return }
        let key = ChineseDay.key(month)
        // 先摆缓存（翻回看过的月份不闪空），再后台重拉
        byDay = cache[key] ?? [:]
        loadError = nil
        loadSeq += 1
        let seq = loadSeq
        let days = gridDays
        loading = true
        Task {
            do {
                let evs = try await feishu.events(from: days.first!, to: days.last!.addingTimeInterval(86400))
                let map = Self.bucket(evs, days: days)
                await MainActor.run {
                    guard seq == self.loadSeq else { return }   // 期间又翻了月，丢掉过期结果
                    self.cache[key] = map
                    self.byDay = map
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    guard seq == self.loadSeq else { return }
                    self.loadError = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    /// 按天分桶：与 [当天 0 点, 次日 0 点) 有交集的都算（跨天日程每天都出现）；
    /// 零时长日程按开始时刻落在哪天算。没有日程的日子也放空数组，区分「没日程」和「没拉到」
    static func bucket(_ events: [Event], days: [Date]) -> [String: [Event]] {
        var out: [String: [Event]] = [:]
        for d in days {
            let end = d.addingTimeInterval(86400)
            out[ChineseDay.key(d)] = events.filter { e in
                e.start == e.end ? (e.start >= d && e.start < end) : (e.start < end && e.end > d)
            }
        }
        return out
    }

    /// 右栏的分组：已结束 / 全天 / 其余（第一条即「下一场」）。只有看今天才折叠已结束的；
    /// 看别的日子全部按原顺序列出。纯函数，可单测
    struct DayList: Equatable {
        var past: [Event] = []
        var allDay: [Event] = []
        var upcoming: [Event] = []
        var next: Event? { upcoming.first }
    }

    static func dayList(_ events: [Event], day: Date, now: Date) -> DayList {
        var out = DayList()
        let isToday = ChineseDay.gregorian.isDate(day, inSameDayAs: now)
        for e in events {
            if e.isAllDay { out.allDay.append(e) }
            else if isToday && e.end <= now { out.past.append(e) }
            else { out.upcoming.append(e) }
        }
        return out
    }
}

// MARK: - 颜色（对比度已实算：文字对各自底色均 ≥ 4.5）

extension Color {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Palette {
    static let festivalText = Color.adaptive(0xB42318, 0xFF9A90)   // 5.59 / 7.06
    static let festivalFill = Color.adaptive(0xFDE8E6, 0x3A2422)
    static let termText = Color.adaptive(0x1D5BB8, 0x9CC2FF)       // 5.48 / 7.95
    static let termFill = Color.adaptive(0xE3EDFB, 0x1E2A3E)
    static let offBadge = Color.adaptive(0x1B7F45, 0x1B7F45)       // 白字 5.04
    static let workBadge = Color.adaptive(0xC2410C, 0xC2410C)      // 白字 5.18
    static let todayText = Color.adaptive(0x0B63CE, 0x8FC0FF)      // 4.80 / 7.28
    static let todayFill = Color.adaptive(0xE1EDFC, 0x1F2E44)
    static let todayRing = Color.adaptive(0x8DB8F0, 0x3E6AA8)
    static let dot = Color.adaptive(0x0B63CE, 0x8FC0FF)
}

// MARK: - 视图

struct MainPanelView: View {
    @ObservedObject var board: CalendarBoard
    let timer: TimerManager
    let water: WaterCounter
    let wifi: WifiMonitor
    let onNewEvent: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            MonthView(board: board)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(width: MainPanelController.leftWidth)
            Divider()
            SideView(board: board, timer: timer, water: water, wifi: wifi, onNewEvent: onNewEvent)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(width: MainPanelController.rightWidth)
        }
        .frame(height: MainPanelController.height)
        // 标题栏是隐藏的，不给它留安全区；否则 SwiftUI 在顶上让出 32
        .ignoresSafeArea()
    }
}

/// 左栏：月历
struct MonthView: View {
    @ObservedObject var board: CalendarBoard

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdayRow
            Divider().padding(.leading, 4)
            grid
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { board.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("上个月（←）")
                Text(Self.monthTitle(board.month))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 112)
                Button { board.step(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("下个月（→）")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))

            Button { board.goToday() } label: {
                Label("今天", systemImage: "calendar").font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: [])
            .help("回到今天（T）")

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.clockLine(ctx.date))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(height: 50, alignment: .top)
        .padding(.bottom, 2)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 30, height: 1)
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                Text(w).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22)
        .padding(.bottom, 8)
    }

    private var grid: some View {
        let days = board.gridDays
        let cal = ChineseDay.gregorian
        let monthNo = cal.component(.month, from: board.month)
        let today = cal.startOfDay(for: Date())
        return VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    Text("\(cal.component(.weekOfYear, from: days[row * 7]))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30)
                    ForEach(0..<7, id: \.self) { col in
                        let d = days[row * 7 + col]
                        DayCell(
                            date: d,
                            inMonth: cal.component(.month, from: d) == monthNo,
                            isToday: d == today,
                            isSelected: d == board.selected,
                            eventCount: board.events(on: d)?.count ?? 0
                        )
                        .onTapGesture { board.select(d) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.top, 4)
    }

    static func monthTitle(_ d: Date) -> String {
        let c = ChineseDay.gregorian.dateComponents([.year, .month], from: d)
        return "\(c.year!)年\(c.month!)月"
    }

    /// 「14:36:54  10月14日 周三  九月初五」
    static func clockLine(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = ChineseDay.timeZone
        f.dateFormat = "HH:mm:ss  M月d日 EEE"
        return f.string(from: d) + "  " + ChineseDay.lunarFull(d)
    }
}

private struct DayCell: View {
    let date: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int

    var body: some View {
        let info = ChineseDay.info(for: date)
        VStack(spacing: 3) {
            Text("\(ChineseDay.gregorian.component(.day, from: date))")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isToday ? Palette.todayText : Color.primary)
                .overlay(alignment: .topTrailing) {
                    if let mark = info.mark { Badge(mark: mark).offset(x: 15, y: -7) }
                }
            label(info)
            // 只标「有没有」：工作日几乎天天 ≥3 个会，按个数画点每格都是满的，没有信息量
            Circle().fill(eventCount > 0 ? Palette.dot : Color.clear).frame(width: 5, height: 5)
        }
        .frame(width: 56, height: 62)
        .background {
            if isToday {
                Circle().fill(Palette.todayFill)
                    .overlay(Circle().stroke(Palette.todayRing, lineWidth: isSelected ? 1.5 : 1))
                    .frame(width: 62, height: 62)
            } else if isSelected {
                Circle().fill(Color.primary.opacity(0.06))
                    .overlay(Circle().stroke(Color.primary.opacity(0.28), lineWidth: 1))
                    .frame(width: 62, height: 62)
            }
        }
        .opacity(inMonth ? 1 : 0.4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(eventCount > 0 ? "\(eventCount) 个日程" : "")
    }

    @ViewBuilder private func label(_ info: ChineseDay.Info) -> some View {
        switch info.kind {
        case .lunar:
            Text(info.label).font(.system(size: 12))
                .foregroundStyle(isToday ? Palette.todayText : Color.secondary)
                .frame(height: 18)
        case .festival, .term:
            let festival = info.kind == .festival
            Text(info.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(festival ? Palette.festivalText : Palette.termText)
                .padding(.horizontal, 4)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(festival ? Palette.festivalFill : Palette.termFill))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke((festival ? Palette.festivalText : Palette.termText).opacity(0.35), lineWidth: 1))
        }
    }
}

private struct Badge: View {
    let mark: ChineseDay.Mark
    var body: some View {
        Text(mark == .off ? "休" : "班")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(mark == .off ? Palette.offBadge : Palette.workBadge))
    }
}

/// 右栏：三个状态 + 当天日程 + 新建
struct SideView: View {
    @ObservedObject var board: CalendarBoard
    @ObservedObject var timer: TimerManager
    @ObservedObject var water: WaterCounter
    @ObservedObject var wifi: WifiMonitor
    let onNewEvent: (Date) -> Void
    @State private var showPast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                restChip
                StatusChip(caption: "今日喝水", value: "\(water.cupsToday) 杯",
                           actionLabel: AnyView(Text("+1").font(.system(size: 10.5, weight: .bold))),
                           actionHelp: "记一杯") { water.add() }
                wifiChip
            }
            .frame(height: 44)
            .padding(.bottom, 8)

            dayHeader
                .frame(height: 22)
                .padding(.bottom, 8)
            Divider()

            content
                .padding(.top, 10)
                .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Spacer()
                Button { onNewEvent(board.selected) } label: {
                    Label("新建日程", systemImage: "plus").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(!board.isAvailable)
                .keyboardShortcut("n", modifiers: .command)
                .help("在选中那天新建飞书日程（⌘N）")
            }
            .padding(.top, 8)
        }
        .onChange(of: board.selected) { showPast = false }
    }

    // MARK: 状态

    @ViewBuilder private var restChip: some View {
        switch timer.state {
        case .counting:
            StatusChip(caption: "下次休息", value: Self.mmss(timer.remainingWork),
                       actionLabel: AnyView(Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))),
                       actionHelp: "暂停") { timer.pause() }
        case .paused:
            StatusChip(caption: "已暂停", value: Self.mmss(timer.remainingWork), dimValue: true,
                       actionLabel: AnyView(Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))),
                       actionHelp: "继续") { timer.resume() }
        case .breaking:
            StatusChip(caption: "正在休息", value: "\(timer.remainingBreak) 秒")
        }
    }

    @ViewBuilder private var wifiChip: some View {
        switch wifi.reading {
        case .connected(let rssi, let noise, let rate):
            let q = WifiMonitor.quality(rssi: rssi, noise: noise)
            StatusChip(caption: "Wi-Fi  \(rssi)", value: q.label, dot: Color(nsColor: q.color),
                       help: Self.wifiDetail(noise: noise, rssi: rssi, rate: rate))
        case .disconnected:
            StatusChip(caption: "Wi-Fi", value: "未连接")
        case .off:
            StatusChip(caption: "Wi-Fi", value: "已关闭")
        case .unavailable:
            EmptyView()
        }
    }

    static func mmss(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }

    static func wifiDetail(noise: Int, rssi: Int, rate: Int) -> String {
        var parts = ["信号 \(rssi) dBm"]
        if noise < 0 { parts += ["噪声 \(noise)", "信噪比 \(rssi - noise) dB"] }
        if rate > 0 { parts.append("\(rate) Mbps") }
        return parts.joined(separator: " · ")
    }

    // MARK: 日程

    private var dayHeader: some View {
        let day = board.selected
        let isToday = ChineseDay.gregorian.isDate(day, inSameDayAs: Date())
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isToday ? "今天" : Self.weekday(day))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isToday ? Palette.todayText : Color.primary)
            Text(Self.subtitle(day)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            SettingsMenu(timer: timer, wifi: wifi)
        }
    }

    @ViewBuilder private var content: some View {
        let day = board.selected
        if !board.isAvailable {
            placeholder("calendar.badge.exclamationmark", "这台电脑没有飞书凭证，只显示日历")
        } else if let events = board.events(on: day) {
            if events.isEmpty {
                placeholder("calendar", board.loadError.map { "读取失败：\($0)" } ?? "这天没有日程")
            } else {
                // 每分钟重算一次：「N 分钟后」、进行中、哪些算已结束都随时间变
                TimelineView(.everyMinute) { ctx in
                    list(CalendarBoard.dayList(events, day: day, now: ctx.date), day: day, now: ctx.date)
                }
            }
        } else if let err = board.loadError {
            placeholder("exclamationmark.triangle", "读取失败：\(err)")
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ g: CalendarBoard.DayList, day: Date, now: Date) -> some View {
        let isToday = ChineseDay.gregorian.isDate(day, inSameDayAs: now)
        let dayPast = !isToday && day < now
        return ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(g.allDay.enumerated()), id: \.offset) { _, e in
                    EventLine(event: e, day: day, now: now, isNext: false, dimmed: dayPast)
                }
                ForEach(Array(g.upcoming.enumerated()), id: \.offset) { i, e in
                    EventLine(event: e, day: day, now: now, isNext: isToday && i == 0, dimmed: dayPast)
                }
                if !g.past.isEmpty {
                    Button { showPast.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(g.upcoming.isEmpty ? "今天的日程都结束了 · \(g.past.count) 场" : "已结束 \(g.past.count) 场")
                            Image(systemName: showPast ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6).padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showPast {
                        ForEach(Array(g.past.enumerated()), id: \.offset) { _, e in
                            EventLine(event: e, day: day, now: now, isNext: false, dimmed: true)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = ChineseDay.timeZone
        f.dateFormat = "EEE"
        return f.string(from: d)
    }

    /// 「10月14日 · 九月初五」后面跟节日 / 节气 / 休班，有几样跟几样
    static func subtitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = ChineseDay.timeZone
        f.dateFormat = "M月d日"
        let info = ChineseDay.info(for: d)
        var parts = [f.string(from: d), ChineseDay.lunarFull(d)]
        if info.kind != .lunar { parts.append(info.label) }
        if let m = info.mark { parts.append(m == .off ? "放假" : "调休上班") }
        return parts.joined(separator: " · ")
    }
}

/// 两行小卡：上标签、下数值，右侧可带一个圆形小按钮
private struct StatusChip: View {
    let caption: String
    let value: String
    var dimValue = false
    var dot: Color? = nil
    var help: String? = nil
    var actionLabel: AnyView? = nil
    var actionHelp: String? = nil
    var action: (() -> Void)? = nil

    init(caption: String, value: String, dimValue: Bool = false, dot: Color? = nil, help: String? = nil,
         actionLabel: AnyView? = nil, actionHelp: String? = nil, action: (() -> Void)? = nil) {
        self.caption = caption; self.value = value; self.dimValue = dimValue; self.dot = dot; self.help = help
        self.actionLabel = actionLabel; self.actionHelp = actionHelp; self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(dimValue ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                if let actionLabel, let action {
                    Button(action: action) {
                        actionLabel.frame(width: 24, height: 20)
                            .background(Capsule().fill(Color.primary.opacity(0.10)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(actionHelp ?? "")
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .help(help ?? "")
    }
}

/// 齿轮：原菜单里的设置项
private struct SettingsMenu: View {
    @ObservedObject var timer: TimerManager
    @ObservedObject var wifi: WifiMonitor

    var body: some View {
        Menu {
            Picker("工作间隔", selection: Binding(get: { timer.workDuration }, set: { timer.setWorkDuration($0) })) {
                ForEach(TimerManager.workOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
            }
            .pickerStyle(.menu)
            Picker("休息时长", selection: Binding(get: { timer.breakDuration }, set: { timer.setBreakDuration($0) })) {
                ForEach(TimerManager.breakOptions, id: \.seconds) { Text($0.label).tag($0.seconds) }
            }
            .pickerStyle(.menu)
            Button("重置护眼计时") { timer.reset() }
            Divider()
            if wifi.reading != .unavailable {
                Toggle("信号巡测（菜单栏显示实时信号，10 分钟自动关）",
                       isOn: Binding(get: { wifi.surveying }, set: { _ in wifi.toggleSurvey() }))
                Divider()
            }
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("设置")
    }
}

private struct EventLine: View {
    let event: FeishuCalendar.Event
    let day: Date
    let now: Date
    let isNext: Bool
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Palette.dot).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: isNext ? .semibold : .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.timeText(event, day: day)).monospacedDigit()
                    if isNext, let rel = Self.relative(event, now: now) {
                        Text(rel).foregroundStyle(Palette.todayText).fontWeight(.semibold)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isNext, let url = event.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text("入会").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Palette.offBadge))
                }
                .buttonStyle(.plain)
                .help(url.absoluteString)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(isNext ? Palette.todayFill : Color.primary.opacity(0.04)))
        .opacity(dimmed ? 0.55 : 1)
        .help(event.title)
    }

    /// 进行中 / N 分钟后（一小时内）/ 一小时以上不写，时间本身就够
    static func relative(_ e: FeishuCalendar.Event, now: Date) -> String? {
        if e.start <= now { return "进行中" }
        let mins = Int(ceil(e.start.timeIntervalSince(now) / 60))
        return mins <= 60 ? "\(mins) 分钟后" : nil
    }

    /// 当天内：「09:30 – 10:00」；跨天的带日期：「10/13 22:00 – 10/14 01:00」；全天：「全天」
    static func timeText(_ e: FeishuCalendar.Event, day: Date) -> String {
        if e.isAllDay { return "全天" }
        let cal = ChineseDay.gregorian
        let f = DateFormatter()
        f.timeZone = ChineseDay.timeZone
        let sameDay = cal.isDate(e.start, inSameDayAs: day)
            && (cal.isDate(e.end, inSameDayAs: day) || e.end == day.addingTimeInterval(86400))
        f.dateFormat = sameDay ? "HH:mm" : "M/d HH:mm"
        return "\(f.string(from: e.start)) – \(f.string(from: e.end))"
    }
}
