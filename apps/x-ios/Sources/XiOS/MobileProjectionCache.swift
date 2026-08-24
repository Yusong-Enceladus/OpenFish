import Foundation
import CryptoKit

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
    /// Identity only: prompt text and pending attachments remain memory-only.
    /// This lets iPhone resume the exact blank provider task after backgrounding
    /// instead of creating an invisible duplicate upstream.
    let draftSessionId: String?
    let draftHarnessId: String?
}

/// A bounded, read-only client projection of DSH state for launch and reconnect UX.
/// The Host remains authoritative; this file never accepts local mutations for replay.
actor MobileProjectionCache {
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    func load(matching host: URL) -> MobileProjectionSnapshot? {
        guard let urls = try? candidateURLs(for: host) else { return nil }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(MobileProjectionSnapshot.self, from: data),
                  (1...2).contains(snapshot.version),
                  snapshot.host == host.absoluteString,
                  Date().timeIntervalSince(snapshot.savedAt) <= maximumAge else {
                continue
            }
            return snapshot
        }
        return nil
    }

    func save(_ snapshot: MobileProjectionSnapshot) {
        guard let host = URL(string: snapshot.host),
              let url = try? cacheURL(for: host),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            try? FileManager.default.removeItem(at: legacyCacheURL())
        } catch {
            // Offline projection failure must never interfere with Host-backed operation.
        }
    }

    func clear(matching host: URL) {
        if let url = try? cacheURL(for: host) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: legacyCacheURL())
    }

    private func candidateURLs(for host: URL) throws -> [URL] {
        [try cacheURL(for: host), legacyCacheURL()]
    }

    private func cacheURL(for host: URL) throws -> URL {
        try cacheDirectory().appending(path: "iphone-\(hostKey(host))-projection-v2.json")
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
                attributes: [
                    .posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
        }
        try manager.setAttributes(
            [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: directory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }

    private func legacyCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenCodex", directoryHint: .isDirectory)
            .appending(path: "iphone-projection-v1.json")
    }

    private func hostKey(_ host: URL) -> String {
        SHA256.hash(data: Data(host.absoluteString.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
