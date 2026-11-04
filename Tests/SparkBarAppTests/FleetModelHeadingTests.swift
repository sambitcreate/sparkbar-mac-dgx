import Foundation
import SparkBarCore
import Testing
@testable import SparkBar

@Suite("Persistent fleet model heading")
struct FleetModelHeadingTests {
    private func snapshot(_ json: String) throws -> SparkSnapshot {
        try JSONDecoder().decode(SparkSnapshot.self, from: Data(json.utf8))
    }

    @Test("A worker never replaces the actual head model")
    func headModel() throws {
        let worker = try snapshot(#"{"id":"worker","name":"DGX2","online":true,"role":"worker","metrics":{"llm":[{"modelId":"worker-stale-name","available":true}]}}"#)
        let head = try snapshot(#"{"id":"head","name":"DGX1","online":true,"role":"head","metrics":{"llm":[{"modelId":"DeepSeek-V4.1-Flash-1017","backend":"TensorFold","available":true}]}}"#)
        let heading = try #require(FleetModelHeading.resolve([worker, head]))
        #expect(heading.name == "DeepSeek-V4.1-Flash-1017")
        #expect(heading.backend == "TensorFold")
        #expect(heading.displayName == "DeepSeek V4.1 Flash 1017")
        #expect(heading.isCurrent)
        #expect(FleetModelHeading.resolve([head, worker]) == heading)
    }

    @Test("An online model outranks an offline head's last known model")
    func liveBeforeStale() throws {
        let stale = try snapshot(#"{"id":"a","name":"Old head","online":false,"role":"head","metrics":{"llm":[{"modelId":"Old","available":true}]}}"#)
        let live = try snapshot(#"{"id":"b","name":"Standalone","online":true,"metrics":{"llm":[{"modelId":"Current","available":true}]}}"#)
        #expect(FleetModelHeading.resolve([stale, live])?.name == "Current")
    }

    @Test("An available model on a later port outranks an unavailable first port")
    func activePort() throws {
        let head = try snapshot(#"{"id":"head","name":"DGX1","online":true,"role":"head","metrics":{"llm":[{"modelId":"Old","available":false},{"modelId":"Active","available":true}]}}"#)
        #expect(FleetModelHeading.resolve([head])?.name == "Active")
    }

    @Test("Keep a model's identity when its server goes offline")
    func retainIdentity() throws {
        let head = try snapshot(#"{"id":"head","name":"DGX1","online":false,"role":"head","metrics":{"llm":[{"modelId":"DeepSeek","available":false}]}}"#)
        let heading = try #require(FleetModelHeading.resolve([head]))
        #expect(heading.name == "DeepSeek")
        #expect(!heading.isCurrent)
    }

    @Test("No model and worker-only fleets have an explicit empty heading")
    func noModel() throws {
        #expect(FleetModelHeading.resolve([]) == nil)
        let unnamed = try snapshot(#"{"id":"a","name":"A","online":true,"metrics":{"llm":[{"modelId":"   ","available":true}]}}"#)
        let worker = try snapshot(#"{"id":"b","name":"B","online":true,"workerNode":true,"metrics":{"llm":[{"modelId":"stale","available":true}]}}"#)
        #expect(FleetModelHeading.resolve([unnamed, worker]) == nil)
    }
}
