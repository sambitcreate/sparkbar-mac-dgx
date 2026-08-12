import AppKit
import Observation
import SparkBarCore
import SwiftUI

struct PopoverRootView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @State private var selectedSection: DashboardSection = .overview

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            sectionPicker
            Divider()

            if model.snapshots.isEmpty {
                if model.connectionState.isLive, model.configuredSparks.isEmpty {
                    NoSparksView(model: model)
                } else {
                    ConnectionView(model: model)
                }
            } else {
                ScrollView {
                    Group {
                        if selectedSection == .overview {
                            OverviewView(model: model) { id in
                                selectedSection = .spark(id)
                                model.setSelectedSpark(id)
                            }
                        } else if case .spark(let id) = selectedSection,
                                  let snapshot = model.snapshots.first(where: { $0.id == id }) {
                            SparkDetailView(snapshot: snapshot, isServerLive: model.connectionState.isLive, temperatureUnit: model.effectiveTemperatureUnit)
                        } else if let snapshot = model.selectedSnapshot {
                            SparkDetailView(snapshot: snapshot, isServerLive: model.connectionState.isLive, temperatureUnit: model.effectiveTemperatureUnit)
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.automatic)
            }

            Divider()
            FooterView(model: model, openSettings: openSettings)
        }
        .frame(width: 390, height: 680)
        .background(.regularMaterial)
        .onChange(of: model.snapshots.map(\.id), initial: true) { _, ids in
            if case .spark(let id) = selectedSection, !ids.contains(id) {
                selectedSection = .overview
            }
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                SectionButton(title: "Overview", isSelected: selectedSection == .overview) {
                    selectedSection = .overview
                }
                ForEach(model.snapshots) { snapshot in
                    SectionButton(
                        title: snapshot.name,
                        isSelected: selectedSection == .spark(snapshot.id),
                        status: snapshot.isOnline
                    ) {
                        selectedSection = .spark(snapshot.id)
                        model.setSelectedSpark(snapshot.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spark selection")
    }
}

private enum DashboardSection: Equatable {
    case overview
    case spark(String)
}

private struct HeaderView: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("SparkBar")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SparkBar, \(statusText)")
    }

    private var statusText: String {
        if model.connectionState == .connected {
            return model.snapshots.isEmpty ? "Live" : "Live · \(model.onlineCount) online"
        }
        if model.snapshots.isEmpty { return model.connectionState.shortLabel }
        return "Last known · \(model.connectionState.shortLabel)"
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        default: return .secondary
        }
    }
}

private struct SectionButton: View {
    let title: String
    let isSelected: Bool
    var status: Bool?
    let action: () -> Void

    init(title: String, isSelected: Bool, status: Bool? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.status = status
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let status {
                    Circle()
                        .fill(status ? .green : .secondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(status == false ? "\(title), offline" : title)
    }
}

private struct ConnectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 12)
            Image(systemName: isFailure ? "bolt.triangle.fill" : "bolt.horizontal.circle")
                .font(.system(size: 34))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Connect to sparkDash")
                    .font(.title3.weight(.semibold))
                Text(model.lastError ?? "Enter the dashboard URL to monitor your Sparks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("http://sparkdash:5555", text: Binding(
                get: { model.settings.endpoint },
                set: { model.settings.endpoint = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.connectFromSettings() }
            .accessibilityLabel("sparkDash dashboard URL")

            Button {
                model.connectFromSettings()
            } label: {
                Label(model.connectionState == .connecting ? "Connecting…" : "Connect", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.connectionState == .connecting)

            if case .apiReachableLiveStreamUnavailable = model.connectionState {
                Label("sparkDash found, but the live stream is unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(24)
    }

    private var isFailure: Bool {
        if case .failed = model.connectionState { return true }
        return false
    }
}

private struct NoSparksView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Sparks configured")
                .font(.title3.weight(.semibold))
            Text("Connected to sparkDash, but it has no DGX Spark systems configured yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open sparkDash") { model.openSparkDash() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
    }
}

private struct FooterView: View {
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.openSparkDash()
            } label: {
                Label("Open sparkDash", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .accessibilityLabel("Settings")
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .accessibilityLabel("Quit SparkBar")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
