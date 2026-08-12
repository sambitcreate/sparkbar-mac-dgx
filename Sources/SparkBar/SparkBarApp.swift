import AppKit
import SwiftUI

@main
@MainActor
struct SparkBarApp {
    init() {
        // AppKit owns the process lifetime for this LSUIElement application.
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let coordinator = AppCoordinator()
        coordinator.start()
        application.run()
    }
}

@MainActor
final class AppCoordinator {
    let model = AppModel()
    private var statusItemController: StatusItemController?
    private var settingsWindowController: NSWindowController?
    private let sleepWakeMonitor = SleepWakeMonitor()
    private var didStart = false

    func start() {
        guard !didStart else { return }
        didStart = true
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        sleepWakeMonitor.start(
            onSleep: { [weak self] in Task { @MainActor [weak self] in self?.model.sleep() } },
            onWake: { [weak self] in Task { @MainActor [weak self] in self?.model.wake() } }
        )
        model.start()
    }

    func openSettings() {
        if let settingsWindowController {
            settingsWindowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(model: model)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SparkBar Settings"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindowController = NSWindowController(window: window)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
