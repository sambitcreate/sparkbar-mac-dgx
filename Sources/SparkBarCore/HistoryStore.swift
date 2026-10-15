import Foundation

public struct MetricHistoryPoint: Codable, Equatable, Identifiable, Sendable {
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

public struct HistoryOutage: Codable, Equatable, Identifiable, Sendable {
    public let start: Date
    public var end: Date?

    public var id: Date { start }

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }
}

public struct HistoryStore: Codable, Equatable, Sendable {
    public let maxSamples: Int
    public let maxArchiveSamples: Int
    /// How many consecutive snapshots may omit a Spark before its series is
    /// discarded. A single dropped poll must not erase a chart: the REST
    /// fallback skips Sparks whose metrics request fails, so absence in one
    /// snapshot is not evidence that the Spark left the fleet.
    public let maxConsecutiveMisses: Int
    private(set) public var samplesBySparkID: [String: [MetricHistoryPoint]] = [:]
    private(set) public var archiveBySparkID: [String: [MetricHistoryPoint]] = [:]
    private(set) public var outages: [HistoryOutage] = []
    private var missesBySparkID: [String: Int] = [:]
    private var hasSeenConnection = false

    public init(maxSamples: Int = 900, maxConsecutiveMisses: Int = 15, maxArchiveSamples: Int = 10_080) {
        self.maxSamples = max(1, maxSamples)
        self.maxConsecutiveMisses = max(1, maxConsecutiveMisses)
        self.maxArchiveSamples = max(1, maxArchiveSamples)
    }

    public mutating func sample(_ snapshots: [SparkSnapshot], at date: Date = .now) {
        let archiveCutoff = date.addingTimeInterval(-7 * 24 * 60 * 60)
        for staleID in Array(archiveBySparkID.keys)
        where (archiveBySparkID[staleID]?.last?.date ?? .distantPast) < archiveCutoff {
            archiveBySparkID.removeValue(forKey: staleID)
        }
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

            // One point per minute preserves a week of trends without keeping
            // every two-second sample in memory or on disk.
            var archive = archiveBySparkID[snapshot.id, default: []]
            let minute = Int(date.timeIntervalSince1970 / 60)
            if let last = archive.last,
               Int(last.date.timeIntervalSince1970 / 60) == minute {
                archive[archive.index(before: archive.endIndex)] = point
            } else {
                archive.append(point)
            }
            if let oldest = archive.first, oldest.date < archiveCutoff {
                archive.removeAll { $0.date < archiveCutoff }
            }
            if archive.count > maxArchiveSamples {
                archive.removeFirst(archive.count - maxArchiveSamples)
            }
            archiveBySparkID[snapshot.id] = archive
        }
    }

    public func samples(for sparkID: String) -> [MetricHistoryPoint] {
        samplesBySparkID[sparkID] ?? []
    }

    public func archiveSamples(for sparkID: String) -> [MetricHistoryPoint] {
        archiveBySparkID[sparkID] ?? []
    }

    public mutating func recordConnectivity(isConnected: Bool, at date: Date = .now) {
        if isConnected {
            hasSeenConnection = true
            if let index = outages.indices.last, outages[index].end == nil {
                outages[index].end = date
            }
        } else if hasSeenConnection && (outages.isEmpty || outages.last?.end != nil) {
            outages.append(HistoryOutage(start: date))
            if outages.count > 256 {
                outages.removeFirst(outages.count - 256)
            }
        }
    }

    public static func load(from url: URL, maxSamples: Int = 900, at date: Date = .now) throws -> HistoryStore {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return HistoryStore(maxSamples: maxSamples)
        }
        var restored = try JSONDecoder().decode(HistoryStore.self, from: Data(contentsOf: url))
        let archiveCutoff = date.addingTimeInterval(-7 * 24 * 60 * 60)
        let archiveLimit = restored.maxArchiveSamples
        restored.archiveBySparkID = restored.archiveBySparkID.compactMapValues { points in
            let kept = points.filter { $0.date >= archiveCutoff }
            return kept.isEmpty ? nil : Array(kept.suffix(archiveLimit))
        }
        let recentCutoff = date.addingTimeInterval(-30 * 60)
        let recentLimit = restored.maxSamples
        restored.samplesBySparkID = restored.samplesBySparkID.compactMapValues { points in
            let kept = points.filter { $0.date >= recentCutoff }
            return kept.isEmpty ? nil : Array(kept.suffix(recentLimit))
        }
        return restored
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public func exportCSV(for sparkID: String) -> String {
        Self.exportCSV(recent: samples(for: sparkID), archive: archiveSamples(for: sparkID), outages: outages)
    }

    public static func exportCSV(
        recent: [MetricHistoryPoint] = [],
        archive: [MetricHistoryPoint],
        outages: [HistoryOutage]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["type,timestamp,end,gpu_usage,temperature,power,memory_percentage,llm_tokens_per_second"]
        let olderArchive = archive.filter { point in
            guard let earliestRecent = recent.first?.date else { return true }
            return point.date < earliestRecent
        }
        for point in olderArchive + recent {
            var values = ["metric", formatter.string(from: point.date), ""]
            values.append(point.gpuUsage.map { String($0) } ?? "")
            values.append(point.temperature.map { String($0) } ?? "")
            values.append(point.power.map { String($0) } ?? "")
            values.append(point.memoryPercentage.map { String($0) } ?? "")
            values.append(point.llmTokensPerSecond.map { String($0) } ?? "")
            lines.append(values.joined(separator: ","))
        }
        for outage in outages {
            var values = ["outage", formatter.string(from: outage.start)]
            values.append(outage.end.map { formatter.string(from: $0) } ?? "")
            values.append(contentsOf: ["", "", "", "", ""])
            lines.append(values.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
