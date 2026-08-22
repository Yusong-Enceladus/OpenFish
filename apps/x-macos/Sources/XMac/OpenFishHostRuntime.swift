import Foundation
import Darwin

/// Starts the Host embedded in the app bundle when no compatible local Host is already healthy.
@MainActor
enum OpenFishHostRuntime {
    private static var process: Process?
    private static let launcherRuntimeVersion = "embedded-harness-runtime-v1"

    private struct RuntimeManifest: Decodable {
        let runtimeId: String
    }

    private struct Health: Decodable {
        let ok: Bool
        let product: String
        let protocolVersion: String
        let host: String
        let surface: String
        let embeddedRuntimeId: String?
        let embeddedProcessId: Int32?
    }

    private enum LocalHostState {
        case absent
        case compatible
        case unmanaged
        case stale(pid: Int32)
    }

    static func bootstrapIfNeeded() {
        guard let resources = Bundle.main.resourceURL else { return }
        let runtime = resources.appendingPathComponent("OpenFishHostRuntime", isDirectory: true)
        let node = runtime.appendingPathComponent("node/bin/node")
        let host = runtime.appendingPathComponent("app/lib/bin.js")
        let manifest = runtime.appendingPathComponent("runtime.json")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: host.path),
              let data = try? Data(contentsOf: manifest),
              let expected = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { return }

        let managedRuntimeId = "\(expected.runtimeId):\(launcherRuntimeVersion)"
        switch localHostState(expectedRuntimeId: managedRuntimeId) {
        case .compatible, .unmanaged:
            return
        case .stale(let pid):
            guard kill(pid, SIGTERM) == 0 else { return }
            var retired = false
            for _ in 0..<20 {
                if case .absent = localHostState(expectedRuntimeId: expected.runtimeId) {
                    retired = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard retired else { return }
        case .absent:
            break
        }

        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/openfish/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let output = logs.appendingPathComponent("embedded-host.log")
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        guard let log = try? FileHandle(forWritingTo: output) else { return }
        _ = try? log.seekToEnd()

        let child = Process()
        child.executableURL = node
        var arguments = [host.path, "--profile", "x", "--port", "3080", "--no-open"]
        if let trustedHost = trustedBonjourHost() {
            arguments.append(contentsOf: ["--trusted-host", trustedHost])
        }
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(runtime.appendingPathComponent("node/bin").path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["OPENFISH_EMBEDDED_RUNTIME_ID"] = managedRuntimeId
        environment["OPENFISH_EMBEDDED_RUNTIME_ROOT"] = runtime.path
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        do {
            try child.run()
            process = child
        } catch {
            try? log.write(contentsOf: Data("Open Fish could not start its embedded Host: \(error)\n".utf8))
        }
    }

    private static func trustedBonjourHost() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let hostname = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return nil }
        return hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
    }

    private static func localHostState(expectedRuntimeId: String) -> LocalHostState {
        guard let url = URL(string: "http://127.0.0.1:3080/x-native/v2/health") else { return .absent }
        let request = URLRequest(url: url, timeoutInterval: 0.35)
        let completed = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable { var health: Health? }
        let result = ResultBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                result.health = try? JSONDecoder().decode(Health.self, from: data)
            }
            completed.signal()
        }.resume()
        _ = completed.wait(timeout: .now() + 0.4)
        guard let health = result.health,
              health.ok,
              health.product == "opencodex",
              health.protocolVersion == "v2",
              health.host == "dsh",
              health.surface == "native" else { return .absent }
        guard let actual = health.embeddedRuntimeId, !actual.isEmpty else { return .unmanaged }
        if actual == expectedRuntimeId { return .compatible }
        guard let pid = health.embeddedProcessId, pid > 1 else { return .unmanaged }
        return .stale(pid: pid)
    }
}
