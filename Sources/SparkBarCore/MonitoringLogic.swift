import Foundation

public enum DisplayMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case gpuUtilization
    case gpuTemperature
    case unifiedMemory
    case memoryPercentage
    case llmTokensPerSecond
    case gpuAndTemperature

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .gpuUtilization: return "GPU utilization"
        case .gpuTemperature: return "GPU temperature"
        case .unifiedMemory: return "Unified-memory usage"
        case .memoryPercentage: return "Memory percentage"
        case .llmTokensPerSecond: return "LLM tokens/sec"
        case .gpuAndTemperature: return "GPU + temperature"
        }
    }
}

public enum SparkSourceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case selected
    case aggregate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .selected: return "Specific Spark"
        case .aggregate: return "Aggregate"
        }
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit
    case followSparkDash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .celsius: return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        case .followSparkDash: return "Follow sparkDash"
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case apiReachableLiveStreamUnavailable
    case failed(String)

    public var isLive: Bool {
        if case .connected = self { return true }
        return false
    }

    public var shortLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Live"
        case .reconnecting: return "Reconnecting…"
        case .apiReachableLiveStreamUnavailable: return "Live stream unavailable"
        case .failed: return "Disconnected"
        }
    }
}

public enum SparkAlertReason: String, CaseIterable, Hashable, Codable, Sendable {
    case offline
    case highTemperature
    case highMemory
    case oomRisk
    case thermalThrottle
    case powerLimited
    case llmUnavailable

    public var title: String {
        switch self {
        case .offline: return "Spark offline"
        case .highTemperature: return "High temperature"
        case .highMemory: return "High unified memory"
        case .oomRisk: return "OOM risk"
        case .thermalThrottle: return "Thermal throttling"
        case .powerLimited: return "Power limited"
        case .llmUnavailable: return "LLM unavailable"
        }
    }
}

public struct AlertThresholds: Equatable, Sendable {
    public var temperatureCelsius: Double
    public var memoryPercentage: Double
    public var memoryClearPercentage: Double
    public var temperatureClearCelsius: Double

    public init(
        temperatureCelsius: Double = 85,
        memoryPercentage: Double = 85,
        memoryClearPercentage: Double = 80,
        temperatureClearCelsius: Double = 80
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.memoryPercentage = memoryPercentage
        self.memoryClearPercentage = memoryClearPercentage
        self.temperatureClearCelsius = temperatureClearCelsius
    }
}

public extension SparkSnapshot {
    func alertReasons(thresholds: AlertThresholds = .init()) -> Set<SparkAlertReason> {
        var reasons = Set<SparkAlertReason>()
        guard isOnline else {
            reasons.insert(.offline)
            return reasons
        }

        if let temperature = metrics?.gpu?.temperature, temperature >= thresholds.temperatureCelsius {
            reasons.insert(.highTemperature)
        }

        let memoryRisk = metrics?.unifiedMemory?.oomRisk?.lowercased()
        if memoryPercentage >= thresholds.memoryPercentage {
            reasons.insert(.highMemory)
        }
        if memoryRisk == "high" || memoryRisk == "critical" {
            reasons.insert(.oomRisk)
        }

        if metrics?.gpu?.throttle?.thermal == true {
            reasons.insert(.thermalThrottle)
        }
        if metrics?.gpu?.throttle?.powerCap == true {
            reasons.insert(.powerLimited)
        }

        if let llm = metrics?.llm, !llm.isEmpty, llm.contains(where: { $0.available == false }) {
            reasons.insert(.llmUnavailable)
        }

        return reasons
    }

    var isAlerting: Bool { !alertReasons().isEmpty }
}

public struct MenuBarPresentation: Equatable, Sendable {
    public let title: String
    public let accessibilityLabel: String
    public let iconName: String
    public let isDimmed: Bool
    public let isPulsing: Bool
    public let severity: MenuBarSeverity
    public let sourceSparkID: String?

    public init(
        title: String,
        accessibilityLabel: String,
        iconName: String,
        isDimmed: Bool,
        isPulsing: Bool,
        severity: MenuBarSeverity,
        sourceSparkID: String?
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.iconName = iconName
        self.isDimmed = isDimmed
        self.isPulsing = isPulsing
        self.severity = severity
        self.sourceSparkID = sourceSparkID
    }
}

public enum MenuBarSeverity: Equatable, Sendable {
    case normal
    case warning
    case offline
    case disconnected
}

public enum SparkSelector {
    public static func auto(
        snapshots: [SparkSnapshot],
        selectedID: String?,
        thresholds: AlertThresholds = .init()
    ) -> SparkSnapshot? {
        let online = snapshots.filter(\.isOnline)
        guard !online.isEmpty else { return nil }

        if let alerting = online
            .filter({ !$0.alertReasons(thresholds: thresholds).isEmpty })
            .sorted(by: { prioritySort($0, $1, thresholds: thresholds) })
            .first {
            return alerting
        }

        if let busiestGPU = online.max(by: { lhs, rhs in
            if lhs.gpuUsage == rhs.gpuUsage { return lhs.llmActivity < rhs.llmActivity }
            return lhs.gpuUsage < rhs.gpuUsage
        }), busiestGPU.gpuUsage > 0 {
            return busiestGPU
        }

        if let busiestLLM = online.max(by: { $0.llmActivity < $1.llmActivity }), busiestLLM.llmActivity > 0 {
            return busiestLLM
        }

        return online.first(where: { $0.id == selectedID }) ?? online.first
    }

    private static func prioritySort(
        _ lhs: SparkSnapshot,
        _ rhs: SparkSnapshot,
        thresholds: AlertThresholds
    ) -> Bool {
        let lhsReasons = lhs.alertReasons(thresholds: thresholds).count
        let rhsReasons = rhs.alertReasons(thresholds: thresholds).count
        if lhsReasons != rhsReasons { return lhsReasons > rhsReasons }
        if lhs.gpuUsage != rhs.gpuUsage { return lhs.gpuUsage > rhs.gpuUsage }
        if lhs.llmActivity != rhs.llmActivity { return lhs.llmActivity > rhs.llmActivity }
        return lhs.id < rhs.id
    }
}

public enum MenuBarPresenter {
    public static func make(
        snapshots: [SparkSnapshot],
        connectionState: ConnectionState,
        metric: DisplayMetric,
        sourceMode: SparkSourceMode,
        selectedID: String?,
        temperatureUnit: TemperatureUnit = .celsius,
        thresholds: AlertThresholds = .init()
    ) -> MenuBarPresentation {
        guard isShowingData(connectionState), !snapshots.isEmpty else {
            let isConnecting: Bool = {
                switch connectionState {
                case .connecting, .reconnecting: return true
                default: return false
                }
            }()
            let icon = isConnecting ? "bolt.badge.clock" : "bolt.slash"
            return MenuBarPresentation(
                title: "—",
                accessibilityLabel: "sparkDash \(connectionState.shortLabel.lowercased())",
                iconName: icon,
                isDimmed: true,
                isPulsing: connectionState == .connecting,
                severity: .disconnected,
                sourceSparkID: nil
            )
        }

        let selected: SparkSnapshot?
        let aggregate = sourceMode == .aggregate
        switch sourceMode {
        case .auto:
            selected = SparkSelector.auto(snapshots: snapshots, selectedID: selectedID, thresholds: thresholds)
        case .selected:
            selected = snapshots.first(where: { $0.id == selectedID }) ?? snapshots.first
        case .aggregate:
            selected = nil
        }

        if aggregate {
            let online = snapshots.filter(\.isOnline)
            guard let maxGPU = online.map(\.gpuUsage).max(), !online.isEmpty else {
                return MenuBarPresentation(
                    title: "—",
                    accessibilityLabel: "No Sparks online",
                    iconName: "bolt.slash",
                    isDimmed: true,
                    isPulsing: false,
                    severity: .offline,
                    sourceSparkID: nil
                )
            }
            let title = aggregateTitle(metric: metric, snapshots: online, maxGPU: maxGPU, temperatureUnit: temperatureUnit)
            let warning = online.contains { !$0.alertReasons(thresholds: thresholds).isEmpty }
            return MenuBarPresentation(
                title: title,
                accessibilityLabel: "Aggregate Spark status, \(title)",
                iconName: warning ? "bolt.triangle.fill" : "bolt.fill",
                isDimmed: false,
                isPulsing: online.contains { $0.llmActivity > 0 },
                severity: warning ? .warning : .normal,
                sourceSparkID: nil
            )
        }

        guard let spark = selected else {
            return MenuBarPresentation(
                title: "—",
                accessibilityLabel: "No Spark selected",
                iconName: "bolt.slash",
                isDimmed: true,
                isPulsing: false,
                severity: .offline,
                sourceSparkID: nil
            )
        }

        guard spark.isOnline else {
            return MenuBarPresentation(
                title: "—",
                accessibilityLabel: "\(spark.name) offline",
                iconName: "bolt.slash",
                isDimmed: true,
                isPulsing: false,
                severity: .offline,
                sourceSparkID: spark.id
            )
        }

        let title = singleTitle(metric: metric, spark: spark, temperatureUnit: temperatureUnit)
        let warning = !spark.alertReasons(thresholds: thresholds).isEmpty
        return MenuBarPresentation(
            title: title,
            accessibilityLabel: "\(spark.name), \(title)",
            iconName: warning ? "bolt.triangle.fill" : "bolt.fill",
            isDimmed: false,
            isPulsing: spark.llmActivity > 0,
            severity: warning ? .warning : .normal,
            sourceSparkID: spark.id
        )
    }

    /// The menu bar may show data while the connection is healthy or while
    /// the REST polling fallback is delivering snapshots.
    private static func isShowingData(_ state: ConnectionState) -> Bool {
        switch state {
        case .connected, .apiReachableLiveStreamUnavailable: return true
        default: return false
        }
    }

    private static func singleTitle(metric: DisplayMetric, spark: SparkSnapshot, temperatureUnit: TemperatureUnit) -> String {
        switch metric {
        case .iconOnly: return ""
        case .gpuUtilization: return MetricFormatter.percent(spark.metrics?.gpu?.usage)
        case .gpuTemperature: return MetricFormatter.temperatureShort(spark.metrics?.gpu?.temperature, unit: temperatureUnit)
        case .unifiedMemory: return MetricFormatter.memoryGigabytesShort(spark.metrics?.unifiedMemory?.used)
        case .memoryPercentage: return MetricFormatter.percent(spark.metrics?.unifiedMemory?.percentage)
        case .llmTokensPerSecond: return MetricFormatter.tokensPerSecond(spark.primaryLLM?.generationTps)
        case .gpuAndTemperature:
            return "\(MetricFormatter.percent(spark.metrics?.gpu?.usage)) · \(MetricFormatter.temperatureShort(spark.metrics?.gpu?.temperature, unit: temperatureUnit))"
        }
    }

    private static func aggregateTitle(metric: DisplayMetric, snapshots: [SparkSnapshot], maxGPU: Double, temperatureUnit: TemperatureUnit) -> String {
        switch metric {
        case .iconOnly: return ""
        case .gpuUtilization: return MetricFormatter.percent(maxGPU)
        case .gpuTemperature: return MetricFormatter.temperatureShort(snapshots.compactMap { $0.metrics?.gpu?.temperature }.max(), unit: temperatureUnit)
        case .unifiedMemory: return MetricFormatter.memoryGigabytesShort(snapshots.compactMap { $0.metrics?.unifiedMemory?.used }.max())
        case .memoryPercentage: return MetricFormatter.percent(snapshots.compactMap { $0.metrics?.unifiedMemory?.percentage }.max())
        case .llmTokensPerSecond: return MetricFormatter.tokensPerSecond(snapshots.compactMap(\.primaryLLM?.generationTps).max())
        case .gpuAndTemperature:
            return "\(MetricFormatter.percent(maxGPU)) · \(MetricFormatter.temperatureShort(snapshots.compactMap { $0.metrics?.gpu?.temperature }.max(), unit: temperatureUnit))"
        }
    }
}
