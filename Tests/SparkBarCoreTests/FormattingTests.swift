import Testing
import SparkBarCore

@Suite("Metric formatting")
struct FormattingTests {
    @Test func formatsMissingAndBoundedPercentages() {
        #expect(MetricFormatter.percent(nil) == "—")
        #expect(MetricFormatter.percent(0) == "0%")
        #expect(MetricFormatter.percent(72.4) == "72%")
        #expect(MetricFormatter.percent(120) == "100%")
        #expect(MetricFormatter.percent(-4) == "0%")
    }

    @Test func convertsTemperatureAndFormatsMemory() {
        #expect(MetricFormatter.temperature(25) == "25°C")
        #expect(MetricFormatter.temperature(25, unit: .fahrenheit) == "77°F")
        #expect(MetricFormatter.memory(1024) == "1 GB")
        #expect(MetricFormatter.memory(nil) == "—")
    }

    @Test func formatsRatesAndUptime() {
        #expect(MetricFormatter.tokensPerSecond(81.4) == "81.4 t/s")
        #expect(MetricFormatter.bytesPerSecond(1_048_576) == "1 MB/s")
        #expect(MetricFormatter.uptime(3 * 86_400 + 14 * 3_600) == "3d 14h")
    }
}
