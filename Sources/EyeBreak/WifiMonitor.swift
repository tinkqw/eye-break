import AppKit
import Combine
import CoreWLAN

/// 当前 Wi-Fi 的信号质量。菜单里回答「网怎么样」，巡测模式把实时数值临时顶到菜单栏
/// 供走动找位置用，同时把聚合后的采样落 CSV 供事后观察。
///
/// 为什么默认不常驻菜单栏标题：RSSI 总在阈值附近晃，菜单栏右对齐互推，
/// 标题每几秒变一次宽度会把左侧所有图标推着位移。所以常驻只在巡测期间、且用户显式开启。
///
/// 为什么对外给的是中位数而不是瞬时值：2026-09-16 实测机器原地不动，15 秒内 RSSI
/// 在 -64…-68 之间变化 66 次、中位变化间隔 0.12 秒（约等于 beacon 节奏）。
/// 显示或存储瞬时值会让用户把测量抖动当成信号变化。
final class WifiMonitor: ObservableObject {

    enum Quality {
        case good, fair, poor

        var label: String {
            switch self {
            case .good: return "良好"
            case .fair: return "一般"
            case .poor: return "较差"
            }
        }

        var color: NSColor {
            switch self {
            case .good: return .systemGreen
            case .fair: return .systemOrange
            case .poor: return .systemRed
            }
        }

        fileprivate var downgraded: Quality {
            switch self {
            case .good: return .fair
            case .fair, .poor: return .poor
            }
        }
    }

    enum Reading: Equatable {
        case off                                            // Wi-Fi 硬件关闭
        case unavailable                                    // 没有 Wi-Fi 网卡
        case disconnected                                   // 开着但没连上
        case connected(rssi: Int, noise: Int, rate: Int)
    }

    struct Sample {
        let at: Date
        let rssi: Int, noise: Int, rate: Int, channel: Int
    }

    /// 分档阈值。-67 是业界常用的语音/视频可靠下限（惯例，非标准），-80 以下基本不可用。
    private static let goodThreshold = -67
    private static let fairThreshold = -80
    /// 信噪比下限。低于此值即便 RSSI 好也要降档——同样的 -64 dBm，
    /// 噪声 -100（SNR 36）很健康，噪声 -80（SNR 16）实际很糟。
    private static let minSNR = 20

    /// 采样间隔：巡测时 0.2 秒（单次读网卡实测 3.5 ms，频率不是成本），平时 5 秒。
    private static let surveyInterval: TimeInterval = 0.2
    private static let normalInterval: TimeInterval = 5
    /// 落盘间隔：巡测 1 秒一行（5 个样本），平时 60 秒一行（12 个样本）。
    private static let surveyFlush: TimeInterval = 1
    private static let normalFlush: TimeInterval = 60
    /// 对外显示取最近这段时间内样本的中位数
    private static let smoothWindow: TimeInterval = 2
    /// 巡测自动关闭时限，防止用户忘记关掉后标题长期抖动
    static let surveyTimeout: TimeInterval = 600

    @Published private(set) var reading: Reading = .disconnected
    @Published private(set) var surveying: Bool = false

    private let logger: WifiLogger
    private var timer: Timer?
    private var surveyDeadline: Date?
    /// 读网卡可能慢于轮询间隔，防重入避免任务堆积
    private var sampling = false
    private let sampleQueue = DispatchQueue(label: "eyebreak.wifi", qos: .utility)

    /// 平滑窗口用的近期样本
    private var recent: [Sample] = []
    /// 当前落盘桶
    private var bucket: [Sample] = []
    private var bucketStart = Date()
    private var lastLoggedQuality: Quality?

    init(logger: WifiLogger = WifiLogger()) {
        self.logger = logger
        restartTimer()
        tick()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 判定（纯函数，可单测）

    /// noise 为 0 表示驱动没给出噪声值，此时不参与判定。
    static func quality(rssi: Int, noise: Int) -> Quality {
        var q: Quality = rssi >= goodThreshold ? .good
                       : (rssi >= fairThreshold ? .fair : .poor)
        if noise < 0, rssi - noise < minSNR {
            q = q.downgraded
        }
        return q
    }

    // MARK: - 聚合（纯函数，可单测）

    static func median(_ xs: [Int]) -> Int {
        precondition(!xs.isEmpty)
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// 把一桶样本压成一行。空桶返回 nil。
    static func aggregate(_ samples: [Sample]) -> WifiLogger.Row? {
        guard let last = samples.last else { return nil }
        let rssis = samples.map(\.rssi)
        let noises = samples.map(\.noise)
        return WifiLogger.Row(
            at: last.at,
            rssiMed: median(rssis),
            rssiMin: rssis.min()!,
            rssiMax: rssis.max()!,
            noiseMed: median(noises),
            noiseMax: noises.max()!,
            rate: last.rate,
            channel: last.channel,
            samples: samples.count
        )
    }

    // MARK: - 巡测

    func toggleSurvey() {
        flushBucket()                       // 换采样率前先把当前桶结掉，避免两种频率混在一行
        surveying.toggle()
        surveyDeadline = surveying ? Date().addingTimeInterval(WifiMonitor.surveyTimeout) : nil
        restartTimer()
        tick()
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = surveying ? WifiMonitor.surveyInterval : WifiMonitor.normalInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 菜单打开时主 runloop 进入 modal 模式，默认模式的 timer 会停摆，
        // 巡测数值必须在菜单展开期间也继续刷新
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if let deadline = surveyDeadline, Date() >= deadline {
            flushBucket()
            surveying = false
            surveyDeadline = nil
            restartTimer()
        }
        sample()
    }

    // MARK: - 取值

    private func sample() {
        guard !sampling else { return }
        sampling = true
        sampleQueue.async { [weak self] in
            let snapshot = WifiMonitor.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                self.ingest(snapshot)
            }
        }
    }

    private func ingest(_ snapshot: (Reading, Sample?)) {
        let (raw, sample) = snapshot

        guard let sample else {
            // 关闭 / 未连接 / 无网卡：桶结掉，直接透出状态
            flushBucket()
            recent.removeAll()
            lastLoggedQuality = nil
            if reading != raw { reading = raw }
            return
        }

        recent.append(sample)
        bucket.append(sample)
        let cutoff = Date().addingTimeInterval(-WifiMonitor.smoothWindow)
        recent.removeAll { $0.at < cutoff }
        if recent.isEmpty { recent = [sample] }

        // 对外给窗口内的中位数，不给瞬时值
        let smoothed = Reading.connected(
            rssi: WifiMonitor.median(recent.map(\.rssi)),
            noise: WifiMonitor.median(recent.map(\.noise)),
            rate: sample.rate
        )
        if reading != smoothed { reading = smoothed }

        maybeFlush(smoothed)
    }

    private func maybeFlush(_ smoothed: Reading) {
        let elapsed = Date().timeIntervalSince(bucketStart)
        let due = elapsed >= (surveying ? WifiMonitor.surveyFlush : WifiMonitor.normalFlush)

        // 档位跨档时立刻补一行，不等满桶——这才是值得记的「变化」，
        // ±1 dBm 的抖动不是（否则又变成把测量噪声存下来）
        var bandChanged = false
        if case .connected(let r, let n, _) = smoothed {
            let q = WifiMonitor.quality(rssi: r, noise: n)
            bandChanged = lastLoggedQuality != nil && lastLoggedQuality != q
            if due || bandChanged { lastLoggedQuality = q }
        }

        if due || bandChanged { flushBucket(scheduled: due) }
    }

    /// `scheduled` 时按整倍步进 bucketStart，而不是重置为 now。
    /// 重置会累积每桶几十毫秒的延迟，实测会让 1 秒一行漂成 1.1 秒、每分钟丢掉几行
    /// （2026-09-16 首版即此现象：18:04:27 下一行直接到 :29）。落后超过两个间隔则直接对齐当下。
    private func flushBucket(scheduled: Bool = false) {
        let interval = surveying ? WifiMonitor.surveyFlush : WifiMonitor.normalFlush
        defer {
            bucket.removeAll()
            if scheduled {
                let next = bucketStart.addingTimeInterval(interval)
                bucketStart = Date().timeIntervalSince(next) > interval ? Date() : next
            } else {
                bucketStart = Date()
            }
        }
        guard let row = WifiMonitor.aggregate(bucket) else { return }
        logger.append(row)
    }

    private static func read() -> (Reading, Sample?) {
        guard let itf = CWWiFiClient.shared().interface() else { return (.unavailable, nil) }
        guard itf.powerOn() else { return (.off, nil) }
        let rssi = itf.rssiValue()
        // 未关联时驱动返回 0，不是「0 dBm 超强信号」
        guard rssi != 0 else { return (.disconnected, nil) }
        let noise = itf.noiseMeasurement()
        let rate = Int(itf.transmitRate())
        let channel = itf.wlanChannel()?.channelNumber ?? 0
        return (.connected(rssi: rssi, noise: noise, rate: rate),
                Sample(at: Date(), rssi: rssi, noise: noise, rate: rate, channel: channel))
    }
}
