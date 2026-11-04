import AppKit
import SwiftUI

enum SparkPalette: String, CaseIterable, Identifiable {
    case slate, mineral, clay, lichen, ink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var accents: [UInt32] {
        switch self {
        case .slate: [0x425C75, 0x496F69, 0x8C684A]
        case .mineral: [0x416B72, 0x64628A, 0x876847]
        case .clay: [0x855B50, 0x536D78, 0x75714B]
        case .lichen: [0x5D6D55, 0x53677D, 0x876256]
        case .ink: [0x555E7C, 0x6E657D, 0x7C694F]
        }
    }
    var darkAccents: [UInt32] {
        switch self {
        case .slate: [0xA4BAD0, 0xA6C8BD, 0xD2B699]
        case .mineral: [0xA1C5CC, 0xC0BADC, 0xCFB496]
        case .clay: [0xD8B5AA, 0xAFC6CF, 0xCBC69D]
        case .lichen: [0xB9C9AC, 0xB0C0D4, 0xD1B5A9]
        case .ink: [0xB7C1DF, 0xC8BDD5, 0xCFBD9F]
        }
    }
    var layers: [UInt32] {
        switch self {
        case .slate: [0xEFF1F3, 0xFFFFFF, 0xE7EAED, 0x1D2126, 0x272C33, 0x323840]
        case .mineral: [0xEFF2F1, 0xFFFFFF, 0xE5EBE9, 0x1C2324, 0x262F31, 0x323C3E]
        case .clay: [0xF3F0ED, 0xFEFDFB, 0xEAE4DE, 0x26211F, 0x302A27, 0x3B3430]
        case .lichen: [0xF0F1ED, 0xFEFEFB, 0xE5E8DE, 0x21241E, 0x2B2F27, 0x363B30]
        case .ink: [0xF0F0F3, 0xFFFFFF, 0xE6E7ED, 0x202127, 0x2A2B33, 0x353640]
        }
    }
}

enum SparkAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct SparkTheme {
    var palette: SparkPalette = .slate
    var dark = false
    var primary: Color { Color(hex: (dark ? palette.darkAccents : palette.accents)[0]) }
    var memory: Color { Color(hex: (dark ? palette.darkAccents : palette.accents)[1]) }
    var power: Color { Color(hex: (dark ? palette.darkAccents : palette.accents)[2]) }
    var base: Color { Color(hex: palette.layers[dark ? 3 : 0]) }
    var surface: Color { Color(hex: palette.layers[dark ? 4 : 1]) }
    var control: Color { Color(hex: palette.layers[dark ? 5 : 2]) }
    var text: Color { Color(hex: dark ? 0xECEEF1 : 0x292D32) }
    var secondaryText: Color { Color(hex: dark ? 0xB6BCC5 : 0x5E646D) }
    var onPrimary: Color { Color(hex: dark ? 0x20252B : 0xFFFFFF) }
    var hairline: Color { text.opacity(0.08) }
}

extension EnvironmentValues {
    @Entry var sparkTheme = SparkTheme()
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255, opacity: 1)
    }
}

/// AppKit preserves the supplied SVG as a vector representation at every size.
struct DGXDeviceIcon: View {
    @MainActor private static let image: NSImage? = {
        let url = Bundle.main.url(forResource: "DGXSpark", withExtension: "svg")
            ?? Bundle.module.url(forResource: "DGXSpark", withExtension: "svg")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "server.rack").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Flat capsule segments avoid the beveled system tint used by macOS pickers.
struct SparkSegmentedControl<Selection: Hashable>: View {
    let options: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    @Environment(\.sparkTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(selection == option ? theme.surface : .clear, in: Capsule())
                        .foregroundStyle(selection == option ? theme.text : theme.secondaryText)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(theme.control, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
