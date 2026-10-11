import AppKit
import SwiftUI

/// 「新建日程」小窗：标题 / 日期 / 开始时间 / 时长 → 建到飞书主日历。
final class NewEventPanelController {
    private var panel: NSPanel?
    private let calendar: FeishuCalendar

    init(calendar: FeishuCalendar) {
        self.calendar = calendar
    }

    func show() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = NewEventView(
            calendar: calendar,
            initialStart: Self.nextHalfHour(),
            onClose: { [weak self] in self?.close() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "新建飞书日程"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        // NSPanel 默认失焦即隐藏；切去别处查一眼时间再回来，小窗不该消失
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        // 菜单栏 app（accessory）不主动激活的话，输入框拿不到键盘焦点
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func close() {
        panel?.close()
        panel = nil
    }

    /// 默认开始时间：下一个整点或半点
    static func nextHalfHour(from now: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = FeishuCalendar.timeZone
        // 先截到整分钟再加。date(bySetting: .second, value: 0) 会往后找「下一个秒为 0 的时刻」，
        // 10:30:31 会变成 10:31:00（实测踩过）
        let minuteStart = cal.dateInterval(of: .minute, for: now)!.start
        let minute = cal.component(.minute, from: minuteStart)
        let add = minute < 30 ? 30 - minute : 60 - minute
        return cal.date(byAdding: .minute, value: add, to: minuteStart)!
    }
}

struct NewEventView: View {
    let calendar: FeishuCalendar
    let onClose: () -> Void

    @State private var title = ""
    @State private var start: Date
    @State private var minutes = 30
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private static let durations = [30, 60, 90, 120]

    init(calendar: FeishuCalendar, initialStart: Date, onClose: @escaping () -> Void) {
        self.calendar = calendar
        self.onClose = onClose
        _start = State(initialValue: initialStart)
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("日程标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(save)

            HStack {
                DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .environment(\.timeZone, FeishuCalendar.timeZone)
                Spacer()
            }

            Picker("", selection: $minutes) {
                ForEach(Self.durations, id: \.self) { m in
                    Text(m < 60 ? "\(m) 分钟" : (m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60).5 小时")).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "创建中…" : "建到飞书", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || saving)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(width: 340)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        error = nil
        Task {
            do {
                try await calendar.create(title: trimmed, start: start, minutes: minutes)
                await MainActor.run { onClose() }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.saving = false
                }
            }
        }
    }
}
