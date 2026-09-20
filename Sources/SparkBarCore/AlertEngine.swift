import Foundation

public struct AlertEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let sparkID: String
    public let sparkName: String
    public let reason: SparkAlertReason
    public let title: String
    public let body: String

    public init(sparkID: String, sparkName: String, reason: SparkAlertReason, body: String) {
        self.id = "\(sparkID)-\(reason.rawValue)"
        self.sparkID = sparkID
        self.sparkName = sparkName
        self.reason = reason
        self.title = reason.title
        self.body = body
    }
}

/// Pure alert state machine. The app decides whether notifications are enabled;
/// this type only implements cooldown and hysteresis so it can be tested offline.
///
/// A Spark that is simply *missing* from a snapshot is treated as unknown, not
/// as recovered. The REST fallback deliberately skips Sparks whose metrics
/// request fails, so treating absence as recovery would clear the latch and the
/// cooldown and let one dropped poll re-notify — exactly the flapping the
/// hysteresis and cooldown exist to prevent.
public struct AlertEngine: Equatable, Sendable {
    public var thresholds: AlertThresholds
    public var cooldown: TimeInterval
    /// How many consecutive snapshots may omit a Spark before its latch and
    /// cooldown are forgotten. Bounds state for a fleet whose identifiers churn.
    public var maxMissedRounds: Int

    private var active: [String: Set<SparkAlertReason>] = [:]
    private var lastSent: [String: [SparkAlertReason: Date]] = [:]
    private var missedRounds: [String: Int] = [:]

    public init(
        thresholds: AlertThresholds = .init(),
        cooldown: TimeInterval = 900,
        maxMissedRounds: Int = 12
    ) {
        self.thresholds = thresholds
        self.cooldown = cooldown
        self.maxMissedRounds = max(1, maxMissedRounds)
    }

    public mutating func evaluate(
        snapshots: [SparkSnapshot],
        at date: Date = .now,
        temperatureUnit: TemperatureUnit = .celsius
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let reportedIDs = Set(snapshots.map(\.id))
        var nextActive: [String: Set<SparkAlertReason>] = [:]

        for snapshot in snapshots {
            var reasons = snapshot.alertReasons(thresholds: thresholds)
            // Hysteresis only applies to a Spark that is reporting. An offline
            // Spark must not resurface a temperature or memory alert from a
            // stale reading the server is still echoing back.
            if snapshot.isOnline {
                let latched = active[snapshot.id] ?? []
                if latched.contains(.highTemperature),
                   let temperature = snapshot.metrics?.gpu?.temperature,
                   temperature >= thresholds.temperatureClearCelsius,
                   temperature < thresholds.temperatureCelsius {
                    reasons.insert(.highTemperature)
                }
                if latched.contains(.highMemory),
                   snapshot.memoryPercentage >= thresholds.memoryClearPercentage,
                   snapshot.memoryPercentage < thresholds.memoryPercentage {
                    reasons.insert(.highMemory)
                }
            }
            nextActive[snapshot.id] = reasons

            for reason in reasons {
                let wasActive = active[snapshot.id]?.contains(reason) ?? false
                let cooldownElapsed = lastSent[snapshot.id]?[reason]
                    .map { date.timeIntervalSince($0) >= cooldown } ?? true
                guard !wasActive || cooldownElapsed else { continue }
                events.append(AlertEvent(
                    sparkID: snapshot.id,
                    sparkName: snapshot.name,
                    reason: reason,
                    body: body(for: reason, snapshot: snapshot, temperatureUnit: temperatureUnit)
                ))
                lastSent[snapshot.id, default: [:]][reason] = date
            }
            missedRounds.removeValue(forKey: snapshot.id)
        }

        // Retain the latch, cooldown, and miss counter of Sparks that were not
        // reported this round, up to `maxMissedRounds`.
        for (sparkID, reasons) in active where !reportedIDs.contains(sparkID) {
            let missed = (missedRounds[sparkID] ?? 0) + 1
            guard missed < maxMissedRounds else {
                missedRounds.removeValue(forKey: sparkID)
                continue
            }
            missedRounds[sparkID] = missed
            nextActive[sparkID] = reasons
        }

        active = nextActive
        lastSent = Self.prune(lastSent, keeping: nextActive)
        missedRounds = missedRounds.filter { nextActive[$0.key] != nil }
        return events.sorted { $0.id < $1.id }
    }

    /// Keeps a recorded send only while its reason is still latched, so a
    /// reason that clears can notify immediately the next time it occurs.
    private static func prune(
        _ lastSent: [String: [SparkAlertReason: Date]],
        keeping active: [String: Set<SparkAlertReason>]
    ) -> [String: [SparkAlertReason: Date]] {
        var result: [String: [SparkAlertReason: Date]] = [:]
        for (sparkID, reasons) in active {
            guard let sent = lastSent[sparkID] else { continue }
            let kept = sent.filter { reasons.contains($0.key) }
            if !kept.isEmpty { result[sparkID] = kept }
        }
        return result
    }

    private func body(
        for reason: SparkAlertReason,
        snapshot: SparkSnapshot,
        temperatureUnit: TemperatureUnit
    ) -> String {
        switch reason {
        case .offline:
            return "\(snapshot.name) went offline."
        case .highTemperature:
            return "\(snapshot.name) reached \(MetricFormatter.temperature(snapshot.metrics?.gpu?.temperature, unit: temperatureUnit))."
        case .highMemory:
            return "\(snapshot.name) is using \(MetricFormatter.percent(snapshot.memoryPressurePercentage)) \(snapshot.memoryNoun)."
        case .oomRisk:
            return "\(snapshot.name) reports a high memory OOM risk."
        case .thermalThrottle:
            return "\(snapshot.name) is thermally throttling."
        case .powerLimited:
            return "\(snapshot.name) is power limited."
        case .llmUnavailable:
            return "An LLM monitored by \(snapshot.name) is unavailable."
        }
    }
}
