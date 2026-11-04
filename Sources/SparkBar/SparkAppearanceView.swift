import SparkBarCore
import SwiftUI

struct SparkAppearanceView: View {
    @Bindable var model: AppModel
    @Binding var paletteRaw: String
    @Binding var appearanceRaw: String
    let close: () -> Void
    let openSettings: () -> Void
    @Environment(\.sparkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Appearance").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 30, height: 30)
                    .background(theme.control, in: Circle()) }
                    .buttonStyle(.plain).accessibilityLabel("Close appearance")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Color palette").font(.subheadline.weight(.semibold))
                HStack(spacing: 13) {
                    ForEach(SparkPalette.allCases) { palette in
                        Button { paletteRaw = palette.rawValue } label: {
                            VStack(spacing: 7) {
                                HStack(spacing: 0) {
                                    ForEach(palette.accents, id: \.self) { color in Color(hex: color) }
                                }
                                .frame(width: 43, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(3)
                                .overlay { RoundedRectangle(cornerRadius: 9)
                                    .stroke(paletteRaw == palette.rawValue ? theme.secondaryText : .clear, lineWidth: 1.5) }
                                Text(palette.title).font(.system(size: 9))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(palette.title) palette")
                        .accessibilityAddTraits(paletteRaw == palette.rawValue ? [.isSelected] : [])
                    }
                }
            }
            SparkSegmentedControl(options: SparkAppearance.allCases.map(\.rawValue), selection: $appearanceRaw) {
                SparkAppearance(rawValue: $0)?.title ?? $0
            }
            .accessibilityLabel("Appearance")
            Divider()
            Picker("Menu bar", selection: Binding(get: { model.settings.displayMetric }, set: {
                model.settings.displayMetric = $0; model.settings.persist()
            })) {
                ForEach(DisplayMetric.allCases) { metric in Text(metric.title).tag(metric) }
            }
            Picker("Temperature", selection: Binding(get: { model.settings.temperatureUnit }, set: {
                model.settings.temperatureUnit = $0; model.settings.persist()
            })) {
                ForEach(TemperatureUnit.allCases) { unit in Text(unit.title).tag(unit) }
            }
            HStack {
                Button("Connection & all settings…", action: openSettings).buttonStyle(.link)
                Spacer()
                Button { model.openSparkBarRepository() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).accessibilityLabel("About SparkBar")
            }
            .font(.caption)
            Button(action: close) { Text("Done").font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(theme.primary, in: Capsule()).foregroundStyle(theme.onPrimary) }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
        }
        .padding(22)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityAddTraits(.isModal)
    }
}
