import SparkBarCore
import SwiftUI

/// Scan progress and hits. Used in Settings and the first-run popover so a
/// scan started from Settings is not invisible while the dashboard is Live.
struct DiscoveryScanPanel: View {
    @Bindable var model: AppModel
    var showsStartStop: Bool = true

    var body: some View {
        Group {
            LabeledContent("Known host") {
                TextField("Optional hostname or IP", text: Binding(
                    get: { model.settings.scanKnownHost },
                    set: { model.settings.scanKnownHost = $0; model.settings.persist() }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Known sparkDash hostname or IP")
            }
            LabeledContent("Probe port") {
                TextField("Port", value: Binding(
                    get: { model.settings.scanPort },
                    set: {
                        guard (1...65535).contains($0) else { return }
                        model.settings.scanPort = $0
                        model.settings.persist()
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .accessibilityLabel("sparkDash probe port")
            }
            Text("Known host checks one address. LAN scans only private /24 networks.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if showsStartStop {
                if model.discoveryPhase == .scanning {
                    Button("Stop scan") { model.stopNetworkScan() }
                } else {
                    Button("Scan for sparkDash…") { model.openConnectionScan() }
                }
            }

            if model.discoveryPhase == .scanning {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if let progress = model.discoveryProgress, progress.total > 0 {
                            ProgressView(value: Double(progress.checked), total: Double(progress.total))
                                .frame(width: 56)
                            Text("Checked \(progress.checked) of \(progress.total)")
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text("Looking for sparkDash…")
                        }
                    }
                }
            } else if model.discoveryPhase == .completed {
                LabeledContent("Status") {
                    Text(model.discoveryHits.isEmpty ? "None found" : "\(model.discoveryHits.count) found")
                }
            } else if model.discoveryPhase == .failed {
                LabeledContent("Status") {
                    Text(model.discoveryError ?? "Scan failed")
                        .foregroundStyle(.orange)
                }
            }

            if let error = model.discoveryError, model.discoveryPhase != .failed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(model.discoveryHits) { hit in
                Button {
                    model.connectToDiscoveryHit(hit)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.name)
                        Text("\(sourceLabel(hit.source)) · \(hit.displayURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sourceLabel(_ source: SparkDashDiscoverySource) -> String {
        switch source {
        case .mdns: return "Bonjour"
        case .probe: return "LAN"
        case .knownHost: return "Known host"
        case .tailnet: return "Tailscale"
        }
    }
}
