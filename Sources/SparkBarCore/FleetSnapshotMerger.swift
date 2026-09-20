import Foundation

/// Merges a freshly received Spark list into the fleet SparkBar already knows.
///
/// The REST fallback deliberately skips Sparks whose metrics request fails, and
/// a WebSocket frame can decode fewer Sparks than the fleet really has.
/// Replacing the whole list on every frame would make a Spark disappear from the
/// overview, the section picker, and menu-bar auto-selection for that cycle, and
/// would discard its history. A Spark is therefore only treated as gone after it
/// has been missing from several consecutive snapshots.
public struct FleetSnapshotMerger: Equatable, Sendable {
    public let missTolerance: Int
    private var missedSnapshots: [String: Int] = [:]

    public init(missTolerance: Int = 5) {
        self.missTolerance = max(0, missTolerance)
    }

    /// Returns the fleet to display, keeping the previous ordering for Sparks
    /// that are still present and appending newly reported ones at the end.
    public mutating func merge(known: [SparkSnapshot], incoming: [SparkSnapshot]) -> [SparkSnapshot] {
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var merged: [SparkSnapshot] = []
        var nextMisses: [String: Int] = [:]

        for previous in known {
            if let fresh = incomingByID[previous.id] {
                merged.append(fresh)
                continue
            }
            let missed = (missedSnapshots[previous.id] ?? 0) + 1
            if missed <= missTolerance {
                merged.append(previous)
                nextMisses[previous.id] = missed
            }
        }

        let knownIDs = Set(known.map(\.id))
        var appendedIDs = Set<String>()
        for fresh in incoming where !knownIDs.contains(fresh.id) {
            guard appendedIDs.insert(fresh.id).inserted else { continue }
            merged.append(fresh)
        }

        missedSnapshots = nextMisses
        return merged
    }

    /// Forgets all miss accounting, e.g. after switching endpoints.
    public mutating func reset() {
        missedSnapshots.removeAll()
    }
}
