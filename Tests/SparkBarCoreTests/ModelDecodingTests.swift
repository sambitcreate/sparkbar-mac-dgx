import Foundation
import Testing
import SparkBarCore

@Suite("sparkDash wire decoding")
struct ModelDecodingTests {
    @Test func decodesCapturedLiveFrame() throws {
        let envelope = try TestFixtures.decodeEnvelope("snapshot-live")
        #expect(envelope.type == "snapshot")
        #expect(envelope.refreshInterval == 1000)
        #expect(envelope.sparks.count == 1)
        let spark = try #require(envelope.sparks.first)
        #expect(spark.id == "dgx1")
        #expect(spark.isOnline)
        #expect(spark.metrics?.gpu?.temperature == 44)
        #expect(spark.metrics?.unifiedMemory?.oomRisk == "high")
        #expect(spark.primaryLLM?.modelId == "deepseek-v4-flash")
        #expect(spark.metrics?.network?.interfaces?.isEmpty == true)
        #expect(spark.metrics?.comfy == nil)
    }

    @Test func decodesConfigurationAndSettingsFixtures() throws {
        let configurations = try JSONDecoder().decode(SparkListResponse.self, from: TestFixtures.data("sparks"))
        #expect(configurations.sparks.map(\.id) == ["dgx1"])
        #expect(configurations.sparks.first?.llmPorts == [8888])
        #expect(configurations.sparks.first?.isGPUHost == false)
        let settings = try JSONDecoder().decode(SparkDashSettings.self, from: TestFixtures.data("settings"))
        #expect(settings.pollIntervalMs == 1000)
        #expect(settings.temperatureUnit == "celsius")
    }

    @Test func ignoresUnknownFieldsAndMissingOptionalFields() throws {
        let envelope = try TestFixtures.decodeEnvelope("snapshot-unknown")
        #expect(envelope.sparks.count == 1)
        #expect(envelope.sparks[0].gpuUsage == 55)
        #expect(envelope.refreshInterval == nil)
        #expect(envelope.sparks[0].metrics?.gpu?.power == nil)
    }

    @Test func unknownMessageTypeIsDecodedForCallerToIgnore() throws {
        let data = Data(#"{"type":"future-message"}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        #expect(envelope.type == "future-message")
        #expect(envelope.sparks.isEmpty)
    }

    @Test func malformedSparkOrLLMDoesNotDiscardValidSiblings() throws {
        let data = Data(#"{"type":"snapshot","sparks":[{"id":"good","name":"Good","online":true},{"id":"bad","name":"Bad","online":true,"metrics":{"llm":[{"generationTps":"not-a-number"},{"modelId":"valid","generationTps":3}]}}]}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        #expect(envelope.sparks.count == 2)
        #expect(envelope.sparks[1].metrics?.llm?.count == 1)
        #expect(envelope.sparks[1].metrics?.llm?.first?.modelId == "valid")
        #expect(envelope.hasUnreadableSparks == false)
    }

    /// A frame that silently loses Sparks must be reported, not presented as a
    /// smaller fleet: downstream history, alerts, and selection all trust it.
    @Test func reportsSparksThatFailedToDecode() throws {
        let data = Data(#"{"type":"snapshot","sparks":[{"id":"good","name":"Good"},{"name":"no-id"},{"id":"also-good","name":"Also good"}]}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        #expect(envelope.sparks.map(\.id) == ["good", "also-good"])
        #expect(envelope.droppedSparkCount == 1)
        #expect(envelope.sparksFieldIsUnreadable == false)
        #expect(envelope.hasUnreadableSparks)
    }

    @Test func reportsASparkListThatIsPresentButNotAnArray() throws {
        let data = Data(#"{"type":"snapshot","sparks":"nope"}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        #expect(envelope.sparks.isEmpty)
        #expect(envelope.sparksFieldIsUnreadable)
        #expect(envelope.hasUnreadableSparks)
    }

    @Test func absentSparkListIsNotReportedAsUnreadable() throws {
        let data = Data(#"{"type":"snapshot"}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        #expect(envelope.sparks.isEmpty)
        #expect(envelope.sparksFieldIsUnreadable == false)
        #expect(envelope.hasUnreadableSparks == false)
    }

    @Test func healthyFixturesReportNoDroppedSparks() throws {
        for fixture in ["snapshot-live", "snapshot-multi", "snapshot-host", "snapshot-comfy", "snapshot-network", "snapshot-unknown"] {
            let envelope = try TestFixtures.decodeEnvelope(fixture)
            #expect(envelope.hasUnreadableSparks == false, "\(fixture) reported unreadable Sparks")
        }
    }

    @Test func decodesGPUHostSnapshotWithTailscaleAndPrefillSplit() throws {
        let envelope = try TestFixtures.decodeEnvelope("snapshot-host")
        let host = try #require(envelope.sparks.first)
        #expect(host.kind == "host")
        #expect(host.isGPUHost)
        #expect(host.usesUnifiedMemory == false)
        #expect(host.memoryNoun == "VRAM")
        #expect(host.memoryPercentage == 75)
        #expect(host.memoryUsedMB == 18432)
        #expect(host.tailscaleMonitoring == true)
        #expect(host.metrics?.tailscale?.online == true)
        #expect(host.metrics?.tailscale?.tailscaleIp == "100.64.0.12")
        let llm = try #require(host.primaryLLM)
        #expect(llm.backend == "exl3")
        #expect(llm.cachedPrefillTps == 1200)
        #expect(llm.uncachedPrefillTps == 180)
    }

    @Test func sparkKindStillPrefersUnifiedMemoryOverVRAM() throws {
        let spark = makeSnapshot(id: "spark", name: "Spark", memory: 40, vram: 90)
        #expect(spark.isGPUHost == false)
        #expect(spark.memoryPercentage == 40)
        #expect(spark.memoryNoun == "unified memory")
    }

    /// `pollIntervalMs` is server-supplied. Converting an enormous value to
    /// nanoseconds used to overflow and trap, and a merely large one silently
    /// stopped the fallback from ever refreshing again.
    @Test func clampsServerSuppliedPollInterval() throws {
        func interval(_ json: String) throws -> Duration {
            try JSONDecoder().decode(SparkDashSettings.self, from: Data(json.utf8)).boundedPollInterval
        }
        #expect(try interval(#"{"pollIntervalMs":2000}"#) == .milliseconds(2_000))
        #expect(try interval(#"{"pollIntervalMs":1000}"#) == .milliseconds(1_000))
        #expect(try interval(#"{"pollIntervalMs":50}"#) == .milliseconds(1_000))
        #expect(try interval(#"{"pollIntervalMs":0}"#) == .milliseconds(1_000))
        #expect(try interval(#"{"pollIntervalMs":-1}"#) == .milliseconds(1_000))
        #expect(try interval(#"{"pollIntervalMs":60000}"#) == .milliseconds(60_000))
        #expect(try interval(#"{"pollIntervalMs":4000000000000}"#) == .milliseconds(60_000))
        #expect(try interval(#"{"pollIntervalMs":9223372036854775807}"#) == .milliseconds(60_000))
        #expect(try interval(#"{}"#) == .milliseconds(2_000))
    }
}
