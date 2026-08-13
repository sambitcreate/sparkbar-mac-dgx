import Foundation
import Testing
import SparkBarCore

@Suite("sparkDash network and ComfyUI decoding")
struct NetworkAndComfyTests {
    @Test func decodesCurrentNetworkInterfaceShape() throws {
        let envelope = try TestFixtures.decodeEnvelope("snapshot-network")
        let network = try #require(envelope.sparks.first?.metrics?.network)
        #expect(network.primaryInterface == "enP7s7")
        #expect(network.linkSpeedMbps == 10_000)
        #expect(network.wolMac == "aa:bb:cc:dd:ee:ff")

        let interfaces = try #require(network.interfaces)
        #expect(interfaces.count == 2)

        let primary = try #require(interfaces.first)
        #expect(primary.name == "enP7s7")
        #expect(primary.rxSpeed == 1_048_576)
        #expect(primary.txSpeed == 2048)
        #expect(primary.ip == "192.168.1.143")
        #expect(primary.isUp)

        let disabled = try #require(interfaces.last)
        #expect(disabled.disabled == true)
        #expect(disabled.isUp == false)
        #expect(disabled.ip == nil)
    }

    @Test func acceptsLegacyNetworkRateKeys() throws {
        let data = Data(#"{"type":"snapshot","sparks":[{"id":"a","name":"A","online":true,"metrics":{"network":{"interfaces":[{"name":"eth0","rxBytesPerSecond":12.5,"txBytesPerSecond":3.25,"ipAddress":"10.0.0.1","linkSpeedMbps":1000,"operstate":"up"}]}}}]}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        let interface = try #require(envelope.sparks.first?.metrics?.network?.interfaces?.first)
        #expect(interface.rxSpeed == 12.5)
        #expect(interface.txSpeed == 3.25)
        #expect(interface.ip == "10.0.0.1")
        #expect(interface.isUp)
    }

    @Test func decodesCurrentComfyMetricsShape() throws {
        let envelope = try TestFixtures.decodeEnvelope("snapshot-comfy")
        let comfy = try #require(envelope.sparks.first?.metrics?.comfy)
        #expect(comfy.available == true)
        #expect(comfy.port == 8188)
        #expect(comfy.version == "0.3.49")
        #expect(comfy.pytorchVersion == "2.9.1")
        #expect(comfy.queueRunning == 1)
        #expect(comfy.queuePending == 2)
        #expect(comfy.progress?.value == 18)
        #expect(comfy.progress?.max == 30)
        #expect(comfy.progress?.percent == 60)
        #expect(comfy.progress?.source == "ws")
        #expect(comfy.activeJob?.title == "SDXL Workflow")
        #expect(comfy.activeJob?.models == ["sd_xl_base_1.0.safetensors"])
        #expect(comfy.activeJob?.steps == 30)
        #expect(comfy.pendingJobs?.count == 1)
        #expect(comfy.pendingJobs?.first?.title == "Batch 2")
        #expect(comfy.lastJob?.status == "completed")
        #expect(comfy.modelsInstalled?.checkpoints == ["sd_xl_base_1.0.safetensors"])
        #expect(comfy.queueEtaMs == 240_000)
        #expect(comfy.openUrl == "http://192.168.1.143:8188")
        #expect(comfy.error == nil)
    }

    @Test func comfyMetricsDecodeWhenIdle() throws {
        let data = Data(#"{"type":"snapshot","sparks":[{"id":"a","name":"A","online":true,"metrics":{"comfy":{"available":true,"port":8188,"queueRunning":0,"queuePending":0,"activeJob":null,"pendingJobs":[],"progress":null,"error":null}}}]}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        let comfy = try #require(envelope.sparks.first?.metrics?.comfy)
        #expect(comfy.available == true)
        #expect(comfy.queueRunning == 0)
        #expect(comfy.progress == nil)
        #expect(comfy.activeJob == nil)
    }

    @Test func malformedComfyJobDoesNotDiscardQueueState() throws {
        let data = Data(#"{"type":"snapshot","sparks":[{"id":"a","name":"A","online":true,"metrics":{"comfy":{"available":true,"queueRunning":1,"queuePending":3,"pendingJobs":[{"id":"ok","title":"Good"},{"title":"missing id"}]}}}]}"#.utf8)
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        let comfy = try #require(envelope.sparks.first?.metrics?.comfy)
        #expect(comfy.queuePending == 3)
        #expect(comfy.pendingJobs?.count == 1)
        #expect(comfy.pendingJobs?.first?.id == "ok")
    }
}
