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
        #expect(MetricFormatter.uptime(90) == "1m")
        #expect(MetricFormatter.uptime(45) == "45s")
        #expect(MetricFormatter.uptime(0) == "0s")
    }

    /// A server-supplied temperature can be any finite Double. Converting one
    /// beyond `Int.max` used to trap and take the whole app down.
    @Test func neverTrapsOnAbsurdTemperatures() {
        for celsius in [1e19, 1e300, -1e300, 1.9e307, -1_000, 10_001] {
            #expect(MetricFormatter.temperatureShort(celsius) == "—")
            #expect(MetricFormatter.temperature(celsius) == "—")
            #expect(MetricFormatter.temperature(celsius, unit: .fahrenheit) == "—")
        }
        // Fahrenheit conversion overflows to infinity for a large finite input;
        // the converted value must be re-checked, not just the Celsius input.
        #expect(MetricFormatter.temperatureShort(1.9e307, unit: .fahrenheit) == "—")
        #expect(MetricFormatter.temperatureShort(.infinity) == "—")
        #expect(MetricFormatter.temperatureShort(.nan) == "—")
    }

    @Test func keepsPlausibleTemperatures() {
        #expect(MetricFormatter.temperatureShort(85.4) == "85°")
        #expect(MetricFormatter.temperatureShort(25, unit: .fahrenheit) == "77°")
        #expect(MetricFormatter.temperature(25, unit: .fahrenheit) == "77°F")
        #expect(MetricFormatter.temperature(-40) == "-40°C")
    }

    /// The same trap existed for uptime and ComfyUI queue ETAs.
    @Test func neverTrapsOnAbsurdUptimes() {
        #expect(MetricFormatter.uptime(1e300) == "—")
        #expect(MetricFormatter.uptime(9.3e18) == "—")
        #expect(MetricFormatter.uptime(.infinity) == "—")
        #expect(MetricFormatter.uptime(.nan) == "—")
        #expect(MetricFormatter.uptime(-1) == "—")
        #expect(MetricFormatter.uptime(1e14) != "—")
    }

    /// `percent` is documented on a 0-100 scale, so 1 means one percent.
    @Test func normalisesProgressWithoutInflatingOnePercent() {
        #expect(MetricFormatter.normalisedProgress(1) == 1)
        #expect(MetricFormatter.normalisedProgress(0) == 0)
        #expect(MetricFormatter.normalisedProgress(0.5) == 50)
        #expect(MetricFormatter.normalisedProgress(72) == 72)
        #expect(MetricFormatter.normalisedProgress(140) == 100)
        #expect(MetricFormatter.normalisedProgress(-3) == 0)
        #expect(MetricFormatter.normalisedProgress(nil) == nil)
    }
}
