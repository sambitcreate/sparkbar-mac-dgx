import SwiftUI

/// One confirmation is required for each public HTTP endpoint. The accepted
/// URL is saved by AppModel, so reconnects to that exact URL can resume.
struct InsecureConnectionAlert: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            "Connect over unencrypted HTTP?",
            isPresented: Binding(
                get: { model.pendingInsecureEndpoint != nil },
                set: { if !$0 { model.cancelPendingInsecureConnection() } }
            )
        ) {
            Button("Connect over HTTP") { model.confirmPendingInsecureConnection() }
            Button("Cancel", role: .cancel) { model.cancelPendingInsecureConnection() }
        } message: {
            Text("Traffic to \(model.pendingInsecureEndpoint?.displayString ?? "this server") can be read or changed on the network. Use HTTPS if available.")
        }
    }
}
