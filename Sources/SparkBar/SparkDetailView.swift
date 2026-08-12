import SparkBarCore
import SwiftUI

struct SparkDetailView: View {
    let snapshot: SparkSnapshot
    let isServerLive: Bool
    let temperatureUnit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(snapshot: snapshot, isServerLive: isServerLive)
            if snapshot.isOnline {
                GPUCard(snapshot: snapshot, temperatureUnit: temperatureUnit)
                UnifiedMemoryCard(snapshot: snapshot)
                SystemSummary(snapshot: snapshot, temperatureUnit: temperatureUnit)
                if let llms = snapshot.metrics?.llm, !llms.isEmpty {
                    SectionTitle("LLM Monitoring", systemImage: "text.bubble")
                    ForEach(llmEntries(llms: llms, snapshot: snapshot)) { entry in
                        LLMCard(llm: entry.metrics, port: entry.port)
                    }
                }
                if snapshot.comfyMonitoring == true || snapshot.metrics?.comfy != nil {
                    SectionTitle("ComfyUI", systemImage: "wand.and.stars")
                    ComfyCard(metrics: snapshot.metrics?.comfy)
                }
                if let processes = snapshot.metrics?.gpu?.processes, !processes.isEmpty {
                    SectionTitle("GPU Processes", systemImage: "list.bullet.rectangle")
                    ProcessCard(processes: Array(processes.prefix(5)))
                }
                NetworkCard(metrics: snapshot.metrics?.network)
                StorageCard(metrics: snapshot.metrics?.storage, isDisabled: snapshot.storagePollDisabled == true)
            } else {
                OfflineCard()
            }
        }
    }

    private func llmEntries(llms: [LLMMetrics], snapshot: SparkSnapshot) -> [LLMEntry] {
        llms.enumerated().map { index, metrics in
            let configuredPort = snapshot.llmPorts?.indices.contains(index) == true ? snapshot.llmPorts?[index] : nil
            let port = metrics.port ?? configuredPort ?? snapshot.llmPort
            return LLMEntry(id: "\(metrics.id)#\(port.map(String.init) ?? String(index))", metrics: metrics, port: port)
        }
    }
}

private struct LLMEntry: Identifiable {
    let id: String
    let metrics: LLMMetrics
    let port: Int?
}

private struct DetailHeader: View {
    let snapshot: SparkSnapshot
    let isServerLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.name)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(snapshot.isOnline ? "Online" : "Offline")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(snapshot.isOnline ? .green : .secondary)
            }
            HStack(spacing: 5) {
                Image(systemName: isServerLive ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    .accessibilityHidden(true)
                Text(isServerLive ? "Live" : "Last known · sparkDash disconnected")
                if let uptime = snapshot.uptime {
                    Text("· uptime \(MetricFormatter.uptime(uptime))")
                }
            }
            .font(.caption)
            .foregroundStyle(isServerLive ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.name), \(snapshot.isOnline ? "online" : "offline"), \(isServerLive ? "live" : "last known, sparkDash disconnected")")
    }
}

private struct GPUCard: View {
    let snapshot: SparkSnapshot
    let temperatureUnit: TemperatureUnit

    var body: some View {
        let gpu = snapshot.metrics?.gpu
        let throttle = gpu?.throttle
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("GPU", systemImage: "gauge.with.dots.needle.67percent")
                Spacer()
                Text(MetricFormatter.percent(gpu?.usage))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            }
            if let usage = gpu?.usage {
                ProgressView(value: usage / 100)
                    .tint(.accentColor)
            }
            HStack(spacing: 0) {
                MetricPair(label: "Temperature", value: MetricFormatter.temperature(gpu?.temperature, unit: temperatureUnit))
                Spacer()
                MetricPair(label: "Power", value: "\(MetricFormatter.watts(gpu?.power?.draw)) / \(MetricFormatter.watts(gpu?.power?.limit))")
                Spacer()
                MetricPair(label: "System", value: MetricFormatter.watts(gpu?.power?.systemDraw))
            }
            if throttle?.active == true || throttle?.thermal == true || throttle?.powerCap == true {
                Label(throttleLabel(throttle), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if throttle?.smClockMHz != nil || throttle?.smClockPct != nil {
                Text("SM clock \(MetricFormatter.frequency(throttle?.smClockMHz)) · \(MetricFormatter.percent(throttle?.smClockPct))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .metricCard()
    }

    private func throttleLabel(_ throttle: ThrottleMetrics?) -> String {
        if throttle?.thermal == true { return "Thermal throttle" }
        if throttle?.powerCap == true { return "Power limited" }
        return throttle?.reason?.capitalized ?? "GPU throttled"
    }
}

private struct UnifiedMemoryCard: View {
    let snapshot: SparkSnapshot

    var body: some View {
        let memory = snapshot.metrics?.unifiedMemory
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Unified Memory", systemImage: "memorychip")
            HStack(alignment: .firstTextBaseline) {
                Text("\(MetricFormatter.memory(memory?.used, includeUnit: false)) / \(MetricFormatter.memory(memory?.total))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Spacer()
                Text(MetricFormatter.percent(memory?.percentage))
                    .font(.headline.monospacedDigit())
            }
            if let percentage = memory?.percentage {
                ProgressView(value: percentage / 100)
                    .tint(memoryColor(memory?.oomRisk))
            }
            HStack {
                Text("\(MetricFormatter.memory(memory?.available)) available")
                Spacer()
                Text("OOM risk: \(memory?.oomRisk?.capitalized ?? "—")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let bandwidth = memory?.bandwidth, bandwidth.current != nil {
                Text("Bandwidth \(MetricFormatter.memory(bandwidth.current, includeUnit: false)) / \(MetricFormatter.memory(bandwidth.peak))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .metricCard()
    }

    private func memoryColor(_ risk: String?) -> Color {
        switch risk?.lowercased() {
        case "high", "critical": return .orange
        case "medium": return .yellow
        default: return .accentColor
        }
    }
}

private struct SystemSummary: View {
    let snapshot: SparkSnapshot
    let temperatureUnit: TemperatureUnit

    var body: some View {
        HStack(spacing: 8) {
            SmallMetricCard(title: "CPU", value: MetricFormatter.percent(snapshot.metrics?.cpu?.usage), detail: MetricFormatter.temperature(snapshot.metrics?.cpu?.temperature, unit: temperatureUnit))
            SmallMetricCard(title: "RAM", value: MetricFormatter.percent(snapshot.metrics?.ram?.percentage), detail: "\(MetricFormatter.memory(snapshot.metrics?.ram?.used)) / \(MetricFormatter.memory(snapshot.metrics?.ram?.total))")
            SmallMetricCard(title: "Network", value: networkValue, detail: networkDetail)
        }
    }

    private var networkValue: String {
        guard let interface = snapshot.metrics?.network?.interfaces?.first(where: { $0.disabled != true }) else { return "—" }
        return "↓ \(MetricFormatter.bytesPerSecond(interface.rxBytesPerSecond))"
    }

    private var networkDetail: String {
        guard let interface = snapshot.metrics?.network?.interfaces?.first(where: { $0.disabled != true }) else { return "Unavailable" }
        return "↑ \(MetricFormatter.bytesPerSecond(interface.txBytesPerSecond))"
    }
}

private struct LLMCard: View {
    let llm: LLMMetrics
    let port: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(llm.modelId ?? "LLM")
                        .font(.headline)
                        .lineLimit(1)
                Text("\(llm.backend ?? "Unknown backend") · \(portText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(llm.available == false ? "Down" : MetricFormatter.tokensPerSecond(llm.generationTps))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(llm.available == false ? .orange : .primary)
            }
            HStack {
                MetricPair(label: "Prefill", value: MetricFormatter.tokensPerSecond(llm.prefillTps))
                Spacer()
                MetricPair(label: "Requests", value: "\(llm.requestsRunning.map(String.init) ?? "—") / \(llm.requestsWaiting.map(String.init) ?? "—")")
                Spacer()
                MetricPair(label: "KV cache", value: MetricFormatter.percent(llm.kvCacheUsage))
            }
            HStack {
                MetricPair(label: "Slots", value: "\(llm.slotsActive.map(String.init) ?? "—") / \(llm.slotsTotal.map(String.init) ?? "—")")
                Spacer()
                MetricPair(label: "TTFT p95", value: seconds(llm.ttftP95Seconds))
                Spacer()
                MetricPair(label: "E2E p95", value: seconds(llm.e2eP95Seconds))
            }
        }
        .metricCard()
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2))))s"
    }

    private var portText: String {
        guard let port else { return "port unavailable" }
        return ":\(port)"
    }
}

private struct ComfyCard: View {
    let metrics: ComfyMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(metrics?.model ?? "ComfyUI")
                    .font(.headline)
                Spacer()
                Text(metrics == nil ? "Idle" : MetricFormatter.percent(MetricFormatter.normalisedProgress(metrics?.progress)))
                    .font(.subheadline.monospacedDigit())
            }
            if let metrics {
                ProgressView(value: (MetricFormatter.normalisedProgress(metrics.progress) ?? 0) / 100)
                Text("\(metrics.currentStep.map(String.init) ?? "—") / \(metrics.totalSteps.map(String.init) ?? "—") steps · \(metrics.running.map(String.init) ?? "—") running · \(metrics.queued.map(String.init) ?? "—") queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let eta = metrics.etaSeconds {
                    Text("ETA \(MetricFormatter.uptime(eta))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .metricCard()
    }
}

private struct ProcessCard: View {
    let processes: [GPUProcess]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(processes) { process in
                HStack {
                    Text(process.name.split(separator: "/").last.map(String.init) ?? process.name)
                        .lineLimit(1)
                    Spacer()
                    Text(MetricFormatter.memory(process.vramMB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .metricCard()
    }
}

private struct NetworkCard: View {
    let metrics: NetworkMetrics?

    var body: some View {
        let interfaces = metrics?.interfaces?.filter { $0.disabled != true } ?? []
        if !interfaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Network", systemImage: "network")
                ForEach(interfaces) { interface in
                    HStack {
                        Text(interface.label ?? interface.name ?? "Interface")
                        Spacer()
                        Text("↓ \(MetricFormatter.bytesPerSecond(interface.rxBytesPerSecond))")
                        Text("↑ \(MetricFormatter.bytesPerSecond(interface.txBytesPerSecond))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .metricCard()
        }
    }
}

private struct StorageCard: View {
    let metrics: [StorageMetrics]?
    let isDisabled: Bool

    var body: some View {
        if isDisabled {
            EmptyView()
        } else if let metrics, !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Storage", systemImage: "internaldrive")
                ForEach(metrics) { storage in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(storage.label ?? storage.device ?? "Volume")
                            Spacer()
                            Text("\(MetricFormatter.memory(storage.used, includeUnit: false)) / \(MetricFormatter.memory(storage.total))")
                                .font(.caption.monospacedDigit())
                        }
                        if let percentage = storage.percentage {
                            ProgressView(value: percentage / 100)
                        }
                        HStack {
                            Text("Read \(MetricFormatter.bytesPerSecond(storage.readSpeed))")
                            Spacer()
                            Text("Write \(MetricFormatter.bytesPerSecond(storage.writeSpeed))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .metricCard()
        }
    }
}

private struct OfflineCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.title)
                .accessibilityHidden(true)
            Text("Spark offline")
                .font(.headline)
            Text("sparkDash is still reachable, but this Spark reports itself offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SectionTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }
}

private struct MetricPair: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SmallMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}

private extension View {
    func metricCard() -> some View {
        padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}
