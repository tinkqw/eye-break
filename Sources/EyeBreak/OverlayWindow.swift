import AppKit
import SwiftUI

final class OverlayWindowController {
    private var panels: [NSPanel] = []
    private let timerManager: TimerManager
    private let waterCounter: WaterCounter

    init(timerManager: TimerManager, waterCounter: WaterCounter) {
        self.timerManager = timerManager
        self.waterCounter = waterCounter
    }

    func show() {
        guard panels.isEmpty else { return }

        waterCounter.beginBreakSession()

        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 360

        for screen in NSScreen.screens {
            let contentView = OverlayView(
                timerManager: timerManager,
                waterCounter: waterCounter,
                onDismiss: { [weak self] in
                    self?.timerManager.reset()
                }
            )
            let hostingView = NSHostingView(rootView: contentView)

            let screenFrame = screen.frame
            let originX = screenFrame.midX - panelWidth / 2
            let originY = screenFrame.midY - panelHeight / 2

            let panel = NSPanel(
                contentRect: NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovable = false

            panel.contentView = hostingView
            panel.orderFrontRegardless()

            panels.append(panel)
        }
    }

    func hide() {
        for panel in panels {
            panel.close()
        }
        panels.removeAll()
    }
}

struct OverlayView: View {
    @ObservedObject var timerManager: TimerManager
    @ObservedObject var waterCounter: WaterCounter
    var onDismiss: () -> Void


    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.55, blue: 0.65),
                            Color(red: 0.15, green: 0.4, blue: 0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
                Spacer()
            }

            VStack(spacing: 24) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.9))

                Text("看看窗外，休息一下")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)

                Text("\(timerManager.remainingBreak)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text("秒后自动关闭")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))

                waterButton
            }
        }
        .frame(width: 400, height: 360)
    }

    /// 本次休息是否已记过一杯。读共享状态，两块屏的浮窗同步。
    private var logged: Bool { waterCounter.loggedThisBreak }

    private var waterButton: some View {
        Button {
            guard !logged else { return }
            waterCounter.add()   // add() 内部置 loggedThisBreak，两屏同步
        } label: {
            HStack(spacing: 8) {
                Image(systemName: logged ? "checkmark.circle.fill" : "drop.fill")
                    .font(.system(size: 15))
                Text(logged ? "今天第 \(waterCounter.cupsToday) 杯" : "顺便喝口水 +1")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.white.opacity(logged ? 0.75 : 0.95))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(.white.opacity(logged ? 0.12 : 0.22))
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: logged)
    }
}
