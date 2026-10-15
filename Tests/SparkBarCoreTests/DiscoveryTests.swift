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
}
