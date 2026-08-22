import Foundation

@main
struct ApiSmoke {
    static func main() async {
        let api = DshApiClient()
        do {
            async let description = api.hostDescription()
            async let sessions = api.sessions()
            async let workspaces = api.workspaces()
            let (host, sessionRows, workspaceRows) = try await (description, sessions, workspaces)

            if let first = sessionRows.first {
                let history = try await api.history(sessionId: first.sessionId, maxMessages: 5)
                _ = try await api.models(sessionId: first.sessionId)
                guard history.events.allSatisfy({ $0.event.seq >= 0 }) else {
                    throw SmokeError.invalidHistory
                }
            }

            let connection = DshLiveConnection(baseURL: api.baseURL)
            let updates = connection.updates
            await connection.start()
            let connected = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await update in updates {
                        if case let .state(state) = update {
                            print("DSH stream state: \(state.label)")
                            if state == .connected { return true }
                        }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            await connection.stop()
            guard connected else { throw SmokeError.streamHandshakeTimedOut }

            print(
                "OpenCodex DSH smoke passed: host \(host.version), "
                    + "\(sessionRows.count) sessions, \(workspaceRows.items.count) workspaces, two streams connected"
            )
        } catch {
            fputs("OpenCodex DSH smoke failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private enum SmokeError: Error {
    case invalidHistory
    case streamHandshakeTimedOut
}
