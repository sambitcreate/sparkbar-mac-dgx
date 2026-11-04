import Foundation
import SparkBarCore

/// A worker selection must never replace the fleet's model heading with a node name.
struct FleetModelHeading: Equatable {
    let name: String
    let backend: String?
    let isCurrent: Bool

    static func resolve(_ snapshots: [SparkSnapshot]) -> FleetModelHeading? {
        let candidates = snapshots.filter { $0.role != "worker" && $0.workerNode != true }
            .flatMap { spark in
                (spark.metrics?.llm ?? []).compactMap { llm -> (SparkSnapshot, LLMMetrics, String)? in
                    guard let name = llm.modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else { return nil }
                    return (spark, llm, name)
                }
            }
        // Prefer an available online head; retain a known name on interruption.
        let ranked = candidates.sorted { lhs, rhs in
            func rank(_ candidate: (SparkSnapshot, LLMMetrics, String)) -> Int {
                (candidate.0.isOnline && candidate.1.available != false ? 0 : 2)
                    + (candidate.0.role == "head" ? 0 : 1)
            }
            let a = rank(lhs), b = rank(rhs)
            return a == b ? lhs.0.id + lhs.2 < rhs.0.id + rhs.2 : a < b
        }
        guard let (spark, llm, name) = ranked.first else { return nil }
        return FleetModelHeading(name: name, backend: llm.backend,
                                 isCurrent: spark.isOnline && llm.available != false)
    }

    var displayName: String { name.replacingOccurrences(of: "-", with: " ") }
}
