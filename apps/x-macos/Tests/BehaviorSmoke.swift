import Foundation

@main
@MainActor
struct BehaviorSmoke {
    static func main() async {
        guard CommandLine.arguments.count == 4,
              let baseURL = URL(string: CommandLine.arguments[1]) else {
            fputs("usage: behavior-smoke <base-url> <workspace> <prompt-file>\n", stderr)
            exit(2)
        }

        let workspace = CommandLine.arguments[2]
        let promptFile = CommandLine.arguments[3]
        UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
        defer { UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId") }

        do {
            let prompt = try String(contentsOfFile: promptFile, encoding: .utf8)
            let api = DshApiClient(baseURL: baseURL)
            let sessionId = try await api.createSession(cwd: workspace)

            let store = OpenCodexStore(baseURL: baseURL)
            await store.boot()
            guard store.errorBanner == nil else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "native bootstrap failed")
            }
            await store.selectSession(sessionId)
            guard store.errorBanner == nil else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "session selection failed")
            }
            try await waitUntil("permissions projection") { store.currentPermissions != nil }

            guard let readOnly = store.currentPermissions?.options.first(where: { $0.value == "read-only" }) else {
                throw BehaviorSmokeError.missingReadOnlyPreset
            }
            await store.choosePermission(readOnly)
            guard store.errorBanner == nil else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "permission switch failed")
            }
            try await waitUntil("read-only permission switch") {
                store.currentPermissions?.currentValue == "read-only"
            }

            store.draft = prompt
            await store.send()
            guard store.errorBanner == nil else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "prompt failed")
            }
            try await waitUntil("approval request", timeoutSeconds: 45) {
                store.selectedApprovals.count == 1
            }

            guard let approval = store.selectedApprovals.first else {
                throw BehaviorSmokeError.missingApproval
            }
            await store.answer(approval, allow: true)
            guard store.errorBanner == nil else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "approval failed")
            }
            try await waitUntil("completed tool and final answer", timeoutSeconds: 60) {
                store.selectedApprovals.isEmpty
                    && store.currentSession?.running == false
                    && store.conversation.contains {
                        $0.kind == .activity && $0.activityState == .completed
                    }
                    && store.conversation.contains {
                        $0.kind == .assistant
                            && !$0.isStreaming
                            && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "DONE"
                    }
            }
            await store.shutdown()

            let output = workspace + "/notes.txt"
            guard FileManager.default.fileExists(atPath: output),
                  !(try String(contentsOfFile: output, encoding: .utf8)).isEmpty else {
                throw BehaviorSmokeError.toolDidNotWrite
            }

            let resumed = OpenCodexStore(baseURL: baseURL)
            await resumed.boot()
            await resumed.selectSession(sessionId)
            try await waitUntil("resumed durable transcript") {
                resumed.selectedApprovals.isEmpty
                    && resumed.conversation.contains {
                        $0.kind == .assistant
                            && !$0.isStreaming
                            && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "DONE"
                    }
            }
            await resumed.shutdown()

            print("OpenCodex behavior smoke passed: DSH prompt, approval, tool result, final answer, and restart resume")
        } catch {
            fputs("OpenCodex behavior smoke failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func waitUntil(
        _ label: String,
        timeoutSeconds: Double = 15,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BehaviorSmokeError.timedOut(label)
    }
}

private enum BehaviorSmokeError: Error, CustomStringConvertible {
    case missingReadOnlyPreset
    case missingApproval
    case storeFailure(String)
    case timedOut(String)
    case toolDidNotWrite

    var description: String {
        switch self {
        case .missingReadOnlyPreset: return "DSH did not advertise the read-only permission preset"
        case .missingApproval: return "the pending approval disappeared before it could be answered"
        case let .storeFailure(message): return message
        case let .timedOut(label): return "timed out waiting for \(label)"
        case .toolDidNotWrite: return "the approved DSH tool did not write its expected workspace file"
        }
    }
}
