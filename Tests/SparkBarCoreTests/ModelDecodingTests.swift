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
    }
}
