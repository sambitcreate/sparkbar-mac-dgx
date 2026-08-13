@preconcurrency import Foundation

public struct ConnectionTestResult: Equatable, Sendable {
    public let endpoint: SparkDashEndpoint
    public let sparkCount: Int
    public let sparks: [SparkConfiguration]
    public let settings: SparkDashSettings?

    public init(endpoint: SparkDashEndpoint, sparks: [SparkConfiguration], settings: SparkDashSettings? = nil) {
        self.endpoint = endpoint
        self.sparkCount = sparks.count
        self.sparks = sparks
        self.settings = settings
    }
}

public struct SparkDashSettings: Decodable, Equatable, Sendable {
    public let pollIntervalMs: Int?
    public let defaultLlmPort: Int?
    public let autoHideOffline: Bool?
    public let temperatureUnit: String?
    public let density: String?
}

public enum SparkDashClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidHTTPStatus(Int)
    case invalidResponse
    case invalidPayload
    case websocketUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let status): return "sparkDash returned HTTP \(status)."
        case .invalidResponse: return "sparkDash returned an invalid HTTP response."
        case .invalidPayload: return "sparkDash returned an unreadable payload."
        case .websocketUnavailable: return "sparkDash was reachable, but its live stream is unavailable."
        }
    }
}

public enum SparkDashClientEvent: Equatable, Sendable {
    case state(ConnectionState)
    case connectionTested(ConnectionTestResult)
    case snapshot(SnapshotEnvelope)
    case diagnostic(String)
}

public struct ReconnectBackoff: Equatable, Sendable {
    public let maximum: TimeInterval
    public let jitterRatio: Double

    public init(maximum: TimeInterval = 30, jitterRatio: Double = 0.2) {
        self.maximum = maximum
        self.jitterRatio = max(0, min(jitterRatio, 1))
    }

    public func delay(attempt: Int, jitter: Double = 0.5) -> TimeInterval {
        let schedule: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        let base = schedule[min(max(attempt, 0), schedule.count - 1)]
        let boundedJitter = max(-1, min(jitter, 1)) * jitterRatio
        return min(maximum, max(0, base * (1 + boundedJitter)))
    }
}

/// The only network client in SparkBar. It performs the allow-listed REST
/// validation request and maintains one WebSocket for every configured Spark.
public actor SparkDashClient {
    public let endpoint: SparkDashEndpoint

    private let session: URLSession
    private let decoder: JSONDecoder
    private let eventsStream: AsyncStream<SparkDashClientEvent>
    private var continuation: AsyncStream<SparkDashClientEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var running = false
    private var reconnectAttempt = 0
    private let backoff: ReconnectBackoff

    /// SparkBar talks to LAN hosts that may be offline, so a snappy timeout
    /// matters more than the system default of 60s per request.
    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public init(
        endpoint: SparkDashEndpoint,
        session: URLSession? = nil,
        decoder: JSONDecoder = JSONDecoder(),
        backoff: ReconnectBackoff = .init()
    ) {
        self.endpoint = endpoint
        self.session = session ?? Self.makeDefaultSession()
        self.decoder = decoder
        self.backoff = backoff
        var continuation: AsyncStream<SparkDashClientEvent>.Continuation?
        self.eventsStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func events() -> AsyncStream<SparkDashClientEvent> { eventsStream }

    public func start() {
        guard runTask == nil else { return }
        running = true
        runTask = Task { await self.runLoop() }
    }

    public func stop() {
        running = false
        runTask?.cancel()
        runTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        emit(.state(.disconnected))
        continuation?.finish()
        continuation = nil
    }

    public func testConnection() async throws -> ConnectionTestResult {
        // Fetch settings in parallel with the spark list; both are cheap GETs
        // and the connection test waits for neither to finish the other.
        async let settingsTask = Self.fetchSettings(endpoint: endpoint, session: session)
        let request = URLRequest(url: endpoint.apiURL(path: "/api/sparks"))
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SparkDashClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SparkDashClientError.invalidHTTPStatus(httpResponse.statusCode)
        }
        let list: SparkListResponse
        do {
            list = try decoder.decode(SparkListResponse.self, from: data)
        } catch {
            throw SparkDashClientError.invalidPayload
        }
        let settings = await settingsTask
        return ConnectionTestResult(endpoint: endpoint, sparks: list.sparks, settings: settings)
    }

    /// Settings are advisory; a failure must not fail the connection test.
    /// Uses its own decoder to stay nonisolated.
    private nonisolated static func fetchSettings(
        endpoint: SparkDashEndpoint,
        session: URLSession
    ) async -> SparkDashSettings? {
        do {
            let (data, response) = try await session.data(for: URLRequest(url: endpoint.apiURL(path: "/api/settings")))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(SparkDashSettings.self, from: data)
        } catch {
            return nil
        }
    }

    /// REST fallback for when the WebSocket is blocked but the API is not.
    /// Fetches the per-spark metrics endpoint and wraps them in the same
    /// envelope shape the WebSocket delivers, skipping sparks that fail.
    public func pollSnapshot(sparkIDs: [String]) async throws -> SnapshotEnvelope {
        var snapshots: [SparkSnapshot] = []
        snapshots.reserveCapacity(sparkIDs.count)
        for id in sparkIDs {
            let request = URLRequest(url: endpoint.apiURL(path: "/api/sparks/\(id)/metrics"))
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    continue
                }
                if let snapshot = try? decoder.decode(SparkSnapshot.self, from: data) {
                    snapshots.append(snapshot)
                }
            } catch {
                continue
            }
        }
        return SnapshotEnvelope(type: "snapshot", sparks: snapshots, refreshInterval: nil)
    }

    private func runLoop() async {
        defer {
            webSocket?.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            runTask = nil
        }

        while running && !Task.isCancelled {
            do {
                emit(.state(.connecting))
                let result = try await testConnection()
                emit(.connectionTested(result))

                guard running, !Task.isCancelled else { break }
                try await runWebSocket()
            } catch is CancellationError {
                break
            } catch let error as SparkDashClientError {
                if case .websocketUnavailable = error {
                    emit(.state(.apiReachableLiveStreamUnavailable))
                } else {
                    emit(.state(.failed(error.localizedDescription)))
                }
                emit(.diagnostic(error.localizedDescription))
                await waitBeforeReconnect()
            } catch {
                emit(.state(.failed(error.localizedDescription)))
                emit(.diagnostic(error.localizedDescription))
                await waitBeforeReconnect()
            }
        }
    }

    private func runWebSocket() async throws {
        let task = session.webSocketTask(with: endpoint.webSocketURL)
        webSocket = task
        task.resume()
        reconnectAttempt = 0
        emit(.state(.connected))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.receiveLoop(task) }
                group.addTask { try await self.pingLoop(task) }
                do {
                    try await group.next()
                } catch {
                    group.cancelAll()
                    throw error
                }
                group.cancelAll()
                try await group.waitForAll()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            throw SparkDashClientError.websocketUnavailable
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async throws {
        while running && !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let string):
                data = Data(string.utf8)
            case .data(let dataValue):
                data = dataValue
            @unknown default:
                continue
            }

            guard !data.isEmpty else {
                emit(.diagnostic("Received an empty WebSocket frame."))
                continue
            }

            do {
                let envelope = try decoder.decode(SnapshotEnvelope.self, from: data)
                guard envelope.type == nil || envelope.type == "snapshot" else { continue }
                emit(.snapshot(envelope))
            } catch {
                // A malformed frame should not kill a healthy stream. A valid
                // frame received afterwards still updates the same store.
                emit(.diagnostic("Ignored an unreadable WebSocket frame."))
            }
        }
        throw SparkDashClientError.websocketUnavailable
    }

    private func pingLoop(_ task: URLSessionWebSocketTask) async throws {
        while running && !Task.isCancelled {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            try await sendPing(task)
        }
    }

    private func sendPing(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func waitBeforeReconnect() async {
        guard running, !Task.isCancelled else { return }
        reconnectAttempt += 1
        emit(.state(.reconnecting(attempt: reconnectAttempt)))
        let randomJitter = Double.random(in: -1...1)
        let seconds = backoff.delay(attempt: reconnectAttempt - 1, jitter: randomJitter)
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            // Cancellation is expected during app shutdown or URL replacement.
        }
    }

    private func emit(_ event: SparkDashClientEvent) {
        continuation?.yield(event)
    }
}
