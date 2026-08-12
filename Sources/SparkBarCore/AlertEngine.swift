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
public struct AlertEngine: Equatable, Sendable {
    public var thresholds: AlertThresholds
    public var cooldown: TimeInterval
    private var active: Set<String> = []
    private var lastSent: [String: Date] = [:]

    public init(thresholds: AlertThresholds = .init(), cooldown: TimeInterval = 900) {
        self.thresholds = thresholds
        self.cooldown = cooldown
    }

    public mutating func evaluate(snapshots: [SparkSnapshot], at date: Date = .now) -> [AlertEvent] {
        var events: [AlertEvent] = []
        var currentKeys = Set<String>()

        for snapshot in snapshots {
            var reasons = snapshot.alertReasons(thresholds: thresholds)
            let temperatureKey = "\(snapshot.id)-\(SparkAlertReason.highTemperature.rawValue)"
            if active.contains(temperatureKey),
               let temperature = snapshot.metrics?.gpu?.temperature,
               temperature >= thresholds.temperatureClearCelsius,
               temperature < thresholds.temperatureCelsius {
                reasons.insert(.highTemperature)
            }
            let memoryKey = "\(snapshot.id)-\(SparkAlertReason.highMemory.rawValue)"
            if active.contains(memoryKey),
               snapshot.memoryPercentage >= thresholds.memoryClearPercentage,
               snapshot.memoryPercentage < thresholds.memoryPercentage {
                reasons.insert(.highMemory)
            }
            for reason in reasons {
                let key = "\(snapshot.id)-\(reason.rawValue)"
                currentKeys.insert(key)
                let wasActive = active.contains(key)
                let cooldownElapsed = lastSent[key].map { date.timeIntervalSince($0) >= cooldown } ?? true
                if !wasActive || cooldownElapsed {
                    events.append(AlertEvent(
                        sparkID: snapshot.id,
                        sparkName: snapshot.name,
                        reason: reason,
                        body: body(for: reason, snapshot: snapshot)
                    ))
                    lastSent[key] = date
                }
            }
        }

        active = currentKeys
        lastSent = lastSent.filter { currentKeys.contains($0.key) }
        return events.sorted { $0.id < $1.id }
    }

    private func body(for reason: SparkAlertReason, snapshot: SparkSnapshot) -> String {
        switch reason {
        case .offline:
            return "\(snapshot.name) went offline."
        case .highTemperature:
            return "\(snapshot.name) reached \(MetricFormatter.temperature(snapshot.metrics?.gpu?.temperature))."
        case .highMemory:
            return "\(snapshot.name) is using \(MetricFormatter.percent(snapshot.metrics?.unifiedMemory?.percentage)) unified memory."
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
