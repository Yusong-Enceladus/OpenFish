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

        let workspaceArgument = CommandLine.arguments[2]
        let workspace: String? = workspaceArgument == "--no-project" ? nil : workspaceArgument
        let promptFile = CommandLine.arguments[3]
        UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
        UserDefaults.standard.removeObject(forKey: "OpenFish.defaultHarnessId")
        defer {
            UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
            UserDefaults.standard.removeObject(forKey: "OpenFish.defaultHarnessId")
        }

        do {
            let prompt = try String(contentsOfFile: promptFile, encoding: .utf8)
            let api = DshApiClient(baseURL: baseURL)
            let store = OpenCodexStore(baseURL: baseURL)
            await store.boot()
            guard store.errorBanner == nil else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "native bootstrap failed")
            }

            // A clean Host deliberately has no fabricated default Harness.
            // Exercise the same native onboarding action a first-time user
            // takes before asking the Host to create either kind of task.
            await store.loadHarnessCatalogForOnboarding()
            guard store.harnessCatalogError == nil else {
                throw BehaviorSmokeError.storeFailure(store.harnessCatalogError ?? "Harness catalog failed")
            }
            guard let dsh = store.harnesses.first(where: { $0.id == "dsh" }) else {
                throw BehaviorSmokeError.missingDSHHarness
            }
            await store.selectDefaultHarness(dsh, completesOnboarding: true)
            guard store.errorBanner == nil,
                  store.selectedHarnessId == dsh.id,
                  !store.needsHarnessOnboarding else {
                throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "default Harness onboarding did not complete")
            }

            let workspaceId: String?
            if let workspace {
                workspaceId = try await api.createWorkspace(path: workspace).workspaceId
            } else {
                workspaceId = nil
            }
            store.beginNewTask(in: workspaceId)
            try await waitUntil("prepared native draft") {
                guard let draftSessionId = store.draftSessionId else { return false }
                return store.sessions.contains(where: { $0.sessionId == draftSessionId })
                    && store.currentPermissions != nil
                    && store.sessionModels != nil
            }
            guard let sessionId = store.draftSessionId else {
                throw BehaviorSmokeError.missingPreparedDraft
            }
            try await waitUntil("permissions projection") { store.currentPermissions != nil }
            guard let effectiveWorkspace = store.sessions.first(where: { $0.sessionId == sessionId })?.cwd,
                  !effectiveWorkspace.isEmpty else {
                throw BehaviorSmokeError.missingEffectiveWorkspace
            }
            if workspace == nil {
                guard effectiveWorkspace.contains("/openfish/sessions/no-workspace/\(sessionId)") else {
                    throw BehaviorSmokeError.invalidNoProjectWorkspace(effectiveWorkspace)
                }
            }

            // Fresh installations intentionally start without a fabricated
            // provider selection. Exercise the same first-run model choice a
            // user makes instead of depending on a developer machine's saved
            // default; the replay adapter keeps this hermetic and credential-free.
            try await waitUntil("model directory") { store.sessionModels != nil }
            if store.sessionModels?.routable != true {
                guard let group = store.sessionModels?.groups.first(where: { !$0.models.isEmpty }),
                      let model = group.models.first else {
                    throw BehaviorSmokeError.missingRoutableModel
                }
                await store.chooseModel(
                    provider: group.id,
                    model: model,
                    effort: model.reasoning?.defaultEffort
                )
                guard store.errorBanner == nil else {
                    throw BehaviorSmokeError.storeFailure(store.errorBanner ?? "model switch failed")
                }
                try await waitUntil("routable model selection") {
                    store.sessionModels?.routable == true
                }
            }

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
            do {
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
            } catch {
                let tail = store.conversation.suffix(12).map { item in
                    let text = item.text.replacingOccurrences(of: "\n", with: " ").prefix(120)
                    return "seq=\(item.seq) kind=\(item.kind) state=\(String(describing: item.activityState)) streaming=\(item.isStreaming) text=\(text)"
                }.joined(separator: " | ")
                let banner = store.errorBanner ?? "none"
                throw BehaviorSmokeError.storeFailure(
                    "\(error); session=\(sessionId) running=\(String(describing: store.currentSession?.running)) approvals=\(store.selectedApprovals.count) banner=\(banner) transcript=[\(tail)]"
                )
            }
            await store.shutdown()

            let output = effectiveWorkspace + "/notes.txt"
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

            let mode = workspace == nil ? "No Project" : "project"
            print("OpenCodex behavior smoke passed (\(mode)): DSH prompt, approval, tool result, final answer, and restart resume")
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
    case missingDSHHarness
    case missingPreparedDraft
    case missingReadOnlyPreset
    case missingRoutableModel
    case missingEffectiveWorkspace
    case invalidNoProjectWorkspace(String)
    case missingApproval
    case storeFailure(String)
    case timedOut(String)
    case toolDidNotWrite

    var description: String {
        switch self {
        case .missingDSHHarness: return "the clean Host did not advertise the built-in DSH Harness"
        case .missingPreparedDraft: return "the native new-task flow did not retain its prepared session identity"
        case .missingReadOnlyPreset: return "DSH did not advertise the read-only permission preset"
        case .missingRoutableModel: return "DSH did not advertise a routable model for the replay fixture"
        case .missingEffectiveWorkspace: return "the created session did not expose an effective working directory"
        case let .invalidNoProjectWorkspace(path): return "No Project resolved outside its private managed directory: \(path)"
        case .missingApproval: return "the pending approval disappeared before it could be answered"
        case let .storeFailure(message): return message
        case let .timedOut(label): return "timed out waiting for \(label)"
        case .toolDidNotWrite: return "the approved DSH tool did not write its expected workspace file"
        }
    }
}
