import Foundation
import SparkBarCore
import Testing
@testable import SparkBar

@Suite("Ordered history persistence")
struct HistoryPersistenceTests {
    @Test("Background writes are off the main thread and report success")
    func backgroundWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let writer = HistoryPersistence()
        let succeededOffMain = await withCheckedContinuation { continuation in
            writer.save(HistoryStore(), to: url) { result in
                if case .success = result {
                    continuation.resume(returning: !Thread.isMainThread)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
        #expect(succeededOffMain)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A forced save drains older snapshots before writing the newest")
    func orderedFlush() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let writer = HistoryPersistence()
        for index in 0..<20 {
            var history = HistoryStore()
            history.sample([SparkSnapshot(id: "old-\(index)", name: "Old", online: true)])
            writer.save(history, to: url) { _ in }
        }
        var newest = HistoryStore()
        newest.sample([SparkSnapshot(id: "newest", name: "Newest", online: true)])
        try writer.saveAndWait(newest, to: url)
        let restored = try HistoryStore.load(from: url)
        #expect(restored.samples(for: "newest").count == 1)
        #expect(restored.samplesBySparkID.count == 1)
    }

    @Test("Background and forced writes report filesystem failures")
    func failedWrites() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = file.appendingPathComponent("history.json")
        let writer = HistoryPersistence()
        let failed = await withCheckedContinuation { continuation in
            writer.save(HistoryStore(), to: url) { result in
                if case .failure = result {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
        #expect(failed)
        #expect(throws: (any Error).self) {
            try writer.saveAndWait(HistoryStore(), to: url)
        }
    }
}
