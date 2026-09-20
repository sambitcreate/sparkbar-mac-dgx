import Foundation
import Testing
import SparkBarCore

@Suite("Safe URL guard")
struct SafeURLTests {
    @Test func acceptsPlainWebResources() {
        #expect(SafeURL.openable("http://192.168.1.10:8188")?.absoluteString == "http://192.168.1.10:8188")
        #expect(SafeURL.openable("https://comfy.example.test/ui")?.absoluteString == "https://comfy.example.test/ui")
        #expect(SafeURL.openable("  http://10.0.0.5:8188  ")?.absoluteString == "http://10.0.0.5:8188")
    }

    /// `ComfyMetrics.openUrl` comes from the monitored server, so anything that
    /// could hand off to a local handler must be refused.
    @Test func refusesNonWebSchemes() {
        for value in [
            "file:///Applications/Calculator.app",
            "file:///etc/passwd",
            "smb://user:pass@attacker.test/share",
            "vnc://attacker.test",
            "ssh://attacker.test",
            "x-apple.systempreferences:com.apple.preference.security",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ftp://attacker.test/payload"
        ] {
            #expect(SafeURL.openable(value) == nil, "should refuse \(value)")
        }
    }

    @Test func refusesCredentialsAndMissingHosts() {
        #expect(SafeURL.openable("http://user:secret@10.0.0.5:8188") == nil)
        #expect(SafeURL.openable("http://user@10.0.0.5:8188") == nil)
        #expect(SafeURL.openable("http://") == nil)
        #expect(SafeURL.openable("") == nil)
        #expect(SafeURL.openable("   ") == nil)
        #expect(SafeURL.openable(nil) == nil)
    }
}
