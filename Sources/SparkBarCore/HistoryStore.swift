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
    /// How many consecutive snapshots may omit a Spark before its series is
    /// discarded. A single dropped poll must not erase a chart: the REST
    /// fallback skips Sparks whose metrics request fails, so absence in one
    /// snapshot is not evidence that the Spark left the fleet.
    public let maxConsecutiveMisses: Int
    private(set) public var samplesBySparkID: [String: [MetricHistoryPoint]] = [:]
    private var missesBySparkID: [String: Int] = [:]

    public init(maxSamples: Int = 900, maxConsecutiveMisses: Int = 15) {
        self.maxSamples = max(1, maxSamples)
        self.maxConsecutiveMisses = max(1, maxConsecutiveMisses)
    }

    public mutating func sample(_ snapshots: [SparkSnapshot], at date: Date = .now) {
        // Drop series for Sparks that have been absent for several consecutive
        // snapshots so a long-lived process does not accumulate stale buffers.
        let seenIDs = Set(snapshots.map(\.id))
        for staleID in Array(samplesBySparkID.keys) where !seenIDs.contains(staleID) {
            let misses = (missesBySparkID[staleID] ?? 0) + 1
            if misses >= maxConsecutiveMisses {
                samplesBySparkID.removeValue(forKey: staleID)
                missesBySparkID.removeValue(forKey: staleID)
            } else {
                missesBySparkID[staleID] = misses
            }
        }
        for snapshot in snapshots {
            missesBySparkID.removeValue(forKey: snapshot.id)
            let point = MetricHistoryPoint(
                date: date,
                gpuUsage: snapshot.metrics?.gpu?.usage,
                temperature: snapshot.metrics?.gpu?.temperature,
                power: snapshot.metrics?.gpu?.power?.draw,
                memoryPercentage: snapshot.memoryPressurePercentage,
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
