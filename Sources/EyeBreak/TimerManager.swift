import Foundation
import Combine

final class TimerManager: ObservableObject {
    static let workOptions: [(label: String, seconds: Int)] = [
        ("15 分钟", 15 * 60),
        ("20 分钟", 20 * 60),
        ("25 分钟", 25 * 60),
        ("30 分钟", 30 * 60),
    ]

    static let breakOptions: [(label: String, seconds: Int)] = [
        ("10 秒", 10),
        ("15 秒", 15),
        ("20 秒", 20),
        ("30 秒", 30),
    ]

    private static let workKey = "workDuration"
    private static let breakKey = "breakDuration"

    enum State {
        case counting
        case paused
        case breaking
    }

    @Published var state: State = .counting
    @Published var remainingWork: Int
    @Published var remainingBreak: Int
    @Published var workDuration: Int {
        didSet { UserDefaults.standard.set(workDuration, forKey: TimerManager.workKey) }
    }
    @Published var breakDuration: Int {
        didSet { UserDefaults.standard.set(breakDuration, forKey: TimerManager.breakKey) }
    }

    private var timer: Timer?

    var remainingMinutes: String {
        let minutes = remainingWork / 60
        let seconds = remainingWork % 60
        if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }

    var statusText: String {
        switch state {
        case .counting:
            let m = remainingWork / 60
            let s = remainingWork % 60
            return String(format: "下次休息：%02d:%02d", m, s)
        case .paused:
            return "已暂停"
        case .breaking:
            return "休息中：\(remainingBreak)s"
        }
    }

    init() {
        let savedWork = UserDefaults.standard.integer(forKey: TimerManager.workKey)
        let savedBreak = UserDefaults.standard.integer(forKey: TimerManager.breakKey)
        let work = savedWork > 0 ? savedWork : 20 * 60
        let brk = savedBreak > 0 ? savedBreak : 20
        self.workDuration = work
        self.breakDuration = brk
        self.remainingWork = work
        self.remainingBreak = brk
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        switch state {
        case .counting:
            if remainingWork > 0 {
                remainingWork -= 1
            }
            if remainingWork == 0 {
                startBreak()
            }
        case .paused:
            break
        case .breaking:
            if remainingBreak > 0 {
                remainingBreak -= 1
            }
            if remainingBreak == 0 {
                endBreak()
            }
        }
    }

    private func startBreak() {
        state = .breaking
        remainingBreak = breakDuration
        NotificationCenter.default.post(name: .showOverlay, object: nil)
    }

    private func endBreak() {
        state = .counting
        remainingWork = workDuration
        NotificationCenter.default.post(name: .hideOverlay, object: nil)
    }

    func pause() {
        guard state == .counting else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        state = .counting
    }

    func reset() {
        state = .counting
        remainingWork = workDuration
        remainingBreak = breakDuration
        NotificationCenter.default.post(name: .hideOverlay, object: nil)
    }

    func setWorkDuration(_ seconds: Int) {
        workDuration = seconds
        reset()
    }

    func setBreakDuration(_ seconds: Int) {
        breakDuration = seconds
    }
}

extension Notification.Name {
    static let showOverlay = Notification.Name("showOverlay")
    static let hideOverlay = Notification.Name("hideOverlay")
}
