import Foundation

public enum SparkDashEndpointError: Error, Equatable, LocalizedError, Sendable {
    case missingURL
    case unsupportedScheme(String)
    case missingHost

    public var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Enter a sparkDash URL."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme). Use http, https, ws, or wss."
        case .missingHost:
            return "The sparkDash URL must include a host."
        }
    }
}

public struct SparkDashEndpoint: Equatable, Sendable {
    public let baseURL: URL

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsedURL = URL(string: trimmed) else {
            throw SparkDashEndpointError.missingURL
        }
        guard let scheme = parsedURL.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme) else {
            throw SparkDashEndpointError.unsupportedScheme(parsedURL.scheme ?? "")
        }
        guard parsedURL.host != nil else {
            throw SparkDashEndpointError.missingHost
        }

        var components = URLComponents(url: parsedURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        // Credentials embedded in the URL never leave this init; the endpoint
        // is persisted and logged, so userinfo must not survive normalization.
        components?.user = nil
        components?.password = nil
        if components?.path == "/" {
            components?.path = ""
        } else if let path = components?.path, path.hasSuffix("/") {
            components?.path = String(path.dropLast())
        }
        guard let normalizedURL = components?.url else {
            throw SparkDashEndpointError.missingURL
        }
        baseURL = normalizedURL
    }

    public var displayString: String { baseURL.absoluteString }

    public var usesSecureTransport: Bool {
        let scheme = baseURL.scheme?.lowercased()
        return scheme == "https" || scheme == "wss"
    }

    public var isLikelyPrivateHost: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            if host == "::1" { return true }
            // fc00::/7 unique local and fe80::/10 link local.
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9")
                || host.hasPrefix("fea") || host.hasPrefix("feb") { return true }
            return false
        }
        guard let address = IPv4Address(host) else { return false }
        switch address.octets {
        case (10, _, _, _), (127, _, _, _), (192, 168, _, _), (172, 16...31, _, _), (100, 64...127, _, _):
            return true
        default:
            return false
        }
    }

    public var shouldWarnAboutInsecureRemote: Bool {
        !usesSecureTransport && !isLikelyPrivateHost
    }

    public var apiBaseURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = httpScheme(for: components.scheme)
        return components.url!
    }

    public func apiURL(path: String) -> URL {
        appendPath(path, to: apiBaseURL)
    }

    public var webSocketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = webSocketScheme(for: components.scheme)
        components.path = joinPath(components.path, "/ws")
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private func appendPath(_ path: String, to url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = joinPath(components.path, path)
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private func joinPath(_ left: String, _ right: String) -> String {
        let left = left.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = right.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joined = [left, right].filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "/" : "/\(joined)"
    }

    private func httpScheme(for scheme: String?) -> String {
        scheme?.lowercased() == "https" || scheme?.lowercased() == "wss" ? "https" : "http"
    }

    private func webSocketScheme(for scheme: String?) -> String {
        scheme?.lowercased() == "https" || scheme?.lowercased() == "wss" ? "wss" : "ws"
    }
}

private struct IPv4Address {
    let octets: (Int, Int, Int, Int)

    init?(_ value: String) {
        let components = value.split(separator: ".").compactMap { Int($0) }
        guard components.count == 4, components.allSatisfy({ (0...255).contains($0) }) else { return nil }
        octets = (components[0], components[1], components[2], components[3])
    }
}
