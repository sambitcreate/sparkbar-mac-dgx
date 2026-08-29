import AppKit
import SparkBarCore
import ServiceManagement
import UserNotifications

@MainActor
final class LaunchAtLoginService {
    /// macOS 13+ can leave a "registered" login item pending user approval;
    /// `apply` alone never surfaces that, so the UI checks this status.
    var status: SMAppService.Status { SMAppService.mainApp.status }

    var needsApproval: Bool { status == .requiresApproval }

    func apply(desired: Bool) throws {
        if desired {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
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
        center.delegate = self
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func deliver(_ events: [AlertEvent]) async {
        guard !events.isEmpty else { return }
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
            try? await center.add(request)
        }
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
