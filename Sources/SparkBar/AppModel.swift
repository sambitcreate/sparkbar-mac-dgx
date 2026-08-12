import AppKit
import Observation
import OSLog
import SparkBarCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private let logger = Logger(subsystem: "com.sparkbar.app", category: "runtime")
    let settings: SettingsStore

    private(set) var snapshots: [SparkSnapshot] = []
    private(set) var configuredSparks: [SparkConfiguration] = []
    private(set) var serverSettings: SparkDashSettings?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var lastSnapshotAt: Date?
    private(set) var lastError: String?
    private(set) var history = HistoryStore(maxSamples: 900)

    var selectedSparkID: String? {
        didSet {
            settings.selectedSparkID = selectedSparkID
            settings.persist()
        }
    }

    private var client: SparkDashClient?
    private var currentEndpoint: SparkDashEndpoint?
    private var eventTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var alertEngine: AlertEngine
    let launchAtLoginService = LaunchAtLoginService()
    let notificationService = NotificationService()
    private var isStopping = false

    init(defaults: UserDefaults = .standard) {
        settings = SettingsStore(defaults: defaults)
        selectedSparkID = settings.selectedSparkID
        alertEngine = AlertEngine(thresholds: settings.alertThresholds)
    }

    var isConnected: Bool { connectionState.isLive }

    var effectiveTemperatureUnit: TemperatureUnit {
        guard settings.temperatureUnit == .followSparkDash else { return settings.temperatureUnit }
        return serverSettings?.temperatureUnit?.lowercased() == "fahrenheit" ? .fahrenheit : .celsius
    }

    var currentPresentation: MenuBarPresentation {
        MenuBarPresenter.make(
            snapshots: snapshots,
            connectionState: connectionState,
            metric: settings.displayMetric,
            sourceMode: settings.sourceMode,
            selectedID: selectedSparkID,
            temperatureUnit: effectiveTemperatureUnit,
            thresholds: settings.alertThresholds
        )
    }

    var selectedSnapshot: SparkSnapshot? {
        if let selectedSparkID, let selected = snapshots.first(where: { $0.id == selectedSparkID }) {
            return selected
        }
        return SparkSelector.auto(snapshots: snapshots, selectedID: selectedSparkID)
    }

    var onlineCount: Int { snapshots.filter(\.isOnline).count }

    func start() {
        guard !isStopping else { return }
        logger.info("Starting SparkBar with endpoint \(self.settings.endpoint, privacy: .public)")
        startHistorySampling()
        guard let endpoint = try? SparkDashEndpoint(settings.endpoint), !settings.endpoint.isEmpty else {
            logger.error("No valid endpoint configured")
            return
        }
        connect(to: endpoint)
        do {
            try launchAtLoginService.apply(desired: settings.launchAtLogin)
        } catch {
            lastError = "Launch at login could not be configured: \(error.localizedDescription)"
        }
    }

    func stop() {
        isStopping = true
        eventTask?.cancel()
        historyTask?.cancel()
        eventTask = nil
        historyTask = nil
        if let client {
            Task { await client.stop() }
        }
        client = nil
    }

    func connectFromSettings() {
        do {
            let endpoint = try SparkDashEndpoint(settings.endpoint)
            settings.endpoint = endpoint.displayString
            settings.persist()
            connect(to: endpoint)
        } catch {
            connectionState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            logger.error("Endpoint validation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func connect(to endpoint: SparkDashEndpoint) {
        isStopping = false
        eventTask?.cancel()
        historyTask?.cancel()
        if let oldClient = client {
            Task { await oldClient.stop() }
        }

        let endpointChanged = currentEndpoint != endpoint
        currentEndpoint = endpoint
        settings.endpoint = endpoint.displayString
        settings.persist()
        if endpointChanged {
            snapshots = []
            configuredSparks = []
            serverSettings = nil
            lastSnapshotAt = nil
        }
        lastError = nil

        let newClient = SparkDashClient(endpoint: endpoint)
        client = newClient
        logger.info("Connecting to \(endpoint.displayString, privacy: .public)")
        eventTask = Task { [weak self, newClient] in
            let events = await newClient.events()
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.handle(event)
            }
        }
        Task { await newClient.start() }
        startHistorySampling()
    }

    func reconnect() {
        connectFromSettings()
    }

    func handle(_ event: SparkDashClientEvent) {
        switch event {
        case .state(let state):
            connectionState = state
            logger.info("Connection state: \(state.shortLabel, privacy: .public)")
            if case .failed(let message) = state {
                lastError = message
            }
        case .connectionTested(let result):
            configuredSparks = result.sparks
            serverSettings = result.settings
            connectionState = .apiReachableLiveStreamUnavailable
            logger.info("REST connection succeeded with \(result.sparkCount) Spark(s)")
        case .snapshot(let envelope):
            if snapshots != envelope.sparks {
                snapshots = envelope.sparks
            }
            lastSnapshotAt = .now
            connectionState = .connected
            lastError = nil
            logger.info("Received snapshot with \(envelope.sparks.count) Spark(s)")
            if selectedSparkID == nil || !snapshots.contains(where: { $0.id == selectedSparkID }) {
                selectedSparkID = snapshots.first?.id
            }
            alertEngine.thresholds = settings.alertThresholds
            let events = alertEngine.evaluate(snapshots: snapshots)
            if settings.showNotifications {
                Task { await notificationService.deliver(events) }
            }
        case .diagnostic(let message):
            lastError = message
            logger.error("Transport diagnostic: \(message, privacy: .public)")
        }
    }

    func setSelectedSpark(_ id: String?) {
        selectedSparkID = id
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.apply(desired: enabled)
            settings.launchAtLogin = enabled
            settings.persist()
        } catch {
            lastError = "Launch at login could not be configured: \(error.localizedDescription)"
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        if enabled {
            Task { @MainActor in
                let granted = await notificationService.requestPermission()
                settings.showNotifications = granted
                settings.persist()
                if !granted {
                    lastError = "Notification permission was not granted."
                }
            }
        } else {
            settings.showNotifications = false
            settings.persist()
        }
    }

    func sleep() {
        if let client {
            Task { await client.stop() }
        }
        connectionState = .disconnected
    }

    func wake() {
        connectFromSettings()
    }

    func openSparkDash() {
        guard let endpoint = try? SparkDashEndpoint(settings.endpoint) else { return }
        NSWorkspace.shared.open(endpoint.apiBaseURL)
    }

    func openSparkDashRepository() {
        guard let url = URL(string: "https://github.com/MiaAI-Lab/sparkDash") else { return }
        NSWorkspace.shared.open(url)
    }

    func openSparkBarRepository() {
        guard let url = URL(string: "https://github.com/sambitcreate/sparkbar-mac-dgx") else { return }
        NSWorkspace.shared.open(url)
    }

    func startHistorySampling() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                self?.sampleHistory()
            }
        }
    }

    func sampleHistory() {
        guard !snapshots.isEmpty else { return }
        history.sample(snapshots)
    }
}

@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "com.sparkbar.settings.v1"

    var endpoint: String
    var displayMetric: DisplayMetric
    var sourceMode: SparkSourceMode
    var selectedSparkID: String?
    var temperatureUnit: TemperatureUnit
    var launchAtLogin: Bool
    var startHidden: Bool
    var showNotifications: Bool
    var temperatureThreshold: Double
    var memoryThreshold: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PersistedSettings.self, from: $0) }
        endpoint = saved?.endpoint ?? "http://100.101.194.105:5555"
        displayMetric = saved?.displayMetric ?? .gpuUtilization
        sourceMode = saved?.sourceMode ?? .auto
        selectedSparkID = saved?.selectedSparkID
        temperatureUnit = saved?.temperatureUnit ?? .celsius
        launchAtLogin = saved?.launchAtLogin ?? false
        startHidden = saved?.startHidden ?? true
        showNotifications = saved?.showNotifications ?? false
        temperatureThreshold = saved?.temperatureThreshold ?? 85
        memoryThreshold = saved?.memoryThreshold ?? 90
    }

    var alertThresholds: AlertThresholds {
        AlertThresholds(temperatureCelsius: temperatureThreshold, memoryPercentage: memoryThreshold)
    }

    func persist() {
        let value = PersistedSettings(
            endpoint: endpoint,
            displayMetric: displayMetric,
            sourceMode: sourceMode,
            selectedSparkID: selectedSparkID,
            temperatureUnit: temperatureUnit,
            launchAtLogin: launchAtLogin,
            startHidden: startHidden,
            showNotifications: showNotifications,
            temperatureThreshold: temperatureThreshold,
            memoryThreshold: memoryThreshold
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private struct PersistedSettings: Codable {
        let endpoint: String
        let displayMetric: DisplayMetric
        let sourceMode: SparkSourceMode
        let selectedSparkID: String?
        let temperatureUnit: TemperatureUnit
        let launchAtLogin: Bool
        let startHidden: Bool
        let showNotifications: Bool
        let temperatureThreshold: Double
        let memoryThreshold: Double
    }
}
