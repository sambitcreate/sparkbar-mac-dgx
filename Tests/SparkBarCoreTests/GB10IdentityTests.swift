import Foundation
import Testing
import SparkBarCore

@Suite("GB10 identity")
struct GB10IdentityTests {
    @Test func missingOrSparkKindMatchesAsKindSpark() {
        #expect(GB10Identity.match(kind: nil, name: "Anything", id: "x", hardware: nil)?.confidence == .kindSpark)
        #expect(GB10Identity.match(kind: "spark", name: "DGX", id: "dgx1", hardware: nil)?.confidence == .kindSpark)
        #expect(GB10Identity.match(kind: "SPARK", name: nil, id: nil, hardware: nil)?.family == "GB10")
    }

    @Test(arguments: [
        ("Ascent GX10 workstation", "ASUS Ascent GX10"),
        ("GX10 lab unit", "GX10"),
        ("Veriton GN100", "Acer Veriton GN100"),
        ("GN100 node", "GN100"),
        ("VGN100 desk", "VGN100"),
        ("ThinkStation PGX", "Lenovo ThinkStation PGX"),
        ("NVIDIA GB10 Workstation", "NVIDIA GB10"),
        ("ZGX Nano cluster", "ZGX Nano"),
        ("PGX rack node", "PGX"),
        ("MS-C931 edge", "MS-C931"),
        ("Project DIGITS dev kit", "Project DIGITS"),
        ("Founder's Edition unit", "Founder's Edition"),
        ("FusionXpark appliance", "FusionXpark"),
        ("EdgeXpert box", "EdgeXpert"),
        ("MegaCube server", "MegaCube"),
        ("LinSeer node", "LinSeer"),
        ("FCM1253 reference", "FCM1253"),
        ("ATAGB10 OEM", "ATAGB10"),
        ("30KL SKU", "30KL"),
        ("30KM SKU", "30KM"),
    ])
    func hostAliasTable(name: String, expectedHint: String) {
        let match = GB10Identity.match(kind: "host", name: name, id: nil, hardware: nil)
        #expect(match?.family == "GB10")
        #expect(match?.confidence == .alias)
        #expect(match?.vendorHint == expectedHint)
    }

    @Test func hostChipSignalsMatch() throws {
        let hardware = try decodeHardware("""
        {"device":"OEM box","cpuModel":"NVIDIA GB10","gpuChip":"GB10"}
        """)
        let match = GB10Identity.match(kind: "host", name: "generic-host", id: "h1", hardware: hardware)
        #expect(match?.confidence == .chip)
        #expect(match?.vendorHint == "GB10")
    }

    @Test func rtxHostDoesNotMatch() throws {
        let hardware = try decodeHardware("""
        {"device":"RTX workstation","cpuModel":"AMD Ryzen","gpuChip":"NVIDIA GeForce RTX 4090"}
        """)
        #expect(GB10Identity.match(kind: "host", name: "RTX Box", id: "rtx-1", hardware: hardware) == nil)
    }

    @Test func weakHostTokensAloneDoNotMatch() {
        #expect(GB10Identity.match(kind: "host", name: "dgx spark gpu nano atom", id: "gpu-host", hardware: nil) == nil)
        #expect(GB10Identity.match(kind: "host", name: "spark", id: "nano", hardware: nil) == nil)
    }

    @Test func snapshotLiveSparkMatchesKindSpark() throws {
        let envelope = try TestFixtures.decodeEnvelope("snapshot-live")
        let spark = try #require(envelope.sparks.first)
        let match = GB10Identity.match(
            kind: spark.kind,
            name: spark.name,
            id: spark.id,
            hardware: spark.hardware
        )
        #expect(match?.family == "GB10")
        #expect(match?.confidence == .kindSpark)
    }

    private func decodeHardware(_ json: String) throws -> HardwareInfo {
        try JSONDecoder().decode(HardwareInfo.self, from: Data(json.utf8))
    }
}
