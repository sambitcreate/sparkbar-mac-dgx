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
    private var pollTask: Task<Void, Never>?
    private var alertEngine: AlertEngine
    let launchAtLoginService = LaunchAtLoginService()
    let notificationService = NotificationService()
    private var isStopping = false

    init(defaults: UserDefaults = .standard) {
        settings = SettingsStore(defaults: defaults)
        selectedSparkID = settings.selectedSparkID
        alertEngine = AlertEngine(
            thresholds: settings.alertThresholds,
            cooldown: settings.alertCooldownMinutes * 60
        )
    }

    var isConnected: Bool { connectionState.isLive }

    /// True when snapshots are being refreshed, either over the WebSocket or
    /// through the REST polling fallback.
    var isReceivingData: Bool {
        connectionState.isLive || connectionState == .apiReachableLiveStreamUnavailable
    }

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
        logger.info("Starting SparkBar")
        guard let endpoint = try? SparkDashEndpoint(settings.endpoint), !settings.endpoint.isEmpty else {
            logger.info("No endpoint configured yet; waiting for input from the connection view")
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
        pollTask?.cancel()
        eventTask = nil
        pollTask = nil
        if let client {
            Task { await client.stop() }
        }
        client = nil
    }

    func connectFromSettings() {
        // Keep whatever the user typed so quitting mid-edit does not lose it.
        settings.persist()
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
        pollTask?.cancel()
        pollTask = nil
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
    }

    func reconnect() {
        connectFromSettings()
    }

    func handle(_ event: SparkDashClientEvent) {
        switch event {
        case .state(let state):
            connectionState = state
            logger.info("Connection state: \(state.shortLabel, privacy: .public)")
            switch state {
            case .apiReachableLiveStreamUnavailable:
                startPollingFallback()
            case .connected, .failed, .disconnected:
                stopPollingFallback()
            default:
                break
            }
            if case .failed(let message) = state {
                lastError = message
            }
        case .connectionTested(let result):
            configuredSparks = result.sparks
            serverSettings = result.settings
            logger.info("REST connection succeeded with \(result.sparkCount) Spark(s)")
        case .snapshot(let envelope):
            connectionState = .connected
            logger.info("Received snapshot with \(envelope.sparks.count) Spark(s)")
            applySnapshot(envelope)
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

    func sampleHistory() {
        guard !snapshots.isEmpty else { return }
        history.sample(snapshots)
    }

    /// Shared path for WebSocket frames and REST polling results so alerts,
    /// selection, history, and freshness behave identically on both paths.
    func applySnapshot(_ envelope: SnapshotEnvelope) {
        if snapshots != envelope.sparks {
            snapshots = envelope.sparks
        }
        lastSnapshotAt = .now
        sampleHistory()
        lastError = nil
        // Only auto-pick when nothing is selected; never clobber the
        // user's explicit choice when a spark briefly leaves the list.
        if selectedSparkID == nil {
            selectedSparkID = snapshots.first?.id
        }
        alertEngine.thresholds = settings.alertThresholds
        alertEngine.cooldown = settings.alertCooldownMinutes * 60
        let events = alertEngine.evaluate(snapshots: snapshots, temperatureUnit: effectiveTemperatureUnit)
        if settings.showNotifications {
            Task { await notificationService.deliver(events) }
        }
    }

    /// REST polling fallback for when the WebSocket is blocked but the API is
    /// reachable. Runs across the client's reconnect cycles and stops as soon
    /// as a real WebSocket connection delivers data.
    private func startPollingFallback() {
        guard pollTask == nil, let client else { return }
        pollTask = Task { [weak self, client] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = self.configuredSparks.map(\.id)
                if !ids.isEmpty,
                   let envelope = try? await client.pollSnapshot(sparkIDs: ids),
                   !envelope.sparks.isEmpty {
                    guard !Task.isCancelled, self.connectionState != .connected else { return }
                    self.applySnapshot(envelope)
                }
                let intervalMs = UInt64(max(self.serverSettings?.pollIntervalMs ?? 2000, 1000))
                do {
                    try await Task.sleep(nanoseconds: intervalMs * 1_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopPollingFallback() {
        pollTask?.cancel()
        pollTask = nil
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
    var alertCooldownMinutes: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PersistedSettings.self, from: $0) }
        endpoint = saved?.endpoint ?? ""
        displayMetric = saved?.displayMetric ?? .gpuUtilization
        sourceMode = saved?.sourceMode ?? .auto
        selectedSparkID = saved?.selectedSparkID
        temperatureUnit = saved?.temperatureUnit ?? .celsius
        launchAtLogin = saved?.launchAtLogin ?? false
        startHidden = saved?.startHidden ?? true
        showNotifications = saved?.showNotifications ?? false
        temperatureThreshold = saved?.temperatureThreshold ?? 85
        memoryThreshold = saved?.memoryThreshold ?? 85
        alertCooldownMinutes = saved?.alertCooldownMinutes ?? 15
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
            memoryThreshold: memoryThreshold,
            alertCooldownMinutes: alertCooldownMinutes
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
        let alertCooldownMinutes: Double
    }
}
