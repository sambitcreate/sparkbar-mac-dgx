import Foundation
import SparkBarCore

@main
struct SparkBarSmoke {
    private enum SmokeError: LocalizedError {
        case streamEnded

        var errorDescription: String? { "The live stream ended without a snapshot." }
    }

    nonisolated private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("SparkBar smoke test failed: \(message)\n".utf8))
        exit(code)
    }

    static func main() async {
        var rawURL: String?
        var timeout: TimeInterval = 20
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--help", "-h":
                print("Usage: SparkBarSmoke [URL] [--timeout SECONDS]")
                print("Wait up to 20 seconds by default for REST validation and a WebSocket snapshot.")
                return
            case "--timeout":
                guard let value = arguments.next(), let seconds = TimeInterval(value),
                      seconds.isFinite, seconds > 0, seconds <= 86_400 else {
                    fail("--timeout must be a number greater than 0 and at most 86400 seconds.", code: 2)
                }
                timeout = seconds
            default:
                guard !argument.hasPrefix("-"), rawURL == nil else {
                    fail("Usage: SparkBarSmoke [URL] [--timeout SECONDS]", code: 2)
                }
                rawURL = argument
            }
        }

        // This is a command-line watchdog, not a structured-concurrency race:
        // waiting for a cancelled stream child could itself prevent termination.
        // Cover REST validation too, even if the server never sends a response.
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let timeoutMessage = "No successful REST/WebSocket check within \(timeout) seconds."
        deadline.schedule(deadline: .now() + timeout)
        let expire: @Sendable () -> Void = { fail(timeoutMessage) }
        deadline.setEventHandler(handler: expire)
        deadline.resume()
        defer { deadline.cancel() }

        do {
            let endpoint = try SparkDashEndpoint(rawURL ?? "http://localhost:5555")
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
            throw SmokeError.streamEnded
        } catch {
            fail(error.localizedDescription)
        }
    }
}
