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

    @Test func prunesSamplesForSparksThatLeaveTheFleet() {
        var history = HistoryStore(maxSamples: 10)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)
        history.sample([one, two], at: Date(timeIntervalSince1970: 1))
        #expect(history.samples(for: "one").count == 1)
        #expect(history.samples(for: "two").count == 1)
        history.sample([two], at: Date(timeIntervalSince1970: 2))
        #expect(history.samples(for: "one").isEmpty)
        #expect(history.samples(for: "two").count == 2)
    }
}
