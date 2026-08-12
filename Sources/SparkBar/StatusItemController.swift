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

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        hostingController = NSHostingController(rootView: PopoverRootView(model: model, openSettings: openSettings))
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.font = .systemFont(ofSize: NSFont.systemFontSize)
            button.setAccessibilityLabel("SparkBar lightning status")
            button.toolTip = "SparkBar"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 390, height: 680)
        observeModel()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.initialFirstResponder = popover.contentViewController?.view
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
        button.title = ""
        button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "SparkBar lightning status")
        button.image?.isTemplate = true
        button.image?.size = NSSize(width: 18, height: 18)
        button.alphaValue = presentation.isDimmed ? 0.45 : (pulseVisible ? 1 : 0.65)
        button.toolTip = presentation.accessibilityLabel
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
                self.statusItem.button?.alphaValue = self.pulseVisible ? 1 : 0.72
            }
        }
    }
}
