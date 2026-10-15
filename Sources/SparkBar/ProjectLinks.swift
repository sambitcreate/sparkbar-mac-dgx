import Foundation

/// Project homepages come from Info.plist so a fork can rebrand without
/// touching Swift. Empty or missing keys mean the corresponding About link
/// is omitted.
enum ProjectLinks {
    static var sparkBarRepository: URL? { url(forInfoKey: "SparkBarRepositoryURL") }
    static var sparkDashRepository: URL? { url(forInfoKey: "SparkDashRepositoryURL") }

    private static func url(forInfoKey key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }
}
