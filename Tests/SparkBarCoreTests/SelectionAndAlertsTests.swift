import Foundation
import Testing
import SparkBarCore

@Suite("Selection, warnings, and alerts")
struct SelectionAndAlertsTests {
    @Test func autoPrioritizesAlertBeforeGPUAndLLM() {
        let busy = makeSnapshot(id: "busy", name: "Busy", gpu: 95, temperature: 60, memory: 50, llm: 100)
        let alert = makeSnapshot(id: "alert", name: "Alert", gpu: 10, temperature: 90, memory: 95, llm: 1)
        let selected = SparkSelector.auto(snapshots: [busy, alert], selectedID: "busy")
        #expect(selected?.id == "alert")
    }

    @Test func autoUsesGPUThenLLMThenSelectedFallback() {
        let first = makeSnapshot(id: "first", name: "First", gpu: 0, llm: 0)
        let second = makeSnapshot(id: "second", name: "Second", gpu: 0, llm: 4)
        #expect(SparkSelector.auto(snapshots: [first, second], selectedID: "first")?.id == "second")

        let idle = makeSnapshot(id: "idle", name: "Idle", gpu: 0, llm: 0)
        #expect(SparkSelector.auto(snapshots: [idle, first], selectedID: "first")?.id == "first")
    }

    @Test func offlineSparkIsNeverSelectedByAuto() {
        let offline = makeSnapshot(id: "offline", name: "Offline", online: false, gpu: 100)
        let online = makeSnapshot(id: "online", name: "Online", gpu: 1)
        #expect(SparkSelector.auto(snapshots: [offline, online], selectedID: "offline")?.id == "online")
    }

    @Test func menuBarDistinguishesDisconnectedAndOffline() {
        let disconnected = MenuBarPresenter.make(
            snapshots: [], connectionState: .disconnected, metric: .gpuUtilization, sourceMode: .auto, selectedID: nil
        )
        #expect(disconnected.severity == .disconnected)
        #expect(disconnected.title == "—")

        let offline = MenuBarPresenter.make(
            snapshots: [makeSnapshot(id: "offline", name: "Offline", online: false, gpu: 100)],
            connectionState: .connected, metric: .gpuUtilization, sourceMode: .selected, selectedID: "offline"
        )
        #expect(offline.severity == .offline)
        #expect(offline.title == "—")
    }

    @Test func alertEngineUsesCooldown() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85), cooldown: 60)
        let hot = makeSnapshot(id: "hot", name: "Hot", gpu: 50, temperature: 85)
        let start = Date(timeIntervalSince1970: 100)
        #expect(engine.evaluate(snapshots: [hot], at: start).count == 1)
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(30)).isEmpty)
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(61)).count == 1)
    }

    @Test func alertEngineRetainsTemperatureWarningUntilClearHysteresis() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85, temperatureClearCelsius: 80), cooldown: 60)
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 90)
        let warm = makeSnapshot(id: "hot", name: "Hot", temperature: 82)
        let cool = makeSnapshot(id: "hot", name: "Hot", temperature: 79)
        let start = Date(timeIntervalSince1970: 100)
        #expect(engine.evaluate(snapshots: [hot], at: start).count == 1)
        #expect(engine.evaluate(snapshots: [warm], at: start.addingTimeInterval(1)).isEmpty)
        #expect(engine.evaluate(snapshots: [cool], at: start.addingTimeInterval(2)).isEmpty)
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(3)).count == 1)
    }

    @Test func reconnectScheduleHasExpectedCap() {
        let policy = ReconnectBackoff()
        #expect(policy.delay(attempt: 0, jitter: 0) == 1)
        #expect(policy.delay(attempt: 1, jitter: 0) == 2)
        #expect(policy.delay(attempt: 4, jitter: 0) == 15)
        #expect(policy.delay(attempt: 20, jitter: 0) == 30)
        #expect(policy.delay(attempt: 5, jitter: 1) <= 30)
    }
}
