import Foundation
import Testing
import SparkBarCore

@Suite("Metric history")
struct HistoryTests {
    @Test func samplesLatestStateAndMaintainsRingBound() {
        var history = HistoryStore(maxSamples: 2)
        let snapshot = makeSnapshot(id: "one", name: "One", gpu: 10)
        let first = Date(timeIntervalSince1970: 1)
        history.sample([snapshot], at: first)
        history.sample([snapshot], at: first.addingTimeInterval(2))
        history.sample([snapshot], at: first.addingTimeInterval(4))
        #expect(history.samples(for: "one").count == 2)
        #expect(history.samples(for: "one").first?.date == first.addingTimeInterval(2))
    }

    @Test func repeatedSampleAtSameTimeReplacesPoint() {
        var history = HistoryStore(maxSamples: 10)
        history.sample([makeSnapshot(id: "one", name: "One", gpu: 10)], at: .init(timeIntervalSince1970: 1))
        history.sample([makeSnapshot(id: "one", name: "One", gpu: 20)], at: .init(timeIntervalSince1970: 1))
        #expect(history.samples(for: "one").count == 1)
        #expect(history.samples(for: "one").first?.gpuUsage == 20)
    }

    /// The REST fallback skips Sparks whose metrics request fails, so one
    /// snapshot can legitimately omit a Spark. Erasing the series on the first
    /// miss destroyed the chart for a Spark that was still being monitored.
    @Test func keepsSamplesWhileASparkIsBrieflyMissing() {
        var history = HistoryStore(maxSamples: 10, maxConsecutiveMisses: 3)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)
        let start = Date(timeIntervalSince1970: 1)
        history.sample([one, two], at: start)

        history.sample([two], at: start.addingTimeInterval(2))
        history.sample([two], at: start.addingTimeInterval(3))
        #expect(history.samples(for: "one").count == 1)
        #expect(history.samples(for: "two").count == 3)

        // Only after the tolerance is exhausted is the series discarded.
        history.sample([two], at: start.addingTimeInterval(4))
        #expect(history.samples(for: "one").isEmpty)
    }

    @Test func prunesSamplesForSparksThatLeaveTheFleet() {
        var history = HistoryStore(maxSamples: 10, maxConsecutiveMisses: 1)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)
        history.sample([one, two], at: Date(timeIntervalSince1970: 1))
        #expect(history.samples(for: "one").count == 1)
        #expect(history.samples(for: "two").count == 1)
        history.sample([two], at: Date(timeIntervalSince1970: 2))
        #expect(history.samples(for: "one").isEmpty)
        #expect(history.samples(for: "two").count == 2)
    }

    @Test func returnsSparkThatReappearsAfterABriefMiss() {
        var history = HistoryStore(maxSamples: 10, maxConsecutiveMisses: 3)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let start = Date(timeIntervalSince1970: 1)
        history.sample([one], at: start)
        history.sample([], at: start.addingTimeInterval(2))
        history.sample([one], at: start.addingTimeInterval(3))
        #expect(history.samples(for: "one").count == 2)
        // A reappearance resets the miss counter rather than continuing it.
        history.sample([], at: start.addingTimeInterval(4))
        history.sample([], at: start.addingTimeInterval(5))
        #expect(history.samples(for: "one").count == 2)
    }

    @Test func samplesHostVRAMPercentageInsteadOfUnifiedMemory() {
        var history = HistoryStore(maxSamples: 10)
        let host = makeSnapshot(id: "box", name: "Studio", kind: "host", memory: 11, vram: 75)
        history.sample([host], at: Date(timeIntervalSince1970: 1))
        #expect(history.samples(for: "box").first?.memoryPercentage == 75)
    }

    @Test func archivesOnePointPerMinuteAndKeepsRecentSamples() {
        var history = HistoryStore(maxSamples: 2, maxArchiveSamples: 3)
        let start = Date(timeIntervalSince1970: 60)
        for (offset, gpu) in [(0, 10.0), (2, 20.0), (60, 30.0), (120, 40.0), (180, 50.0)] {
            history.sample([makeSnapshot(id: "one", name: "One", gpu: gpu)],
                           at: start.addingTimeInterval(Double(offset)))
        }
        #expect(history.samples(for: "one").count == 2)
        #expect(history.archiveSamples(for: "one").map(\.gpuUsage) == [30, 40, 50])
        #expect(history.exportCSV(for: "one").components(separatedBy: "metric,").count - 1 == 3)
    }

    @Test func persistsHistoryAndOutageTimelineAcrossRelaunch() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let start = Date.now.addingTimeInterval(-60)
        var history = HistoryStore(maxSamples: 2)
        history.sample([makeSnapshot(id: "one", name: "One", gpu: 42)], at: start)
        history.recordConnectivity(isConnected: true, at: start)
        history.recordConnectivity(isConnected: false, at: start.addingTimeInterval(5))
        history.recordConnectivity(isConnected: false, at: start.addingTimeInterval(6))
        history.recordConnectivity(isConnected: true, at: start.addingTimeInterval(10))
        try history.save(to: file)

        let restored = try HistoryStore.load(from: file)
        #expect(restored == history)
        #expect(restored.archiveSamples(for: "one").count == 1)
        #expect(restored.outages == [HistoryOutage(start: start.addingTimeInterval(5),
                                                   end: start.addingTimeInterval(10))])
        #expect(restored.exportCSV(for: "one").contains("outage,"))
    }

    @Test func discardsExpiredHistoryWhenLoading() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var history = HistoryStore()
        history.sample([makeSnapshot(id: "one", name: "One", gpu: 10)],
                       at: Date.now.addingTimeInterval(-8 * 24 * 60 * 60))
        try history.save(to: file)

        let restored = try HistoryStore.load(from: file)
        #expect(restored.samples(for: "one").isEmpty)
        #expect(restored.archiveSamples(for: "one").isEmpty)
    }
}
