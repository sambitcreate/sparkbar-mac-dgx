import SparkBarCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let selectSpark: (String) -> Void
    @Environment(\.sparkTheme) private var theme
    private var online: [SparkSnapshot] { model.snapshots.filter(\.isOnline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Fleet at a glance").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.snapshots.count) systems").font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
            }
            HStack(alignment: .top, spacing: 10) {
                FleetMetric(value: MetricFormatter.percent(online.compactMap { $0.metrics?.gpu?.usage }.max()), label: "Max GPU")
                FleetMetric(value: aggregateMemory, label: "Memory in use")
                FleetMetric(value: aggregatePower, label: "System power", marker: theme.power)
            }
            Divider().overlay(theme.hairline)
            HStack {
                Text("Your systems").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.onlineCount) online").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }
            VStack(spacing: 0) {
                ForEach(model.snapshots) { snapshot in
                    Button { selectSpark(snapshot.id) } label: {
                        SparkOverviewRow(snapshot: snapshot, temperatureUnit: model.effectiveTemperatureUnit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(snapshot.name), \(snapshot.isOnline ? "online" : "offline"), GPU \(MetricFormatter.percent(snapshot.metrics?.gpu?.usage)), memory \(MetricFormatter.percent(snapshot.memoryPressurePercentage))")
                    .accessibilityHint("Open \(snapshot.name) details")
                    .accessibilityAddTraits(.isButton)
                    if snapshot.id != model.snapshots.last?.id { Divider().overlay(theme.hairline).padding(.vertical, 16) }
                }
            }
        }
    }

    private var aggregateMemory: String {
        guard !online.isEmpty, online.allSatisfy({ $0.memoryUsedMB != nil && $0.memoryTotalMB != nil }) else { return "—" }
        return MetricFormatter.memory(online.compactMap(\.memoryUsedMB).reduce(0, +))
    }
    private var aggregatePower: String {
        guard !online.isEmpty, online.allSatisfy({ $0.metrics?.gpu?.power?.systemDraw != nil }) else { return "—" }
        return "~\(MetricFormatter.watts(online.compactMap { $0.metrics?.gpu?.power?.systemDraw }.reduce(0, +)))"
    }
}

private struct FleetMetric: View {
    let value: String
    let label: String
    var marker: Color? = nil
    @Environment(\.sparkTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                if let marker { Circle().fill(marker).frame(width: 5, height: 5).accessibilityHidden(true) }
                Text(label).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SparkOverviewRow: View {
    let snapshot: SparkSnapshot
    let temperatureUnit: TemperatureUnit
    @Environment(\.sparkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Group {
                    if snapshot.isGPUHost { Image(systemName: "server.rack").font(.system(size: 22)) }
                    else { DGXDeviceIcon().frame(width: 32, height: 25) }
                }
                .frame(width: 35, height: 35)
                .background(theme.control.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.name).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(roleLabel).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Circle().fill(snapshot.isOnline ? Color(hex: theme.dark ? 0x8BBB9E : 0x347451) : .secondary)
                        .frame(width: 5, height: 5)
                    Text(snapshot.isOnline ? "Online" : "Offline").font(.system(size: 10))
                }
                .foregroundStyle(theme.secondaryText)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            if snapshot.isOnline {
                HStack {
                    CompactValue(label: "GPU", value: MetricFormatter.percent(snapshot.metrics?.gpu?.usage))
                    CompactValue(label: "Temperature", value: MetricFormatter.temperatureShort(snapshot.metrics?.gpu?.temperature, unit: temperatureUnit))
                    CompactValue(label: "Memory used", value: MetricFormatter.memory(snapshot.memoryUsedMB))
                }
                if let memory = snapshot.memoryPressurePercentage {
                    ProgressView(value: min(max(memory / 100, 0), 1)).tint(theme.memory)
                    HStack {
                        Text("\(MetricFormatter.percent(memory)) of \(MetricFormatter.memory(snapshot.memoryTotalMB))")
                        Spacer()
                        Text("View details")
                    }
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
            } else {
                Text("No live readings").font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open \(snapshot.name) details")
    }

    private var roleLabel: String {
        let role = snapshot.role == "worker" ? "Worker" : snapshot.role == "head" ? "Head" : "Standalone"
        let hardware = snapshot.isGPUHost ? "GPU host" : GB10Identity.match(kind: snapshot.kind, name: snapshot.name, id: snapshot.id, hardware: snapshot.hardware) != nil ? "NVIDIA GB10" : "Spark"
        return "\(role) · \(hardware)"
    }
}

private struct CompactValue: View {
    let label: String
    let value: String
    @Environment(\.sparkTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
