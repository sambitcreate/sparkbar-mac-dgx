import Foundation

public enum MetricFormatter {
    /// Anything outside this range is not a physical reading for a monitored GPU,
    /// and a value beyond `Int.max` cannot be rounded and converted safely.
    private static let plausibleCelsius: ClosedRange<Double> = -273.15...10_000

    /// Uptime is rendered as whole seconds. A bound keeps `Int(seconds)` from
    /// trapping on an absurd server-supplied value (1e15s is ~31 million years).
    private static let maximumPlausibleUptimeSeconds: Double = 1e15

    public static func percent(_ value: Double?, maximum: Double = 100) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded().clamped(to: 0...maximum)))%"
    }

    public static func percentExact(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    public static func temperatureShort(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let value = plausibleTemperature(celsius, unit: unit) else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    public static func temperature(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let value = plausibleTemperature(celsius, unit: unit) else { return "—" }
        let suffix = unit == .fahrenheit ? "°F" : "°C"
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))\(suffix)"
    }

    /// Validates on the Celsius input, then on the converted value, because
    /// Fahrenheit conversion can turn a large finite Celsius reading into
    /// infinity. Returns nil for anything unsafe to convert to `Int`.
    public static func plausibleTemperature(_ celsius: Double?, unit: TemperatureUnit) -> Double? {
        guard let celsius, celsius.isFinite, plausibleCelsius.contains(celsius) else { return nil }
        let converted = convertedTemperature(celsius, unit: unit)
        guard converted.isFinite else { return nil }
        return converted
    }

    public static func watts(_ value: Double?, includeUnit: Bool = true) -> String {
        guard let value, value.isFinite else { return "—" }
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        return includeUnit ? "\(number) W" : number
    }

    public static func tokensPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) t/s"
    }

    public static func memory(_ megabytes: Double?, includeUnit: Bool = true) -> String {
        guard let megabytes, megabytes.isFinite else { return "—" }
        let absolute = abs(megabytes)
        if absolute < 1024 {
            let value = megabytes.formatted(.number.precision(.fractionLength(0...1)))
            return includeUnit ? "\(value) MB" : value
        }
        let value = (megabytes / 1024).formatted(.number.precision(.fractionLength(0...1)))
        return includeUnit ? "\(value) GB" : value
    }

    public static func memoryGigabytesShort(_ megabytes: Double?) -> String {
        guard let megabytes, megabytes.isFinite else { return "—" }
        let gigabytes = megabytes / 1024
        return "\(gigabytes.formatted(.number.precision(.fractionLength(gigabytes.rounded() == gigabytes ? 0 : 1))))G"
    }

    public static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var amount = abs(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        let fractionDigits = amount.rounded() == amount ? 0 : (index >= 2 ? 1 : 0)
        let number = amount.formatted(.number.precision(.fractionLength(fractionDigits)))
        return "\(number) \(units[index])"
    }

    public static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0, seconds.isFinite,
              seconds < maximumPlausibleUptimeSeconds else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(remainingSeconds)s"
    }

    public static func clockPercentage(_ current: Double?, maximum: Double?) -> String {
        guard let current, let maximum, maximum > 0 else { return "—" }
        return percent(current / maximum * 100)
    }

    public static func frequency(_ megahertz: Double?) -> String {
        guard let megahertz, megahertz.isFinite else { return "—" }
        return "\(megahertz.formatted(.number.precision(.fractionLength(0)))) MHz"
    }

    public static func normalisedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        // sparkDash documents `percent` on a 0-100 scale, so exactly 1 means one
        // percent rather than a complete job; only sub-unit values are treated
        // as a 0-1 fraction.
        let scaled = value > 0 && value < 1 ? value * 100 : value
        return scaled.clamped(to: 0...100)
    }

    public static func convertedTemperature(_ celsius: Double, unit: TemperatureUnit) -> Double {
        unit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }
}

private extension BinaryFloatingPoint {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
