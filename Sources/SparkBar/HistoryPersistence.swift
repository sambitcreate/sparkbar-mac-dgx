import Foundation
import SparkBarCore

/// All writes share one queue so an older snapshot can never replace a newer
/// one. Normal saves do not block the main actor; lifecycle flushes deliberately
/// wait for queued writes before saving the final snapshot or reloading a file.
final class HistoryPersistence: Sendable {
    private let queue = DispatchQueue(label: "com.sparkbar.history", qos: .utility)

    func save(
        _ snapshot: HistoryStore,
        to url: URL,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        queue.async {
            completion(Result { try snapshot.save(to: url) })
        }
    }

    func saveAndWait(_ snapshot: HistoryStore, to url: URL) throws {
        try queue.sync {
            try snapshot.save(to: url)
        }
    }
}
