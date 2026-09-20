import Foundation

/// Guards URLs that originate from the monitored server rather than from the
/// user.
public enum SafeURL {
    /// Returns a URL that is safe to hand to `NSWorkspace.open`, or nil.
    ///
    /// `URL(string:)` accepts `file:` URLs and any custom scheme an installed
    /// application has registered, so passing a server-supplied string straight
    /// to `NSWorkspace.open` lets a rogue or impersonated sparkDash launch
    /// arbitrary handlers on the user's Mac — including `smb:` or `vnc:` URLs
    /// that invite the user to authenticate to an attacker-controlled host.
    /// Only plain `http`/`https` resources with a host and no embedded
    /// credentials qualify.
    public static func openable(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }
}
