import Foundation

@MainActor final class MemoryCredentials: RemoteCredentialStorage {
    var data = Data("{}".utf8)
    func read() -> Data? { data }
    func write(_ data: Data) -> Bool { self.data = data; return true }
}

// Test receiver: memory-only credentials, test port, no MacTVModel and no system input.
@main struct ServerHarness {
    @MainActor static func main() async throws {
        let server = RemoteServer(storage: MemoryCredentials(), id: UUID().uuidString, port: 8766)
        var count = 0
        server.command = { command in
            count += 1
            if command["kind"] as? String == "text", command["text"] as? String == "__mactv_test_drop__" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    server.restart()
                }
            }
            if command["kind"] as? String == "unknown" { return ("unsupported", "Unknown test command") }
            return ("dispatched", "Recorded by transport test receiver")
        }
        server.context = { ["app": "spotify", "title": "Spotify", "keys": ["previous", "next", "app_search"], "foreground": true] }
        server.start()
        for _ in 0..<100 {
            if server.status.hasPrefix("Listening") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard server.status.hasPrefix("Listening") else { fatalError(server.status) }
        server.host = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "127.0.0.1"
        server.newInvitation()
        try server.invitation.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        var previousStatus = ""
        for _ in 0..<1800 {
            if server.status != previousStatus { previousStatus = server.status; print("Receiver: \(previousStatus)"); fflush(stdout) }
            if let name = server.pendingName { server.approve(!name.contains("reject-test")) }
            try await Task.sleep(for: .milliseconds(100))
        }
        server.stop()
        print("Harness stopped: \(count) commands")
    }
}
