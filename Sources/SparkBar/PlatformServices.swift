import AppKit
import SparkBarCore
import ServiceManagement
import UserNotifications

@MainActor
final class LaunchAtLoginService {
    func apply(desired: Bool) throws {
        if desired {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class NotificationService {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

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
            let request = UNNotificationRequest(
                identifier: event.id,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
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
