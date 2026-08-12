import Foundation

public enum MetricFormatter {
    public static func percent(_ value: Double?, maximum: Double = 100) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded().clamped(to: 0...maximum)))%"
    }

    public static func percentExact(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    public static func temperatureShort(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        let value = convertedTemperature(celsius, unit: unit)
        return "\(Int(value.rounded()))°"
    }

    public static func temperature(_ celsius: Double?, unit: TemperatureUnit = .celsius) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        let suffix = unit == .fahrenheit ? "°F" : "°C"
        let value = convertedTemperature(celsius, unit: unit)
        return "\(value.formatted(.number.precision(.fractionLength(0...1))))\(suffix)"
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
        guard let seconds, seconds >= 0, seconds.isFinite else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
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
        return (value <= 1 ? value * 100 : value).clamped(to: 0...100)
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
