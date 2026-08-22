import Foundation

struct MacProjectionSnapshot: Codable, Sendable {
    let version: Int
    let host: String
    let savedAt: Date
    let workspaces: [WorkspaceView]
    let sessions: [SessionSummary]
    let archivedSessionIds: Set<String>
    let recordsBySession: [String: [SessionEventRecord]]
    let historyHasMoreBySession: [String: Bool]
    let projectionsBySession: [String: [String: ProjectionCell]]
    let selectedWorkspaceId: String?
    let selectedSessionId: String?
}

/// A bounded, read-only projection used to render useful state while the Host reconnects.
/// DSH remains authoritative and cached values are never replayed as mutations.
actor MacProjectionCache {
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    func load(matching host: URL) -> MacProjectionSnapshot? {
        guard let url = try? cacheURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(MacProjectionSnapshot.self, from: data),
              snapshot.version == 1,
              snapshot.host == host.absoluteString,
              Date().timeIntervalSince(snapshot.savedAt) <= maximumAge else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: MacProjectionSnapshot) {
        guard let url = try? cacheURL(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            // Projection persistence must never interfere with Host-backed operation.
        }
    }

    private func cacheURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "OpenCodex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "mac-projection-v1.json")
    }
}
