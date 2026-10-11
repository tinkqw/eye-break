import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var timerManager: TimerManager!
    private var waterCounter: WaterCounter!
    private var wifiMonitor: WifiMonitor!
    private var feishuCalendar: FeishuCalendar!
    private var menuBarController: MenuBarController!
    private var overlayController: OverlayWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        timerManager = TimerManager()
        waterCounter = WaterCounter()
        wifiMonitor = WifiMonitor()
        feishuCalendar = FeishuCalendar()
        menuBarController = MenuBarController(timerManager: timerManager, waterCounter: waterCounter, wifiMonitor: wifiMonitor, feishuCalendar: feishuCalendar)
        overlayController = OverlayWindowController(timerManager: timerManager, waterCounter: waterCounter)

        NotificationCenter.default.addObserver(
            forName: .showOverlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.overlayController.show()
        }

        NotificationCenter.default.addObserver(
            forName: .hideOverlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.overlayController.hide()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
