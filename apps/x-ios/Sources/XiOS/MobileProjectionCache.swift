import Foundation

struct MobileProjectionSnapshot: Codable, Sendable {
    let version: Int
    let host: String
    let savedAt: Date
    let workspaces: [MobileWorkspace]
    let sessions: [MobileSession]
    let archived: Set<String>
    let records: [String: [MobileEventRecord]]
    let historyHasMore: [String: Bool]
    let projections: [String: [String: MobileJSONValue]]
    let selectedWorkspaceId: String?
    let selectedSessionId: String?
}

/// A bounded, read-only client projection of DSH state for launch and reconnect UX.
/// The Host remains authoritative; this file never accepts local mutations for replay.
actor MobileProjectionCache {
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    func load(matching host: URL) -> MobileProjectionSnapshot? {
        guard let url = try? cacheURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(MobileProjectionSnapshot.self, from: data),
              snapshot.version == 1,
              snapshot.host == host.absoluteString,
              Date().timeIntervalSince(snapshot.savedAt) <= maximumAge else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: MobileProjectionSnapshot) {
        guard let url = try? cacheURL(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            // Offline projection failure must never interfere with Host-backed operation.
        }
    }

    func clear() {
        guard let url = try? cacheURL() else { return }
        try? FileManager.default.removeItem(at: url)
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
        return directory.appending(path: "iphone-projection-v1.json")
    }
}
