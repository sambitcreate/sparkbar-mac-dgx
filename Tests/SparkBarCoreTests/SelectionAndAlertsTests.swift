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

        // PRD 8: an unreachable sparkDash must not be representable as an
        // offline Spark, so the two states cannot share a glyph.
        #expect(disconnected.iconName != offline.iconName)
        #expect(disconnected.iconName == "bolt.horizontal.circle")
    }

    @Test func menuBarKeepsDisconnectedGlyphAfterLosingConnection() {
        let online = makeSnapshot(id: "one", name: "One", gpu: 42)
        for state in [ConnectionState.failed("boom"), .disconnected] {
            let presentation = MenuBarPresenter.make(
                snapshots: [online], connectionState: state, metric: .gpuUtilization,
                sourceMode: .auto, selectedID: "one"
            )
            #expect(presentation.severity == .disconnected)
            #expect(presentation.iconName == "bolt.horizontal.circle")
            #expect(presentation.isDimmed)
        }
        let reconnecting = MenuBarPresenter.make(
            snapshots: [online], connectionState: .reconnecting(attempt: 2), metric: .gpuUtilization,
            sourceMode: .auto, selectedID: "one"
        )
        #expect(reconnecting.severity == .connecting)
        #expect(reconnecting.iconName == "bolt.badge.clock")
    }

    /// Silently falling back to `snapshots.first` reported a different machine's
    /// metrics under the user's explicit Spark selection.
    @Test func selectedModeDoesNotSubstituteAnotherSpark() {
        let other = makeSnapshot(id: "other", name: "Other", gpu: 99)
        let presentation = MenuBarPresenter.make(
            snapshots: [other], connectionState: .connected, metric: .gpuUtilization,
            sourceMode: .selected, selectedID: "chosen"
        )
        #expect(presentation.title == "—")
        #expect(presentation.title != "99%")
        #expect(presentation.accessibilityLabel == "Selected Spark is not reporting")
        #expect(presentation.sourceSparkID == "chosen")
    }

    @Test func selectedModeWithNoChoiceUsesTheFirstSpark() {
        let first = makeSnapshot(id: "first", name: "First", gpu: 42)
        let second = makeSnapshot(id: "second", name: "Second", gpu: 99)
        let presentation = MenuBarPresenter.make(
            snapshots: [first, second], connectionState: .connected, metric: .gpuUtilization,
            sourceMode: .selected, selectedID: nil
        )
        #expect(presentation.title == "42%")
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

    /// The REST fallback skips Sparks whose metrics request fails, so a Spark
    /// can be absent from one snapshot while still alerting. Treating absence
    /// as recovery cleared the latch and the cooldown, and the next snapshot
    /// re-notified immediately.
    @Test func alertEngineDoesNotRearmCooldownWhenASparkIsBrieflyMissing() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85), cooldown: 900)
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 90)
        let start = Date(timeIntervalSince1970: 1_000_000)

        #expect(engine.evaluate(snapshots: [hot], at: start).count == 1)
        // Spark missing for one round: nothing fires and nothing is forgotten.
        #expect(engine.evaluate(snapshots: [], at: start.addingTimeInterval(2)).isEmpty)
        // Still inside the 900s cooldown, so it must stay silent.
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(4)).isEmpty)
        // Past the cooldown it fires again, which is correct.
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(901)).count == 1)
    }

    @Test func alertEngineForgetsLatchesAfterProlongedAbsence() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85), cooldown: 900, maxMissedRounds: 2)
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 90)
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(engine.evaluate(snapshots: [hot], at: start).count == 1)
        #expect(engine.evaluate(snapshots: [], at: start.addingTimeInterval(2)).isEmpty)
        #expect(engine.evaluate(snapshots: [], at: start.addingTimeInterval(4)).isEmpty)
        // The latch and cooldown are gone, so the alert is treated as new.
        #expect(engine.evaluate(snapshots: [hot], at: start.addingTimeInterval(6)).count == 1)
    }

    /// Hysteresis re-added a temperature reason for a Spark the engine had just
    /// reported offline, so an offline machine kept re-notifying a stale reading.
    @Test func alertEngineDoesNotReraiseTemperatureForAnOfflineSpark() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85), cooldown: 900)
        let hot = makeSnapshot(id: "hot", name: "Hot", temperature: 95)
        let offlineWithStaleReading = makeSnapshot(id: "hot", name: "Hot", online: false, temperature: 82)
        let start = Date(timeIntervalSince1970: 1_000_000)

        #expect(engine.evaluate(snapshots: [hot], at: start).map(\.reason) == [.highTemperature])
        #expect(engine.evaluate(snapshots: [offlineWithStaleReading], at: start.addingTimeInterval(2)).map(\.reason) == [.offline])
        // The offline alert repeats once the cooldown elapses, but the stale 82C
        // reading must never resurface as a temperature alert alongside it.
        for offset in [910.0, 1_820.0] {
            let events = engine.evaluate(snapshots: [offlineWithStaleReading], at: start.addingTimeInterval(offset))
            #expect(events.map(\.reason) == [.offline])
            #expect(events.contains { $0.reason == .highTemperature } == false)
        }
    }

    @Test func alertEngineKeepsIndependentCooldownsPerSpark() {
        var engine = AlertEngine(thresholds: AlertThresholds(temperatureCelsius: 85), cooldown: 60)
        let first = makeSnapshot(id: "first", name: "First", temperature: 90)
        let second = makeSnapshot(id: "second", name: "Second", temperature: 90)
        let start = Date(timeIntervalSince1970: 100)
        #expect(engine.evaluate(snapshots: [first], at: start).map(\.sparkID) == ["first"])
        // A different Spark alerting later still notifies.
        #expect(engine.evaluate(snapshots: [first, second], at: start.addingTimeInterval(1)).map(\.sparkID) == ["second"])
        #expect(engine.evaluate(snapshots: [first, second], at: start.addingTimeInterval(30)).isEmpty)
        #expect(engine.evaluate(snapshots: [first, second], at: start.addingTimeInterval(62)).map(\.sparkID) == ["first", "second"])
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
