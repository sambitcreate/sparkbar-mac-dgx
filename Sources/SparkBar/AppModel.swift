import AppKit
import Observation
import OSLog
import SparkBarCore
import SwiftUI

enum ConnectionSetupMode: String, CaseIterable {
    case scan
    case manual
}

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
    /// Transport chatter (malformed frames, reconnect reasons). Kept separate
    /// from `lastError` so routine noise never masks the user-facing message.
    private(set) var lastDiagnostic: String?
    /// Set by `focusSpark(_:)` (e.g. a notification tap) to ask the popover to
    /// navigate to a spark's detail page. Consumed and cleared by the view.
    private(set) var focusedSparkID: String?
    private(set) var history = HistoryStore(maxSamples: 900)

    var connectionSetupMode: ConnectionSetupMode = .scan
    private(set) var discoveryPhase: SparkDashDiscoveryPhase = .idle
    private(set) var discoveryHits: [SparkDashDiscoveryHit] = []
    private(set) var discoveryError: String?

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
    private var historyTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Incremented on start/stop so a cancelled scan cannot clobber a newer one.
    private var scanSession = 0
    private let scanner = SparkDashScanner()
    private var alertEngine: AlertEngine
    /// Retains Sparks that a single snapshot omitted, so one failed metrics
    /// request cannot remove a machine from the dashboard.
    private var fleetMerger = FleetSnapshotMerger()
    /// Identifies the current polling loop. A cancelled loop must not clear the
    /// handle of a newer one that replaced it.
    private var pollGeneration = 0
    let launchAtLoginService = LaunchAtLoginService()
    let notificationService = NotificationService()
    private var isStopping = false

    /// sparkDash skips broadcasting an unchanged snapshot, so a Spark sitting
    /// idle produces no frames. Sampling on an independent timer keeps the
    /// history continuous instead of only recording changes.
    private static let historySampleInterval: Duration = .seconds(2)

    init(defaults: UserDefaults = .standard) {
        settings = SettingsStore(defaults: defaults)
        selectedSparkID = settings.selectedSparkID
        alertEngine = AlertEngine(
            thresholds: settings.alertThresholds,
            cooldown: settings.alertCooldownMinutes * 60
        )
        migrateUnusedLocalhostEndpoint()
    }

    private static let unusedLocalhostEndpoints: Set<String> = [
        "http://localhost:5555",
        "http://127.0.0.1:5555",
    ]

    private func migrateUnusedLocalhostEndpoint() {
        guard settings.lastSuccessfulEndpoint?.isEmpty ?? true,
              Self.isUnusedLocalhost(settings.endpoint) else { return }
        settings.endpoint = ""
        settings.persist()
    }

    private static func isUnusedLocalhost(_ rawValue: String) -> Bool {
        unusedLocalhostEndpoints.contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private var usableEndpointString: String? {
        if let last = settings.lastSuccessfulEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !last.isEmpty {
            return last
        }
        let draft = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return nil }
        if Self.isUnusedLocalhost(draft) { return nil }
        return draft
    }

    private func recordSuccessfulEndpoint() {
        guard let endpoint = currentEndpoint?.displayString,
              !Self.isUnusedLocalhost(endpoint) else { return }
        settings.lastSuccessfulEndpoint = endpoint
        settings.persist()
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
        return SparkSelector.auto(snapshots: snapshots, selectedID: selectedSparkID, thresholds: settings.alertThresholds)
    }

    var onlineCount: Int { snapshots.filter(\.isOnline).count }

    func start() {
        guard !isStopping else { return }
        logger.info("Starting SparkBar")
        do {
            try launchAtLoginService.apply(desired: settings.launchAtLogin)
        } catch {
            lastError = "Launch at login could not be configured: \(error.localizedDescription)"
        }
        guard let raw = usableEndpointString,
              let endpoint = try? SparkDashEndpoint(raw) else {
            logger.info("No endpoint configured yet; waiting for input from the connection view")
            return
        }
        connect(to: endpoint)
    }

    func stop() {
        isStopping = true
        eventTask?.cancel()
        stopPollingFallback()
        stopHistorySampling()
        eventTask = nil
        if let client {
            Task { await client.shutdown() }
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
        stopPollingFallback()
        if let oldClient = client {
            Task { await oldClient.shutdown() }
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
            // A different sparkDash describes different machines, so the
            // accumulated chart no longer applies to anything.
            history = HistoryStore(maxSamples: 900)
            fleetMerger.reset()
        }
        lastError = nil
        startHistorySampling()

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
            recordSuccessfulEndpoint()
            logger.info("REST connection succeeded with \(result.sparkCount) Spark(s)")
        case .snapshot(let envelope):
            connectionState = .connected
            recordSuccessfulEndpoint()
            logger.info("Received snapshot with \(envelope.sparks.count) Spark(s)")
            applySnapshot(envelope)
        case .diagnostic(let message):
            lastDiagnostic = message
            logger.error("Transport diagnostic: \(message, privacy: .public)")
        }
    }

    func setSelectedSpark(_ id: String?) {
        selectedSparkID = id
    }

    /// Selects a spark and asks the popover to open its detail page. Used by
    /// notification taps, where a bare selection change would leave the user
    /// on the overview.
    func focusSpark(_ id: String) {
        setSelectedSpark(id)
        focusedSparkID = id
    }

    func clearFocus() {
        focusedSparkID = nil
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
        // Stop the event consumer and the REST polling fallback too, not just
        // the WebSocket client: polling against a stopped client would keep
        // refreshing snapshots (and could fire alerts) while the Mac sleeps.
        eventTask?.cancel()
        eventTask = nil
        stopPollingFallback()
        stopHistorySampling()
        if let client {
            Task { await client.shutdown() }
        }
        client = nil
        connectionState = .disconnected
    }

    func wake() {
        guard let raw = usableEndpointString,
              let endpoint = try? SparkDashEndpoint(raw) else {
            return
        }
        connect(to: endpoint)
    }

    func startNetworkScan() {
        scanSession += 1
        let session = scanSession
        scanTask?.cancel()
        scanTask = nil
        discoveryPhase = .scanning
        discoveryHits = []
        discoveryError = nil
        logger.info("Starting sparkDash scan lan=\(self.settings.scanLAN) bonjour=\(self.settings.scanBonjour) tailscale=\(self.settings.scanTailscaleLocalAPI)")
        let options = SparkDashScanOptions(
            probeLAN: settings.scanLAN,
            bonjour: settings.scanBonjour,
            tailscaleLocalAPI: settings.scanTailscaleLocalAPI
        )
        scanTask = Task { [scanner, options] in
            await scanner.cancel()
            guard session == scanSession else { return }
            let result = await scanner.scan(options)
            await MainActor.run {
                guard session == scanSession else { return }
                switch result {
                case .success(let hits):
                    discoveryPhase = .completed
                    discoveryHits = hits
                case .failure(let error):
                    if error as? SparkDashDiscoveryError == .cancelled {
                        discoveryPhase = .idle
                    } else {
                        discoveryPhase = .failed
                        discoveryError = error.localizedDescription
                    }
                }
                scanTask = nil
            }
        }
    }

    func stopNetworkScan() {
        scanSession += 1
        scanTask?.cancel()
        scanTask = nil
        if discoveryPhase == .scanning {
            discoveryPhase = .idle
        }
        Task { await scanner.cancel() }
    }

    func connectToDiscoveryHit(_ hit: SparkDashDiscoveryHit) {
        stopNetworkScan()
        settings.endpoint = hit.displayURL
        connectFromSettings()
    }

    func fillEndpointFromLastSuccessIfEmpty() {
        let draft = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.isEmpty,
              let last = settings.lastSuccessfulEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !last.isEmpty else {
            return
        }
        settings.endpoint = last
    }

    func openConnectionScan() {
        connectionSetupMode = .scan
        startNetworkScan()
    }

    func openSparkDash() {
        guard let raw = usableEndpointString ?? settings.endpoint.nilIfEmpty,
              let endpoint = try? SparkDashEndpoint(raw) else { return }
        NSWorkspace.shared.open(endpoint.apiBaseURL)
    }

    func openSparkDashRepository() {
        guard let url = ProjectLinks.sparkDashRepository else { return }
        NSWorkspace.shared.open(url)
    }

    func openSparkBarRepository() {
        guard let url = ProjectLinks.sparkBarRepository else { return }
        NSWorkspace.shared.open(url)
    }

    func sampleHistory() {
        guard !snapshots.isEmpty else { return }
        history.sample(snapshots)
    }

    private func startHistorySampling() {
        guard historyTask == nil else { return }
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.historySampleInterval)
                } catch {
                    return
                }
                guard let self else { return }
                // Do not extend a chart with values that are not being
                // refreshed any more.
                guard self.isReceivingData else { continue }
                self.sampleHistory()
            }
        }
    }

    private func stopHistorySampling() {
        historyTask?.cancel()
        historyTask = nil
    }

    /// Shared path for WebSocket frames and REST polling results so alerts,
    /// selection, history, and freshness behave identically on both paths.
    func applySnapshot(_ envelope: SnapshotEnvelope) {
        // Merge rather than replace: a snapshot that omits a Spark (the REST
        // fallback skips failed metrics requests, and a frame can drop entries
        // that did not decode) must not delete it from the dashboard.
        let merged = fleetMerger.merge(known: snapshots, incoming: envelope.sparks)
        if snapshots != merged {
            snapshots = merged
        }
        lastSnapshotAt = .now
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
            Task { @MainActor in
                if let failure = await notificationService.deliver(events) {
                    lastError = failure
                }
            }
        }
    }

    /// REST polling fallback for when the WebSocket is blocked but the API is
    /// reachable. Runs across the client's reconnect cycles and stops as soon
    /// as a real WebSocket connection delivers data.
    private func startPollingFallback() {
        guard pollTask == nil, let client else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self, client] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = self.configuredSparks.map(\.id)
                if !ids.isEmpty,
                   let envelope = try? await client.pollSnapshot(sparkIDs: ids),
                   !envelope.sparks.isEmpty {
                    guard !Task.isCancelled, self.connectionState != .connected else {
                        self.finishPollingFallback(generation: generation)
                        return
                    }
                    self.applySnapshot(envelope)
                }
                // The interval is server-supplied, so it is clamped: an
                // enormous value used to overflow the nanosecond conversion.
                let interval = self.serverSettings?.boundedPollInterval
                    ?? .milliseconds(SparkDashSettings.defaultPollIntervalMs)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Clears the handle only if this loop still owns it. A cancelled loop can
    /// resume after a newer one was installed, and clearing that newer handle
    /// would leave it running with no way to cancel it.
    private func finishPollingFallback(generation: Int) {
        guard pollGeneration == generation else { return }
        pollTask = nil
    }

    private func stopPollingFallback() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "com.sparkbar.settings.v1"

    var endpoint: String
    var lastSuccessfulEndpoint: String?
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
    var scanLAN: Bool
    var scanBonjour: Bool
    var scanTailscaleLocalAPI: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PersistedSettings.self, from: $0) }
        endpoint = saved?.endpoint ?? ""
        lastSuccessfulEndpoint = saved?.lastSuccessfulEndpoint
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
        scanLAN = saved?.scanLAN ?? true
        scanBonjour = saved?.scanBonjour ?? false
        scanTailscaleLocalAPI = saved?.scanTailscaleLocalAPI ?? false
    }

    var alertThresholds: AlertThresholds {
        AlertThresholds(temperatureCelsius: temperatureThreshold, memoryPercentage: memoryThreshold, clearMargin: 5)
    }

    func persist() {
        let value = PersistedSettings(
            endpoint: endpoint,
            lastSuccessfulEndpoint: lastSuccessfulEndpoint,
            displayMetric: displayMetric,
            sourceMode: sourceMode,
            selectedSparkID: selectedSparkID,
            temperatureUnit: temperatureUnit,
            launchAtLogin: launchAtLogin,
            startHidden: startHidden,
            showNotifications: showNotifications,
            temperatureThreshold: temperatureThreshold,
            memoryThreshold: memoryThreshold,
            alertCooldownMinutes: alertCooldownMinutes,
            scanLAN: scanLAN,
            scanBonjour: scanBonjour,
            scanTailscaleLocalAPI: scanTailscaleLocalAPI
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private struct PersistedSettings: Codable {
        let endpoint: String
        let lastSuccessfulEndpoint: String?
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
        var scanLAN: Bool?
        var scanBonjour: Bool?
        var scanTailscaleLocalAPI: Bool?
    }
}
