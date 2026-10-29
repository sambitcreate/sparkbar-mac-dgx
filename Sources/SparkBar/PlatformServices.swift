import AppKit
import SparkBarCore
import ServiceManagement
import UserNotifications

@MainActor
final class LaunchAtLoginService {
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(
        status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        readStatus = status
        self.register = register
        self.unregister = unregister
    }

    /// macOS can leave a registered login item pending user approval;
    /// the settings view uses this status to offer the System Settings link.
    var status: SMAppService.Status { readStatus() }

    var needsApproval: Bool { status == .requiresApproval }

    func apply(desired: Bool) throws {
        let currentStatus = status
        if desired {
            // Pending approval is already registered. Keep the existing UI
            // prompt instead of attempting to register the same item again.
            if currentStatus == .notRegistered || currentStatus == .notFound {
                try register()
            }
        } else if currentStatus == .enabled || currentStatus == .requiresApproval {
            // Turning off a pending item must remove its registration too.
            try unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Called with the alerting spark's ID when the user taps a notification.
    var onSelectSpark: ((String) -> Void)?

    override init() {
        super.init()
    }

    func activate() {
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                continuation.resume(returning: error == nil && granted)
            }
        }
    }

    /// Delivers the events and returns a user-facing message when delivery
    /// failed. A swallowed failure used to consume the alert's cooldown with
    /// nothing shown to the user.
    func deliver(_ events: [AlertEvent]) async -> String? {
        guard !events.isEmpty else { return nil }
        var failure: String?
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = "\(event.title) · \(event.sparkName)"
            content.body = event.body
            content.sound = .default
            content.userInfo = ["sparkID": event.sparkID]
            let request = UNNotificationRequest(
                identifier: event.id,
                content: content,
                trigger: nil
            )
            let errorMessage = await withCheckedContinuation { continuation in
                center.add(request) { error in
                    continuation.resume(returning: error?.localizedDescription)
                }
            }
            if let errorMessage {
                failure = "Notifications could not be delivered: \(errorMessage)"
            }
        }
        return failure
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // SparkBar is a menu-bar app: when the popover has focus the app is
        // frontmost, and alerts would otherwise be silently suppressed.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let sparkID = response.notification.request.content.userInfo["sparkID"] as? String else {
            return
        }
        await MainActor.run { [weak self] in
            self?.onSelectSpark?(sparkID)
        }
    }
}

@MainActor
final class SleepWakeMonitor {
    private var observers: [NSObjectProtocol] = []

    func start(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            onSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            onWake()
        })
    }

}
