import Foundation

/// Classifies a sparkDash unit as an NVIDIA GB10-class Spark after JSON is confirmed.
/// Network discovery must not use this to label IP addresses.
public enum GB10Identity: Sendable {
    public enum Confidence: String, Sendable {
        case kindSpark
        case chip
        case alias
    }

    public struct Match: Equatable, Sendable {
        public var family: String
        public var vendorHint: String?
        public var confidence: Confidence

        public init(family: String, vendorHint: String? = nil, confidence: Confidence) {
            self.family = family
            self.vendorHint = vendorHint
            self.confidence = confidence
        }
    }

    public static func match(kind: String?, name: String?, id: String?, hardware: HardwareInfo?) -> Match? {
        if !SparkSnapshot.isGPUHost(kind: kind) {
            return Match(family: "GB10", confidence: .kindSpark)
        }

        if let chipMatch = matchChip(hardware: hardware) {
            return chipMatch
        }
        if let aliasMatch = matchAlias(name: name, id: id, hardware: hardware) {
            return aliasMatch
        }
        return nil
    }

    // MARK: - Chip-level signals

    private static let chipPatterns: [(pattern: String, hint: String)] = [
        ("vgn100", "VGN100"),
        ("gn100", "GN100"),
        ("gb10", "GB10"),
        ("gx10", "GX10"),
    ]

    private static func matchChip(hardware: HardwareInfo?) -> Match? {
        let fields = [hardware?.gpuChip, hardware?.cpuModel].compactMap { $0?.lowercased() }
        for field in fields {
            for (pattern, hint) in chipPatterns where field.contains(pattern) {
                return Match(family: "GB10", vendorHint: hint, confidence: .chip)
            }
        }
        return nil
    }

    // MARK: - Vendor / product aliases (host kind only)

    private static let aliasPatterns: [(pattern: String, hint: String)] = [
        ("nvidia gb10", "NVIDIA GB10"),
        ("ascent gx10", "ASUS Ascent GX10"),
        ("thinkstation pgx", "Lenovo ThinkStation PGX"),
        ("veriton gn100", "Acer Veriton GN100"),
        ("fcm1253", "FCM1253"),
        ("atagb10", "ATAGB10"),
        ("zgx nano", "ZGX Nano"),
        ("vgn100", "VGN100"),
        ("gx10", "GX10"),
        ("gn100", "GN100"),
        ("pgx", "PGX"),
        ("30kl", "30KL"),
        ("30km", "30KM"),
        ("edgexpert", "EdgeXpert"),
        ("ms-c931", "MS-C931"),
        ("megacube", "MegaCube"),
        ("linseer", "LinSeer"),
        ("fusionxpark", "FusionXpark"),
        ("project digits", "Project DIGITS"),
        ("founder's edition", "Founder's Edition"),
        ("founders edition", "Founder's Edition"),
        ("founder edition", "Founder's Edition"),
    ]

    private static let weakTokens: Set<String> = ["spark", "dgx", "gpu", "nano", "atom"]

    private static func matchAlias(name: String?, id: String?, hardware: HardwareInfo?) -> Match? {
        let haystack = normalizedHaystack(name: name, id: id, hardware: hardware)
        guard !haystack.isEmpty else { return nil }

        for (pattern, hint) in aliasPatterns where haystack.contains(pattern) {
            return Match(family: "GB10", vendorHint: hint, confidence: .alias)
        }

        let tokens = tokenize(haystack)
        if !tokens.isEmpty, tokens.isSubset(of: weakTokens) {
            return nil
        }
        return nil
    }

    private static func normalizedHaystack(name: String?, id: String?, hardware: HardwareInfo?) -> String {
        [name, id, hardware?.device]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func tokenize(_ value: String) -> Set<String> {
        Set(
            value
                .split { !$0.isLetter && !$0.isNumber }
                .map { String($0).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}
