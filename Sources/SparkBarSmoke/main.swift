import Foundation
import SparkBarCore

@main
struct SparkBarSmoke {
    static func main() async {
        let rawURL = CommandLine.arguments.dropFirst().first ?? "http://100.101.194.105:5555"
        do {
            let endpoint = try SparkDashEndpoint(rawURL)
            let client = SparkDashClient(endpoint: endpoint)
            let result = try await client.testConnection()
            print("REST OK: \(result.sparkCount) Spark(s) at \(result.endpoint.displayString) · settings temperature \(result.settings?.temperatureUnit ?? "unavailable")")

            let events = await client.events()
            await client.start()
            for await event in events {
                switch event {
                case .snapshot(let envelope):
                    let online = envelope.sparks.filter(\.isOnline).count
                    print("WS OK: snapshot with \(envelope.sparks.count) Spark(s), \(online) online, refresh \(envelope.refreshInterval.map(String.init) ?? "—") ms")
                    await client.stop()
                    return
                case .state(let state):
                    print("STATE: \(state.shortLabel)")
                case .connectionTested, .diagnostic:
                    break
                }
            }
        } catch {
            fputs("SparkBar smoke test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
