import Testing
import SparkBarCore

@Suite("Fleet snapshot merging")
struct FleetMergeTests {
    @Test func keepsSparksThatAreMissingFromASingleSnapshot() {
        var merger = FleetSnapshotMerger(missTolerance: 3)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)
        let three = makeSnapshot(id: "three", name: "Three", gpu: 30)

        let merged = merger.merge(known: [one, two, three], incoming: [one, three])
        // The missing Spark is retained in its original position.
        #expect(merged.map(\.id) == ["one", "two", "three"])
    }

    @Test func replacesRetainedSparksWithFreshData() {
        var merger = FleetSnapshotMerger(missTolerance: 3)
        let stale = makeSnapshot(id: "one", name: "One", gpu: 10)
        let fresh = makeSnapshot(id: "one", name: "One", gpu: 90)
        let merged = merger.merge(known: [stale], incoming: [fresh])
        #expect(merged.count == 1)
        #expect(merged.first?.gpuUsage == 90)
    }

    @Test func dropsSparksAfterTheMissTolerance() {
        var merger = FleetSnapshotMerger(missTolerance: 2)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)

        #expect(merger.merge(known: [one, two], incoming: [two]).count == 2)
        #expect(merger.merge(known: [one, two], incoming: [two]).count == 2)
        // Third consecutive miss exceeds the tolerance.
        #expect(merger.merge(known: [one, two], incoming: [two]).map(\.id) == ["two"])
    }

    @Test func reappearanceResetsMissAccounting() {
        var merger = FleetSnapshotMerger(missTolerance: 2)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)

        _ = merger.merge(known: [one, two], incoming: [two])
        _ = merger.merge(known: [one, two], incoming: [one, two])
        // The counter restarted, so one further miss is still tolerated.
        #expect(merger.merge(known: [one, two], incoming: [two]).count == 2)
        #expect(merger.merge(known: [one, two], incoming: [two]).count == 2)
    }

    @Test func appendsNewlyReportedSparksOnce() {
        var merger = FleetSnapshotMerger(missTolerance: 3)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)
        let duplicate = makeSnapshot(id: "two", name: "Two", gpu: 20)

        let merged = merger.merge(known: [one], incoming: [two, duplicate])
        #expect(merged.map(\.id) == ["one", "two"])
    }

    @Test func keepsTheLastKnownFleetWhenNothingIsReadable() {
        var merger = FleetSnapshotMerger(missTolerance: 3)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        // A frame that decoded to no Sparks must not empty the fleet, because
        // the popover, section picker, and alerts all read from it.
        #expect(merger.merge(known: [one], incoming: []).map(\.id) == ["one"])
    }

    @Test func resetForgetsMissAccounting() {
        var merger = FleetSnapshotMerger(missTolerance: 1)
        let one = makeSnapshot(id: "one", name: "One", gpu: 10)
        let two = makeSnapshot(id: "two", name: "Two", gpu: 20)
        #expect(merger.merge(known: [one, two], incoming: [two]).count == 2)
        #expect(merger.merge(known: [one, two], incoming: [two]).count == 1)
        // After a reset the miss counter restarts, so the Spark is kept again.
        merger.reset()
        #expect(merger.merge(known: [one, two], incoming: [two]).count == 2)
    }
}
