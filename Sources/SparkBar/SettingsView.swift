import SparkBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Form {
                Section("Connection") {
                    TextField("sparkDash URL", text: Binding(
                        get: { model.settings.endpoint },
                        set: { model.settings.endpoint = $0 }
                    ))
                    HStack {
                        Circle()
                            .fill(model.connectionState.isLive ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(model.connectionState.shortLabel)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Test & Connect") { model.connectFromSettings() }
                    }
                    Button("Open sparkDash") { model.openSparkDash() }
                    if let endpoint = try? SparkDashEndpoint(model.settings.endpoint), endpoint.shouldWarnAboutInsecureRemote {
                        Label("This remote endpoint uses unencrypted HTTP. Prefer HTTPS/WSS or a trusted private network.", systemImage: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
                            ForEach(model.snapshots) { spark in
                                Text(spark.name).tag(spark.id)
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
                            set: { model.settings.temperatureThreshold = $0; model.settings.persist() }
                        ), format: .number)
                        .frame(width: 70)
                    }
                    HStack {
                        Text("Memory threshold")
                        Spacer()
                        TextField("%", value: Binding(
                            get: { model.settings.memoryThreshold },
                            set: { model.settings.memoryThreshold = $0; model.settings.persist() }
                        ), format: .number)
                        .frame(width: 70)
                    }
                    Text("Notifications use cooldown and hysteresis to prevent repeated alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 500, minHeight: 520)
        .padding()
    }
}
