import Foundation
import Combine

/// 今日喝水杯数。只做计数，不产生独立提醒——记录动作寄生在护眼浮窗这个已有的中断上。
/// 跨天自动清零，不保留历史。
final class WaterCounter: ObservableObject {
    private static let cupsKey = "waterCupsToday"
    private static let dayKey = "waterCupsDay"
    /// 单日封顶。作用不是限制喝水，是防手改 plist 后的脏值（负数 / 天文数字 /
    /// Int.max 时 `cupsToday += 1` 会整数溢出直接 trap 崩进程）流进 UI 和运算。
    private static let maxCups = 99

    @Published private(set) var cupsToday: Int = 0

    /// 本次休息是否已记过一杯。多屏时每块屏各有一个浮窗，这个状态必须共享，
    /// 否则在另一块屏上再点一次会把同一杯记成两杯。不持久化。
    @Published private(set) var loggedThisBreak: Bool = false

    private let calendar: Calendar
    private var currentDay: String

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        self.calendar = cal
        self.currentDay = WaterCounter.dayString(for: Date(), calendar: cal)

        // 同一天内重启保留计数，跨天启动清零
        if UserDefaults.standard.string(forKey: WaterCounter.dayKey) == currentDay {
            let raw = UserDefaults.standard.integer(forKey: WaterCounter.cupsKey)
            self.cupsToday = min(max(raw, 0), WaterCounter.maxCups)
        }
        persist()   // 两个分支都写回：跨天清零要落盘，脏值 clamp 后也要落盘
    }

    /// 菜单栏每秒刷新时调用，跨天自动清零（进程常驻，不能只在启动时判断）
    func refreshIfNeeded() {
        let today = WaterCounter.dayString(for: Date(), calendar: calendar)
        guard today != currentDay else { return }
        currentDay = today
        cupsToday = 0
        persist()
    }

    /// 浮窗弹出时调用（每次休息一次），重置「本次已记」
    func beginBreakSession() {
        loggedThisBreak = false
    }

    func add() {
        refreshIfNeeded()
        guard cupsToday < WaterCounter.maxCups else { return }
        cupsToday += 1
        loggedThisBreak = true
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(cupsToday, forKey: WaterCounter.cupsKey)
        UserDefaults.standard.set(currentDay, forKey: WaterCounter.dayKey)
    }

    private static func dayString(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
