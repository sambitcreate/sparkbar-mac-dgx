import AppKit
import Observation
import SparkBarCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<PopoverRootView>
    private var contextMenu = NSMenu()
    private var pulseTimer: Timer?
    private var pulseVisible = true

    // Template images are cached: the status item updates on every snapshot
    // and must not allocate a fresh NSImage each time. The glyph is selected by
    // severity, so an unreachable sparkDash cannot render as an offline Spark.
    private static let boltImage = templateImage("bolt.fill")
    private static let warningImage = templateImage("bolt.triangle.fill")
    private static let offlineImage = templateImage("bolt.slash")
    private static let disconnectedImage = templateImage("bolt.horizontal.circle")
    private static let connectingImage = templateImage("bolt.badge.clock")

    private static func templateImage(_ symbolName: String) -> NSImage {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func image(for severity: MenuBarSeverity) -> NSImage {
        switch severity {
        case .normal: return boltImage
        case .warning: return warningImage
        case .offline: return offlineImage
        case .disconnected: return disconnectedImage
        case .connecting: return connectingImage
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
            button.action = #selector(handleStatusItemClick(_:))
            // Left click opens the dashboard; right click opens the menu.
            // Assigning `statusItem.menu` would steal the left click and never
            // call this action.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.toolTip = "SparkBar"
        }
        configureMenu()

        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = PopoverRootView.contentSize
        observeModel()
        updateStatusItem()
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
        statusItem.menu = nil
        contextMenu = menu
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        togglePopover(sender)
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
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
        guard button.window != nil else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.showPopover(relativeTo: button)
            }
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Activate after the popover is attached. Doing it in the same turn
        // (or making the popover key first) can drop the status-item window
        // and AppKit then parks the popover at screen origin — bottom left.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.popover.contentViewController?.view.window?.makeKey()
            self.popover.contentViewController?.view.window?.initialFirstResponder = self.popover.contentViewController?.view
        }
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
        button.image = Self.image(for: presentation.severity)
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
