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

        // Single-instance guard: a second launch should exit immediately
        // instead of stacking identical status items.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sparkbar.app"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusItemController = StatusItemController(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        sleepWakeMonitor.start(
            onSleep: { [weak self] in Task { @MainActor [weak self] in self?.model.sleep() } },
            onWake: { [weak self] in Task { @MainActor [weak self] in self?.model.wake() } }
        )
        model.start()

        // "Start hidden" now has real semantics: when off, open the popover
        // shortly after launch so the dashboard greets the user.
        if !model.settings.startHidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.statusItemController?.showPopover()
            }
        }
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
