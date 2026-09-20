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

public extension SparkDashSettings {
    /// The polling interval to actually use.
    ///
    /// sparkDash supplies this value, so it is untrusted: it is clamped to a
    /// sane window. Without the upper bound, converting a huge interval to
    /// nanoseconds overflows and traps, and a merely large one silently stops
    /// the fallback from ever refreshing again.
    var boundedPollInterval: Duration {
        .milliseconds(min(max(pollIntervalMs ?? Self.defaultPollIntervalMs, Self.minimumPollIntervalMs), Self.maximumPollIntervalMs))
    }

    static let defaultPollIntervalMs = 2_000
    static let minimumPollIntervalMs = 1_000
    static let maximumPollIntervalMs = 60_000
}

public enum SparkDashClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidHTTPStatus(Int)
    case invalidResponse
    case invalidPayload
    case websocketUnavailable
    case pongTimeout

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let status): return "sparkDash returned HTTP \(status)."
        case .invalidResponse: return "sparkDash returned an invalid HTTP response."
        case .invalidPayload: return "sparkDash returned an unreadable payload."
        case .websocketUnavailable: return "sparkDash was reachable, but its live stream is unavailable."
        case .pongTimeout: return "The live stream stopped answering; reconnecting."
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
    private var lastPongAt: Date?
    private let backoff: ReconnectBackoff

    private static let pingInterval: Duration = .seconds(15)
    private static let pongTimeout: Duration = .seconds(10)

    /// Bounds the buffer between this actor and the MainActor consumer. A
    /// server that writes frames faster than the UI drains them would otherwise
    /// grow it without limit. Control events are rare and snapshots are
    /// idempotent, so keeping the newest entries is the right trade.
    private static let eventBufferLimit = 512

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
        self.eventsStream = AsyncStream(bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)) { continuation = $0 }
        self.continuation = continuation
    }

    public func events() -> AsyncStream<SparkDashClientEvent> { eventsStream }

    /// Starts streaming. Safe to call again after `stop()`; it is a no-op while
    /// a run is already in flight.
    public func start() {
        guard runTask == nil, continuation != nil else { return }
        running = true
        runTask = Task { await self.runLoop() }
    }

    /// Stops streaming and releases the socket, leaving the client restartable.
    /// The event stream is deliberately not finished here: doing so used to
    /// make a later `start()` a silent no-op that emitted nothing forever.
    public func stop() {
        running = false
        runTask?.cancel()
        runTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        emit(.state(.disconnected))
    }

    /// Terminal teardown: finishes the event stream so the consumer's
    /// `for await` loop ends. The client cannot be restarted afterwards.
    public func shutdown() {
        stop()
        continuation?.finish()
        continuation = nil
    }

    public func testConnection() async throws -> ConnectionTestResult {
        // Fetch settings in parallel with the spark list; both are cheap GETs
        // and the connection test waits for neither to finish the other.
        async let settingsTask = Self.fetchSettings(endpoint: endpoint, session: session)
        let request = URLRequest(url: try endpoint.apiURL(path: "/api/sparks"))
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
    /// Fetches the per-spark metrics endpoints concurrently — a slow or offline
    /// Spark must not stall the whole fleet behind a chain of timeouts — and
    /// wraps them in the same envelope shape the WebSocket delivers, skipping
    /// sparks that fail. Results keep the caller's spark order.
    public func pollSnapshot(sparkIDs: [String]) async throws -> SnapshotEnvelope {
        let indexed: [(Int, SparkSnapshot)] = await withTaskGroup(of: (Int, SparkSnapshot?).self) { group in
            for (index, id) in sparkIDs.enumerated() {
                group.addTask { (index, await self.fetchMetricsSnapshot(sparkID: id)) }
            }
            var collected: [(Int, SparkSnapshot)] = []
            collected.reserveCapacity(sparkIDs.count)
            for await (index, snapshot) in group {
                if let snapshot {
                    collected.append((index, snapshot))
                }
            }
            return collected.sorted { $0.0 < $1.0 }
        }
        return SnapshotEnvelope(type: "snapshot", sparks: indexed.map(\.1), refreshInterval: nil)
    }

    private func fetchMetricsSnapshot(sparkID: String) async -> SparkSnapshot? {
        // A server-supplied identifier that cannot be encoded as one path
        // component is rejected here instead of being interpolated raw.
        guard let url = try? endpoint.metricsURL(sparkID: sparkID) else { return nil }
        let request = URLRequest(url: url)
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            return try? decoder.decode(SparkSnapshot.self, from: data)
        } catch {
            return nil
        }
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
        lastPongAt = nil
        task.resume()
        reconnectAttempt = 0
        emit(.state(.connected))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.receiveLoop(task) }
                group.addTask { try await self.pingLoop(task) }
                do {
                    _ = try await group.next()
                } catch {
                    // Cancel the socket before draining the group: `receive()`
                    // only returns once the task is cancelled, and the earliest
                    // failure may have come from the ping loop instead.
                    task.cancel(with: .goingAway, reason: nil)
                    group.cancelAll()
                    throw error
                }
                task.cancel(with: .goingAway, reason: nil)
                group.cancelAll()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            emit(.diagnostic("Live stream ended: \(error.localizedDescription)"))
            throw SparkDashClientError.websocketUnavailable
        }
    }

    /// sparkDash deliberately skips broadcasting an unchanged snapshot
    /// (PRD section 20), so frame silence is normal and cannot be used as a
    /// liveness signal. Pings are the only signal, and a peer that stops
    /// answering them leaves a socket that looks open forever: every frame and
    /// every ping simply never arrives, and the menu bar keeps showing frozen
    /// values.
    ///
    /// Pings are therefore fire-and-forget with a deadline. Nothing blocks on a
    /// ping completion handler, so a wedged peer can never stall this loop, and
    /// a missed reply cancels the socket so `receive()` fails and the reconnect
    /// loop takes over.
    private func pingLoop(_ task: URLSessionWebSocketTask) async throws {
        while running && !Task.isCancelled {
            try await Task.sleep(for: Self.pingInterval)
            let sentAt = Date()
            task.sendPing { [weak self] error in
                guard error == nil else { return }
                Task { await self?.notePong(at: sentAt) }
            }
            try await Task.sleep(for: Self.pongTimeout)
            if let lastPongAt, lastPongAt >= sentAt { continue }
            task.cancel(with: .goingAway, reason: nil)
            throw SparkDashClientError.pongTimeout
        }
    }

    private func notePong(at date: Date) {
        lastPongAt = date
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
                // Never let a frame that lost Sparks pass as a healthy one: the
                // fleet would look smaller than it is, and downstream state
                // (history, alerts, selection) would treat that as real.
                if envelope.hasUnreadableSparks {
                    emit(.diagnostic(envelope.sparksFieldIsUnreadable
                        ? "sparkDash sent a snapshot whose Spark list was unreadable."
                        : "Ignored \(envelope.droppedSparkCount) unreadable Spark entr\(envelope.droppedSparkCount == 1 ? "y" : "ies") in a snapshot."))
                }
                emit(.snapshot(envelope))
            } catch {
                // A malformed frame should not kill a healthy stream. A valid
                // frame received afterwards still updates the same store.
                emit(.diagnostic("Ignored an unreadable WebSocket frame."))
            }
        }
        throw SparkDashClientError.websocketUnavailable
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
