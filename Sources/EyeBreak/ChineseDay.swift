import Foundation

/// 月历格子里「日期数字下面那一行」与右上角休/班角标。纯函数，可单测。
///
/// 显示优先级：农历节日（含除夕）> 放假日的节日名 > 公历节日 > 节气 > 农历日（初一显示月名）。
/// 农历节日排在放假名前面，是为了春节假期里那天显示「除夕」而不是笼统的「春节」。
/// 调休上班日只给「班」角标，不显示节日名（如 2026-10-10 显示「九月」而非「国庆节」）。
enum ChineseDay {
    enum Kind: Equatable { case lunar, festival, term }
    enum Mark: Equatable { case off, work }

    struct Info: Equatable {
        let label: String
        let kind: Kind
        let mark: Mark?
    }

    static let timeZone = FeishuCalendar.timeZone

    /// 周一为一周第一天，周数按 ISO 8601（含 1 月 4 日的那周为第 1 周）
    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()

    static let chinese: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.timeZone = timeZone
        return c
    }()

    private static let lunarDays = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    private static let lunarMonths = ["正月", "二月", "三月", "四月", "五月", "六月",
                                      "七月", "八月", "九月", "十月", "冬月", "腊月"]

    /// 常见节日表（除夕另算：腊月可能只有 29 天，取「正月初一的前一天」）
    private static let lunarFestivals: [String: String] = [
        "1-1": "春节", "1-15": "元宵节", "5-5": "端午节", "7-7": "七夕",
        "7-15": "中元节", "8-15": "中秋节", "9-9": "重阳节", "12-8": "腊八节",
    ]
    private static let solarFestivals: [String: String] = [
        "1-1": "元旦", "2-14": "情人节", "3-8": "妇女节", "4-1": "愚人节", "5-1": "劳动节",
        "5-4": "青年节", "6-1": "儿童节", "7-1": "建党节", "8-1": "建军节", "9-10": "教师节",
        "10-1": "国庆节", "12-25": "圣诞节",
    ]

    static func key(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func info(for date: Date) -> Info {
        let holiday = HolidayData.days[key(date)]
        let mark: Mark? = holiday.map { $0.isOffDay ? .off : .work }

        let l = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
        let leap = l.isLeapMonth ?? false
        if !leap, let f = lunarFestivals["\(l.month!)-\(l.day!)"] {
            return Info(label: f, kind: .festival, mark: mark)
        }
        if let next = gregorian.date(byAdding: .day, value: 1, to: date) {
            let n = chinese.dateComponents([.month, .day, .isLeapMonth], from: next)
            if n.month == 1, n.day == 1, n.isLeapMonth != true {
                return Info(label: "除夕", kind: .festival, mark: mark)
            }
        }
        if let h = holiday, h.isOffDay { return Info(label: h.name, kind: .festival, mark: mark) }
        let g = gregorian.dateComponents([.month, .day], from: date)
        if let f = solarFestivals["\(g.month!)-\(g.day!)"] {
            return Info(label: f, kind: .festival, mark: mark)
        }
        if let t = SolarTerms.name(on: date) { return Info(label: t, kind: .term, mark: mark) }
        return Info(label: lunarText(month: l.month!, day: l.day!, leap: leap), kind: .lunar, mark: mark)
    }

    /// 初一显示月名（「九月」「闰六月」），其余显示日（「初五」「廿三」）
    static func lunarText(month: Int, day: Int, leap: Bool) -> String {
        day == 1 ? (leap ? "闰" : "") + lunarMonths[month - 1] : lunarDays[day - 1]
    }

    /// 「九月初五」，顶栏和右侧日详情用
    static func lunarFull(_ date: Date) -> String {
        let l = chinese.dateComponents([.month, .day, .isLeapMonth], from: date)
        return (l.isLeapMonth == true ? "闰" : "") + lunarMonths[l.month! - 1] + lunarDays[l.day! - 1]
    }
}

/// 二十四节气：按太阳视黄经每 15° 一个，算出交节时刻再取北京时间的日期。
/// 太阳位置用 Meeus《天文算法》第 25 章低精度公式（误差约 0.01°，折合约 15 分钟），
/// 只有交节时刻恰在午夜前后十几分钟内才可能差一天。
enum SolarTerms {
    /// 从小寒（285°）起，按一年里出现的先后排
    private static let names = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
                                "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
                                "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"]

    private static var cache: [Int: [String: String]] = [:]
    private static let lock = NSLock()

    static func name(on date: Date) -> String? {
        let year = ChineseDay.gregorian.component(.year, from: date)
        return terms(year: year)[ChineseDay.key(date)]
    }

    /// 该年 24 个节气的「yyyy-MM-dd → 名字」
    static func terms(year: Int) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[year] { return c }
        var out: [String: String] = [:]
        // 1 月 6 日前后是小寒，之后每个节气平均隔 15.22 天，作为迭代初值
        let jan6 = julianDay(year: year, month: 1, day: 6)
        for (i, name) in names.enumerated() {
            let target = Double((285 + 15 * i) % 360)
            var jd = jan6 + Double(i) * 365.2422 / 24
            for _ in 0..<8 {
                var diff = target - sunLongitude(jd)
                diff -= 360 * (diff / 360).rounded()   // 落到 [-180, 180]
                jd += diff * 365.2422 / 360
                if abs(diff) < 1e-6 { break }
            }
            // 公式里的时间是力学时，减 ΔT（约 69 秒）换成世界时
            let unix = (jd - 2440587.5) * 86400 - 69
            out[ChineseDay.key(Date(timeIntervalSince1970: unix))] = name
        }
        cache[year] = out
        return out
    }

    /// 视黄经（度）
    static func sunLongitude(_ jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525
        let rad = Double.pi / 180
        let l0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
        let m = (357.52911 + 35999.05029 * t - 0.0001537 * t * t) * rad
        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(m)
            + (0.019993 - 0.000101 * t) * sin(2 * m)
            + 0.000289 * sin(3 * m)
        let omega = (125.04 - 1934.136 * t) * rad
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(omega)
        return lambda.truncatingRemainder(dividingBy: 360) + (lambda < 0 ? 360 : 0)
    }

    /// 公历日期 0 时（UT）的儒略日
    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = y / 100
        let b = 2 - a + a / 4
        return Double(Int(365.25 * Double(y + 4716))) + Double(Int(30.6001 * Double(m + 1)))
            + Double(day) + Double(b) - 1524.5
    }
}
