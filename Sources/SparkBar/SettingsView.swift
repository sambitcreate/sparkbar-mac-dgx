import SparkBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        TabView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("sparkDash URL")
                            .font(.headline)
                        TextField(
                            "sparkDash URL",
                            text: Binding(
                                get: { model.settings.endpoint },
                                set: { model.settings.endpoint = $0 }
                            ),
                            prompt: Text("http://<sparkDash-host>:5555")
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { model.connectFromSettings() }
                        .accessibilityLabel("sparkDash URL")
                        .onAppear { model.fillEndpointFromLastSuccessIfEmpty() }
                    }

                    if let last = model.settings.lastSuccessfulEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !last.isEmpty,
                       last != model.settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) {
                        LabeledContent("Last connected") {
                            Button(last) {
                                model.settings.endpoint = last
                                model.connectFromSettings()
                            }
                            .buttonStyle(.link)
                            .help("Reuse the last URL that connected successfully")
                        }
                    }

                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.connectionState.isLive ? .green : .secondary)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(model.connectionState.shortLabel)
                        }
                    }

                    HStack {
                        Button("Test & Connect") { model.connectFromSettings() }
                            .disabled(!hasTypedEndpoint)
                        Button("Open sparkDash") { model.openSparkDash() }
                            .disabled(!canOpenSparkDash)
                    }

                    if let endpoint = try? SparkDashEndpoint(model.settings.endpoint), endpoint.shouldWarnAboutInsecureRemote {
                        Label("This remote URL is unencrypted HTTP. Prefer HTTPS or a trusted private network.", systemImage: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let diagnostic = model.lastDiagnostic {
                        Label(diagnostic, systemImage: "waveform.path.ecg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text("SparkBar reads metrics from this sparkDash URL. It does not SSH into the DGX.")
                }

                Section {
                    DiscoveryScanPanel(model: model)
                    Toggle("LAN", isOn: Binding(
                        get: { model.settings.scanLAN },
                        set: { model.settings.scanLAN = $0; model.settings.persist() }
                    ))
                    Toggle("Bonjour", isOn: Binding(
                        get: { model.settings.scanBonjour },
                        set: { model.settings.scanBonjour = $0; model.settings.persist() }
                    ))
                    Toggle("Tailscale peers", isOn: Binding(
                        get: { model.settings.scanTailscaleLocalAPI },
                        set: { model.settings.scanTailscaleLocalAPI = $0; model.settings.persist() }
                    ))
                } header: {
                    Text("Find on this Mac’s network")
                } footer: {
                    Text("LAN covers private /24 networks only, not Tailscale CGNAT. Bonjour needs SPARKDASH_BONJOUR=1 on the server. Tailscale uses this Mac’s Tailscale app peer list, then confirms GET /api/sparks.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Connection", systemImage: "network") }

            Form {
                Section("Menu Bar") {
                    Picker("Display", selection: Binding(
                        get: { model.settings.displayMetric },
                        set: { model.settings.displayMetric = $0; model.settings.persist() }
                    )) {
                        ForEach(DisplayMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    Picker("Source", selection: Binding(
                        get: { model.settings.sourceMode },
                        set: { model.settings.sourceMode = $0; model.settings.persist() }
                    )) {
                        ForEach(SparkSourceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if model.settings.sourceMode == .selected {
                        Picker("Spark", selection: Binding(
                            get: { model.selectedSparkID ?? "" },
                            set: { model.setSelectedSpark($0.isEmpty ? nil : $0) }
                        )) {
                            Text("Choose a Spark").tag("")
                            if model.configuredSparks.isEmpty {
                                ForEach(model.snapshots) { spark in
                                    Text(spark.name).tag(spark.id)
                                }
                            } else {
                                ForEach(model.configuredSparks) { spark in
                                    Text(spark.name).tag(spark.id)
                                }
                            }
                        }
                    }
                }
                Section("Temperature") {
                    Picker("Unit", selection: Binding(
                        get: { model.settings.temperatureUnit },
                        set: { model.settings.temperatureUnit = $0; model.settings.persist() }
                    )) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Display", systemImage: "menubar.rectangle") }

            Form {
                Section("General") {
                    Toggle("Launch SparkBar at login", isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    if model.launchAtLoginService.needsApproval {
                        HStack {
                            Label("macOS requires approval before SparkBar can launch at login.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Login Items Settings") { model.launchAtLoginService.openSystemSettings() }
                                .font(.caption)
                        }
                    }
                    Toggle("Start hidden", isOn: Binding(
                        get: { model.settings.startHidden },
                        set: { model.settings.startHidden = $0; model.settings.persist() }
                    ))
                    Toggle("Show notifications", isOn: Binding(
                        get: { model.settings.showNotifications },
                        set: { model.setNotificationsEnabled($0) }
                    ))
                }
                Section("Alerts") {
                    HStack {
                        Text("Temperature threshold")
                        Spacer()
                        TextField("°C", value: Binding(
                            get: { model.settings.temperatureThreshold },
                            set: {
                                model.settings.temperatureThreshold = min(max($0, 20), 120)
                                model.settings.persist()
                            }
                        ), format: .number)
                        .frame(width: 70)
                    }
                    HStack {
                        Text("Memory threshold")
                        Spacer()
                        TextField("%", value: Binding(
                            get: { model.settings.memoryThreshold },
                            set: {
                                model.settings.memoryThreshold = min(max($0, 20), 100)
                                model.settings.persist()
                            }
                        ), format: .number)
                        .frame(width: 70)
                    }
                    Stepper(value: Binding(
                        get: { model.settings.alertCooldownMinutes },
                        set: { model.settings.alertCooldownMinutes = $0; model.settings.persist() }
                    ), in: 1...120) {
                        Text("Notification cooldown \(Int(model.settings.alertCooldownMinutes)) min")
                    }
                    Text("Notifications use cooldown and hysteresis to prevent repeated alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: versionString)
                    if ProjectLinks.sparkBarRepository != nil {
                        Button("SparkBar repository") { model.openSparkBarRepository() }
                    }
                    if ProjectLinks.sparkDashRepository != nil {
                        Button("sparkDash project") { model.openSparkDashRepository() }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 520, minHeight: 580)
        .padding()
        .modifier(InsecureConnectionAlert(model: model))
    }

    private var hasTypedEndpoint: Bool {
        !model.settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canOpenSparkDash: Bool {
        if (try? SparkDashEndpoint(model.settings.endpoint)) != nil { return true }
        if let last = model.settings.lastSuccessfulEndpoint,
           (try? SparkDashEndpoint(last)) != nil {
            return true
        }
        return false
    }
}
