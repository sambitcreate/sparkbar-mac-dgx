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

    @Test func alertBodyUsesRequestedTemperatureUnit() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85), cooldown: 60)
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 90)
        let events = engine.evaluate(
            snapshots: [hot],
            at: Date(timeIntervalSince1970: 100),
            temperatureUnit: .fahrenheit
        )
        #expect(events.count == 1)
        #expect(events.first?.body == "Hot reached 194°F.")
    }

    @Test func autoSelectionRespectsCustomThresholds() {
        let hot = makeSnapshot(id: "hot", name: "Hot", gpu: 10, temperature: 90)
        let busy = makeSnapshot(id: "busy", name: "Busy", gpu: 95, temperature: 60)
        // Default thresholds flag the hot spark as alerting.
        #expect(SparkSelector.auto(snapshots: [busy, hot], selectedID: nil)?.id == "hot")
        // With a raised threshold it is no longer alerting; GPU wins.
        let custom = AlertThresholds(temperatureCelsius: 95)
        #expect(SparkSelector.auto(snapshots: [busy, hot], selectedID: nil, thresholds: custom)?.id == "busy")
    }

    @Test func presenterShowsDataWhileRESTPollingFallbackIsActive() {
        let online = makeSnapshot(id: "one", name: "One", gpu: 42)
        let presentation = MenuBarPresenter.make(
            snapshots: [online],
            connectionState: .apiReachableLiveStreamUnavailable,
            metric: .gpuUtilization,
            sourceMode: .auto,
            selectedID: "one"
        )
        #expect(presentation.title == "42%")
        #expect(presentation.severity == .normal)
    }

    @Test func presenterAggregatesAcrossOnlineSparks() {
        let first = makeSnapshot(id: "one", name: "One", gpu: 42)
        let second = makeSnapshot(id: "two", name: "Two", gpu: 78)
        let presentation = MenuBarPresenter.make(
            snapshots: [first, second],
            connectionState: .connected,
            metric: .gpuUtilization,
            sourceMode: .aggregate,
            selectedID: nil
        )
        #expect(presentation.title == "78%")
        #expect(presentation.iconName == "bolt.fill")
        #expect(presentation.severity == .normal)
    }

    @Test func presenterFlagsAlertingSparkWithWarningIcon() {
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 90)
        let presentation = MenuBarPresenter.make(
            snapshots: [hot],
            connectionState: .connected,
            metric: .gpuUtilization,
            sourceMode: .auto,
            selectedID: nil
        )
        #expect(presentation.iconName == "bolt.triangle.fill")
        #expect(presentation.severity == .warning)
    }

    @Test func presenterShowsConnectingIconWhileReconnecting() {
        let presentation = MenuBarPresenter.make(
            snapshots: [],
            connectionState: .reconnecting(attempt: 3),
            metric: .gpuUtilization,
            sourceMode: .auto,
            selectedID: nil
        )
        #expect(presentation.iconName == "bolt.badge.clock")
        #expect(presentation.isDimmed)
    }

    @Test func derivedClearThresholdsKeepHysteresisBelowCustomTriggers() {
        // A trigger below the default clear point (80) would silently disable
        // hysteresis; the margin-based initializer derives a working band.
        let thresholds = AlertThresholds(temperatureCelsius: 70, memoryPercentage: 60, clearMargin: 5)
        #expect(thresholds.temperatureClearCelsius == 65)
        #expect(thresholds.memoryClearPercentage == 55)

        var engine = AlertEngine(thresholds: thresholds, cooldown: 60)
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 71, memory: 61)
        let warm = makeSnapshot(id: "hot", name: "Hot", temperature: 66, memory: 56)
        let cool = makeSnapshot(id: "hot", name: "Hot", temperature: 64, memory: 54)
        let start = Date(timeIntervalSince1970: 100)
        #expect(engine.evaluate(snapshots: [hot], at: start).count == 2)
        // Inside the derived band the alerts stay latched without refiring.
        #expect(engine.evaluate(snapshots: [warm], at: start.addingTimeInterval(1)).isEmpty)
        // Below the band they clear, and a new spike refires.
        #expect(engine.evaluate(snapshots: [cool], at: start.addingTimeInterval(2)).isEmpty)
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(3)).count == 2)
    }

    @Test func hostHighVRAMAlertsWithoutUnifiedMemoryOOM() {
        let host = makeSnapshot(id: "box", name: "Studio", kind: "host", memory: 99, vram: 90)
        #expect(host.memoryPercentage == 90)
        #expect(host.alertReasons().contains(.highMemory))
        #expect(host.alertReasons().contains(.oomRisk) == false)

        var engine = AlertEngine(thresholds: AlertThresholds(memoryPercentage: 85), cooldown: 60)
        let events = engine.evaluate(snapshots: [host], at: Date(timeIntervalSince1970: 100))
        #expect(events.map(\.reason) == [.highMemory])
        #expect(events.first?.title == "High memory")
        #expect(events.first?.body == "Studio is using 90% VRAM.")
    }

    @Test func presenterUsesHostVRAMForMemoryMetrics() {
        let host = makeSnapshot(id: "box", name: "Studio", kind: "host", vram: 75)
        let used = MenuBarPresenter.make(
            snapshots: [host],
            connectionState: .connected,
            metric: .unifiedMemory,
            sourceMode: .auto,
            selectedID: "box"
        )
        #expect(used.title == MetricFormatter.memoryGigabytesShort(7_500))
        let percent = MenuBarPresenter.make(
            snapshots: [host],
            connectionState: .connected,
            metric: .memoryPercentage,
            sourceMode: .auto,
            selectedID: "box"
        )
        #expect(percent.title == "75%")
    }
}
