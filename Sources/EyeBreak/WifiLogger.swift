import Foundation

/// Wi-Fi 采样落盘。按月一个 CSV，写的是聚合行（中位数 + 极值），不是瞬时值——
/// 实测原地不动 RSSI 也会在 4 dBm 范围内每 0.12 秒跳一次，逐条存瞬时值只是把抖动存下来。
///
/// 数据落 `~/Library/Application Support/EyeBreak/`。
final class WifiLogger {

    struct Row {
        let at: Date
        let rssiMed: Int, rssiMin: Int, rssiMax: Int
        /// 噪声除中位数外还留最差值（数值上的 max，越接近 0 越糟）。
        /// 只留中位数会把微波炉那种一两秒的干扰尖峰抹掉，而噪声恰恰是最该抓尖峰的字段。
        let noiseMed: Int, noiseMax: Int
        let rate: Int
        let channel: Int
        let samples: Int
    }

    static let header = "time,rssi_med,rssi_min,rssi_max,noise_med,noise_max,snr,rate_mbps,channel,samples\n"

    private let dir: URL
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private lazy var monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(directory: URL? = nil) {
        self.dir = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/EyeBreak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func fileURL(for date: Date) -> URL {
        dir.appendingPathComponent("wifi-\(monthFormatter.string(from: date)).csv")
    }

    /// 单行 CSV。noise 为 0（驱动没给值）时 snr 留空，不写一个假数。
    func line(for row: Row) -> String {
        let snr = row.noiseMed < 0 ? String(row.rssiMed - row.noiseMed) : ""
        return [
            formatter.string(from: row.at),
            String(row.rssiMed), String(row.rssiMin), String(row.rssiMax),
            String(row.noiseMed), String(row.noiseMax), snr,
            row.rate > 0 ? String(row.rate) : "",
            row.channel > 0 ? String(row.channel) : "",
            String(row.samples)
        ].joined(separator: ",") + "\n"
    }

    func append(_ row: Row) {
        let url = fileURL(for: row.at)
        prepare(url)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        if let d = line(for: row).data(using: .utf8) { try? h.write(contentsOf: d) }
    }

    /// 已检查过表头的文件，避免每次 append 都读一遍
    private var verified: URL?

    /// 保证目标文件存在且表头与当前字段一致。字段变更（比如 2026-09-16 加 noise_max）时
    /// 把老文件改名成 `.vN`，不让两种列宽的行混进同一个 CSV——混了之后 Numbers 和 awk 都会错位。
    func prepare(_ url: URL) {
        guard verified != url else { return }
        defer { verified = url }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? WifiLogger.header.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard firstLine(of: url) != WifiLogger.header.trimmingCharacters(in: .newlines) else { return }
        try? fm.moveItem(at: url, to: rotatedURL(for: url))
        try? WifiLogger.header.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 只读文件开头，不把整个 CSV 读进内存
    private func firstLine(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 1024), let s = String(data: d, encoding: .utf8) else { return nil }
        return s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    func rotatedURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base).v\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
