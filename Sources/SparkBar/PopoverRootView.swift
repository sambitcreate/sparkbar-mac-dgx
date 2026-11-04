import AppKit
import Observation
import SparkBarCore
import SwiftUI

struct PopoverRootView: View {
    static let contentSize = CGSize(width: 390, height: 680)
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("sparkbar.palette") private var paletteRaw = SparkPalette.slate.rawValue
    @AppStorage("sparkbar.appearance") private var appearanceRaw = SparkAppearance.system.rawValue
    @State private var selectedSection: DashboardSection = .overview
    @State private var showsAppearance = false

    private var appearance: SparkAppearance { SparkAppearance(rawValue: appearanceRaw) ?? .system }
    private var scheme: ColorScheme { appearance.colorScheme ?? systemScheme }
    private var theme: SparkTheme {
        SparkTheme(palette: SparkPalette(rawValue: paletteRaw) ?? .slate, dark: scheme == .dark)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HeaderView(model: model) { showsAppearance = true }
                    .padding(.bottom, 16)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                if !model.snapshots.isEmpty { sectionPicker.padding(.top, 12) }
                footer.padding(.top, 12)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 15)
            .allowsHitTesting(!showsAppearance)
            .accessibilityHidden(showsAppearance)
            if showsAppearance {
                Color.black.opacity(0.22).ignoresSafeArea()
                SparkAppearanceView(model: model, paletteRaw: $paletteRaw, appearanceRaw: $appearanceRaw,
                                    close: { showsAppearance = false },
                                    openSettings: { showsAppearance = false; openSettings() })
                    .padding(13)
                    .onExitCommand { showsAppearance = false }
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(theme.base)
        .foregroundStyle(theme.text)
        .tint(theme.primary)
        .environment(\.sparkTheme, theme)
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(appearance.colorScheme)
        .modifier(InsecureConnectionAlert(model: model))
        .onChange(of: model.snapshots.map(\.id), initial: true) { _, ids in
            if case .spark(let id) = selectedSection, !ids.contains(id) { selectedSection = .overview }
        }
        .onChange(of: model.focusedSparkID) { _, focusedID in
            guard let focusedID else { return }
            if model.snapshots.contains(where: { $0.id == focusedID }) { selectedSection = .spark(focusedID) }
            model.clearFocus()
        }
    }

    @ViewBuilder private var content: some View {
        if model.snapshots.isEmpty {
            if model.connectionState.isLive, model.configuredSparks.isEmpty { NoSparksView(model: model) }
            else { ConnectionView(model: model) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.connectionState.isLive {
                        Label("Last known readings · \(model.connectionState.shortLabel)", systemImage: "wifi.slash")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                        Button("Reconnect") { model.connectFromSettings() }.buttonStyle(.link)
                    }
                    if selectedSection == .overview {
                        OverviewView(model: model) { id in
                            selectedSection = .spark(id)
                            model.setSelectedSpark(id)
                        }
                    } else if let snapshot = visibleSnapshot {
                        SparkDetailView(snapshot: snapshot, isServerLive: model.connectionState.isLive,
                                        isPolling: model.connectionState == .apiReachableLiveStreamUnavailable,
                                        temperatureUnit: model.effectiveTemperatureUnit,
                                        history: model.history.samples(for: snapshot.id),
                                        archivedHistory: model.history.archiveSamples(for: snapshot.id),
                                        outages: model.history.outages)
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var visibleSnapshot: SparkSnapshot? {
        if case .spark(let id) = selectedSection { return model.snapshots.first { $0.id == id } }
        return model.selectedSnapshot
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                SectionButton(title: "Overview", isSelected: selectedSection == .overview, isDevice: false) {
                    selectedSection = .overview
                }
                ForEach(model.snapshots) { snapshot in
                    SectionButton(title: snapshot.name, isSelected: selectedSection == .spark(snapshot.id),
                                  isDevice: !snapshot.isGPUHost, online: snapshot.isOnline) {
                        selectedSection = .spark(snapshot.id)
                        model.setSelectedSpark(snapshot.id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spark selection")
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(snapshotAge(asOf: context.date)).foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button { model.openSparkDash() } label: {
                Label("Open dashboard", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 5)
    }

    private func snapshotAge(asOf date: Date) -> String {
        guard let last = model.lastSnapshotAt else { return "sparkDash" }
        let seconds = max(0, Int(date.timeIntervalSince(last)))
        if seconds < 60 { return "Updated \(seconds)s ago" }
        if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
        return "Updated \(seconds / 3600)h ago"
    }

}

private enum DashboardSection: Equatable { case overview, spark(String) }

private struct HeaderView: View {
    let model: AppModel
    let openAppearance: () -> Void
    @Environment(\.sparkTheme) private var theme
    private var heading: FleetModelHeading? { FleetModelHeading.resolve(model.snapshots) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(heading?.displayName ?? (model.snapshots.isEmpty ? "SparkBar" : "No model loaded"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .lineLimit(3).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(heading?.name ?? "Connect to sparkDash to see the live model")
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(statusText).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: openAppearance) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                    .frame(width: 43, height: 43)
                    .background(theme.control, in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
            .accessibilityLabel("Appearance and settings")
        }
        .padding(.horizontal, 5)
    }

    private var statusText: String {
        let backend = heading?.backend.map { "\($0) · " } ?? ""
        if !model.connectionState.isLive {
            return heading == nil ? model.connectionState.shortLabel : "Disconnected · last known model"
        }
        if heading?.isCurrent == false { return "\(backend)Model unavailable · last known name" }
        let mode = model.connectionState == .apiReachableLiveStreamUnavailable ? "Polling" : "Live"
        return "\(backend)\(mode) · \(model.onlineCount) online"
    }
    private var statusColor: Color {
        model.connectionState.isLive ? Color(hex: theme.dark ? 0x8BBB9E : 0x347451) : .orange
    }
}

private struct SectionButton: View {
    let title: String
    let isSelected: Bool
    let isDevice: Bool
    var online: Bool? = nil
    let action: () -> Void
    @Environment(\.sparkTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isDevice { DGXDeviceIcon().frame(width: 23, height: 19) }
                else { Image(systemName: online == nil ? "square.grid.2x2" : "server.rack").font(.system(size: 13)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 13)
            .frame(minWidth: 105, minHeight: 43)
            .background(isSelected ? theme.primary : theme.control, in: Capsule())
            .foregroundStyle(isSelected ? theme.onPrimary : theme.secondaryText)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(online == false ? "\(title), offline" : title)
    }
}

private struct ConnectionView: View {
    @Bindable var model: AppModel
    private static let endpointPlaceholder = "http://<sparkDash-host>:5555"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: isFailure ? "bolt.triangle.fill" : "bolt.horizontal.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect to sparkDash")
                        .font(.title3.weight(.semibold))
                    Text(model.lastError ?? "Find sparkDash on your network or enter its URL manually.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Transport chatter was recorded but never shown, so a
                    // stream repeatedly dropping frames looked like silence.
                    if let diagnostic = model.lastDiagnostic, model.lastError == nil {
                        Text(diagnostic)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Connection mode", selection: Binding(
                    get: { model.connectionSetupMode },
                    set: { model.connectionSetupMode = $0 }
                )) {
                    Text("Scan").tag(ConnectionSetupMode.scan)
                    Text("Manual").tag(ConnectionSetupMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Connection mode")

                if model.connectionSetupMode == .scan {
                    scanSection
                } else {
                    manualSection
                }

                SparkDashSetupCard(model: model)
            }
            .padding(24)
        }
        .scrollIndicators(.automatic)
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("sparkDash can run on this Mac or on another host reachable over LAN or Tailscale.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if model.discoveryPhase == .scanning {
                    Button("Stop") { model.stopNetworkScan() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        model.startNetworkScan()
                    } label: {
                        Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            DiscoveryScanPanel(model: model, showsStartStop: false)

            Text("LAN scan may miss sparkDash hosts reachable only over Tailscale. Enable Tailscale peers in Settings to probe known peers, or Bonjour if sparkDash advertises _sparkdash._tcp.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(Self.endpointPlaceholder, text: Binding(
                get: { model.settings.endpoint },
                set: { model.settings.endpoint = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.connectFromSettings() }
            .accessibilityLabel("sparkDash dashboard URL")

            if let endpoint = try? SparkDashEndpoint(model.settings.endpoint),
               endpoint.shouldWarnAboutInsecureRemote {
                Label("This remote endpoint uses unencrypted HTTP. Prefer HTTPS/WSS or a trusted private network.", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

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
        }
    }

    private var isFailure: Bool {
        if case .failed = model.connectionState { return true }
        return false
    }
}

private struct SparkDashSetupCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("sparkDash is required", systemImage: "info.circle")
                .font(.headline)

            Text("SparkBar reads metrics from sparkDash; it does not collect DGX metrics itself.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("If sparkDash is not already running:")
                .font(.caption.weight(.semibold))

            Text("cd sparkDash\ndocker compose up --build -d")
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))

            Text("Connect to http://localhost:5555 when sparkDash runs on this Mac, or use the host’s LAN or Tailscale address. For a remote host, configure sparkDash to listen beyond 127.0.0.1. Optional Bonjour: SPARKDASH_BONJOUR=1 advertises _sparkdash._tcp for Scan.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if ProjectLinks.sparkDashRepository != nil {
                Button {
                    model.openSparkDashRepository()
                } label: {
                    Label("Open sparkDash documentation", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
            Text("Connected to sparkDash, but it has no Sparks or GPU hosts configured yet.")
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
