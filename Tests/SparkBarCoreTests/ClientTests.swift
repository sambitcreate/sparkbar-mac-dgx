import Foundation
import Testing
import SparkBarCore

@Suite("SparkDashClient REST behavior", .serialized)
struct ClientTests {
    @Test func connectionTestFetchesSparksAndSettingsInParallel() async throws {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/sparks":
                return (Self.response(status: 200), Data(#"{"sparks":[{"id":"dgx1","name":"DGX1"}]}"#.utf8))
            case "/api/settings":
                return (Self.response(status: 200), Data(#"{"pollIntervalMs":1000,"temperatureUnit":"fahrenheit"}"#.utf8))
            default:
                return (Self.response(status: 404), Data())
            }
        }
        let client = SparkDashClient(endpoint: try SparkDashEndpoint("http://example.test:5555"), session: Self.session())
        let result = try await client.testConnection()
        #expect(result.sparkCount == 1)
        #expect(result.sparks.first?.name == "DGX1")
        #expect(result.settings?.temperatureUnit == "fahrenheit")
        #expect(result.settings?.pollIntervalMs == 1000)
    }

    @Test func connectionTestStillSucceedsWhenSettingsEndpointFails() async throws {
        MockURLProtocol.handler = { request in
            request.url?.path == "/api/sparks"
                ? (Self.response(status: 200), Data(#"{"sparks":[{"id":"dgx1","name":"DGX1"}]}"#.utf8))
                : (Self.response(status: 500), Data())
        }
        let client = SparkDashClient(endpoint: try SparkDashEndpoint("http://example.test:5555"), session: Self.session())
        let result = try await client.testConnection()
        #expect(result.sparkCount == 1)
        #expect(result.settings == nil)
    }

    @Test func connectionTestThrowsOnHTTPError() async throws {
        MockURLProtocol.handler = { _ in (Self.response(status: 503), Data()) }
        let client = SparkDashClient(endpoint: try SparkDashEndpoint("http://example.test:5555"), session: Self.session())
        await #expect(throws: SparkDashClientError.invalidHTTPStatus(503)) {
            _ = try await client.testConnection()
        }
    }

    @Test func connectionTestThrowsOnUnreadablePayload() async throws {
        MockURLProtocol.handler = { _ in (Self.response(status: 200), Data("not json".utf8)) }
        let client = SparkDashClient(endpoint: try SparkDashEndpoint("http://example.test:5555"), session: Self.session())
        await #expect(throws: SparkDashClientError.invalidPayload) {
            _ = try await client.testConnection()
        }
    }

    @Test func pollSnapshotFetchesMetricsForEachSparkAndSkipsFailures() async throws {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/sparks/dgx1/metrics":
                return (Self.response(status: 200), Data(#"{"id":"dgx1","name":"DGX1","online":true}"#.utf8))
            case "/api/sparks/dgx2/metrics":
                return (Self.response(status: 404), Data())
            default:
                return (Self.response(status: 404), Data())
            }
        }
        let client = SparkDashClient(endpoint: try SparkDashEndpoint("http://example.test:5555"), session: Self.session())
        let envelope = try await client.pollSnapshot(sparkIDs: ["dgx1", "dgx2"])
        #expect(envelope.sparks.count == 1)
        #expect(envelope.sparks.first?.id == "dgx1")
        #expect(envelope.sparks.first?.isOnline == true)
    }

    static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://example.test")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
