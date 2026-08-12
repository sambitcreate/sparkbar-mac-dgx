import Foundation
import SparkBarCore

enum TestFixtures {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "TestFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }

    static func decodeEnvelope(_ name: String) throws -> SnapshotEnvelope {
        try JSONDecoder().decode(SnapshotEnvelope.self, from: data(name))
    }
}

func makeSnapshot(
    id: String,
    name: String,
    online: Bool? = true,
    gpu: Double? = nil,
    temperature: Double? = nil,
    memory: Double? = nil,
    llm: Double? = nil
) -> SparkSnapshot {
    var gpuObject: [String: Any] = [:]
    if let gpu { gpuObject["usage"] = gpu }
    if let temperature { gpuObject["temperature"] = temperature }
    var memoryObject: [String: Any] = [:]
    if let memory { memoryObject["percentage"] = memory }
    var metricsObject: [String: Any] = ["gpu": gpuObject, "unifiedMemory": memoryObject]
    if let llm {
        metricsObject["llm"] = [["backend": "test", "modelId": "model", "generationTps": llm]]
    }
    var object: [String: Any] = ["id": id, "name": name, "metrics": metricsObject]
    if let online { object["online"] = online }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(SparkSnapshot.self, from: data)
}
