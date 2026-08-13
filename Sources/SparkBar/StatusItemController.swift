import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<PopoverRootView>
    private var pulseTimer: Timer?
    private var pulseVisible = true

    // Template images are cached: the status item updates on every snapshot
    // and must not allocate a fresh NSImage each time.
    private static let boltImage = templateImage("bolt.fill")
    private static let warningImage = templateImage("bolt.triangle.fill")
    private static let offlineImage = templateImage("bolt.slash")
    private static let connectingImage = templateImage("bolt.badge.clock")

    private static func templateImage(_ symbolName: String) -> NSImage {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func image(for iconName: String) -> NSImage {
        switch iconName {
        case "bolt.triangle.fill": return warningImage
        case "bolt.slash": return offlineImage
        case "bolt.badge.clock": return connectingImage
        default: return boltImage
        }
    }

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        hostingController = NSHostingController(rootView: PopoverRootView(model: model, openSettings: openSettings))
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.toolTip = "SparkBar"
        }
        configureMenu()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 390, height: 680)
        observeModel()
    }

    private func configureMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open sparkDash", action: #selector(openSparkDashFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SparkBar", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openSparkDashFromMenu() {
        model.openSparkDash()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(relativeTo: button)
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        showPopover(relativeTo: button)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.initialFirstResponder = popover.contentViewController?.view
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.currentPresentation
            _ = model.snapshots
            _ = model.connectionState
            _ = model.settings.displayMetric
            _ = model.settings.sourceMode
            _ = model.settings.temperatureUnit
            _ = model.serverSettings
            _ = model.selectedSparkID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem()
                self.observeModel()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let presentation = model.currentPresentation
        button.title = presentation.title
        button.image = Self.image(for: presentation.iconName)
        button.alphaValue = presentation.isDimmed ? 0.45 : (pulseVisible ? 1 : 0.7)
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        updatePulse(isPulsing: presentation.isPulsing)
    }

    private func updatePulse(isPulsing: Bool) {
        guard isPulsing else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseVisible = true
            statusItem.button?.alphaValue = model.currentPresentation.isDimmed ? 0.45 : 1
            return
        }
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseVisible.toggle()
                self.statusItem.button?.alphaValue = self.model.currentPresentation.isDimmed ? 0.45 : (self.pulseVisible ? 1 : 0.7)
            }
        }
    }
}
