import SparkBarCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let selectSpark: (String) -> Void

    private var onlineSnapshots: [SparkSnapshot] { model.snapshots.filter(\.isOnline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overview")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.snapshots.count) Sparks · \(model.onlineCount) online")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                SummaryCard(title: "Max GPU", value: MetricFormatter.percent(onlineSnapshots.map(\.gpuUsage).max()), icon: "gauge.with.dots.needle.67percent")
                SummaryCard(title: "Memory", value: aggregateMemory, icon: "memorychip")
                SummaryCard(title: "Power", value: aggregatePower, icon: "bolt")
            }

            VStack(spacing: 8) {
                ForEach(model.snapshots) { snapshot in
                    Button {
                        selectSpark(snapshot.id)
                    } label: {
                            SparkOverviewRow(snapshot: snapshot, temperatureUnit: model.effectiveTemperatureUnit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var aggregateMemory: String {
        guard !onlineSnapshots.isEmpty,
              onlineSnapshots.allSatisfy({ $0.metrics?.unifiedMemory?.used != nil && $0.metrics?.unifiedMemory?.total != nil }) else {
            return "—"
        }
        let used = onlineSnapshots.compactMap { $0.metrics?.unifiedMemory?.used }.reduce(0, +)
        let total = onlineSnapshots.compactMap { $0.metrics?.unifiedMemory?.total }.reduce(0, +)
        return "\(MetricFormatter.memory(used, includeUnit: false)) / \(MetricFormatter.memory(total))"
    }

    private var aggregatePower: String {
        guard !onlineSnapshots.isEmpty,
              onlineSnapshots.allSatisfy({ $0.metrics?.gpu?.power?.systemDraw != nil }) else {
            return "—"
        }
        let total = onlineSnapshots.compactMap { $0.metrics?.gpu?.power?.systemDraw }.reduce(0, +)
        return "~\(MetricFormatter.watts(total))"
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct SparkOverviewRow: View {
    let snapshot: SparkSnapshot
    let temperatureUnit: TemperatureUnit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(snapshot.isOnline ? .green : .secondary)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(snapshot.name)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if snapshot.isOnline {
                    HStack(spacing: 12) {
                        CompactValue(label: "GPU", value: MetricFormatter.percent(snapshot.metrics?.gpu?.usage))
                        CompactValue(label: "Temp", value: MetricFormatter.temperatureShort(snapshot.metrics?.gpu?.temperature, unit: temperatureUnit))
                        CompactValue(label: "Memory", value: MetricFormatter.percent(snapshot.metrics?.unifiedMemory?.percentage))
                    }
                    if let llm = snapshot.primaryLLM, llm.available != false {
                        Text("\(llm.modelId ?? llm.backend ?? "LLM") · \(MetricFormatter.tokensPerSecond(llm.generationTps))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Idle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel)
    }

    private var rowLabel: String {
        if !snapshot.isOnline { return "\(snapshot.name), offline" }
        return "\(snapshot.name), GPU \(MetricFormatter.percent(snapshot.metrics?.gpu?.usage)), \(MetricFormatter.temperature(snapshot.metrics?.gpu?.temperature, unit: temperatureUnit)), memory \(MetricFormatter.percent(snapshot.metrics?.unifiedMemory?.percentage))"
    }
}

private struct CompactValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
