import Testing
import SparkBarCore

@Suite("SparkDash endpoint")
struct EndpointTests {
    @Test func normalizesHTTPAndDerivesWebSocket() throws {
        let endpoint = try SparkDashEndpoint(" http://100.101.194.105:5555/ ")
        #expect(endpoint.displayString == "http://100.101.194.105:5555")
        #expect(try endpoint.apiURL(path: "/api/sparks").absoluteString == "http://100.101.194.105:5555/api/sparks")
        #expect(endpoint.webSocketURL.absoluteString == "ws://100.101.194.105:5555/ws")
        #expect(endpoint.isLikelyPrivateHost)
        #expect(!endpoint.shouldWarnAboutInsecureRemote)
    }

    @Test func preservesReverseProxyPathAndMapsHTTPS() throws {
        let endpoint = try SparkDashEndpoint("https://example.test/monitor/?ignored=yes#fragment")
        #expect(try endpoint.apiURL(path: "/api/sparks").absoluteString == "https://example.test/monitor/api/sparks")
        #expect(endpoint.webSocketURL.absoluteString == "wss://example.test/monitor/ws")
    }

    @Test func acceptsWebSocketInputForms() throws {
        let ws = try SparkDashEndpoint("ws://spark.local:5555")
        let wss = try SparkDashEndpoint("wss://spark.local:5555")
        #expect(try ws.apiURL(path: "/api/sparks").scheme == "http")
        #expect(try wss.apiURL(path: "/api/sparks").scheme == "https")
        #expect(ws.webSocketURL.scheme == "ws")
        #expect(wss.webSocketURL.scheme == "wss")
    }

    @Test func rejectsUnsupportedAndMissingURLs() {
        #expect(throws: SparkDashEndpointError.unsupportedScheme("ftp")) {
            try SparkDashEndpoint("ftp://example.test")
        }
        #expect(throws: SparkDashEndpointError.missingURL) {
            try SparkDashEndpoint(" ")
        }
    }

    @Test func stripsEmbeddedCredentialsFromNormalizedURL() throws {
        let endpoint = try SparkDashEndpoint("http://user:secret@10.0.0.5:5555")
        #expect(endpoint.displayString == "http://10.0.0.5:5555")
        #expect(try endpoint.apiURL(path: "/api/sparks").absoluteString == "http://10.0.0.5:5555/api/sparks")
    }

    @Test func detectsPrivateIPv6Hosts() throws {
        #expect(try SparkDashEndpoint("http://[::1]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[fc00::7]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[fd12:3456::1]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[fe80::1]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[febf::1]:5555").isLikelyPrivateHost)
        #expect(!(try SparkDashEndpoint("http://[2001:db8::1]:5555").isLikelyPrivateHost))
    }

    /// A host that percent-decodes to an embedded space or colon parses via
    /// `URL(string:)` but cannot be re-serialized once the scheme is rewritten.
    /// That used to force-unwrap to nil and trap the process on the first
    /// request. It must now be reported as an error instead.
    @Test func rejectsHostsThatCannotBeReSerialized() {
        for host in ["exa%20mple.com", "spark%00.local", "spark%3A5555.local"] {
            #expect(throws: SparkDashEndpointError.self) {
                try SparkDashEndpoint("http://\(host):5555")
            }
        }
    }

    /// Valid hosts must keep working, including link-local and CGNAT ranges
    /// that are treated as local for the insecure-remote warning.
    @Test func acceptsOrdinaryAndLiteralHosts() throws {
        #expect(try SparkDashEndpoint("http://192.168.1.10:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://10.0.0.5:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://172.16.0.5:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://169.254.1.5:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://spark.local:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://spark_local:5555").isLikelyPrivateHost == false)
    }

    /// Spark identifiers come from the server's own Spark list, so they are
    /// untrusted: they must be encoded as a single path component.
    @Test func buildsMetricsURLFromASinglePathComponent() throws {
        let endpoint = try SparkDashEndpoint("http://10.0.0.5:5555")
        #expect(
            try endpoint.metricsURL(sparkID: "dgx1").absoluteString
                == "http://10.0.0.5:5555/api/sparks/dgx1/metrics"
        )
        #expect(
            try endpoint.metricsURL(sparkID: "dgx 1").absoluteString
                == "http://10.0.0.5:5555/api/sparks/dgx%201/metrics"
        )
    }

    @Test func refusesTraversingSparkIdentifiers() throws {
        let endpoint = try SparkDashEndpoint("http://10.0.0.5:5555")
        for id in ["../../admin", "..", "a/b", "a\\b", "a?b", "a#b", "a%b", "", "   ", "a\nb"] {
            #expect(throws: SparkDashEndpointError.self) {
                try endpoint.metricsURL(sparkID: id)
            }
        }
    }

    /// The identifier never reaches the request path as raw dot segments.
    @Test func metricsURLKeepsRequestsInsideTheSparksPrefix() throws {
        let endpoint = try SparkDashEndpoint("http://10.0.0.5:5555")
        let url = try endpoint.metricsURL(sparkID: "dgx-1")
        #expect(url.path.hasPrefix("/api/sparks/"))
        #expect(!url.path.contains(".."))
        #expect(url.path.hasSuffix("/metrics"))
    }
}
