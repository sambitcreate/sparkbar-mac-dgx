import Foundation
import SparkBarCore
import Testing
@testable import SparkBar

@Suite("SparkBar app connection lifecycle")
@MainActor
struct AppModelTests {
    private func fixture() -> (UserDefaults, URL, String) {
        let suiteName = "SparkBarAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkBarAppTests-\(UUID().uuidString)", isDirectory: true)
        return (defaults, historyDirectory, suiteName)
    }

    private func cleanUp(_ defaults: UserDefaults, _ historyDirectory: URL, _ suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyDirectory)
    }

    @Test("First launch waits for a URL")
    func firstLaunch() {
        let (defaults, directory, suiteName) = fixture()
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
        let (defaults, directory, suiteName) = fixture()
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
        let (defaults, directory, suiteName) = fixture()
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
    func scanCancellation() async {
        let (defaults, directory, suiteName) = fixture()
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
        let (defaults, directory, suiteName) = fixture()
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
        let (defaults, directory, suiteName) = fixture()
        defer { cleanUp(defaults, directory, suiteName) }
        let model = AppModel(defaults: defaults, historyDirectory: directory, systemServicesEnabled: false)
        for rawURL in ["http://192.168.1.10:5555", "http://100.101.194.105:5555"] {
            model.connect(to: try SparkDashEndpoint(rawURL))
            #expect(model.pendingInsecureEndpoint == nil)
        }
        model.stop()
    }
}
