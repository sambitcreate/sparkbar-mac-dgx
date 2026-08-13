import Testing
import SparkBarCore

@Suite("SparkDash endpoint")
struct EndpointTests {
    @Test func normalizesHTTPAndDerivesWebSocket() throws {
        let endpoint = try SparkDashEndpoint(" http://100.101.194.105:5555/ ")
        #expect(endpoint.displayString == "http://100.101.194.105:5555")
        #expect(endpoint.apiURL(path: "/api/sparks").absoluteString == "http://100.101.194.105:5555/api/sparks")
        #expect(endpoint.webSocketURL.absoluteString == "ws://100.101.194.105:5555/ws")
        #expect(endpoint.isLikelyPrivateHost)
        #expect(!endpoint.shouldWarnAboutInsecureRemote)
    }

    @Test func preservesReverseProxyPathAndMapsHTTPS() throws {
        let endpoint = try SparkDashEndpoint("https://example.test/monitor/?ignored=yes#fragment")
        #expect(endpoint.apiURL(path: "/api/sparks").absoluteString == "https://example.test/monitor/api/sparks")
        #expect(endpoint.webSocketURL.absoluteString == "wss://example.test/monitor/ws")
    }

    @Test func acceptsWebSocketInputForms() throws {
        let ws = try SparkDashEndpoint("ws://spark.local:5555")
        let wss = try SparkDashEndpoint("wss://spark.local:5555")
        #expect(ws.apiURL(path: "/api/sparks").scheme == "http")
        #expect(wss.apiURL(path: "/api/sparks").scheme == "https")
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
        #expect(endpoint.apiURL(path: "/api/sparks").absoluteString == "http://10.0.0.5:5555/api/sparks")
    }

    @Test func detectsPrivateIPv6Hosts() throws {
        #expect(try SparkDashEndpoint("http://[::1]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[fc00::7]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[fd12:3456::1]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[fe80::1]:5555").isLikelyPrivateHost)
        #expect(try SparkDashEndpoint("http://[febf::1]:5555").isLikelyPrivateHost)
        #expect(!(try SparkDashEndpoint("http://[2001:db8::1]:5555").isLikelyPrivateHost))
    }
}
