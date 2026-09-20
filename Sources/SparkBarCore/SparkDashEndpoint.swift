import Foundation

public enum SparkDashEndpointError: Error, Equatable, LocalizedError, Sendable {
    case missingURL
    case unsupportedScheme(String)
    case missingHost
    /// The URL parsed but could not be re-serialized after normalization. The
    /// associated value is the sanitized endpoint string and never contains
    /// embedded credentials.
    case unusableURL(String)
    /// A server-supplied Spark identifier could not be used as a single path
    /// component.
    case invalidSparkIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Enter a sparkDash URL."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme). Use http, https, ws, or wss."
        case .missingHost:
            return "The sparkDash URL must include a host."
        case .unusableURL(let value):
            return "The sparkDash URL could not be used as entered: \(value)"
        case .invalidSparkIdentifier(let value):
            return "sparkDash returned a Spark identifier that cannot be requested safely: \(value)"
        }
    }
}

public struct SparkDashEndpoint: Equatable, Sendable {
    public let baseURL: URL

    /// Derived URLs are built and validated once here rather than on every
    /// request. `URL(string:)` accepts hosts that `URLComponents` cannot
    /// re-serialize after the scheme is rewritten — for example a host that
    /// percent-decodes to an embedded space, such as
    /// `http://exa%20mple.com:5555`. Force-unwrapping that result used to trap
    /// the process the moment a request or `openSparkDash()` was attempted.
    private let apiBase: URL
    private let socketURL: URL

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

        let sanitized = normalizedURL.absoluteString
        guard let apiBase = Self.derivedURL(
            from: normalizedURL,
            scheme: Self.httpScheme(for: scheme),
            appendingPath: nil
        ), let socketURL = Self.derivedURL(
            from: normalizedURL,
            scheme: Self.webSocketScheme(for: scheme),
            appendingPath: "/ws"
        ) else {
            throw SparkDashEndpointError.unusableURL(sanitized)
        }

        self.baseURL = normalizedURL
        self.apiBase = apiBase
        self.socketURL = socketURL
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
        case (10, _, _, _), (127, _, _, _), (192, 168, _, _), (172, 16...31, _, _),
             // Tailscale uses the CGNAT range; link-local is never a remote host.
             (100, 64...127, _, _), (169, 254, _, _):
            return true
        default:
            return false
        }
    }

    public var shouldWarnAboutInsecureRemote: Bool {
        !usesSecureTransport && !isLikelyPrivateHost
    }

    public var apiBaseURL: URL { apiBase }

    public var webSocketURL: URL { socketURL }

    public func apiURL(path: String) throws -> URL {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)
        let currentPath = components?.path ?? ""
        components?.path = Self.joinPath(currentPath, path)
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else {
            throw SparkDashEndpointError.unusableURL(apiBase.absoluteString)
        }
        return url
    }

    /// The per-Spark metrics endpoint. The identifier is supplied by the
    /// server's own Spark list, so it is untrusted input: it is encoded as a
    /// single path component and rejected outright if it could traverse or
    /// otherwise re-shape the request path.
    public func metricsURL(sparkID: String) throws -> URL {
        guard let component = Self.pathComponent(sparkID) else {
            throw SparkDashEndpointError.invalidSparkIdentifier(sparkID)
        }
        // The identifier is already percent-encoded, so the path is assembled
        // from encoded pieces. Assigning to `path` here would encode the `%`
        // again and send a double-escaped identifier.
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)
        let prefix = (components?.percentEncodedPath ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = ["api", "sparks", component, "metrics"].joined(separator: "/")
        components?.percentEncodedPath = "/" + (prefix.isEmpty ? suffix : "\(prefix)/\(suffix)")
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else {
            throw SparkDashEndpointError.unusableURL(apiBase.absoluteString)
        }
        return url
    }

    /// Percent-encodes a value for use as exactly one path component. Returns
    /// nil when the value cannot be represented safely. The value is encoded
    /// verbatim so the request names the same Spark the server reported.
    public static func pathComponent(_ value: String) -> String? {
        guard !value.isEmpty, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard !value.contains(".."),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("?"),
              !value.contains("#"),
              !value.contains("%"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?\\#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func derivedURL(from url: URL, scheme: String, appendingPath path: String?) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        if let path {
            let currentPath = components?.path ?? ""
            components?.path = joinPath(currentPath, path)
        }
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private static func joinPath(_ left: String, _ right: String) -> String {
        let left = left.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = right.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joined = [left, right].filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "/" : "/\(joined)"
    }

    private static func httpScheme(for scheme: String?) -> String {
        scheme?.lowercased() == "https" || scheme?.lowercased() == "wss" ? "https" : "http"
    }

    private static func webSocketScheme(for scheme: String?) -> String {
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
