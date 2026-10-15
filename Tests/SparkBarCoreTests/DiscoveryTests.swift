import Foundation
import Testing
@testable import SparkBarCore

@Suite("SparkDash discovery")
struct DiscoveryTests {
    @Test func deduplicatesByDisplayURL() {
        let hits = [
            SparkDashDiscoveryHit(id: "a", name: "A", displayURL: "http://192.168.1.10:5555", source: .probe),
            SparkDashDiscoveryHit(id: "b", name: "B", displayURL: "HTTP://192.168.1.10:5555", source: .mdns),
            SparkDashDiscoveryHit(id: "c", name: "C", displayURL: "http://192.168.1.11:5555", source: .probe),
        ]
        let unique = SparkDashScanner.deduplicate(hits)
        #expect(unique.count == 2)
        #expect(unique.map(\.displayURL).contains("http://192.168.1.10:5555"))
        #expect(unique.map(\.displayURL).contains("http://192.168.1.11:5555"))
    }

    @Test func classifiesRFC1918Addresses() {
        typealias IP = LocalNetworkEnumeration.IPv4Octets
        #expect(LocalNetworkEnumeration.isRFC1918(IP(dotted: "10.0.0.5")!))
        #expect(LocalNetworkEnumeration.isRFC1918(IP(dotted: "172.16.4.2")!))
        #expect(LocalNetworkEnumeration.isRFC1918(IP(dotted: "192.168.50.1")!))
        #expect(!LocalNetworkEnumeration.isRFC1918(IP(dotted: "8.8.8.8")!))
        #expect(!LocalNetworkEnumeration.isRFC1918(IP(dotted: "127.0.0.1")!))
    }

    @Test func excludesTailscaleCGNATFromRFC1918Scanning() {
        typealias IP = LocalNetworkEnumeration.IPv4Octets
        #expect(LocalNetworkEnumeration.isTailscaleCGNAT(IP(dotted: "100.64.0.1")!))
        #expect(LocalNetworkEnumeration.isTailscaleCGNAT(IP(dotted: "100.127.255.2")!))
        #expect(!LocalNetworkEnumeration.isRFC1918(IP(dotted: "100.64.0.1")!))
        #expect(LocalNetworkEnumeration.isPublicIPv4(IP(dotted: "100.64.0.1")!))
    }

    @Test func enumeratesSlash24HostsExcludingNetworkBroadcastAndSelf() {
        let interface = LocalNetworkEnumeration.IPv4Interface(
            address: LocalNetworkEnumeration.IPv4Octets(dotted: "192.168.1.42")!,
            prefixLength: 24
        )
        let hosts = LocalNetworkEnumeration.hosts(in: interface).map(\.dotted)
        #expect(hosts.count == 254)
        #expect(!hosts.contains("192.168.1.0"))
        #expect(!hosts.contains("192.168.1.255"))
        #expect(hosts.contains("192.168.1.42"))

        let filtered = hosts.filter { $0 != "192.168.1.42" }
        #expect(filtered.contains("192.168.1.10"))
        #expect(!filtered.contains("192.168.1.42"))
    }

    @Test func skipsWideSubnetsInProbeTargets() {
        #expect(!LocalNetworkEnumeration.isProbeablePrefix(16))
        #expect(!LocalNetworkEnumeration.isProbeablePrefix(23))
        #expect(LocalNetworkEnumeration.isProbeablePrefix(24))
        #expect(LocalNetworkEnumeration.isProbeablePrefix(32))
    }

    @Test func cancelStopsActiveScan() async {
        let scanner = SparkDashScanner()
        let scanTask = Task {
            await scanner.scan()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await scanner.cancel()
        scanTask.cancel()
        let result = await scanTask.value
        switch result {
        case .failure(let error):
            #expect(error as? SparkDashDiscoveryError == .cancelled)
        case .success:
            Issue.record("Expected scan to fail after cancel()")
        }
    }

    @Test func parsesSameUserProofFileNames() {
        let named = TailscaleLocalAPI.parseSameUserProofFileName("sameuserproof-41234-deadbeef42")
        #expect(named?.port == 41234)
        #expect(named?.token == "deadbeef42")
        let macsys = TailscaleLocalAPI.parseSameUserProofFileName("sameuserproof-55512")
        #expect(macsys?.port == 55512)
        #expect(macsys?.token == nil)
        #expect(TailscaleLocalAPI.parseSameUserProofFileName("ipnport") == nil)
    }

    @Test func extractsOnlineTailnetPeersAndSkipsSelf() throws {
        let json = """
        {
          "Self": {
            "HostName": "macbook",
            "TailscaleIPs": ["100.64.1.1", "fd7a:115c::1"]
          },
          "Peer": {
            "nodekey:a": {
              "HostName": "dgx-spark",
              "DNSName": "dgx-spark.tailnet.ts.net.",
              "Online": true,
              "TailscaleIPs": ["100.101.194.105/32", "fd7a:115c::2"]
            },
            "nodekey:b": {
              "HostName": "offline-box",
              "Online": false,
              "TailscaleIPs": ["100.64.9.9"]
            },
            "nodekey:c": {
              "HostName": "lan-relay",
              "Online": true,
              "TailscaleIPs": ["192.168.1.20"]
            }
          }
        }
        """.data(using: .utf8)!
        let peers = try TailscaleLocalAPI.peerTargets(fromStatusJSON: json)
        #expect(peers == [TailscaleLocalAPI.PeerTarget(name: "dgx-spark", ipv4: "100.101.194.105")])
    }

    @Test func splitsHTTPBodyAfterHeaders() {
        let payload = Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(String(data: TailscaleLocalAPI.httpBody(from: payload) ?? Data(), encoding: .utf8) == "{}")
    }

    @Test func waitsForWholeHTTPBodyAndChecksStatus() {
        let headers = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n"
        #expect(TailscaleLocalAPI.httpBody(from: Data((headers + "abc").utf8), isComplete: false) == nil)
        #expect(TailscaleLocalAPI.httpBody(from: Data((headers + "abc").utf8), isComplete: true) == nil)
        #expect(String(data: TailscaleLocalAPI.httpBody(from: Data((headers + "abcdef").utf8), isComplete: false) ?? Data(), encoding: .utf8) == "abcdef")
        #expect(TailscaleLocalAPI.httpBody(from: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}".utf8)) == nil)
        #expect(TailscaleLocalAPI.httpBody(from: Data("HTTP/1.1 200 OK\r\n\r\n{}".utf8), isComplete: false) == nil)
        #expect(TailscaleLocalAPI.httpBody(from: Data("HTTP/1.1 200 OK\r\n\r\n{}".utf8), isComplete: true) == Data("{}".utf8))
    }

    @Test func decodesChunkedHTTPBodyOnlyWhenComplete() {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        #expect(TailscaleLocalAPI.httpBody(from: Data(response.dropLast(2).utf8), isComplete: false) == nil)
        #expect(TailscaleLocalAPI.httpBody(from: Data(response.utf8), isComplete: false) == Data("{}".utf8))
    }

    @Test func buildsIPv6URLAndRejectsMalformedKnownHosts() {
        #expect(SparkDashScanner.baseURL(host: "fe80::1", port: 5555)?.absoluteString == "http://[fe80::1]:5555")
        #expect(SparkDashScanner.baseURL(host: "fe80::1%en0", port: 5555)?.absoluteString == "http://[fe80::1%25en0]:5555")
        #expect(SparkDashScanner.baseURL(host: "[::1]", port: 8000)?.absoluteString == "http://[::1]:8000")
        #expect(SparkDashScanner.baseURL(host: "spark.local", port: 7777)?.absoluteString == "http://spark.local:7777")
        #expect(SparkDashScanner.baseURL(host: "host.local/path", port: 5555) == nil)
        #expect(SparkDashScanner.baseURL(host: "user@host.local", port: 5555) == nil)
        #expect(SparkDashScanner.baseURL(host: "host.local:5555", port: 5555) == nil)
        #expect(SparkDashScanner.baseURL(host: "999.999.999.999", port: 5555) == nil)
        #expect(SparkDashScanner.baseURL(host: "host.local", port: 0) == nil)
    }

    @Test func validatesBonjourCandidateThroughSparkDashAPI() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            DiscoveryMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let baseURL = URL(string: "http://[::1]:5555")!
        let isCancelled: @Sendable () -> Bool = { false }

        DiscoveryMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sparks")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"sparks":[{"id":"one","name":"DGX"}]}"#.utf8))
        }
        let valid = await SparkDashScanner.validateSparkDash(at: baseURL, preferredName: "Advertised SparkDash", session: session, source: .mdns, isCancelled: isCancelled)
        #expect(valid?.displayURL == "http://[::1]:5555")
        #expect(valid?.name == "Advertised SparkDash")
        #expect(valid?.sparkCount == 1)

        DiscoveryMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"unrelated":true}"#.utf8))
        }
        let unrelated = await SparkDashScanner.validateSparkDash(at: baseURL, session: session, source: .mdns, isCancelled: isCancelled)
        #expect(unrelated == nil)
    }
}

private final class DiscoveryMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
