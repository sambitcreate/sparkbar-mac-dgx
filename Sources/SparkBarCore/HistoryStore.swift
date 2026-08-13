import Foundation

public struct MetricHistoryPoint: Equatable, Identifiable, Sendable {
    public let date: Date
    public let gpuUsage: Double?
    public let temperature: Double?
    public let power: Double?
    public let memoryPercentage: Double?
    public let llmTokensPerSecond: Double?

    public init(
        date: Date,
        gpuUsage: Double?,
        temperature: Double?,
        power: Double?,
        memoryPercentage: Double?,
        llmTokensPerSecond: Double?
    ) {
        self.date = date
        self.gpuUsage = gpuUsage
        self.temperature = temperature
        self.power = power
        self.memoryPercentage = memoryPercentage
        self.llmTokensPerSecond = llmTokensPerSecond
    }

    /// Points within a spark's series are timestamp-unique (duplicate
    /// timestamps replace the previous sample).
    public var id: Date { date }
}

public struct HistoryStore: Equatable, Sendable {
    public let maxSamples: Int
    private(set) public var samplesBySparkID: [String: [MetricHistoryPoint]] = [:]

    public init(maxSamples: Int = 900) {
        self.maxSamples = max(1, maxSamples)
    }

    public mutating func sample(_ snapshots: [SparkSnapshot], at date: Date = .now) {
        // Drop series for sparks that left the fleet so a long-lived process
        // does not accumulate stale per-spark buffers.
        let seenIDs = Set(snapshots.map(\.id))
        for staleID in samplesBySparkID.keys.filter({ !seenIDs.contains($0) }) {
            samplesBySparkID.removeValue(forKey: staleID)
        }
        for snapshot in snapshots {
            let point = MetricHistoryPoint(
                date: date,
                gpuUsage: snapshot.metrics?.gpu?.usage,
                temperature: snapshot.metrics?.gpu?.temperature,
                power: snapshot.metrics?.gpu?.power?.draw,
                memoryPercentage: snapshot.metrics?.unifiedMemory?.percentage,
                llmTokensPerSecond: snapshot.primaryLLM?.generationTps
            )
            var samples = samplesBySparkID[snapshot.id, default: []]
            if samples.last?.date == date {
                samples[samples.index(before: samples.endIndex)] = point
            } else {
                samples.append(point)
            }
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
            samplesBySparkID[snapshot.id] = samples
        }
    }

    public func samples(for sparkID: String) -> [MetricHistoryPoint] {
        samplesBySparkID[sparkID] ?? []
    }
}
