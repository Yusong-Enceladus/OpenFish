import Foundation
import CryptoKit

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
    /// A provider-backed task that has been prepared for model/config discovery
    /// but has not received its first user prompt yet. Persisting the identity
    /// prevents an invisible blank provider task from being recreated at every
    /// launch while keeping the composer text itself out of the cache.
    let draftSessionId: String?
    let draftHarnessId: String?
}

/// A bounded, read-only projection used to render useful state while the Host reconnects.
/// DSH remains authoritative and cached values are never replayed as mutations.
actor MacProjectionCache {
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    func load(matching host: URL) -> MacProjectionSnapshot? {
        guard let urls = try? candidateURLs(for: host) else { return nil }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(MacProjectionSnapshot.self, from: data),
                  (1...2).contains(snapshot.version),
                  snapshot.host == host.absoluteString,
                  Date().timeIntervalSince(snapshot.savedAt) <= maximumAge else {
                continue
            }
            return snapshot
        }
        return nil
    }

    func save(_ snapshot: MacProjectionSnapshot) {
        guard let host = URL(string: snapshot.host),
              let url = try? cacheURL(for: host),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            // Version 1 used one global, misbranded cache file. Remove it only
            // after the host-keyed OpenFish snapshot is durably written.
            try? FileManager.default.removeItem(at: legacyCacheURL())
        } catch {
            // Projection persistence must never interfere with Host-backed operation.
        }
    }

    func clear(matching host: URL) {
        if let url = try? cacheURL(for: host) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: legacyCacheURL())
    }

    private func candidateURLs(for host: URL) throws -> [URL] {
        [try cacheURL(for: host), legacyCacheURL()]
    }

    private func cacheURL(for host: URL) throws -> URL {
        try cacheDirectory().appending(path: "mac-\(hostKey(host))-projection-v2.json")
    }

    private func cacheDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "OpenFish", directoryHint: .isDirectory)
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }

    private func legacyCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/OpenCodex", directoryHint: .isDirectory)
            .appending(path: "mac-projection-v1.json")
    }

    private func hostKey(_ host: URL) -> String {
        SHA256.hash(data: Data(host.absoluteString.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
