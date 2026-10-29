import Darwin
import Foundation
import Network

public enum SparkDashDiscoverySource: String, Sendable, Equatable {
    case mdns
    case probe
    case tailnet
    case knownHost
}

public enum SparkDashDiscoveryPhase: String, Sendable, Equatable {
    case idle
    case scanning
    case completed
    case failed
}

public struct SparkDashDiscoveryHit: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var displayURL: String
    public var source: SparkDashDiscoverySource
    public var sparkCount: Int?

    public init(
        id: String,
        name: String,
        displayURL: String,
        source: SparkDashDiscoverySource,
        sparkCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.displayURL = displayURL
        self.source = source
        self.sparkCount = sparkCount
    }
}

public enum SparkDashDiscoveryError: Error, Equatable, Sendable {
    case cancelled
}

public struct SparkDashScanOptions: Equatable, Sendable {
    public var probeLAN: Bool
    public var bonjour: Bool
    public var tailscaleLocalAPI: Bool
    /// Port used for LAN, tailnet, and known-host probes. Bonjour uses its advertised port.
    public var port: UInt16
    /// Optional DNS name or IP address to probe without sweeping a subnet.
    public var knownHost: String?

    public init(
        probeLAN: Bool = true,
        bonjour: Bool = false,
        tailscaleLocalAPI: Bool = false,
        port: UInt16 = 5555,
        knownHost: String? = nil
    ) {
        self.probeLAN = probeLAN
        self.bonjour = bonjour
        self.tailscaleLocalAPI = tailscaleLocalAPI
        self.port = port
        self.knownHost = knownHost
    }

    public static let `default` = SparkDashScanOptions()
}

public struct SparkDashScanProgress: Equatable, Sendable {
    public let checked: Int
    public let total: Int
}

public actor SparkDashScanner {
    private static let probeConcurrency = 24
    private static let tcpProbeTimeout: TimeInterval = 0.75
    private static let httpTimeout: TimeInterval = 1.0
    private static let mdnsBrowseTimeout: TimeInterval = 2.0

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func reset() {
            lock.lock()
            value = false
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private let callback: (@Sendable (SparkDashScanProgress) -> Void)?
        private var checked = 0
        private var total = 0

        init(callback: (@Sendable (SparkDashScanProgress) -> Void)?) {
            self.callback = callback
            callback?(SparkDashScanProgress(checked: 0, total: 0))
        }

        func addTargets(_ count: Int) {
            guard count > 0 else { return }
            lock.lock()
            total += count
            callback?(SparkDashScanProgress(checked: checked, total: total))
            lock.unlock()
        }

        func didCheckTarget() {
            lock.lock()
            checked += 1
            callback?(SparkDashScanProgress(checked: checked, total: total))
            lock.unlock()
        }
    }

    private let cancellation = CancellationFlag()
    private var activeSession: URLSession?

    public init() {}

    public func scan(
        _ options: SparkDashScanOptions = .default,
        progress: (@Sendable (SparkDashScanProgress) -> Void)? = nil
    ) async -> Result<[SparkDashDiscoveryHit], Error> {
        cancellation.reset()
        let tracker = ProgressTracker(callback: progress)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.httpTimeout
        configuration.timeoutIntervalForResource = Self.httpTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        activeSession = session
        defer {
            session.invalidateAndCancel()
            activeSession = nil
        }

        let isCancelled: @Sendable () -> Bool = { [cancellation] in
            cancellation.isCancelled() || Task.isCancelled
        }

        do {
            try Task.checkCancellation()
            if isCancelled() { return .failure(SparkDashDiscoveryError.cancelled) }

            async let mdnsHits = Self.bonjourHits(enabled: options.bonjour, session: session, progress: tracker, isCancelled: isCancelled)
            async let probeHits = Self.lanHits(enabled: options.probeLAN, port: options.port, session: session, progress: tracker, isCancelled: isCancelled)
            async let tailnetHits = Self.tailscaleHits(enabled: options.tailscaleLocalAPI, port: options.port, session: session, progress: tracker, isCancelled: isCancelled)
            async let knownHostHit = Self.knownHostHit(host: options.knownHost, port: options.port, session: session, progress: tracker, isCancelled: isCancelled)

            var hits = try await mdnsHits + tailnetHits + probeHits
            if let knownHostHit = await knownHostHit { hits.append(knownHostHit) }
            if isCancelled() {
                return .failure(SparkDashDiscoveryError.cancelled)
            }
            hits = Self.deduplicate(hits)
            return .success(hits)
        } catch is CancellationError {
            return .failure(SparkDashDiscoveryError.cancelled)
        } catch let error as SparkDashDiscoveryError {
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    public func cancel() {
        cancellation.cancel()
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }
}

// MARK: - Continuation helpers

final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var finished = false
    private var value: T?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func store(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func complete(with defaultValue: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return }
        finished = true
        continuation.resume(returning: value ?? defaultValue)
        self.continuation = nil
    }
}

// MARK: - Local network probing

extension SparkDashScanner {
    static func bonjourHits(enabled: Bool, session: URLSession, progress: ProgressTracker, isCancelled: @Sendable @escaping () -> Bool) async throws -> [SparkDashDiscoveryHit] {
        guard enabled else { return [] }
        return try await discoverViaBonjour(session: session, progress: progress, isCancelled: isCancelled)
    }

    static func lanHits(enabled: Bool, port: UInt16, session: URLSession, progress: ProgressTracker, isCancelled: @Sendable @escaping () -> Bool) async throws -> [SparkDashDiscoveryHit] {
        guard enabled else { return [] }
        return try await probeLocalRFC1918(port: port, session: session, progress: progress, isCancelled: isCancelled)
    }

    static func tailscaleHits(enabled: Bool, port: UInt16, session: URLSession, progress: ProgressTracker, isCancelled: @Sendable @escaping () -> Bool) async throws -> [SparkDashDiscoveryHit] {
        guard enabled else { return [] }
        return try await probeTailscalePeers(port: port, session: session, progress: progress, isCancelled: isCancelled)
    }

    static func knownHostHit(host: String?, port: UInt16, session: URLSession, progress: ProgressTracker, isCancelled: @Sendable @escaping () -> Bool) async -> SparkDashDiscoveryHit? {
        guard let host, baseURL(host: host, port: port) != nil else { return nil }
        progress.addTargets(1)
        let hit = await probeSparkDash(at: host, port: port, session: session, source: .knownHost, isCancelled: isCancelled)
        progress.didCheckTarget()
        return hit
    }

    static func probeLocalRFC1918(
        port: UInt16,
        session: URLSession,
        progress: ProgressTracker,
        isCancelled: @Sendable @escaping () -> Bool
    ) async throws -> [SparkDashDiscoveryHit] {
        let selfAddresses = Set(LocalNetworkEnumeration.localIPv4Addresses())
        let targets = LocalNetworkEnumeration.probeTargets(excluding: selfAddresses)
        guard !targets.isEmpty else { return [] }
        progress.addTargets(targets.count)

        return try await withThrowingTaskGroup(of: SparkDashDiscoveryHit?.self) { group in
            var iterator = targets.makeIterator()
            var inFlight = 0
            var hits: [SparkDashDiscoveryHit] = []

            func enqueueNext() {
                guard inFlight < probeConcurrency, let target = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    if isCancelled() { return nil }
                    try Task.checkCancellation()
                    let hit = await probeSparkDash(at: target, port: port, session: session, source: .probe, isCancelled: isCancelled)
                    progress.didCheckTarget()
                    return hit
                }
            }

            for _ in 0..<min(probeConcurrency, targets.count) {
                enqueueNext()
            }

            while let result = try await group.next() {
                inFlight -= 1
                if let hit = result {
                    hits.append(hit)
                }
                if isCancelled() || Task.isCancelled {
                    group.cancelAll()
                    throw SparkDashDiscoveryError.cancelled
                }
                enqueueNext()
            }

            return hits
        }
    }

    static func probeTailscalePeers(
        port: UInt16,
        session: URLSession,
        progress: ProgressTracker,
        isCancelled: @Sendable @escaping () -> Bool
    ) async throws -> [SparkDashDiscoveryHit] {
        let peers = await TailscaleLocalAPI.fetchPeerTargets(session: session, isCancelled: isCancelled)
        guard !peers.isEmpty else { return [] }
        if isCancelled() { throw SparkDashDiscoveryError.cancelled }
        progress.addTargets(peers.count)

        return try await withThrowingTaskGroup(of: SparkDashDiscoveryHit?.self) { group in
            var hits: [SparkDashDiscoveryHit] = []
            for peer in peers {
                group.addTask {
                    if isCancelled() { return nil }
                    let hit = await probeSparkDash(
                        at: peer.ipv4,
                        preferredName: peer.name,
                        port: port,
                        session: session,
                        source: .tailnet,
                        isCancelled: isCancelled
                    )
                    progress.didCheckTarget()
                    return hit
                }
            }
            while let result = try await group.next() {
                if isCancelled() || Task.isCancelled {
                    group.cancelAll()
                    throw SparkDashDiscoveryError.cancelled
                }
                if let hit = result {
                    hits.append(hit)
                }
            }
            return hits
        }
    }

    static func probeSparkDash(
        at ip: String,
        preferredName: String? = nil,
        port: UInt16,
        session: URLSession,
        source: SparkDashDiscoverySource,
        isCancelled: @Sendable @escaping () -> Bool
    ) async -> SparkDashDiscoveryHit? {
        if isCancelled() { return nil }
        guard let baseURL = baseURL(host: ip, port: port) else { return nil }
        let connectionHost = normalizedHost(ip)!
        guard await isTCPPortOpen(host: connectionHost, port: port, timeout: tcpProbeTimeout) else {
            return nil
        }
        if isCancelled() { return nil }

        return await validateSparkDash(at: baseURL, preferredName: preferredName, session: session, source: source, isCancelled: isCancelled)
    }

    static func validateSparkDash(
        at baseURL: URL,
        preferredName: String? = nil,
        session: URLSession,
        source: SparkDashDiscoverySource,
        isCancelled: @Sendable @escaping () -> Bool
    ) async -> SparkDashDiscoveryHit? {
        if isCancelled() { return nil }
        let url = baseURL.appendingPathComponent("api/sparks")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = httpTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            if isCancelled() { return nil }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let list = try JSONDecoder().decode(SparkListResponse.self, from: data)
            let trimmedName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = trimmedName.isEmpty ? (list.sparks.first?.name ?? baseURL.host ?? "SparkDash") : trimmedName
            let urlString = baseURL.absoluteString
            return SparkDashDiscoveryHit(
                id: urlString,
                name: name,
                displayURL: urlString,
                source: source,
                sparkCount: list.sparks.count
            )
        } catch {
            return nil
        }
    }

    static func baseURL(host rawHost: String, port: UInt16) -> URL? {
        guard port > 0, let host = normalizedHost(rawHost) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        if host.contains(":") {
            // `host` percent-escapes again on older Foundation versions;
            // percentEncodedHost preserves the IPv6 zone separator exactly.
            components.percentEncodedHost = "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
        } else {
            components.host = host
        }
        components.port = Int(port)
        return components.url
    }

    private static func normalizedHost(_ rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        if host.contains(":") {
            let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            var address = in6_addr()
            guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            if parts.count == 2 {
                guard !parts[1].isEmpty,
                      parts[1].utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 }) else { return nil }
            }
            return host
        }
        guard host.count <= 253,
              host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 }),
              host.split(separator: ".", omittingEmptySubsequences: false).dropLast(host.hasSuffix(".") ? 1 : 0).allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return nil }
        if host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }),
           LocalNetworkEnumeration.IPv4Octets(dotted: host) == nil { return nil }
        return host
    }

    static func isTCPPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let connection = NWConnection(to: endpoint, using: .tcp)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.complete(with: true)
                    connection.cancel()
                case .failed, .cancelled:
                    connection.cancel()
                    box.complete(with: false)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                box.complete(with: false)
            }
        }
    }
}

// MARK: - Bonjour

extension SparkDashScanner {
    static func discoverViaBonjour(session: URLSession, progress: ProgressTracker, isCancelled: @Sendable @escaping () -> Bool) async throws -> [SparkDashDiscoveryHit] {
        let results = await browseBonjourServices(timeout: mdnsBrowseTimeout, isCancelled: isCancelled)
        if isCancelled() { throw SparkDashDiscoveryError.cancelled }
        progress.addTargets(results.count)

        var hits: [SparkDashDiscoveryHit] = []
        for result in results {
            if isCancelled() { throw SparkDashDiscoveryError.cancelled }
            let hit = await resolveBonjourResult(result, session: session, isCancelled: isCancelled)
            progress.didCheckTarget()
            if let hit { hits.append(hit) }
        }
        return hits
    }

    static func browseBonjourServices(timeout: TimeInterval, isCancelled: @Sendable @escaping () -> Bool) async -> [NWBrowser.Result] {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: "_sparkdash._tcp", domain: nil), using: parameters)

            browser.browseResultsChangedHandler = { results, _ in
                box.store(Array(results))
            }

            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    browser.cancel()
                    box.complete(with: [])
                }
            }

            browser.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                box.complete(with: [])
            }
        }
    }

    static func resolveBonjourResult(
        _ result: NWBrowser.Result,
        session: URLSession,
        isCancelled: @Sendable @escaping () -> Bool
    ) async -> SparkDashDiscoveryHit? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        guard let resolved = await resolveServiceEndpoint(result.endpoint, timeout: tcpProbeTimeout) else {
            return nil
        }
        if isCancelled() { return nil }
        guard case .hostPort(let host, let port) = resolved else { return nil }
        guard let hostString = describeHost(host) else { return nil }

        guard let baseURL = baseURL(host: hostString, port: port.rawValue) else { return nil }
        return await validateSparkDash(
            at: baseURL,
            preferredName: name,
            session: session,
            source: .mdns,
            isCancelled: isCancelled
        )
    }

    static func resolveServiceEndpoint(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let connection = NWConnection(to: endpoint, using: .tcp)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.complete(with: connection.currentPath?.remoteEndpoint ?? connection.endpoint)
                    connection.cancel()
                case .failed, .cancelled:
                    connection.cancel()
                    box.complete(with: nil)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                box.complete(with: nil)
            }
        }
    }

    static func describeHost(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }
}

// MARK: - Deduplication

extension SparkDashScanner {
    static func deduplicate(_ hits: [SparkDashDiscoveryHit]) -> [SparkDashDiscoveryHit] {
        var seen = Set<String>()
        var unique: [SparkDashDiscoveryHit] = []
        unique.reserveCapacity(hits.count)
        for hit in hits {
            let key = hit.displayURL.lowercased()
            guard seen.insert(key).inserted else { continue }
            unique.append(hit)
        }
        return unique
    }
}

// MARK: - Interface enumeration

enum LocalNetworkEnumeration {
    struct IPv4Interface {
        let address: IPv4Octets
        let prefixLength: Int
    }

    struct IPv4Octets: Hashable, Sendable {
        let a: UInt8
        let b: UInt8
        let c: UInt8
        let d: UInt8

        init?(dotted: String) {
            let parts = dotted.split(separator: ".")
            guard parts.count == 4,
                  let a = UInt8(parts[0]),
                  let b = UInt8(parts[1]),
                  let c = UInt8(parts[2]),
                  let d = UInt8(parts[3]) else {
                return nil
            }
            self.a = a
            self.b = b
            self.c = c
            self.d = d
        }

        var dotted: String { "\(a).\(b).\(c).\(d)" }

        var uint32: UInt32 {
            (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
        }

        init(uint32 value: UInt32) {
            a = UInt8((value >> 24) & 0xFF)
            b = UInt8((value >> 16) & 0xFF)
            c = UInt8((value >> 8) & 0xFF)
            d = UInt8(value & 0xFF)
        }
    }

    static func localIPv4Addresses() -> [String] {
        interfaces().map(\.address.dotted)
    }

    static func isProbeablePrefix(_ prefixLength: Int) -> Bool {
        prefixLength >= 24
    }

    static func probeTargets(excluding selfAddresses: Set<String>) -> [String] {
        var targets = Set<String>()
        for interface in interfaces() {
            guard isProbeablePrefix(interface.prefixLength) else { continue }
            guard isRFC1918(interface.address) else { continue }
            for host in hosts(in: interface) {
                let dotted = host.dotted
                if selfAddresses.contains(dotted) { continue }
                if isNetworkOrBroadcast(host, prefixLength: interface.prefixLength) { continue }
                targets.insert(dotted)
            }
        }
        return targets.sorted { lhs, rhs in
            (IPv4Octets(dotted: lhs)?.uint32 ?? 0) < (IPv4Octets(dotted: rhs)?.uint32 ?? 0)
        }
    }

    static func interfaces() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var addressByName: [String: IPv4Octets] = [:]
        var maskByName: [String: IPv4Octets] = [:]

        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(cursor.pointee.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            guard let addressPointer = cursor.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: cursor.pointee.ifa_name)
            var storage = addressPointer.pointee
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addressLength = socklen_t(addressPointer.pointee.sa_len)
            guard getnameinfo(
                &storage,
                addressLength,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let addressString = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let address = IPv4Octets(dotted: addressString) else { continue }
            addressByName[name] = address

            if let maskPointer = cursor.pointee.ifa_netmask,
               maskPointer.pointee.sa_family == UInt8(AF_INET) {
                var maskStorage = maskPointer.pointee
                var maskBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let maskLength = socklen_t(maskPointer.pointee.sa_len)
                if getnameinfo(
                    &maskStorage,
                    maskLength,
                    &maskBuffer,
                    socklen_t(maskBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let maskString = String(decoding: maskBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if let mask = IPv4Octets(dotted: maskString) {
                        maskByName[name] = mask
                    }
                }
            }
        }

        for (name, address) in addressByName {
            guard let mask = maskByName[name] else { continue }
            guard let prefix = prefixLength(for: mask) else { continue }
            result.append(IPv4Interface(address: address, prefixLength: prefix))
        }

        return result
    }

    static func hosts(in interface: IPv4Interface) -> [IPv4Octets] {
        let mask = mask(forPrefixLength: interface.prefixLength)
        let network = interface.address.uint32 & mask
        let broadcast = network | ~mask
        let hostCount = min(1 << (32 - interface.prefixLength), 256)
        var hosts: [IPv4Octets] = []
        hosts.reserveCapacity(Int(hostCount))
        for offset in 0..<hostCount {
            let value = network + UInt32(offset)
            if value == network || value == broadcast { continue }
            hosts.append(IPv4Octets(uint32: value))
        }
        return hosts
    }

    static func isRFC1918(_ address: IPv4Octets) -> Bool {
        if isTailscaleCGNAT(address) { return false }
        switch address.a {
        case 10:
            return true
        case 172 where (16...31).contains(Int(address.b)):
            return true
        case 192 where address.b == 168:
            return true
        default:
            return false
        }
    }

    static func isTailscaleCGNAT(_ address: IPv4Octets) -> Bool {
        address.a == 100 && (64...127).contains(Int(address.b))
    }

    static func isPublicIPv4(_ address: IPv4Octets) -> Bool {
        !isRFC1918(address) && address.a != 127
    }

    static func isNetworkOrBroadcast(_ address: IPv4Octets, prefixLength: Int) -> Bool {
        let mask = mask(forPrefixLength: prefixLength)
        let network = address.uint32 & mask
        let broadcast = network | ~mask
        return address.uint32 == network || address.uint32 == broadcast
    }

    static func prefixLength(for mask: IPv4Octets) -> Int? {
        let value = mask.uint32
        guard value != 0 else { return nil }
        var length = 0
        var remaining = value
        while (remaining & 0x8000_0000) != 0 {
            length += 1
            remaining <<= 1
        }
        guard remaining == 0 else { return nil }
        return length
    }

    static func mask(forPrefixLength prefixLength: Int) -> UInt32 {
        guard prefixLength >= 0, prefixLength <= 32 else { return 0 }
        if prefixLength == 0 { return 0 }
        return ~(UInt32.max >> prefixLength)
    }
}
