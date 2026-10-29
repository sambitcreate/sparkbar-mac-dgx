import Foundation
import SparkBarCore
import ServiceManagement
import Testing
@testable import SparkBar

@Suite("SparkBar app connection lifecycle")
@MainActor
struct AppModelTests {
    private func fixture() throws -> (UserDefaults, URL, String) {
        let suiteName = "SparkBarAppTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkBarAppTests-\(UUID().uuidString)", isDirectory: true)
        return (defaults, historyDirectory, suiteName)
    }

    private func cleanUp(_ defaults: UserDefaults, _ historyDirectory: URL, _ suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyDirectory)
    }

    @Test("First launch waits for a URL")
    func firstLaunch() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        model.start()
        #expect(model.settings.endpoint.isEmpty)
        #expect(model.connectionState == .disconnected)
        #expect(model.discoveryPhase == .idle)
        #expect(model.pendingInsecureEndpoint == nil)
        model.stop()
    }

    @Test("A successful localhost URL reconnects after relaunch", arguments: [
        "http://localhost:5555", "http://127.0.0.1:5555",
    ])
    func localhostPersists(url: String) throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let endpoint = try SparkDashEndpoint(url)
        let first = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        first.connect(to: endpoint)
        first.handle(.connectionTested(ConnectionTestResult(endpoint: endpoint, sparks: [])))
        #expect(first.settings.lastSuccessfulEndpoint == url)
        first.stop()

        let relaunched = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        #expect(relaunched.settings.endpoint == url)
        #expect(relaunched.settings.lastSuccessfulEndpoint == url)
        relaunched.start()
        #expect(relaunched.pendingInsecureEndpoint == nil)
        relaunched.stop()
    }

    @Test("Switching endpoints restores each endpoint's own history")
    func switchingEndpoints() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let first = try SparkDashEndpoint("http://127.0.0.1:5555")
        let second = try SparkDashEndpoint("http://127.0.0.1:5556")
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        model.connect(to: first)
        model.applySnapshot(SnapshotEnvelope(sparks: [SparkSnapshot(id: "dgx-a", name: "DGX A", online: true)]))
        model.sampleHistory()
        #expect(model.history.samples(for: "dgx-a").count == 1)

        model.connect(to: second)
        #expect(model.snapshots.isEmpty)
        #expect(model.history.samples(for: "dgx-a").isEmpty)
        model.connect(to: first)
        #expect(model.history.samples(for: "dgx-a").count == 1)
        model.stop()
    }

    @Test("Stopping a scan keeps a cancelled result from taking over the UI")
    func scanCancellation() async throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        model.settings.scanLAN = false
        model.settings.scanBonjour = false
        model.settings.scanTailscaleLocalAPI = false
        model.startNetworkScan()
        #expect(model.discoveryPhase == .scanning)
        model.stopNetworkScan()
        await Task.yield()
        #expect(model.discoveryPhase == .idle)
        #expect(model.discoveryHits.isEmpty)
        model.stop()
    }

    @Test("Public HTTP requires approval for the exact URL")
    func publicHTTPApproval() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let endpoint = try SparkDashEndpoint("http://example.com:5555")
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        model.connect(to: endpoint)
        #expect(model.pendingInsecureEndpoint == endpoint)
        #expect(model.connectionState == .disconnected)
        #expect(model.settings.approvedInsecureEndpoint == nil)
        model.cancelPendingInsecureConnection()
        #expect(model.pendingInsecureEndpoint == nil)

        model.connect(to: endpoint)
        model.confirmPendingInsecureConnection()
        #expect(model.pendingInsecureEndpoint == nil)
        #expect(model.settings.approvedInsecureEndpoint == endpoint.displayString)
        let relaunched = SettingsStore(defaults: defaults)
        #expect(relaunched.approvedInsecureEndpoint == endpoint.displayString)
        let differentServer = try SparkDashEndpoint("http://another.example.com:5555")
        model.connect(to: differentServer)
        #expect(model.pendingInsecureEndpoint == differentServer)
        model.stop()
    }

    @Test("Private and Tailscale HTTP URLs connect without a public-network prompt")
    func privateHTTP() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        for rawURL in ["http://192.168.1.10:5555", "http://100.101.194.105:5555"] {
            model.connect(to: try SparkDashEndpoint(rawURL))
            #expect(model.pendingInsecureEndpoint == nil)
        }
        model.stop()
    }

    @Test("Snapshots clear transport failures but preserve settings-action errors")
    func errorLifetimes() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        enum RegistrationError: Error { case rejected }
        var shouldFail = true
        let service = LaunchAtLoginService(status: { .notRegistered }, register: {
            if shouldFail { throw RegistrationError.rejected }
        }, unregister: {})
        let model = AppModel(defaults: defaults, historyDirectory: directory,
                             systemServicesEnabled: false, launchAtLoginService: service)
        defer { model.stop() }
        model.setLaunchAtLogin(true)
        let actionError = try #require(model.lastError)
        #expect(actionError.contains("Launch at login"))
        model.connect(to: try SparkDashEndpoint("http://127.0.0.1:5555"))
        model.handle(.state(.failed("Network unavailable")))
        model.handle(.snapshot(SnapshotEnvelope(sparks: [])))
        #expect(model.lastError == actionError)

        shouldFail = false
        model.setLaunchAtLogin(true)
        #expect(model.lastError == nil)
        model.handle(.state(.failed("Network unavailable")))
        #expect(model.lastError == "Network unavailable")
        model.applySnapshot(SnapshotEnvelope(sparks: []))
        #expect(model.lastError == nil)
    }

    @Test("Stopping flushes samples newer than an in-flight save")
    func stopFlushesLatestHistory() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        let endpoint = try SparkDashEndpoint("http://127.0.0.1:5555")
        model.connect(to: endpoint)
        let first = SparkSnapshot(id: "one", name: "One", online: true)
        model.applySnapshot(SnapshotEnvelope(sparks: [first]))
        model.sampleHistory()
        // Change the fleet before the first save's main-actor completion can
        // run, then force a flush. The final write must include both series.
        let second = SparkSnapshot(id: "two", name: "Two", online: true)
        model.applySnapshot(SnapshotEnvelope(sparks: [first, second]))
        model.sampleHistory()
        model.stop()

        let relaunched = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        relaunched.connect(to: endpoint)
        #expect(relaunched.history.samples(for: "one").isEmpty == false)
        #expect(relaunched.history.samples(for: "two").count == 1)
        relaunched.stop()
    }

    @Test("Start can be used again after stop")
    func restartAfterStop() throws {
        let (defaults, directory, suiteName) = try fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        model.stop()
        model.settings.endpoint = "http://example.com:5555"
        model.start()
        #expect(model.pendingInsecureEndpoint?.displayString == "http://example.com:5555")
        model.stop()
    }

}
