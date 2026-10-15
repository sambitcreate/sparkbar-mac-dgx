import Foundation
import Network

/// Optional Tailscale LocalAPI client. Lists tailnet peers so Scan can probe
/// those IPs only — it never sweeps CGNAT `100.64/10`.
public enum TailscaleLocalAPI {
    public static let statusPath = "/localapi/v0/status"
    public static let maxPeers = 48
    private static let maxStatusResponseBytes = 8 * 1024 * 1024

    public struct PeerTarget: Equatable, Sendable {
        public var name: String
        public var ipv4: String

        public init(name: String, ipv4: String) {
            self.name = name
            self.ipv4 = ipv4
        }
    }

    public struct Credentials: Equatable, Sendable {
        public var port: Int
        public var token: String

        public init(port: Int, token: String) {
            self.port = port
            self.token = token
        }
    }

    /// Parses `GET /localapi/v0/status` JSON and returns online peer IPv4s, excluding Self.
    public static func peerTargets(fromStatusJSON data: Data) throws -> [PeerTarget] {
        let status = try JSONDecoder().decode(Status.self, from: data)
        let selfIPs = Set((status.selfNode?.tailscaleIPs ?? []).compactMap(ipv4Address))
        var targets: [PeerTarget] = []
        var seen = Set<String>()

        let peers = (status.peer ?? [:]).values.sorted { lhs, rhs in
            (lhs.hostName ?? lhs.dnsName ?? "") < (rhs.hostName ?? rhs.dnsName ?? "")
        }

        for peer in peers {
            if peer.online == false { continue }
            let name = displayName(peer)
            for raw in peer.tailscaleIPs ?? [] {
                guard let ipv4 = ipv4Address(raw) else { continue }
                guard LocalNetworkEnumeration.IPv4Octets(dotted: ipv4).map(LocalNetworkEnumeration.isTailscaleCGNAT) == true else {
                    continue
                }
                if selfIPs.contains(ipv4) { continue }
                if seen.insert(ipv4).inserted == false { continue }
                targets.append(PeerTarget(name: name, ipv4: ipv4))
                if targets.count >= maxPeers { return targets }
            }
        }
        return targets
    }

    /// `sameuserproof-<port>-<token>` (App Store) or `sameuserproof-<port>` (macsys).
    public static func parseSameUserProofFileName(_ name: String) -> (port: Int, token: String?)? {
        let prefix = "sameuserproof-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        let parts = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let port = Int(parts[0]), port > 0, port <= 65_535 else { return nil }
        if parts.count == 2 {
            let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (port, token.isEmpty ? nil : token)
        }
        return (port, nil)
    }

    public static func credentials(inDirectory url: URL, fileManager: FileManager = .default) -> Credentials? {
        if let fromLink = macsysCredentials(in: url, fileManager: fileManager) {
            return fromLink
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else { return nil }
        for name in entries {
            guard let parsed = parseSameUserProofFileName(name), let token = parsed.token else { continue }
            return Credentials(port: parsed.port, token: token)
        }
        return nil
    }

    public static func discoverCredentials(fileManager: FileManager = .default) -> Credentials? {
        for directory in candidateDirectories(fileManager: fileManager) {
            if let credentials = credentials(inDirectory: directory, fileManager: fileManager) {
                return credentials
            }
        }
        return nil
    }

    public static func unixSocketPaths(fileManager: FileManager = .default) -> [String] {
        [
            "/var/run/tailscaled.socket",
            "/var/run/tailscale/tailscaled.sock",
            "/var/run/tailscale/tailscaled.socket",
        ].filter { fileManager.fileExists(atPath: $0) }
    }

    static func fetchStatus(
        session: URLSession,
        isCancelled: @Sendable () -> Bool
    ) async -> Data? {
        if isCancelled() { return nil }
        if let credentials = discoverCredentials() {
            if let data = await fetchStatusOverLoopback(credentials: credentials, session: session) {
                return data
            }
        }
        if isCancelled() { return nil }
        for path in unixSocketPaths() {
            if isCancelled() { return nil }
            if let data = await fetchStatusOverUnixSocket(path: path, timeout: 1.5) {
                return data
            }
        }
        return nil
    }

    static func fetchPeerTargets(
        session: URLSession,
        isCancelled: @Sendable () -> Bool
    ) async -> [PeerTarget] {
        guard let data = await fetchStatus(session: session, isCancelled: isCancelled) else { return [] }
        return (try? peerTargets(fromStatusJSON: data)) ?? []
    }

    private static func fetchStatusOverLoopback(credentials: Credentials, session: URLSession) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(credentials.port)\(statusPath)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("local-tailscaled.sock", forHTTPHeaderField: "Host")
        let raw = Data((":" + credentials.token).utf8)
        request.setValue("Basic \(raw.base64EncodedString())", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func fetchStatusOverUnixSocket(path: String, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = Data("GET \(statusPath) HTTP/1.0\r\nHost: local-tailscaled.sock\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil {
                            connection.cancel()
                            box.complete(with: nil)
                            return
                        }
                        receiveHTTPBody(on: connection, buffer: Data(), box: box)
                    })
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

    private static func receiveHTTPBody(on connection: NWConnection, buffer: Data, box: ResumeBox<Data?>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
            if error != nil {
                connection.cancel()
                box.complete(with: nil)
                return
            }
            var next = buffer
            if let content { next.append(content) }
            if next.count > maxStatusResponseBytes {
                connection.cancel()
                box.complete(with: nil)
                return
            }
            if let body = httpBody(from: next, isComplete: isComplete) {
                box.complete(with: body)
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                box.complete(with: nil)
                return
            }
            receiveHTTPBody(on: connection, buffer: next, box: box)
        }
    }

    /// Returns a body only after it is complete and the response status is successful.
    /// Without a length header, completion is defined by EOF.
    static func httpBody(from response: Data, isComplete: Bool = true) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else { return nil }
        guard let header = String(data: response[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/"),
              let status = Int(statusParts[1]),
              (200...299).contains(status) else { return nil }

        var contentLength: Int?
        var chunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "content-length" {
                guard let length = Int(value), length >= 0, length <= maxStatusResponseBytes,
                      contentLength == nil || contentLength == length else { return nil }
                contentLength = length
            } else if name == "transfer-encoding" {
                chunked = value.lowercased().split(separator: ",").last?.trimmingCharacters(in: .whitespacesAndNewlines) == "chunked"
            }
        }

        let body = Data(response[range.upperBound...])
        if chunked { return decodedChunkedBody(body) }
        if let contentLength {
            guard body.count >= contentLength else { return nil }
            return Data(body.prefix(contentLength))
        }
        return isComplete ? body : nil
    }

    private static func decodedChunkedBody(_ body: Data) -> Data? {
        let lineBreak = Data("\r\n".utf8)
        let trailerEnd = Data("\r\n\r\n".utf8)
        var cursor = body.startIndex
        var decoded = Data()
        while cursor < body.endIndex {
            guard let lineRange = body.range(of: lineBreak, in: cursor..<body.endIndex),
                  let line = String(data: body[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let sizeText = line.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0,
                  size <= maxStatusResponseBytes - decoded.count else { return nil }
            cursor = lineRange.upperBound
            if size == 0 {
                if body.range(of: lineBreak, in: cursor..<body.endIndex)?.lowerBound == cursor {
                    return decoded
                }
                guard body.range(of: trailerEnd, in: cursor..<body.endIndex) != nil else { return nil }
                return decoded
            }
            guard body.endIndex - cursor >= size + 2 else { return nil }
            decoded.append(body[cursor..<(cursor + size)])
            cursor += size
            guard body[cursor..<(cursor + 2)] == lineBreak else { return nil }
            cursor += 2
        }
        return nil
    }

    private static func macsysCredentials(in directory: URL, fileManager: FileManager) -> Credentials? {
        let portLink = directory.appendingPathComponent("ipnport")
        guard let portString = try? fileManager.destinationOfSymbolicLink(atPath: portLink.path),
              let port = Int(portString), port > 0 else {
            return nil
        }
        let tokenPath = directory.appendingPathComponent("sameuserproof-\(portString)")
        guard let raw = fileManager.contents(atPath: tokenPath.path),
              let token = String(data: raw, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return Credentials(port: port, token: token)
    }

    private static func candidateDirectories(fileManager: FileManager) -> [URL] {
        var urls: [URL] = [URL(fileURLWithPath: "/Library/Tailscale", isDirectory: true)]
        let home = fileManager.homeDirectoryForCurrentUser
        let groupRoot = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        if let groups = try? fileManager.contentsOfDirectory(atPath: groupRoot.path) {
            for name in groups where name.lowercased().contains("tailscale") {
                urls.append(groupRoot.appendingPathComponent(name, isDirectory: true))
            }
        }
        return urls
    }

    private static func displayName(_ peer: Peer) -> String {
        let host = peer.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !host.isEmpty { return host }
        let dns = peer.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces)) ?? ""
        if !dns.isEmpty { return dns }
        return "Tailscale peer"
    }

    private static func ipv4Address(_ raw: String) -> String? {
        let host = raw.split(separator: "/").first.map(String.init) ?? raw
        guard let octets = LocalNetworkEnumeration.IPv4Octets(dotted: host) else { return nil }
        return octets.dotted
    }

    private struct Status: Decodable {
        var selfNode: Peer?
        var peer: [String: Peer]?

        enum CodingKeys: String, CodingKey {
            case selfNode = "Self"
            case peer = "Peer"
        }
    }

    private struct Peer: Decodable {
        var hostName: String?
        var dnsName: String?
        var online: Bool?
        var tailscaleIPs: [String]?

        enum CodingKeys: String, CodingKey {
            case hostName = "HostName"
            case dnsName = "DNSName"
            case online = "Online"
            case tailscaleIPs = "TailscaleIPs"
        }
    }
}
