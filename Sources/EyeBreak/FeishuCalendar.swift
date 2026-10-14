import Foundation
import Combine

/// 飞书日历：按区间读日程（主面板月历用）、新建日程。
///
/// 可选功能。凭证只读一个 JSON 文件：`{"access_token": "...", "expires_at": <unix 秒>}`，
/// 是飞书的 user_access_token（需 calendar 读写权限）。本类从不续期——续期由你自己的脚本负责。
/// 默认路径 `~/.config/eyebreak/feishu_token.json`，可用
/// `defaults write io.github.tinkqw.eyebreak FeishuTokenPath <路径>` 改。
/// 文件不存在 = 不启用，主面板只显示月历和状态。
final class FeishuCalendar: ObservableObject {
    struct Event: Hashable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        /// 飞书视频会议链接（`vchat.meeting_url`），没有会议的日程为 nil
        var meetingURL: URL? = nil
    }

    /// 每建成一条日程 +1，日历面板据此重拉当前月
    @Published private(set) var revision = 0

    static var tokenURL: URL {
        if let custom = UserDefaults.standard.string(forKey: "FeishuTokenPath"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/eyebreak/feishu_token.json")
    }
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private static let api = "https://open.feishu.cn/open-apis"
    private var calendarID: String?

    /// 凭证文件在才启用
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.tokenURL.path)
    }

    /// 新建日程。不加视频会议、不发 Bot 通知（没有参与人，通知只会发给自己）。
    func create(title: String, start: Date, minutes: Int) async throws {
        let cid = try await primaryCalendarID()
        let tz = Self.timeZone.identifier
        let body: [String: Any] = [
            "summary": title,
            "start_time": ["timestamp": String(Int(start.timeIntervalSince1970)), "timezone": tz],
            "end_time": ["timestamp": String(Int(start.timeIntervalSince1970) + minutes * 60), "timezone": tz],
            "vchat": ["vc_type": "no_meeting"],
            "need_notification": false,
        ]
        let data = try await request("POST", "/calendar/v4/calendars/\(escape(cid))/events?user_id_type=open_id", body: body)
        // 创建接口不加参与人；参与人为空的日程飞书客户端不显示（2026-10-09 实测），
        // 所以紧接着把自己（组织者）加为参与人
        guard let event = data["event"] as? [String: Any],
              let eventID = event["event_id"] as? String,
              let me = (event["event_organizer"] as? [String: Any])?["user_id"] as? String else {
            throw CalendarError.message("日程已建，但飞书没返回日程 ID")
        }
        do {
            _ = try await request(
                "POST", "/calendar/v4/calendars/\(escape(cid))/events/\(escape(eventID))/attendees?user_id_type=open_id",
                body: ["attendees": [["type": "user", "user_id": me]], "need_notification": false])
        } catch {
            throw CalendarError.message("日程已建，但没把自己加为参与人：\(error.localizedDescription)")
        }
        await MainActor.run { self.revision += 1 }
    }

    // MARK: - 接口

    /// 区间内的日程（已滤取消 / 已拒绝），全天在前、其余按开始时间。
    /// instance_view 会把重复日程展开成实例（普通 events list 只回母版），但单次区间最多 40 天
    /// （2026-10-14 实测：40 天 code 0，42 天报 193103 requested time exceeds the allowed range），
    /// 所以按 40 天切段；跨段的日程两段都会返回，用 Set 去重。
    func events(from start: Date, to end: Date) async throws -> [Event] {
        guard isAvailable else { return [] }
        let cid = try await primaryCalendarID()
        let maxSpan = 40 * 86400
        var found = Set<Event>()
        var s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        while s < e {
            let segEnd = min(s + maxSpan, e)
            let data = try await request(
                "GET", "/calendar/v4/calendars/\(escape(cid))/events/instance_view?start_time=\(s)&end_time=\(segEnd)")
            for item in (data["items"] as? [[String: Any]]) ?? [] {
                if let ev = Self.parse(item) { found.insert(ev) }
            }
            s = segEnd
        }
        return found.sorted {
            $0.isAllDay != $1.isAllDay ? $0.isAllDay : $0.start < $1.start
        }
    }

    static func parse(_ item: [String: Any]) -> Event? {
        if (item["status"] as? String) == "cancelled" { return nil }
        if (item["self_rsvp_status"] as? String) == "decline" { return nil }
        guard let st = item["start_time"] as? [String: Any],
              let et = item["end_time"] as? [String: Any] else { return nil }
        let summary = (item["summary"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = summary.isEmpty ? "（无主题）" : summary
        let meeting = ((item["vchat"] as? [String: Any])?["meeting_url"] as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if let a = (st["timestamp"] as? String).flatMap(Double.init),
           let b = (et["timestamp"] as? String).flatMap(Double.init) {
            return Event(title: title, start: Date(timeIntervalSince1970: a),
                         end: Date(timeIntervalSince1970: b), isAllDay: false, meetingURL: meeting)
        }
        // 全天日程只给 date（"2026-10-09"），没有 timestamp。
        // 结束日按「含当天」算：官方创建接口示例里单天全天日程的 start/end 是同一天
        if let d = st["date"] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = timeZone
            if let day = f.date(from: d) {
                let last = (et["date"] as? String).flatMap(f.date(from:)).map { max($0, day) } ?? day
                return Event(title: title, start: day, end: last.addingTimeInterval(86400), isAllDay: true,
                             meetingURL: meeting)
            }
        }
        return nil
    }

    private func primaryCalendarID() async throws -> String {
        if let id = calendarID { return id }
        let data = try await request("POST", "/calendar/v4/calendars/primary", body: [:])
        guard let list = data["calendars"] as? [[String: Any]],
              let id = (list.first?["calendar"] as? [String: Any])?["calendar_id"] as? String else {
            throw CalendarError.message("拿不到主日历")
        }
        calendarID = id
        return id
    }

    private func readToken() throws -> String {
        guard let raw = try? Data(contentsOf: Self.tokenURL),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw CalendarError.message("读不到飞书凭证")
        }
        if let exp = obj["expires_at"] as? Double, exp < Date().timeIntervalSince1970 {
            throw CalendarError.message("飞书凭证已过期")
        }
        return token
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: Self.api + path)!, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(try readToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarError.message("飞书返回无法解析")
        }
        let code = obj["code"] as? Int ?? -1
        guard code == 0 else {
            throw CalendarError.message("飞书报错 \(code)：\(obj["msg"] as? String ?? "")")
        }
        return obj["data"] as? [String: Any] ?? [:]
    }

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "@"))) ?? s
    }
}

enum CalendarError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
