import Foundation

public struct SparkListResponse: Decodable, Equatable, Sendable {
    public let sparks: [SparkConfiguration]

    public init(sparks: [SparkConfiguration]) {
        self.sparks = sparks
    }
}

/// The configuration returned by `GET /api/sparks`. It is intentionally separate
/// from `SparkSnapshot`: configuration endpoints do not include live metrics.
public struct SparkConfiguration: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let lanIp: String?
    public let llmPorts: [Int]?
    public let llmMonitoring: Bool?
    public let comfyMonitoring: Bool?
    public let comfyPort: Int?

    public init(
        id: String,
        name: String,
        lanIp: String? = nil,
        llmPorts: [Int]? = nil,
        llmMonitoring: Bool? = nil,
        comfyMonitoring: Bool? = nil,
        comfyPort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.lanIp = lanIp
        self.llmPorts = llmPorts
        self.llmMonitoring = llmMonitoring
        self.comfyMonitoring = comfyMonitoring
        self.comfyPort = comfyPort
    }
}

public struct SnapshotEnvelope: Decodable, Equatable, Sendable {
    public let type: String?
    public let sparks: [SparkSnapshot]
    public let refreshInterval: Int?

    public init(type: String? = "snapshot", sparks: [SparkSnapshot], refreshInterval: Int? = nil) {
        self.type = type
        self.sparks = sparks
        self.refreshInterval = refreshInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        sparks = try container.decodeLossy(SparkSnapshot.self, forKey: .sparks)
        refreshInterval = try container.decodeIfPresent(Int.self, forKey: .refreshInterval)
    }

    private enum CodingKeys: String, CodingKey {
        case type, sparks, refreshInterval
    }
}

public struct SparkSnapshot: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let online: Bool?
    public let uptime: Double?
    public let lanIp: String?
    public let isLocal: Bool?
    public let disabledDevices: [String]?
    public let disabledInterfaces: [String]?
    public let storagePollDisabled: Bool?
    public let workerNode: Bool?
    public let role: String?
    public let workerLabel: String?
    public let workerHeadId: String?
    public let llmMonitoring: Bool?
    public let llmPort: Int?
    public let llmPorts: [Int]?
    public let llmApiKeyPorts: [Int]?
    public let comfyMonitoring: Bool?
    public let comfyPort: Int?
    public let hermes: HermesMetrics?
    public let hardware: HardwareInfo?
    public let metrics: SparkMetrics?

    public init(
        id: String,
        name: String,
        online: Bool? = nil,
        uptime: Double? = nil,
        lanIp: String? = nil,
        isLocal: Bool? = nil,
        disabledDevices: [String]? = nil,
        disabledInterfaces: [String]? = nil,
        storagePollDisabled: Bool? = nil,
        workerNode: Bool? = nil,
        role: String? = nil,
        workerLabel: String? = nil,
        workerHeadId: String? = nil,
        llmMonitoring: Bool? = nil,
        llmPort: Int? = nil,
        llmPorts: [Int]? = nil,
        llmApiKeyPorts: [Int]? = nil,
        comfyMonitoring: Bool? = nil,
        comfyPort: Int? = nil,
        hermes: HermesMetrics? = nil,
        hardware: HardwareInfo? = nil,
        metrics: SparkMetrics? = nil
    ) {
        self.id = id
        self.name = name
        self.online = online
        self.uptime = uptime
        self.lanIp = lanIp
        self.isLocal = isLocal
        self.disabledDevices = disabledDevices
        self.disabledInterfaces = disabledInterfaces
        self.storagePollDisabled = storagePollDisabled
        self.workerNode = workerNode
        self.role = role
        self.workerLabel = workerLabel
        self.workerHeadId = workerHeadId
        self.llmMonitoring = llmMonitoring
        self.llmPort = llmPort
        self.llmPorts = llmPorts
        self.llmApiKeyPorts = llmApiKeyPorts
        self.comfyMonitoring = comfyMonitoring
        self.comfyPort = comfyPort
        self.hermes = hermes
        self.hardware = hardware
        self.metrics = metrics
    }

    public var isOnline: Bool { online == true }

    public var primaryLLM: LLMMetrics? {
        metrics?.llm?.first(where: { $0.available != false }) ?? metrics?.llm?.first
    }

    public var llmActivity: Double {
        metrics?.llm?.reduce(0) { $0 + ($1.generationTps ?? 0) + ($1.prefillTps ?? 0) } ?? 0
    }

    public var gpuUsage: Double { metrics?.gpu?.usage ?? 0 }

    public var memoryPercentage: Double {
        metrics?.unifiedMemory?.percentage
            ?? metrics?.gpu?.vram?.percentage
            ?? metrics?.ram?.percentage
            ?? 0
    }
}

public struct HardwareInfo: Decodable, Equatable, Sendable {
    public let device: String?
    public let cpuModel: String?
    public let cpuCores: Int?
    public let totalMemoryGB: Double?
    public let gpuChip: String?
    public let cudaDriver: String?
    public let storageModel: String?
}

public struct SparkMetrics: Decodable, Equatable, Sendable {
    public let gpu: GPUMetrics?
    public let cpu: CPUMetrics?
    public let ram: MemoryMetrics?
    public let storage: [StorageMetrics]?
    public let network: NetworkMetrics?
    public let unifiedMemory: UnifiedMemoryMetrics?
    public let llm: [LLMMetrics]?
    public let comfy: ComfyMetrics?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gpu = try? c.decode(GPUMetrics.self, forKey: .gpu)
        cpu = try? c.decode(CPUMetrics.self, forKey: .cpu)
        ram = try? c.decode(MemoryMetrics.self, forKey: .ram)
        storage = try? c.decode([StorageMetrics].self, forKey: .storage)
        network = try? c.decode(NetworkMetrics.self, forKey: .network)
        unifiedMemory = try? c.decode(UnifiedMemoryMetrics.self, forKey: .unifiedMemory)
        llm = try c.decodeLossy(LLMMetrics.self, forKey: .llm)
        comfy = try? c.decode(ComfyMetrics.self, forKey: .comfy)
    }

    private enum CodingKeys: String, CodingKey {
        case gpu, cpu, ram, storage, network, unifiedMemory, llm, comfy
    }
}

public struct GPUMetrics: Decodable, Equatable, Sendable {
    public let temperature: Double?
    public let usage: Double?
    public let power: PowerMetrics?
    public let vram: MemoryMetrics?
    public let processes: [GPUProcess]?
    public let throttle: ThrottleMetrics?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        usage = try c.decodeIfPresent(Double.self, forKey: .usage)
        power = try? c.decode(PowerMetrics.self, forKey: .power)
        vram = try? c.decode(MemoryMetrics.self, forKey: .vram)
        processes = try c.decodeLossy(GPUProcess.self, forKey: .processes)
        throttle = try? c.decode(ThrottleMetrics.self, forKey: .throttle)
    }

    private enum CodingKeys: String, CodingKey {
        case temperature, usage, power, vram, processes, throttle
    }
}

public struct PowerMetrics: Decodable, Equatable, Sendable {
    public let draw: Double?
    public let limit: Double?
    public let systemDraw: Double?
}

public struct MemoryMetrics: Decodable, Equatable, Sendable {
    /// sparkDash reports memory quantities in MB in its current API.
    public let used: Double?
    public let total: Double?
    public let percentage: Double?
    public let available: Double?
}

public struct UnifiedMemoryMetrics: Decodable, Equatable, Sendable {
    /// sparkDash reports memory quantities in MB in its current API.
    public let total: Double?
    public let gpuUsed: Double?
    public let cpuUsed: Double?
    public let used: Double?
    public let available: Double?
    public let percentage: Double?
    public let oomRisk: String?
    public let bandwidth: MemoryBandwidth?
}

public struct MemoryBandwidth: Decodable, Equatable, Sendable {
    public let current: Double?
    public let peak: Double?
}

public struct CPUMetrics: Decodable, Equatable, Sendable {
    public let usage: Double?
    public let temperature: Double?
    public let draw: Double?
    public let tdp: Double?
}

public struct ThrottleMetrics: Decodable, Equatable, Sendable {
    public let thermal: Bool?
    public let hwSlowdown: Bool?
    public let powerCap: Bool?
    public let active: Bool?
    public let reason: String?
    public let smClockMHz: Double?
    public let smClockMaxMHz: Double?
    public let smClockPct: Double?
    public let detail: String?
}

public struct GPUProcess: Decodable, Equatable, Identifiable, Sendable {
    public let pid: Int?
    public let name: String
    public let vramMB: Double?

    public var id: String { "\(pid ?? 0)-\(name)" }
}

public struct LLMMetrics: Decodable, Equatable, Identifiable, Sendable {
    public let available: Bool?
    public let backend: String?
    public let modelId: String?
    public let modelPath: String?
    public let contextLength: Int?
    public let gpuMemoryUtilization: Double?
    public let slotsActive: Int?
    public let slotsTotal: Int?
    public let generationTps: Double?
    public let prefillTps: Double?
    public let totalOutputTokens: Int?
    public let kvCacheUsage: Double?
    public let requestsRunning: Int?
    public let requestsWaiting: Int?
    public let ttftP95Seconds: Double?
    public let preemptionsTotal: Int?
    public let prefixCacheHitRate: Double?
    public let e2eP95Seconds: Double?
    public let itlP95Seconds: Double?
    public let mtpAcceptanceRate: Double?
    public let port: Int?
    public let posture: LLMPosture?
    public let error: String?

    public var id: String {
        var parts = [String]()
        if let port { parts.append("port:\(port)") }
        if let backend { parts.append("backend:\(backend)") }
        if let modelId { parts.append("model:\(modelId)") }
        if let modelPath { parts.append("path:\(modelPath)") }
        if let contextLength { parts.append("context:\(contextLength)") }
        return parts.isEmpty ? "llm" : parts.joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case available, backend, modelId, model, modelName, modelPath, contextLength
        case gpuMemoryUtilization, gpuMemoryUsage, slotsActive, activeSlots, slotsTotal, totalSlots
        case generationTps, generationTokensPerSecond, prefillTps, prefillTokensPerSecond
        case totalOutputTokens, kvCacheUsage, kvCacheUtilization, requestsRunning, runningRequests
        case requestsWaiting, waitingRequests, ttftP95Seconds, ttftP95, preemptionsTotal, preemptions
        case prefixCacheHitRate, prefixCacheHit, e2eP95Seconds, e2eP95, itlP95Seconds, itlP95
        case mtpAcceptanceRate, mtpAcceptance, port, posture, error
    }

    public init(
        available: Bool? = nil,
        backend: String? = nil,
        modelId: String? = nil,
        modelPath: String? = nil,
        contextLength: Int? = nil,
        gpuMemoryUtilization: Double? = nil,
        slotsActive: Int? = nil,
        slotsTotal: Int? = nil,
        generationTps: Double? = nil,
        prefillTps: Double? = nil,
        totalOutputTokens: Int? = nil,
        kvCacheUsage: Double? = nil,
        requestsRunning: Int? = nil,
        requestsWaiting: Int? = nil,
        ttftP95Seconds: Double? = nil,
        preemptionsTotal: Int? = nil,
        prefixCacheHitRate: Double? = nil,
        e2eP95Seconds: Double? = nil,
        itlP95Seconds: Double? = nil,
        mtpAcceptanceRate: Double? = nil,
        port: Int? = nil,
        posture: LLMPosture? = nil,
        error: String? = nil
    ) {
        self.available = available
        self.backend = backend
        self.modelId = modelId
        self.modelPath = modelPath
        self.contextLength = contextLength
        self.gpuMemoryUtilization = gpuMemoryUtilization
        self.slotsActive = slotsActive
        self.slotsTotal = slotsTotal
        self.generationTps = generationTps
        self.prefillTps = prefillTps
        self.totalOutputTokens = totalOutputTokens
        self.kvCacheUsage = kvCacheUsage
        self.requestsRunning = requestsRunning
        self.requestsWaiting = requestsWaiting
        self.ttftP95Seconds = ttftP95Seconds
        self.preemptionsTotal = preemptionsTotal
        self.prefixCacheHitRate = prefixCacheHitRate
        self.e2eP95Seconds = e2eP95Seconds
        self.itlP95Seconds = itlP95Seconds
        self.mtpAcceptanceRate = mtpAcceptanceRate
        self.port = port
        self.posture = posture
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available)
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        modelId = try c.decodeFirst(String.self, forKeys: [.modelId, .model, .modelName])
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        gpuMemoryUtilization = try c.decodeFirst(Double.self, forKeys: [.gpuMemoryUtilization, .gpuMemoryUsage])
        slotsActive = try c.decodeFirst(Int.self, forKeys: [.slotsActive, .activeSlots])
        slotsTotal = try c.decodeFirst(Int.self, forKeys: [.slotsTotal, .totalSlots])
        generationTps = try c.decodeFirst(Double.self, forKeys: [.generationTps, .generationTokensPerSecond])
        prefillTps = try c.decodeFirst(Double.self, forKeys: [.prefillTps, .prefillTokensPerSecond])
        totalOutputTokens = try c.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
        kvCacheUsage = try c.decodeFirst(Double.self, forKeys: [.kvCacheUsage, .kvCacheUtilization])
        requestsRunning = try c.decodeFirst(Int.self, forKeys: [.requestsRunning, .runningRequests])
        requestsWaiting = try c.decodeFirst(Int.self, forKeys: [.requestsWaiting, .waitingRequests])
        ttftP95Seconds = try c.decodeFirst(Double.self, forKeys: [.ttftP95Seconds, .ttftP95])
        preemptionsTotal = try c.decodeFirst(Int.self, forKeys: [.preemptionsTotal, .preemptions])
        prefixCacheHitRate = try c.decodeFirst(Double.self, forKeys: [.prefixCacheHitRate, .prefixCacheHit])
        e2eP95Seconds = try c.decodeFirst(Double.self, forKeys: [.e2eP95Seconds, .e2eP95])
        itlP95Seconds = try c.decodeFirst(Double.self, forKeys: [.itlP95Seconds, .itlP95])
        mtpAcceptanceRate = try c.decodeFirst(Double.self, forKeys: [.mtpAcceptanceRate, .mtpAcceptance])
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        posture = try c.decodeIfPresent(LLMPosture.self, forKey: .posture)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct LLMPosture: Decodable, Equatable, Sendable {
    public let level: String?
    public let auth: String?
    public let scope: String?
    public let label: String?
    public let detail: String?
}

public struct ComfyMetrics: Decodable, Equatable, Sendable {
    public let model: String?
    public let progress: Double?
    public let currentStep: Int?
    public let totalSteps: Int?
    public let running: Int?
    public let queued: Int?
    public let etaSeconds: Double?
    public let status: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case model, modelName, currentModel, progress, progressPercent, currentStep, step, totalSteps, steps
        case running, runningJobs, queued, queue, queueLength, etaSeconds, eta, status, error
    }

    public init(
        model: String? = nil,
        progress: Double? = nil,
        currentStep: Int? = nil,
        totalSteps: Int? = nil,
        running: Int? = nil,
        queued: Int? = nil,
        etaSeconds: Double? = nil,
        status: String? = nil,
        error: String? = nil
    ) {
        self.model = model
        self.progress = progress
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.running = running
        self.queued = queued
        self.etaSeconds = etaSeconds
        self.status = status
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeFirst(String.self, forKeys: [.model, .modelName, .currentModel])
        progress = try c.decodeFirst(Double.self, forKeys: [.progress, .progressPercent])
        currentStep = try c.decodeFirst(Int.self, forKeys: [.currentStep, .step])
        totalSteps = try c.decodeFirst(Int.self, forKeys: [.totalSteps, .steps])
        running = try c.decodeFirst(Int.self, forKeys: [.running, .runningJobs])
        queued = try c.decodeFirst(Int.self, forKeys: [.queued, .queue, .queueLength])
        etaSeconds = try c.decodeFirst(Double.self, forKeys: [.etaSeconds, .eta])
        status = try c.decodeIfPresent(String.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct StorageMetrics: Decodable, Equatable, Identifiable, Sendable {
    public let device: String?
    public let label: String?
    public let used: Double?
    public let total: Double?
    public let available: Double?
    public let percentage: Double?
    public let readSpeed: Double?
    public let writeSpeed: Double?
    public let disabled: Bool?

    public var id: String { device ?? label ?? "storage" }
}

public struct NetworkMetrics: Decodable, Equatable, Sendable {
    public let primaryInterface: String?
    public let linkSpeedMbps: Double?
    public let interfaces: [NetworkInterfaceMetrics]?
    public let wolMac: String?
}

public struct NetworkInterfaceMetrics: Decodable, Equatable, Identifiable, Sendable {
    public let name: String?
    public let label: String?
    public let rxBytesPerSecond: Double?
    public let txBytesPerSecond: Double?
    public let linkSpeedMbps: Double?
    public let ipAddress: String?
    public let disabled: Bool?

    public var id: String { name ?? label ?? ipAddress ?? "interface" }
}

public struct HermesMetrics: Decodable, Equatable, Sendable {
    public let monitoring: Bool?
    public let installed: Bool?
    public let version: String?
    public let updateAvailable: Bool?
    public let behindCommits: Int?
    public let checkedAt: String?
    public let status: String?
    public let startedAt: String?
    public let finishedAt: String?
    public let error: String?
}

private extension KeyedDecodingContainer {
    func decodeFirst<T: Decodable>(_ type: T.Type, forKeys keys: [Key]) throws -> T? {
        for key in keys {
            if let value = try decodeIfPresent(type, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        guard var values = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !values.isAtEnd {
            let element = try values.decode(FailableDecodable<T>.self)
            if let value = element.value {
                result.append(value)
            }
        }
        return result
    }
}

private struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
